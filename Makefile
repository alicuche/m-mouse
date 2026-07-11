APP_NAME := mMouse
BUNDLE := $(APP_NAME).app
BUILD_DIR := .build
RELEASE_BIN := $(BUILD_DIR)/release/$(APP_NAME)
DEBUG_BIN := $(BUILD_DIR)/debug/$(APP_NAME)
BUNDLE_DIR := $(BUILD_DIR)/$(BUNDLE)
INFO_PLIST := Resources/Info.plist
BUNDLE_ID := com.alicuche.mMouse

# Signing identity: prefer stable self-signed cert "mMouse Signing".
# Fall back to ad-hoc ("-") if cert not present.
# `find-certificate` is used instead of `find-identity -v` because the latter
# rejects self-signed identities even when codesign itself accepts them.
SIGN_NAME := mMouse Signing
SIGN_IDENTITY := $(shell security find-certificate -c "$(SIGN_NAME)" >/dev/null 2>&1 && echo "$(SIGN_NAME)" || echo "-")

.PHONY: all build debug bundle bundle-debug install run clean setup-cert sign-info tcc-reset reinstall

all: bundle

build:
	swift build -c release

debug:
	swift build

bundle: build
	@echo "Assembling $(BUNDLE)..."
	@rm -rf $(BUNDLE_DIR)
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	@mkdir -p $(BUNDLE_DIR)/Contents/Resources
	@cp $(RELEASE_BIN) $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	@cp $(INFO_PLIST) $(BUNDLE_DIR)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	@cp Resources/MenuIcon.png $(BUNDLE_DIR)/Contents/Resources/MenuIcon.png
	@cp Resources/MenuIcon@2x.png $(BUNDLE_DIR)/Contents/Resources/MenuIcon@2x.png
	@echo "Signing with identity: \"$(SIGN_IDENTITY)\""
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" --options runtime $(BUNDLE_DIR) 2>/dev/null \
		|| (echo "⚠  hardened runtime signing failed — falling back to plain sign" && \
			codesign --force --deep --sign "$(SIGN_IDENTITY)" $(BUNDLE_DIR))
	@codesign --verify --verbose $(BUNDLE_DIR) > /dev/null 2>&1 || (echo "codesign verify FAILED"; exit 1)
	@echo "Bundle ready: $(BUNDLE_DIR)"
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo ""; \
		echo "⚠  Signed with ad-hoc identity. TCC permission may reset after rebuilds."; \
		echo "   Run 'make setup-cert' once to create a stable signing identity."; \
	fi

bundle-debug: debug
	@rm -rf $(BUNDLE_DIR)
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS $(BUNDLE_DIR)/Contents/Resources
	@cp $(DEBUG_BIN) $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	@cp $(INFO_PLIST) $(BUNDLE_DIR)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	@cp Resources/MenuIcon.png $(BUNDLE_DIR)/Contents/Resources/MenuIcon.png
	@cp Resources/MenuIcon@2x.png $(BUNDLE_DIR)/Contents/Resources/MenuIcon@2x.png
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" $(BUNDLE_DIR)
	@echo "Bundle (debug) ready: $(BUNDLE_DIR)"

install: bundle
	@echo "Installing to /Applications..."
	@if pgrep -f "/Applications/$(BUNDLE)/Contents/MacOS/$(APP_NAME)" > /dev/null; then \
		echo "Quitting running instance..."; \
		pkill -f "/Applications/$(BUNDLE)/Contents/MacOS/$(APP_NAME)" || true; \
		sleep 1; \
	fi
	@rm -rf /Applications/$(BUNDLE)
	@cp -R $(BUNDLE_DIR) /Applications/$(BUNDLE)
	@echo "Installed: /Applications/$(BUNDLE)"
	@echo "Launch:    open /Applications/$(BUNDLE)"

reinstall: tcc-reset install
	@echo "→ Now open /Applications/$(BUNDLE) and grant Accessibility when prompted."

run: bundle
	@open $(BUNDLE_DIR)

clean:
	@rm -rf $(BUILD_DIR)
	@swift package clean

setup-cert:
	@./scripts/setup-signing-cert.sh

sign-info:
	@echo "=== Stable cert in keychain ==="
	@if security find-certificate -c "$(SIGN_NAME)" >/dev/null 2>&1; then \
		echo "  ✓ '$(SIGN_NAME)' present (self-signed; usable by codesign)"; \
	else \
		echo "  ✗ not found — run 'make setup-cert'"; \
	fi
	@echo ""
	@echo "=== Build dir bundle ==="
	@if [ -d $(BUNDLE_DIR) ]; then \
		codesign -dvv $(BUNDLE_DIR) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature|CDHash"; \
	else echo "  (no bundle — run 'make bundle')"; fi
	@echo ""
	@echo "=== Installed bundle ==="
	@if [ -d /Applications/$(BUNDLE) ]; then \
		codesign -dvv /Applications/$(BUNDLE) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature|CDHash"; \
	else echo "  (not installed)"; fi

tcc-reset:
	@echo "Resetting TCC Accessibility grant for $(BUNDLE_ID)..."
	@if tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null; then \
		echo "✓ Reset done — next launch will prompt for permission again."; \
	else \
		echo "ℹ  No TCC entry to reset (already clean). Just install + grant fresh."; \
	fi
