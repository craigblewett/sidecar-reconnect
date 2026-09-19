//  Recovery.swift — the reconnect ladder.
//
//  Climbs increasingly disruptive fixes and stops at the first rung that works,
//  so the ordinary morning case costs a second or two and only a genuinely
//  stuck machine pays for the noisy steps.

import Foundation

// MARK: - Shelling out

@discardableResult
func shell(_ path: String, _ args: [String], timeout: TimeInterval = 25) -> (status: Int32, output: String) {
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return (127, "not executable: \(path)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do { try process.run() } catch {
        return (127, "could not run \(path): \(error.localizedDescription)")
    }

    // Read before waiting: a full pipe buffer would otherwise deadlock us.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { usleep(50_000) }
    if process.isRunning {
        process.terminate()
        return (124, "timed out: \(path)")
    }
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func firstExecutable(_ paths: [String]) -> String? {
    paths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: - Outcome

public enum RecoveryOutcome {
    case alreadyConnected
    case connected(rung: String)
    case failed(reason: String)
    /// The Mac reached the iPad and the iPad didn't answer. Kept separate from
    /// `failed` because it calls for a different action from the user — nothing
    /// on this Mac will fix it — and because there's no point climbing further.
    case deviceUnresponsive

    public var succeeded: Bool {
        switch self {
        case .alreadyConnected, .connected: return true
        case .failed, .deviceUnresponsive:  return false
        }
    }

    public var summary: String {
        switch self {
        case .alreadyConnected:      return "Already connected."
        case .connected(let rung):   return "Reconnected (\(rung))."
        case .failed(let reason):    return "Couldn't reconnect: \(reason)"
        case .deviceUnresponsive:
            return "The iPad answered the Mac but never started the screen session. "
                 + "Restarting the iPad is the only known fix — nothing on this Mac will clear it."
        }
    }
}

// MARK: - The ladder

public final class Recovery {
    public static let shared = Recovery()
    private init() {}

    private let queue = DispatchQueue(label: "io.github.sidecarreconnect.recovery")
    private let lock = NSLock()
    private var running = false

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Runs the ladder off the main thread. `progress` and `completion` are
    /// delivered on the main queue so the menu can update directly.
    public func run(reason: String,
                    progress: @escaping (String) -> Void,
                    completion: @escaping (RecoveryOutcome) -> Void) {
        lock.lock()
        if running {
            lock.unlock()
            Log.write("recovery already in progress, ignoring request (\(reason))")
            return
        }
        running = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = self.ladder(reason: reason) { step in
                Log.write("  \(step)")
                DispatchQueue.main.async { progress(step) }
            }
            Log.write(outcome.summary)
            Log.trimIfLarge()
            self.lock.lock(); self.running = false; self.lock.unlock()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private func ladder(reason: String, step: (String) -> Void) -> RecoveryOutcome {
        Log.write("--- reconnect: \(reason) ---")
        let wanted = Prefs.device.isEmpty ? nil : Prefs.device
        let transport = Prefs.transport

        if Sidecar.connectedDevice() != nil {
            return .alreadyConnected
        }

        var lastError = "no Sidecar device was reachable"
        /// Consecutive "device timed out" failures. Every one of those means the
        /// link reached the iPad and the iPad ignored it, so once we've seen a
        /// runful of them there is nothing left for the Mac-side rungs to do —
        /// climbing on just costs a minute and a system alert per attempt.
        var consecutiveTimeouts = 0
        var unresponsive: Bool { consecutiveTimeouts >= Prefs.attempts }

        /// One rung: try to connect a few times, since the daemons come back
        /// asynchronously and the first try after a restart often lands before
        /// anything is listening.
        func tryConnect(_ rung: String) -> Bool {
            for attempt in 1...Prefs.attempts {
                do {
                    let device = try Sidecar.resolve(wanted)
                    try Sidecar.connect(device, transport: transport)
                    step("connected to \(device.name) on attempt \(attempt)")
                    consecutiveTimeouts = 0
                    return true
                } catch {
                    lastError = error.localizedDescription
                    if (error as? SidecarError)?.sidecarCode == SidecarCode.deviceTimedOut {
                        consecutiveTimeouts += 1
                    } else {
                        consecutiveTimeouts = 0
                    }
                    step("attempt \(attempt)/\(Prefs.attempts) failed: \(lastError)")
                    if unresponsive {
                        step("the iPad is reachable but isn't starting a screen session")
                        return false
                    }
                    if attempt < Prefs.attempts { Thread.sleep(forTimeInterval: 3) }
                }
            }
            step("rung “\(rung)” did not get us there")
            return false
        }

        // Rung 1 — just connect. Usually enough: the session was never really
        // torn down, the relay just lost track of it.
        step("connecting")
        if tryConnect("connect") { return .connected(rung: "direct connect") }
        if unresponsive { return restartAndRetry(wanted, step: step, tryConnect: tryConnect) }

        // Rung 2 — bounce the session. Clears a half-open state the connect
        // path won't overwrite on its own. This is the rung that recovers the
        // ordinary post-wake case, where connects fail with "device not found"
        // while the device list is still settling.
        step("bouncing the session")
        if let device = try? Sidecar.resolve(wanted) {
            try? Sidecar.disconnect(device)
            Thread.sleep(forTimeInterval: 2)
            if tryConnect("bounce") { return .connected(rung: "session bounce") }
            if unresponsive { return restartAndRetry(wanted, step: step, tryConnect: tryConnect) }
        }

        // Rung 3 — restart the user agents. Note this cannot do much on a stock
        // Mac: SIP refuses `launchctl kickstart` for every agent it finds.
        step("restarting Sidecar agents")
        restartAgents(step: step)
        if tryConnect("agents") { return .connected(rung: "agent restart") }
        if unresponsive { return restartAndRetry(wanted, step: step, tryConnect: tryConnect) }

        // Rung 4 — Bluetooth. Off by default: it drops BT keyboards and mice.
        if Prefs.bounceBluetooth {
            step("bouncing Bluetooth")
            if bounceBluetooth(step: step), tryConnect("bluetooth") {
                return .connected(rung: "Bluetooth bounce")
            }
        }

        // Rung 5 — Control Center. Last resort; fragile and needs Accessibility.
        if Prefs.uiFallback {
            step("driving Control Center")
            if clickThroughControlCenter(step: step) {
                Thread.sleep(forTimeInterval: 4)
                if Sidecar.connectedDevice() != nil {
                    return .connected(rung: "Control Center")
                }
            }
        }

        return .failed(reason: lastError)
    }

    /// The last rung, and the only one that acts on the iPad rather than the
    /// Mac. Reached only when the hang signature is certain, and only when the
    /// user has opted in — restarting an iPad interrupts whatever is on it.
    private func restartAndRetry(_ wanted: String?,
                                 step: (String) -> Void,
                                 tryConnect: (String) -> Bool) -> RecoveryOutcome {
        guard Prefs.restartDeviceOnHang else { return .deviceUnresponsive }
        guard let device = try? Sidecar.resolve(wanted) else { return .deviceUnresponsive }

        do {
            let style = try DeviceRestart.restart(device.name, progress: step)
            step("waiting for \(device.name) to come back")

            // Sidecar needs an unlocked iPad, and iOS wants the passcode after a
            // restart — Face ID won't do for the first unlock. There is no way
            // to supply it from here, so the most useful thing is to notice and
            // say so rather than retrying into a locked screen until the clock
            // runs out. A userspace restart is back in seconds; a full reboot,
            // and any wait for a human to type a passcode, needs much longer.
            let deadline = Date().addingTimeInterval(style == .userspace ? 90 : 180)
            var askedToUnlock = false

            while Date() < deadline {
                Thread.sleep(forTimeInterval: 5)

                if let lock = DeviceRestart.lockState(device.name), !lock.readyForSidecar {
                    if !askedToUnlock {
                        askedToUnlock = true
                        step("\(device.name) is back — unlock it and this will finish")
                    }
                    continue      // no point attempting a connect into a lock screen
                }

                if !Sidecar.devices().isEmpty, tryConnect("after restart") {
                    return .connected(rung: "iPad restart")
                }
            }
            step(askedToUnlock
                 ? "\(device.name) restarted but is still locked — unlock it, then reconnect"
                 : "\(device.name) didn't come back in time")
        } catch {
            step(error.localizedDescription)
        }
        return .deviceUnresponsive
    }

    // MARK: Rung implementations

    /// Agents are discovered rather than hard-coded: Apple renames these between
    /// releases, and `launchctl list` always tells the truth about this Mac.
    private func restartAgents(step: (String) -> Void) {
        let listing = shell("/bin/launchctl", ["list"]).output
        let pattern = try? NSRegularExpression(
            pattern: "sidecar|airplay|AMPDeviceDiscovery|rapport|screencontinuity",
            options: .caseInsensitive)

        var labels: Set<String> = []
        for line in listing.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let label = columns.last.map(String.init), !label.isEmpty else { continue }
            // Only Apple's own agents. Once this app is installed and running,
            // launchd lists it as `application.io.github.sidecarreconnect.…`,
            // which the pattern below matches on "sidecar" — so without this
            // guard rung 3 kickstarts *us*, killing the ladder halfway through
            // its own most important step. Scoping the search still discovers
            // renamed Apple agents; it just won't restart third-party apps.
            guard label.hasPrefix("com.apple.") else { continue }
            guard !label.contains(Prefs.suiteName) else { continue }
            let range = NSRange(label.startIndex..., in: label)
            if pattern?.firstMatch(in: label, range: range) != nil { labels.insert(label) }
        }

        guard !labels.isEmpty else {
            step("no Sidecar-related agents found in launchctl")
            return
        }
        let uid = getuid()
        var blockedBySIP = 0
        for label in labels.sorted() {
            let result = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])
            switch result.status {
            case 0:
                step("restarted \(label)")
            case 150:
                // launchctl's "Operation not permitted while System Integrity
                // Protection is engaged". Every Apple agent this rung wants is
                // covered by SIP on a stock Mac, so the rung largely cannot do
                // what it was designed to do — better to say that than to
                // report a vague failure and climb on.
                blockedBySIP += 1
                step("can't restart \(label) — blocked by System Integrity Protection")
            default:
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                step("could not restart \(label) — \(detail.isEmpty ? "launchctl exit \(result.status)" : detail)")
            }
        }
        if blockedBySIP > 0 {
            step("\(blockedBySIP) of \(labels.count) agents are SIP-protected — this rung can't restart them on a stock Mac")
        }
        Thread.sleep(forTimeInterval: 3)
    }

    private func bounceBluetooth(step: (String) -> Void) -> Bool {
        guard let blueutil = firstExecutable([
            "/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil",
        ]) else {
            step("blueutil not installed — brew install blueutil")
            return false
        }
        guard shell(blueutil, ["--power", "0"]).status == 0 else {
            step("blueutil could not turn Bluetooth off")
            return false
        }
        Thread.sleep(forTimeInterval: 3)
        guard shell(blueutil, ["--power", "1"]).status == 0 else {
            step("blueutil could not turn Bluetooth back on — check System Settings")
            return false
        }
        Thread.sleep(forTimeInterval: 5)
        return true
    }

    private func clickThroughControlCenter(step: (String) -> Void) -> Bool {
        guard let script = Bundle.main.url(forResource: "sidecar-connect-ui",
                                           withExtension: "applescript")
            ?? firstExistingFile([
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/share/sidecar-reconnect/sidecar-connect-ui.applescript"),
            ]) else {
            step("Control Center script not found")
            return false
        }
        let result = shell("/usr/bin/osascript", [script.path, Prefs.device], timeout: 30)
        if result.status != 0 {
            step("Control Center scripting failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            step("check System Settings › Privacy & Security › Accessibility")
            return false
        }
        return true
    }

    private func firstExistingFile(_ urls: [URL]) -> URL? {
        urls.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
