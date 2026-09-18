# Vendored from Side Screen

These files are taken unmodified from [Side Screen](https://github.com/tranvuongquocdat/SideScreen)
(MIT, Copyright © 2025 Side Screen), which is the engine that drives an Android
tablet as a second display: it creates a virtual display with the private
`CGVirtualDisplay` API, captures it with ScreenCaptureKit, encodes with
VideoToolbox, and serves the stream over USB (adb reverse) or WiFi.

`LICENSE` is their MIT licence and must stay with these files.

## What's here, and why only this

The dependency closure needed to drive a virtual display and stream it — 12
files, ~2,840 lines. Their UI, settings window, daemon management and QR
rendering are deliberately not here; this app has its own menu.

| File | Role |
| --- | --- |
| `VirtualDisplayManager.swift` | creates/destroys the virtual display |
| `ScreenCapture.swift` | ScreenCaptureKit capture of that display |
| `VideoEncoder.swift` | VideoToolbox H.264/H.265 encode |
| `StreamingServer.swift` | the wire protocol and socket server |
| `HandshakeCodec.swift`, `PairingCode.swift`, `PairingURL.swift`, `WirelessAuth.swift` | pairing and auth |
| `PairedDeviceStore.swift`, `LANAddressResolver.swift`, `ConnectionMode.swift`, `CodecLimits.swift` | supporting types |
| `CGVirtualDisplayBridge.h`, `module.modulemap` | the private `CGVirtualDisplay` declarations |

## Keeping them unmodified

They are copied verbatim so they can be diffed against upstream and refreshed.
The one symbol they need from outside — `debugLog` — is supplied by
`../VendorSupport.swift` rather than by editing these files.

Upstream is actively developed, so this copy will drift. To refresh, re-copy the
files above and re-check the closure still compiles.

## Wire protocol

Unchanged from upstream, so Side Screen's own released Android APK works against
this host. Changing the protocol means building and distributing an APK too.

## Build note

`ScreenCapture.swift` uses the legacy `CGDisplayStream` path as a fallback, which
the macOS 26 SDK marks unavailable. It compiles only with a deployment target of
macOS 13 — `build.sh` passes `-target <arch>-apple-macosx13.0` for this reason.
