# mMouse

Điều khiển con trỏ chuột bằng bàn phím trên macOS. Mục tiêu: bỏ chuột càng nhiều càng tốt.

## Tính năng

- **Activation sequence**: nhấn `Cmd + J + J` (J 2 lần trong 500ms) để bật/tắt mMouse mode
- **Di chuyển**: `h` `j` `k` `l` (vim style) — trái / xuống / lên / phải
- **Click** *(hardcoded, không config được)*:
  - `Enter` → left click
  - `Enter × 2` (2 lần liên tiếp trong 400ms) → double click
  - `Shift + Enter` → right click
- **🔒 Full keyboard lockdown** khi active: mọi phím không phải movement / Enter / activation combo đều bị consume — không leak shortcut sang app khác
- **Speed**: 1 số nguyên 1..10 (1=chậm, 10=nhanh)
- **Hot-reload** config khi sửa `~/.mMouse.json`
- **Multi-monitor**: clamp con trỏ trong display đang dùng
- Menu bar app (không hiện trong Dock)

## Build

```bash
make setup-cert   # CHẠY 1 LẦN: tạo stable signing cert (xem mục dưới)
make bundle       # build release + đóng gói .app
make install      # copy vào /Applications/ (quit instance đang chạy)
make run          # build và mở app từ .build/
```

Yêu cầu: Xcode Command Line Tools (Swift 5.9+), `openssl` (có sẵn macOS), và macOS 13+.

## Quy trình setup chuẩn (làm 1 lần)

```bash
make setup-cert   # tạo cert "mMouse Signing" trong login keychain
make install      # build + cài vào /Applications
open /Applications/mMouse.app
```

Lần đầu chạy:
1. App hiện alert yêu cầu Accessibility → bấm **Open System Settings**.
2. Bật toggle cho `mMouse` trong **Privacy & Security → Accessibility**.
3. App **tự relaunch** ngay khi detect được permission → tap hoạt động.

> 🔑 **Vì sao cần stable cert?**
>
> macOS TCC (cơ chế quản lý quyền) gắn permission với **code identity** của binary. Ad-hoc signed app (`codesign --sign -`) tạo identity mới mỗi lần codesign → grant cũ vô hiệu → user phải grant lại mỗi rebuild.
>
> Stable self-signed cert (`make setup-cert`) tạo identity ổn định → grant 1 lần, dùng mãi.

## Sử dụng

| Hành động | Phím |
|---|---|
| **Bật mMouse** | `Cmd + J + J` |
| **Tắt mMouse** (thủ công) | `Cmd + J + J` hoặc `Esc` |
| Lên | `k` |
| Xuống | `j` |
| Trái | `h` |
| Phải | `l` |
| Left click | `Enter` → **tự thoát mode** sau 400ms |
| Double click | `Enter × 2` → **tự thoát mode** sau 400ms |
| Right click | `Shift + Enter` → **tự thoát mode** sau 400ms |
| **Panic exit** (cứu khi stuck) | `Esc` |

> 💡 **Auto-deactivate sau click**: sau khi click xong, mMouse tự thoát active mode → mày có thể gõ phím bình thường ngay. Nếu muốn ở lại để click nhiều lần, di chuyển thêm trước khi click (movement keys huỷ auto-deactivate).

Menu bar:
- `⚪ mM` — inactive (phím gõ bình thường)
- `🟢 mM` — active (toàn bộ phím khác bị khoá; chỉ phím trên có tác dụng)

### Tại sao lockdown toàn bộ phím?

Để **chống conflict** với shortcut của app khác. Vd: khi active mà mày vô tình gõ `w`, nếu không lock thì Cmd+W (nếu đang giữ Cmd) sẽ đóng tab. Lockdown đảm bảo chế độ active là **pure mouse mode** — không có gì khác lọt qua.

Muốn gõ chữ → deactivate trước (`Cmd+J+J`).

## Config

File: `~/.mMouse.json` (tự tạo lần đầu).

```json
{
  "activationCombo": {
    "modifier": "command",
    "key": "j",
    "repeatCount": 2,
    "windowMs": 500
  },
  "keys": {
    "up": "k",
    "down": "j",
    "left": "h",
    "right": "l"
  },
  "speed": 5
}
```

### Tham số

| Field | Ý nghĩa | Giá trị |
|---|---|---|
| `activationCombo.modifier` | Modifier giữ khi nhập combo. Hỗ trợ **combo modifier** bằng `+` (vd: `"command+shift"`) | `command` \| `control` \| `option` \| `shift` \| `none` \| hoặc combo `"a+b"` |
| `activationCombo.key` | Phím chính của combo | `a-z`, `0-9`, hoặc tên đặc biệt (`space`, `tab`, `f1`...`f12`, `escape`,...) |
| `activationCombo.repeatCount` | Số lần nhấn phím chính (vd: 2 = double-tap) | int ≥ 1 |
| `activationCombo.windowMs` | Khoảng thời gian tối đa giữa các lần nhấn | ms |
| `keys.up/down/left/right` | Phím di chuyển | tên phím (vd: `"up"`, `"down"`, `"k"`, `"j"`...) |
| `speed` | Tốc độ di chuyển | **int 1..10** (xem bảng dưới) |

### Speed cheat sheet (quadratic curve + acceleration)

| Speed | Tap (~50ms) | Hold 1s | Use case |
|---|---|---|---|
| 1 | ~1 px | ~80 px | Pixel-perfect precision |
| 3 (mặc định) | ~4 px | ~340 px | Text-cursor-like, precise UI |
| 5 | ~12 px | ~940 px | General use |
| 7 | ~25 px | ~1800 px | Big screens |
| 10 | ~50 px | ~3750 px | Fastest crossing |

**Acceleration**: tap nhanh = di chuyển ít (0.3×), giữ phím lâu = ramp lên 2.5× sau 400ms. Tự nhiên như mouse thật — tap để chỉnh chính xác, hold để di chuyển dài.

Sửa file → save → mMouse tự reload, không cần restart.

### Ví dụ: activate bằng `Cmd + Shift + →` (nhấn 1 lần)

```json
"activationCombo": {
  "modifier": "command+shift",
  "key": "right",
  "repeatCount": 1,
  "windowMs": 500
}
```

> ⚠️ `repeatCount: 1` nghĩa là **nhấn 1 lần là kích hoạt ngay**. An toàn hơn dùng `repeatCount: 2` (double-tap) nếu combo trùng với shortcut app khác.

### Các ví dụ combo khác

```json
"modifier": "command"           // 1 modifier
"modifier": "command+shift"     // 2 modifier
"modifier": "ctrl+option+shift" // 3 modifier
"modifier": "none"              // không cần modifier (rủi ro cao)
```

> Click keys (Enter / Shift+Enter) **hardcoded** — không có trong config.

## Menu bar items

- **Activate / Deactivate** — toggle bằng tay
- **Open Config** — mở file `~/.mMouse.json`
- **Reload Config** — force reload
- **Reveal in Finder** — chỉ vị trí file
- **Quit mMouse**

## Trade-off cần biết

- Lần nhấn `Cmd+J` đầu trong sequence **luôn bị suppress**. Nếu không có J thứ 2 trong 500ms, keypress đầu đó mất (không pass tới app).
- Khi active: **mọi phím** đều bị khoá ngoài h/j/k/l/Enter/Shift+Enter/activation. Cmd+Tab, Cmd+Q, gõ chữ — tất cả bị consume.

## Troubleshooting

### Lần nào mở app cũng prompt grant permission lại

Đây là vấn đề ad-hoc TCC. Fix triệt để:

```bash
make setup-cert        # tạo stable cert (1 lần duy nhất)
make tcc-reset         # clear toàn bộ TCC entry cũ của mMouse
make install           # rebuild + reinstall với cert mới
open /Applications/mMouse.app
# Grant permission lại — lần này sẽ persist
```

Một-liner cho recovery: `make reinstall` (= `tcc-reset` + `install`).

Kiểm tra signing identity hiện tại:
```bash
make sign-info
```
Output mong đợi: `Authority=mMouse Signing` (không phải `Signature=adhoc`).

### Tap bị disable bởi secure input
Khi nhập password sudo trong Terminal, macOS auto-disable tap. mMouse tự re-enable khi thoát secure input.

### Tap chết sau sleep/wake
mMouse có `NSWorkspace.didWakeNotification` listener tự recreate tap. Vẫn không hoạt động → menu bar → **Quit** → mở lại.

### Bị stuck trong active mode (lỡ activate mà không gõ được gì)
Nhấn `Cmd+J+J` để deactivate. Hoặc click menu bar `🟢 mM` → **Deactivate** (chuột vật lý vẫn dùng được).

### Sau khi grant permission, alert vẫn hiện
App sẽ tự relaunch khi detect permission. Nếu vẫn loop:
```bash
make tcc-reset
open /Applications/mMouse.app   # bắt đầu lại fresh
```

## Architecture

```
AppDelegate (@main)
  ├── ConfigManager       — load/save/watch ~/.mMouse.json
  ├── MouseController     — CGEvent post, sub-pixel accumulator, multi-monitor clamp
  ├── EventTapManager     — CGEventTap + sequence state machine + lockdown
  └── MenuBarManager      — NSStatusItem
```

CGEventTap: `.cgSessionEventTap` + `.headInsertEventTap` + `.defaultTap`. Không sandboxed (bắt buộc cho `.defaultTap` consume).
