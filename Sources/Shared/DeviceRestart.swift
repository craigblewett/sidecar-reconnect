//  DeviceRestart.swift — restart the iPad from the Mac.
//
//  When the iPad's Sidecar receiver hangs, nothing on the Mac can clear it:
//  the link is healthy, pairing succeeds, and the iPad simply never answers the
//  video negotiation. The only known fix is restarting the iPad, which until now
//  meant doing it by hand.
//
//  Xcode ships `devicectl`, which can reboot a paired device over USB or the
//  network. That turns the manual workaround into something the app can do —
//  and `--style userspace` restarts the OS userland rather than the hardware,
//  which brings the daemons back (the Sidecar receiver among them) in about half
//  the time and without a cold boot.
//
//  This is deliberately never automatic unless asked for: restarting someone's
//  iPad interrupts whatever is on it.

import Foundation

public enum DeviceRestart {

    public enum Style: String {
        /// Restarts userland only. Quicker, and enough to bring back a hung
        /// daemon. Tried first.
        case userspace
        /// A full reboot, for when userspace isn't supported or didn't take.
        case full
    }

    public enum Failure: LocalizedError {
        case toolMissing
        case deviceNotPaired(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "Restarting the iPad needs Xcode's device tools. "
                     + "Install Xcode, or restart the iPad by hand."
            case .deviceNotPaired(let name):
                return "“\(name)” isn't paired with this Mac for development. "
                     + "Connect it by cable and trust this computer, then try again."
            case .commandFailed(let detail):
                return "Couldn't restart the iPad: \(detail)"
            }
        }
    }

    /// `devicectl` lives inside Xcode, not the Command Line Tools, so it's
    /// absent on plenty of otherwise healthy Macs. Found through xcrun rather
    /// than by guessing a path inside the app bundle.
    public static var isAvailable: Bool { toolPath() != nil }

    private static func toolPath() -> String? {
        let result = shell("/usr/bin/xcrun", ["--find", "devicectl"], timeout: 10)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty ? path : nil
    }

    /// Devices `devicectl` can see, by the name it knows them as. Used to check
    /// a Sidecar device is reachable before offering to restart it.
    public static func pairedDevices() -> [String] {
        guard let tool = toolPath() else { return [] }
        let result = shell(tool, ["list", "devices"], timeout: 30)
        guard result.status == 0 else { return [] }
        // Fixed-width columns: the name runs up to the hostname, which is the
        // first field containing ".coredevice.local".
        return result.output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "  ") else { return nil }
            let name = line[line.startIndex..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard line.contains(".coredevice.local"), !name.isEmpty else { return nil }
            return name
        }
    }

    /// Restart `device`, trying a userspace restart first and falling back to a
    /// full reboot. `progress` is called with what's being attempted.
    @discardableResult
    public static func restart(_ device: String,
                               progress: (String) -> Void = { _ in }) throws -> Style {
        guard let tool = toolPath() else { throw Failure.toolMissing }

        let known = pairedDevices()
        guard known.contains(where: { $0.caseInsensitiveCompare(device) == .orderedSame })
                || known.contains(where: { $0.localizedCaseInsensitiveContains(device) })
        else {
            throw Failure.deviceNotPaired(device)
        }

        var lastDetail = "no output"
        for style in [Style.userspace, Style.full] {
            progress("restarting \(device) (\(style.rawValue))")
            let result = shell(tool,
                               ["device", "reboot", "--device", device,
                                "--style", style.rawValue, "--timeout", "60"],
                               timeout: 90)
            if result.status == 0 {
                Log.write("restarted \(device) — \(style.rawValue)")
                return style
            }
            lastDetail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("\(style.rawValue) restart of \(device) failed: \(lastDetail)")
        }
        throw Failure.commandFailed(lastDetail)
    }
}
