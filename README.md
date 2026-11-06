# ExpandDisplay

Use an Android phone (built for the Galaxy Z Fold series) as a **wireless external display for a Mac**.

- **macOS app** (Swift, menu bar app): creates a **virtual display** at the phone's window resolution (private `CGVirtualDisplay` API), captures it with **ScreenCaptureKit**, encodes it with **VideoToolbox H.264 in low-latency mode**, and streams it over TCP.
- **Android app** (Kotlin + Jetpack Compose): finds the Mac automatically with **mDNS/Bonjour (NSD)**, decodes with **MediaCodec in low-latency mode** straight to a full-screen `SurfaceView`, and turns **touches into left clicks** (and drags).

```
Android (Compose)                         macOS (menu bar app)
 ┌──────────────┐  CONFIG w×h, dpi  ──▶  ┌───────────────────────────┐
 │ SurfaceView  │                         │ CGVirtualDisplay (w×h)    │
 │ MediaCodec   │  ◀── H.264 Annex-B ──   │ ScreenCaptureKit → VT H264│
 │ touch → x,y  │  TOUCH (0..1)     ──▶   │ CGEvent left click/drag   │
 └──────────────┘                         └───────────────────────────┘
          ◀────── Bonjour _expanddisplay._tcp, TCP 47800 ──────▶
```

## How resolution works
The Android app sends its **full-screen window size in pixels** when it connects, and again whenever that size changes (folding/unfolding, rotation). The Mac then creates a virtual display at that size, or changes the resolution of the existing one.
- **HiDPI (Retina)** mode is on by default. For example, a 2176×1812 px window shows up on macOS as 1088×906 pt rendered at 2×, so text is sharp. Turn HiDPI off in the menu bar for more screen space with smaller text.

## Low latency
- Hardware H.264 with `EnableLowLatencyRateControl`, no B-frames, `MaxFrameDelayCount = 0`
- At most 2 frames in flight on the Mac side. When Wi-Fi slows down, the Mac skips frames before encoding them instead of letting latency build up.
- Android: `KEY_LOW_LATENCY`, Qualcomm's low-latency vendor key, and each frame renders as soon as it is decoded (`releaseOutputBuffer(idx, true)`)
- `TCP_NODELAY` on both sides, DSCP EF traffic class
- Bitrate (10–80 Mbps) and frame rate (30/60/120) can be changed from the Mac menu bar.

## Touch input (TouchLink v1)
Touch is sent with a separate protocol, **TouchLink v1** (TCP 47100, Bonjour `_touchlink._tcp`, little-endian, 20-byte header).
- The phone sends up to 10 contacts as `TOUCH_FRAME`s (coordinates 0–65535, ≤120 Hz, 100 ms STATIONARY keep-alive).
- The Mac recognizes gestures and injects CGEvents:
  | Input | Pointer mode (default) | Scroll mode |
  |---|---|---|
  | Tap / repeated taps | Click / double / triple click | Same |
  | One-finger drag | Left drag | Continuous scroll |
  | Long press (500 ms) | Right click (drag allowed) | Same |
  | Two-finger pan | Continuous scroll | Same |
- **Pairing**: over Wi-Fi, enter the 6-digit code shown in the Mac menu bar on the phone once (3 wrong tries locks that address for 1 minute). Only LAN peers are accepted.
- **USB**: TouchLink messages travel inside the USB accessory link (`0x04`/`0x84`), so no adb is needed. A physical connection skips pairing.
- Not implemented yet: per-device keys + PSK TLS, pinch/rotate (no public CGEvent API), web/iOS clients.

## Network: "phone on mobile data, Mac on Wi-Fi"?
Mobile data and home Wi-Fi are different networks, and the Mac sits behind the router's NAT. The phone can't reach it directly without a separate relay server, and a relay would add too much delay for live screen sharing. So the app uses **automatic discovery on the same network**.

**Tip: turn on the phone's hotspot and connect the Mac to it.** Both devices are then on the same network, discovery works, and the phone keeps using mobile data. Mirroring traffic stays inside the hotspot, so it does not use your data plan.

If discovery doesn't work (for example on a network that blocks multicast), type the Mac's IP into **Connect directly** in the app.

## Install
Download from [Releases](../../releases):
- `ExpandDisplay.apk`: install on the phone
- `ExpandDisplay.dmg`: drag into Applications on the Mac (macOS 13 Ventura or later)

### First run on the Mac
1. The app isn't signed with an Apple Developer ID. The first time, right-click it in Finder → **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/ExpandDisplay.app
   ```
2. System Settings → Privacy & Security:
   - **Screen Recording**: allow ExpandDisplay (required for streaming; restart the app after allowing it)
   - **Accessibility**: allow ExpandDisplay (required for touch → click)
   - If macOS asks about **local network** or incoming connections, allow them
3. A ▭ icon appears in the menu bar. Open the app on the phone and it connects automatically.

> Because the app is ad-hoc signed, macOS may ask for the permissions again after an update. If it does, remove ExpandDisplay from the list in System Settings and add it back.

### Using it
- Open the app on the phone → it connects automatically to the Mac it finds → full-screen display
- Tap = left click, double tap = double click, drag = drag with the left button held
- Back gesture: disconnect (this turns off auto-connect; turn it back on with the switch on the screen)

## Build
- Android: `cd android && ./gradlew assembleRelease` (JDK 17, Android SDK 35)
- macOS: `cd macos && ./scripts/build-dmg.sh` (Xcode 15+/Swift 5.9+)
- CI: `.github/workflows/build.yml` builds on every push. Pushing a `v*` tag, or running the workflow manually with `release_tag`, uploads the APK and DMG to Releases.

> APK signing: if the repository Secrets include `KEYSTORE_BASE64` (a base64-encoded .jks), `KEYSTORE_PASSWORD`, `KEY_ALIAS` and `KEY_PASSWORD`, the APK is signed with that key, so new versions install as updates. Without them, each build is signed with a temporary key, and you must uninstall the old app before installing a new version.

## Protocol
`[type u8][len u32 BE][payload]`

| dir | type | payload |
|---|---|---|
| A→M | 0x01 CONFIG | i32 w, i32 h, i32 dpi, utf8 name |
| A→M | 0x02 TOUCH | u8 action(0 down/1 move/2 up), f32 x, f32 y (0..1) |
| A→M | 0x03 KEYFRAME_REQ | – |
| A→M | 0x04 TOUCHLINK | raw TouchLink v1 message (USB tunnel) |
| M→A | 0x81 VIDEO_CONFIG | i32 w, i32 h, u32 displayID |
| M→A | 0x82 FRAME | u8 flags(bit0 key), i64 ptsUs, H.264 Annex-B |
| M→A | 0x83 STATUS | utf8 |
| M→A | 0x84 TOUCHLINK | raw TouchLink v1 message (USB tunnel) |
