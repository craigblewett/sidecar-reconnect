# SidecarReconnect

A macOS menu bar app that recovers a wedged Sidecar connection to an iPad —
typically after the Mac wakes and the iPad, still on its USB-C cable, won't
re-establish mirroring.

## Build and run

```sh
./build.sh          # builds the .app + CLI, installs to ~/Applications and ~/.local/bin, launches
./uninstall.sh      # removes both; --purge also drops settings and the log
```

Requires macOS 13+ and Xcode Command Line Tools. There is no Xcode project and no
SwiftPM manifest — `build.sh` calls `swiftc` directly on the source files. Adding
a file to `Sources/Shared/` picks it up automatically (it globs); adding a new
target does not.

Two binaries are compiled from one set of sources:

- `Sources/Shared/*.swift` + `Sources/App/main.swift` → `SidecarReconnect.app`
- `Sources/Shared/*.swift` + `Sources/CLI/main.swift` → `sidecarctl`

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
| `Sources/CLI/main.swift` | `sidecarctl`, same engine for hotkeys and scripts. |
| `scripts/*.applescript` | Control Center fallback, bundled into the app's Resources. |

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

**`-201` device timed out — not recoverable from the Mac.** The link is healthy:
USB enumerates, IP over the cable pings, Bonjour resolves, Rapport pairs
(`PairVerify completed (RPI-Owner)`), and the data link reaches `Ready` in ~34ms.
The Mac then sends `AVC negotiate offer` and the iPad never sends the answer —
11 `com.apple.sidecar` events out, 0 back. The iPad's Sidecar *receiver* is hung.
Replugging the cable, killing `SidecarRelay`, toggling Handoff on the iPad, and
all four transports were each tried and made no difference; only restarting the
iPad cleared it. After the restart the same handshake produced `AVC negotiate
answer (469 bytes)` and connected in 0.97s.

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
