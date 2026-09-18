# SidecarReconnect

One menu bar app for the extra screens on your desk: it keeps a **Sidecar** iPad
connected, drives an **Android tablet** as a second display, and arranges every
screen the Mac has.

**The iPad half.** The Mac sleeps with the iPad attached, and in the morning
mirroring doesn't come back. The iPad may still be listed under Screen Mirroring
but picking it does nothing — or it isn't listed at all, even though it's sitting
right there on a USB-C cable. The usual fix is rebooting the iPad, which is a slow
way to start a day. This closes the session properly before sleep so it doesn't
wedge in the first place, and climbs a ladder of fixes when it does.

**The Android half.** macOS has no Sidecar for Android, so this builds one: a
virtual display, captured and encoded on the Mac, streamed to the
[Side Screen](https://github.com/tranvuongquocdat/SideScreen) app on the tablet,
with touch coming back the other way. The streaming engine is Side Screen's own,
vendored under `Sources/Vendor/` — see [the note there](Sources/Vendor/SideScreen/README.md).

**Arranging them.** Sidecar iPad, Android tablet, HDMI monitor and the built-in
screen all live in one coordinate space, so they're all arranged from one window
— drag them around, edges snap together.

## The menu

```
Connected — iPad
─────────────────────────────────
Reconnect Now                  ⌘R
Bounce Connection
Disconnect
─────────────────────────────────
Sharing to Android tablet
  57 fps · 2.6 Mbps
Stop Sharing to Android Tablet
Arrange Displays                  ▸   each screen, or "Arrange Visually…"
Tablet Resolution                 ▸   1920×1200 … 1024×640, and Retina
Tablet Quality                    ▸   24/30/45/60 fps, 8–30 Mbps
─────────────────────────────────
Reconnect Automatically After Wake  ✓
Disconnect Cleanly Before Sleep     ✓
Connection                        ▸   Wired (USB-C) ✓ / Wireless / Automatic
Extra Fixes                       ▸   Bounce Bluetooth / Control Center fallback
Show Notifications                ✓
Open at Login                     ✓
─────────────────────────────────
Recent Activity                   ▸   the last 15 log lines, and the log file
Copy Diagnostics
─────────────────────────────────
Quit
```

The icon pulses while it's working, and the header line tells you which step it's
on rather than leaving you guessing. It's a screen with a reconnect arrow —
deliberately not `rectangle.on.rectangle`, which is what macOS's own Screen
Mirroring icon uses, and which sat next to it looking identical.

## What "Reconnect" actually does

It climbs a ladder of increasingly disruptive fixes and stops at the first rung
that works, so the ordinary case costs a second or two and only a genuinely stuck
machine pays for the noisy steps:

| Rung | Action | Cost |
| --- | --- | --- |
| 1 | Connect | free — usually enough |
| 2 | Disconnect, then connect | a second |
| 3 | Restart the Sidecar / AirPlay / device-discovery agents | a few seconds — but see below |
| 4 | Bounce Bluetooth | **off by default** — drops BT keyboards and mice |
| 5 | Click through Control Center | **off by default** — needs Accessibility |

Most of the time no rung should be needed at all. **Disconnect Cleanly Before
Sleep** (on by default) closes the session when the Mac sleeps rather than
letting sleep sever it, and that turns out to matter a lot: a severed session
leaves the Mac unable to find the iPad for the best part of a minute afterwards.
Measured over one sleep/wake each way — six failed attempts and 52 seconds to
recover via rung 2 when the session was severed, versus reconnecting instantly on
rung 1's first attempt when it was closed properly.

When something does go wrong, rung 2 is what recovers the ordinary post-wake
case.

Rung 3 is close to decorative on a stock Mac: System Integrity Protection refuses
`launchctl kickstart` for every agent it finds, so it reports what it couldn't do
and moves on. It's kept because the discovery is still useful diagnostically and
because SIP-disabled machines exist.

Auto-reconnect only fires **if Sidecar was connected before the Mac slept**, so it
restores what you had rather than barging in when you disconnected on purpose.

## What it can't fix

There is a second, nastier failure where the iPad is reachable in every way that
can be measured — USB enumerates, IP over the cable pings, Bonjour resolves,
Rapport pairs, the data link reaches ready in about 34ms — and then the Mac sends
the video negotiation offer and the iPad never answers. The Mac sends eleven
Sidecar events and receives none back. The iPad's Sidecar *receiver* is hung.

No rung in this ladder can fix that, because every rung acts on the Mac.
Replugging the cable, killing the Sidecar relay, toggling Handoff on the iPad and
forcing each of the four transports were all tried against a live instance of it;
only restarting the iPad cleared it.

So the app detects it instead. After a few consecutive `-201` timeouts it stops
climbing and says the iPad answered but never started the screen session, rather
than spending two minutes on rungs that cannot work — each failed attempt also
raises a system alert from macOS, so a full pointless climb used to stack over a
dozen dialogs. If you see that message, restart the iPad; it's an iPadOS bug, not
something this app can route around.

## An Android tablet as a second display

macOS offers nothing here, so the whole chain is ours: a virtual display created
with the private `CGVirtualDisplay` API, captured with ScreenCaptureKit, encoded
with VideoToolbox, and served over a socket. Touch comes back and is injected as
`CGEvent`s. Where Sidecar asks macOS to do everything and we just say "connect",
here every layer is the app's.

The tablet runs Side Screen's own released APK — the wire protocol is unchanged,
so no modified build is needed. Install it from
[their releases](https://github.com/tranvuongquocdat/SideScreen/releases), then:

1. **Share Screen to Android Tablet** from the menu. Grant **Screen Recording**
   when macOS asks, and **Accessibility** if you want touch to work.
2. The menu shows an address and a one-time code. In the tablet app, choose the
   **Wireless** tab → *No camera? Enter code instead*, and type them in.
3. After that the tablet holds a token and reconnects with its **Reconnect**
   button; no code needed again.

Sharing restores itself when the app launches, so with **Open at Login** on, the
Mac side needs nothing from you.

### Getting it looking right

Two settings decide almost everything, and they pull against each other:

| | What it does |
| --- | --- |
| **Tablet Resolution** | The size of the desktop macOS draws. *Smaller means everything looks bigger* — this is the one to reach for when text is too small, not the bitrate |
| **Retina** | Renders at double and scales down. Sharper text, four times the pixels for the tablet to decode |
| **Frame rate** | 24–60. Higher is smoother, and costs the tablet proportionally |
| **Bitrate** | A ceiling, not a target. Ordinary desktop use sits at 1–5 Mbps whatever it's set to |

On a modest tablet you can have crisp text or smooth motion, not both: Retina at
30fps, or no Retina at 60fps. The menu shows live fps and Mbps so the trade is
visible rather than guessed at. The Mac is rarely the constraint — if frame age
stays low and nothing is dropped, what's left is the tablet's decoder and the
network.

### Over a cable

`adb reverse` is the lowest-latency path but needs USB Debugging, which not every
tablet exposes — a Huawei MatePad on HarmonyOS has no Developer options at all.
**USB tethering** gives the same cable without any of that: it puts the Mac on a
small private network that exists only along the wire. The app spots that
interface and offers its address for pairing, marked *(over USB)*.

## Install

Needs macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/craigblewett/sidecar-reconnect.git
cd sidecar-reconnect
./build.sh
```

That builds the app, installs it to `~/Applications`, puts the `sidecarctl` CLI in
`~/.local/bin`, and launches it. Then turn on **Open at Login** from the menu.

### Getting a build without building it

Every push to `main` is built by CI, and a tagged commit becomes a release with
`SidecarReconnect.zip` and `sidecarctl` attached. Nothing is committed to the
repository, so there is no stale binary and nothing to resolve when branches
merge.

CI builds are **ad-hoc signed** — the signing certificate lives on a keychain,
not in a repository — so a downloaded copy arrives quarantined:

```sh
xattr -dr com.apple.quarantine SidecarReconnect.app
```

Building it yourself avoids that entirely: `build.sh` signs with whatever
identity your keychain has, and a locally built app is never quarantined. It's
also a few seconds, and always matches the code in front of you.

## The CLI

Same engine, for hotkeys and scripts — bind `sidecarctl fix` to a Raycast, Alfred,
or Shortcuts hotkey if you want a keystroke for it:

```sh
sidecarctl fix          # the full ladder, same as "Reconnect Now"
sidecarctl status       # exit 0 connected, 1 not, 3 undeterminable
sidecarctl list
sidecarctl bounce
sidecarctl dump         # the private API on this macOS
```

It shares settings with the app, so the transport you pick in the menu is the one
the CLI uses. Sidecar only — the Android display needs a virtual display and a
video pipeline, which belong in the app rather than in a one-shot command.

## How it works

`SidecarCore` is a private framework. `SidecarDisplayManager` gives us
`sharedManager`, `devices`, `connectToDevice:completion:`,
`connectToDevice:withConfig:completion:` and `disconnectFromDevice:completion:` —
which is how the app connects without scraping any UI. For a cabled iPad it uses
`SidecarDisplayConfig.setTransport(2)`, the wired transport, so reconnecting
doesn't depend on Wi-Fi or Bluetooth being healthy after a wake.

Wake detection is `NSWorkspace.didWakeNotification` and `screensDidWakeNotification`
inside the app itself, which is why there's no LaunchAgent to install.

## When a macOS update breaks it

`SidecarCore` is private and Apple will reshape it eventually. The app is built to
say so rather than fail silently:

- **Copy Diagnostics** puts the real method list of `SidecarDisplayManager` and
  friends on your clipboard, alongside your settings and the recent log. Compare
  it against the selectors above — a rename is usually a one-line fix in
  `Sources/Shared/SidecarCore.swift`.
- Rung 3 never hard-codes launchd labels. It discovers them from `launchctl list`
  and restarts whatever `com.apple.*` agent matches, so Apple renaming one doesn't
  break it.
- Connection state comes from `SidecarDisplayManager.connectedDevices`, with the
  older per-device selectors kept as a fallback. If no method works, the menu says
  "state unknown" instead of claiming "disconnected", and the ladder falls back to
  connect attempts, which are idempotent.

## Caveats

- **Tested on exactly one machine.** Built and verified end to end on macOS 26.2
  (Apple silicon) against a cabled iPad: connect, disconnect, bounce, and an
  unattended recovery after a real sleep/wake. Everything else is untested — other
  macOS versions especially, since this leans on private API.
- **Private API.** Unsupported by Apple. Fine for your own Mac, not something to
  build on.
- **`setTransport(2)` is the wired transport**, confirmed by the relay reporting
  `ForceUSB` on a connection that succeeded over the cable. The rest of the map:
  0 automatic, 1 AWDL, 3 infrastructure Wi-Fi.
- **Ad-hoc signed.** Every rebuild changes the app's signing identity, so macOS
  will re-ask for Accessibility permission if you use the Control Center fallback.
- **Rung 4 drops Bluetooth** for a few seconds. If your keyboard and trackpad are
  Bluetooth, that's a real interruption — which is why it's off by default.
- **Two private APIs.** `SidecarCore` for the iPad, `CGVirtualDisplay` for the
  Android display. Either can change in any macOS release; both are probed
  rather than assumed, and "Copy Diagnostics" shows what's actually present.
- **Two-finger gestures aren't implemented.** Touch from the tablet is one
  finger: move, click and drag. Scroll and pinch are swallowed rather than
  misread as stray clicks.
- **The tablet needs one tap** on Reconnect. Side Screen's app only auto-connects
  from that button, and changing it would mean shipping a modified APK.
- **Screen Recording and Accessibility** are required for the Android display,
  and macOS keys those grants to the code signature. `build.sh` signs with a real
  identity when the keychain has one, so they survive rebuilds; with an ad-hoc
  signature they'd need re-granting after every build.

## Uninstall

```sh
./uninstall.sh            # or --purge to drop settings and the log too
```

## License

MIT
