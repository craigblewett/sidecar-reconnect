# Handoff to a local session

This code was written in a remote Linux container with no Mac, no Swift
toolchain, and no iPad. **Nothing in it has ever been compiled or run.** It was
written against the documented shape of Apple's private `SidecarCore` framework.

If you are a Claude Code session running on the user's Mac: you have the hardware
this needs. The job is to get it compiling, verify the private API behaves as
assumed, and confirm the real-world case works. Read `CLAUDE.md` first.

## Context

The user mirrors a Mac to an iPad over **Sidecar**, connected by **USB-C cable
and Bluetooth**. The recurring problem: the Mac sleeps overnight, and in the
morning the connection won't re-establish. Their current workaround is restarting
the iPad, which they want to stop doing.

The working theory is that the USB device re-enumerates on wake and the Sidecar
relay daemon never notices — which is why rung 3 (restarting the Sidecar agents)
is expected to be the rung that usually fixes it. That theory is unverified.

## Do these in order

### 1. Compile

```sh
./build.sh
```

Expect Swift errors on the first run. Likely spots, roughly in order of risk:

- **`Sources/Shared/SidecarCore.swift`** — the `objc_msgSend` typealiases and the
  `@convention(block)` completion parameters. Trailing-closure syntax against a
  C function pointer (in `disconnect`) is the most suspect line.
- **`perform(Selector(...))`** returning `Unmanaged<AnyObject>!` — optional
  chaining and `takeUnretainedValue()` may need adjusting.
- **`Sources/App/main.swift`** — the `#available(macOS 13.0, *)` guard inside the
  `isLoginItemEnabled` computed property, and the two-trailing-closure call to
  `Recovery.shared.run(reason:progress:completion:)`.

Fix compile errors directly. Do not restructure the architecture to dodge one.

### 2. Confirm the private API is real on this macOS

```sh
sidecarctl list     # should print the iPad's name
sidecarctl dump     # the actual method list on this machine
```

`dump` is the ground truth. Check specifically:

- Does `SidecarDisplayManager` have `connectToDevice:withConfig:completion:`?
  If not, wired connect falls back to the plain selector — confirm that path works.
- Does `SidecarDisplayConfig` have `setTransport:`? **The value `2` for "wired" is
  the least verified assumption in the codebase.** If a wired connect fails or
  silently connects wirelessly, try other small integers and see which yields a
  wired session.
- Which connection-state selector actually exists on `SidecarDevice`? If
  `sidecarctl status` reports `unknown` (exit 3), none of the probed names matched
  — find the right one in the dump and add it to `connectedSelectors` or
  `stateSelectors` in `SidecarCore.swift`. Add the name; don't remove the
  probing, and don't make `nil` default to `false`.

### 3. Test connect and disconnect by hand

```sh
sidecarctl status
sidecarctl disconnect
sidecarctl connect --wired
sidecarctl bounce
```

Watch the actual iPad while doing this. Confirm the display really attaches, and
that a "wired" connect is genuinely wired rather than silently falling back.

### 4. Test the ladder

```sh
sidecarctl fix
```

It prints each step. Watch which rung actually lands. Rung 3 restarts user agents
via `launchctl kickstart` — check the labels it discovered on this Mac are the
right ones, and note them, since nobody has yet confirmed which agents matter.

### 5. Test the real scenario

The one that actually matters and can't be simulated:

1. Connect the iPad, confirm the menu bar icon shows connected.
2. Sleep the Mac (properly — closed lid overnight is the real case; `pmset
   sleepnow` is a weaker approximation).
3. Wake it. The app should wait ~12s, then run the ladder on its own.
4. Check the menu's **Recent Activity**, or `~/Library/Logs/SidecarReconnect.log`.

If it reconnects without intervention, it works. If the 12s delay is wrong, it's
`wakeDelay` in `Preferences.swift`.

### 6. Publish

The remote session could not create the GitHub repo — the GitHub App on the
account lacks repo-creation permission (403). Locally, `gh` should work:

```sh
gh repo create sidecar-reconnect --public --source=. --remote=origin --push
```

Ask the user before creating anything public.

## Things to preserve

The three conventions in `CLAUDE.md` — probe don't assume, discover don't
hard-code, make breakage legible — exist because this depends on private API that
Apple will eventually change. They are the difference between a tool that
explains itself when it breaks and one that fails silently a year from now.

Also: every disruptive fix stays opt-in. Bouncing Bluetooth drops the user's
keyboard and mouse; don't promote it to a default because it made a test pass.

## Known unknowns

Resolved on macOS 26.2 (25C56) on 2026-09-18 — see "What actually goes wrong" in
`CLAUDE.md` for the detail:

- ~~Whether `setTransport(2)` is really "wired".~~ **Yes.** It produces
  `CF <ForceUSB NoiWiFi>` in the relay log, confirmed on a connection that
  succeeded over the cable. Full map: 0 = automatic, 1 = `ForceAWDL`,
  2 = `ForceUSB`, 3 = `iWiFi`.
- ~~Which connection-state selector exists on current macOS.~~ **None.**
  `SidecarDevice` has no usable one; `status` is a bitfield that is non-zero
  while disconnected. State now comes from `SidecarDisplayManager.connectedDevices`.
- ~~Which launchd agents actually matter for the post-wake wedge.~~ **None of
  them.** SIP blocks `launchctl kickstart` for all six discovered agents, and the
  post-wake case is cleared by rung 2 before rung 3 would matter anyway.

Still open:

- Whether `SMAppService.mainApp.register()` works for an ad-hoc signed bundle —
  there's a fallback alert pointing at System Settings if it doesn't. **Untested.**
- Whether `UNUserNotificationCenter` delivers for an ad-hoc signed app. **Untested.**
- Whether the `-201` iPad-side hang recurs after an overnight sleep. A ~10s
  `pmset sleepnow` reproduced only the benign `-200` case, which the ladder
  recovered from unaided. The overnight case has not yet been observed by this
  tooling.
- The `.deviceUnresponsive` early stop is implemented and its plumbing is
  unit-checked, but it has not yet run against a live `-201` hang.
