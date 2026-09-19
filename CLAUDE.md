# SidecarReconnect

A macOS menu bar app with two halves that share a menu, a log and nothing else.

**Sidecar** — recovers a wedged connection to an iPad, typically after the Mac
wakes and the iPad, still on its USB-C cable, won't re-establish mirroring. macOS
does all the work here; the app only asks `SidecarCore` to connect.

**Android second display** — macOS offers no equivalent, so the app builds the
whole chain: virtual display, capture, encode, socket, and touch injected back.
The engine is vendored from Side Screen (MIT); `Sources/Display/` is our code
driving it.

The two share no machinery, and that's expected: for the iPad the system is the
implementation, for the tablet we are.

## Build and run

```sh
./build.sh          # builds the .app + CLI, installs to ~/Applications and ~/.local/bin, launches
./uninstall.sh      # removes both; --purge also drops settings and the log
```

Requires macOS 13+ and Xcode Command Line Tools. There is no Xcode project and no
SwiftPM manifest — `build.sh` calls `swiftc` directly on the source files. Adding
a file to `Sources/Shared/`, `Sources/App/`, `Sources/Display/` or
`Sources/Vendor/` picks it up automatically (they glob); adding a new target does
not.

Two build details that are not optional:

- `-target <arch>-apple-macosx13.0`. Without it swiftc targets the *build*
  machine, so a binary built on macOS 26 refuses to launch on 13 despite what
  Info.plist promises. The vendored `ScreenCapture.swift` also needs it: its
  `CGDisplayStream` fallback is unavailable above a 13.0 target in the macOS 26
  SDK.
- A real signing identity when the keychain has one. TCC keys Screen Recording
  and Accessibility to the signature, and an ad-hoc signature is just the
  cdhash — which changes every build, so each rebuild loses both permissions.

Two binaries are compiled from one set of sources:

- `Sources/Shared` + `Sources/Vendor` + `Sources/Display` + `Sources/App` → `SidecarReconnect.app`
- `Sources/Shared` + `Sources/CLI/main.swift` → `sidecarctl`

Both files are named `main.swift` deliberately — top-level code needs that name,
and they're compiled in separate `swiftc` invocations so they never collide.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/Shared/SidecarCore.swift` | Wrapper over the private SidecarCore framework. The only file that touches private API. |
| `Sources/Shared/Recovery.swift` | The reconnect ladder. Also holds the `shell()` helper. |
| `Sources/Shared/Preferences.swift` | UserDefaults in a suite shared by app and CLI. |
| `Sources/Shared/Log.swift` | File log + in-memory tail for the menu. |
| `Sources/App/main.swift` | NSStatusItem menu bar app, wake observers, menu construction. |
| `Sources/App/MenuBarIcon.swift` | The status item glyph, drawn rather than an SF Symbol. |
| `Sources/CLI/main.swift` | `sidecarctl`, same engine for hotkeys and scripts. Sidecar only. |
| `Sources/Display/AndroidDisplay.swift` | Orchestrates the vendored engine: display → capture → encode → serve. |
| `Sources/Display/TouchInjector.swift` | Tablet touches → `CGEvent`s. One finger only. |
| `Sources/Display/DisplayArrangement.swift` | Reads and sets where every screen sits. |
| `Sources/Display/ArrangementWindow.swift` | The drag-to-arrange window. |
| `Sources/Display/NetworkAddresses.swift` | Which address a tablet should dial, cable preferred. |
| `Sources/Vendor/SideScreen/` | Side Screen's streaming engine, verbatim. See its README. |
| `scripts/make-icon.swift` | Generates `Resources/AppIcon.icns`. |
| `scripts/*.applescript` | Control Center fallback, bundled into the app's Resources. |

`Sources/Display` and `Sources/Vendor` are compiled into the app only. The CLI
has no use for a video pipeline and shouldn't carry one.

## The private API

`SidecarCore` is undocumented and unsupported. `SidecarDisplayManager` provides
`sharedManager`, `devices`, `connectedDevices`, `connectToDevice:completion:`,
`connectToDevice:withConfig:completion:` and `disconnectFromDevice:completion:`.
Wired connections pass a `SidecarDisplayConfig` with `setTransport(2)`.

Verified on macOS 26.2 (25C56), 2026-09-18:

- Both connect selectors and `setTransport:` are present. `setTransport:` takes a
  signed 64-bit int and stores whatever you give it — it validates nothing, so
  **2 == wired is still unverified**; it needs a cabled iPad to confirm.
- `SidecarDevice` exposes *no* connection-state selector. The only candidate,
  `status`, is a bitfield (`0x1880306` idle, `0x80_0188_0306` after a failed
  connect), so a `!= 0` test reports a disconnected iPad as connected. Connection
  state now comes from `SidecarDisplayManager.connectedDevices`, which is the
  list macOS itself keeps; the old per-device probing stays as a fallback.
- A closure handed straight to one of the `objc_msgSend` typealiases as a
  trailing closure traps at runtime ("closure argument passed as @noescape to
  Objective-C has escaped"). Completion blocks must be bound to a local of
  explicit `@convention(block)` type first.

Three conventions exist because Apple can change all of this in any release, and
they should be preserved in new code:

1. **Probe, don't assume.** Selectors are checked with `responds(to:)` before use.
   Connection state is probed across several historical selector names and
   reported as `Bool?` — `nil` means "this macOS gave us no way to tell", which
   surfaces as "state unknown" in the UI rather than a fabricated "disconnected".
2. **Discover, don't hard-code.** Rung 3 finds launchd agents by grepping
   `launchctl list`, never by literal label, so a rename by Apple doesn't break
   it. The search is scoped to `com.apple.*`: this app's own bundle ID contains
   "sidecar", so an unscoped match makes rung 3 restart *itself* mid-ladder.
3. **Make breakage legible.** `Sidecar.dump()` prints the live method list of the
   private classes; it's surfaced as "Copy Diagnostics" in the menu and
   `sidecarctl dump` on the CLI. It is the first thing to run when something stops
   working after a system update.

`objc_msgSend` is fetched via `dlsym` because Swift won't call it directly and
`NSInvocation` is gone. It's needed for primitive arguments (`setTransport:`) and
the three-argument wired connect, which `perform(_:with:)` can't express.

## Threading

The ladder runs on a private serial queue; blocking on a semaphore there is
deliberate. All `progress` and `completion` callbacks are delivered back on the
main queue so the menu can update without hopping. `Recovery.shared` refuses to
run twice at once.

SidecarCore's own completion blocks do **not** arrive on the main queue, contrary
to what this file used to say: `sidecarctl connect` blocks the main thread on a
semaphore and still gets its completion, so nothing deadlocks. Don't rely on the
delivery queue either way — hop explicitly.

In the CLI there's no AppKit run loop, so `RunLoop.main.run(mode:before:)` is
spun to drain the main queue the completions land on.

## What actually goes wrong

Two distinct failures, told apart by the `SidecarErrorDomain` code, because they
need opposite responses. Both observed on macOS 26.2 with a cabled iPad.

**`-200` device not found — recoverable, Mac-side.** Seen after a wake when the
session was torn down by sleep rather than closed. Connects fail repeatedly and
then start working; rung 2 clears it, 52s and six failed attempts in a measured
run.

The cause is the teardown, not the wake. `Prefs.disconnectBeforeSleep` (on by
default) closes the session in `willSleep` instead, and in the equivalent run
afterwards the reconnect succeeded on rung 1's *first* attempt, immediately, with
no failures and so no system alerts. Both runs are n=1, but the mechanism matches
what the relay reports: a sleep-severed session leaves "Terminated with Active
Sessions" behind, a closed one doesn't.

The disconnect runs on the main thread inside the sleep window, so its timeout is
4s — skipping the tidy-up is better than delaying sleep.

**`-201` device timed out — usually just a locked iPad.** Sidecar will not start
a session on a locked device, and macOS reports the refusal as a timeout. The
link is healthy throughout: pairing succeeds, the data link reaches ready in
~34ms, the Mac sends `AVC negotiate offer`, and the iPad — being locked — never
answers. Eleven `com.apple.sidecar` events out, none back.

Controlled on one iPad seconds apart: locked → `-201` after 10s; unlocked, no
other change, no restart → connects in 1.0s. The ladder now reads
`DeviceRestart.lockState` before rung 1 and returns `.deviceLocked` rather than
climbing.

This was diagnosed wrongly for most of the project's life as a hung Sidecar
receiver, on the strength of restarting the iPad being the only thing that
helped — which it appeared to do because unlocking happens on the way past.
Replugging, killing the relay, toggling Handoff and forcing each transport were
all tried against it; none of them unlocked the iPad, so none of them worked.

Because every rung acts on the Mac, the ladder stops after `attemptsPerRung`
consecutive `-201`s and returns `.deviceUnresponsive` rather than climbing. Each
failed connect also raises a system alert from `AirPlayUIAgent`, so a full climb
used to stack roughly fourteen dialogs at the user for no benefit.

Rung 3 is largely decorative on a stock Mac: SIP refuses `launchctl kickstart`
for every agent it finds (`launchctl` exit 150). `kill` on the user-owned
`SidecarRelay` does work and launchd respawns it immediately — but restarting the
relay did not clear a `-201` hang, so it isn't a substitute.

## Conventions

- No third-party dependencies, and none should be added.
- `blueutil` is optional and looked up by path; its absence is handled, not fatal.
- Anything that disrupts the user (bouncing Bluetooth, UI scripting) is off by
  default and opt-in from the menu.
- User-facing strings say what happened and what to do about it, not error codes.
