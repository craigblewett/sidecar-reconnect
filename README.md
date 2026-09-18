# SidecarReconnect

A menu bar app that gets a wedged macOS **Sidecar** connection back, without
restarting the iPad or the Mac.

The problem it solves: the Mac sleeps with the iPad attached, and in the morning
mirroring doesn't come back. The iPad may still be listed under Screen Mirroring
but picking it does nothing — or it isn't listed at all, even though it's sitting
right there on a USB-C cable. The usual fix is rebooting the iPad, which is a
slow way to start a day.

It sits next to the Screen Mirroring icon and shows at a glance whether the iPad
is connected. Most mornings you shouldn't have to click it at all: it notices the
Mac waking and restores the connection on its own.

## The menu

```
▣ Connected — Craig's iPad
─────────────────────────────────
Reconnect Now                  ⌘R
Bounce Connection
Disconnect
─────────────────────────────────
Reconnect Automatically After Wake  ✓
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
on rather than leaving you guessing.

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

Rung 2 is what actually recovers the ordinary post-wake case. For the first
minute or so after a wake the device list hasn't settled and connects fail with
"device not found"; disconnecting and retrying rides that out. In a measured run
the ladder recovered 52 seconds after wake, on rung 2.

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

## Install

Needs macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/craigblewett/sidecar-reconnect.git
cd sidecar-reconnect
./build.sh
```

That builds the app, installs it to `~/Applications`, puts the `sidecarctl` CLI in
`~/.local/bin`, and launches it. Then turn on **Open at Login** from the menu.

Building from source is the path to prefer. A prebuilt `SidecarReconnect.app` is
committed here for convenience, but it is **ad-hoc signed with no Team ID**, so a
copy downloaded from GitHub arrives quarantined and macOS will refuse to open it.
If you use it rather than building, clear the quarantine flag first:

```sh
xattr -dr com.apple.quarantine SidecarReconnect.app
```

It also only carries the `sidecarctl` CLI's sibling if you run `./build.sh`, and
it goes stale whenever the sources move ahead of it — `./build.sh` is a few
seconds and always matches the code you're looking at.

If more than one device shows up, pick your iPad under the **iPad** submenu;
with only one, it's chosen automatically.

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
the CLI uses.

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

## Uninstall

```sh
./uninstall.sh            # or --purge to drop settings and the log too
```

## License

MIT
