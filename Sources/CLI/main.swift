//  sidecarctl — the same engine as the menu bar app, for hotkeys and scripts.
//
//  Bind `sidecarctl fix` to a Raycast/Alfred/Shortcuts hotkey if you want a
//  keystroke that does what the menu's "Reconnect Now" does.

import Foundation

Prefs.registerDefaults()

func usage() -> Never {
    print("""
    usage: sidecarctl <command> [options]

      fix                  climb the recovery ladder until the iPad is back
      list                 list Sidecar-capable devices
      status [name]        exit 0 if connected, 1 if not, 3 if undeterminable
      connect [name]       a single connect attempt, no ladder
      disconnect [name]
      bounce [name]        disconnect, pause, reconnect
      dump                 print the private SidecarCore API on this macOS

    options:
      --wired | --wireless   override the configured transport
      --device <name>        override the configured device
      --quiet                only print the final result
    """)
    exit(64)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

let quiet = takeFlag("--quiet")
let wired = takeFlag("--wired")
let wireless = takeFlag("--wireless")
let deviceOverride = takeValue("--device") ?? args.first(where: { !$0.hasPrefix("--") })

// Flags override the shared preferences for this invocation only.
let transport: Transport = wireless ? .wireless : (wired ? .wired : Prefs.transport)
let wanted = deviceOverride ?? (Prefs.device.isEmpty ? nil : Prefs.device)

func bail(_ error: Error) -> Never {
    FileHandle.standardError.write(
        Data(("sidecarctl: " + error.localizedDescription + "\n").utf8))
    exit(1)
}

switch command {
case "fix":
    // The ladder reads its settings from Prefs, so an override has to be
    // written there — and put back afterwards, or using `--wireless` once
    // would quietly change what the menu bar app does from then on.
    let savedTransport = Prefs.transport
    let savedDevice = Prefs.device
    if wired || wireless { Prefs.transport = transport }
    if let override = deviceOverride { Prefs.device = override }

    var outcome: RecoveryOutcome?
    Recovery.shared.run(reason: "sidecarctl") { step in
        if !quiet { print("  \(step)") }
    } completion: { result in
        outcome = result
    }
    // Running the main run loop drains the main queue the completion lands on.
    while outcome == nil {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    Prefs.transport = savedTransport
    Prefs.device = savedDevice
    print(outcome!.summary)
    exit(outcome!.succeeded ? 0 : 1)

case "list":
    let devices = Sidecar.devices()
    if devices.isEmpty {
        print("no Sidecar devices visible")
        exit(2)
    }
    for device in devices {
        let state = device.connected.map { $0 ? "connected" : "disconnected" } ?? "state-unknown"
        print("\(device.name)\t\(state)")
    }

case "status":
    let devices = Sidecar.devices()
    let matching = wanted.map { name in
        devices.filter { $0.name.localizedCaseInsensitiveContains(name) }
    } ?? devices
    let connected = matching.filter { $0.connected == true }
    if !connected.isEmpty {
        connected.forEach { print("connected: \($0.name)") }
        exit(0)
    }
    if matching.contains(where: { $0.connected == nil }) {
        // Don't claim "disconnected" when macOS gave us no way to tell.
        print("unknown: this macOS exposes no connection-state selector we recognise")
        exit(3)
    }
    print("not connected")
    exit(1)

case "connect":
    do {
        let device = try Sidecar.resolve(wanted)
        let usedWired = try Sidecar.connect(device, transport: transport)
        print("connected: \(device.name)\(usedWired ? " (wired)" : "")")
    } catch { bail(error) }

case "disconnect":
    do {
        let device = try Sidecar.resolve(wanted)
        try Sidecar.disconnect(device)
        print("disconnected: \(device.name)")
    } catch { bail(error) }

case "bounce":
    do {
        if let device = try? Sidecar.resolve(wanted) {
            try? Sidecar.disconnect(device)
            Thread.sleep(forTimeInterval: 2)
        }
        // Re-resolve: the device object can be replaced after a disconnect.
        let device = try Sidecar.resolve(wanted)
        let usedWired = try Sidecar.connect(device, transport: transport)
        print("reconnected: \(device.name)\(usedWired ? " (wired)" : "")")
    } catch { bail(error) }

case "dump":
    print(Sidecar.dump())

case "-h", "--help", "help":
    usage()

default:
    usage()
}
