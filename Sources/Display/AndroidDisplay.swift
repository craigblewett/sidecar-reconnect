//  AndroidDisplay.swift — drives the vendored Side Screen engine.
//
//  Sidecar needs none of this: macOS creates the display, encodes the video,
//  moves the bytes and delivers touch, and we only ask it to connect. For an
//  Android tablet every one of those layers is ours, so this is the piece that
//  ties them together:
//
//      virtual display → screen capture → H.264/265 encode → socket → tablet
//                                                     touch ← socket ←
//
//  Upstream does this inside its AppDelegate, which we deliberately didn't
//  vendor — this app has its own menu and its own log.

import Foundation
import CoreGraphics

public final class AndroidDisplay {

    public static let shared = AndroidDisplay()
    private init() {}

    /// Upstream's default, and what the Side Screen Android app offers first.
    /// Keeping it means their released APK pairs with us without being told a
    /// different number.
    public static let defaultPort: UInt16 = 54321

    public enum State: Equatable {
        case stopped
        case starting
        /// Server is listening; the tablet hasn't connected yet.
        case waiting
        case streaming
        case failed(String)

        public var summary: String {
            switch self {
            case .stopped:            return "Not sharing to Android"
            case .starting:           return "Starting the display…"
            case .waiting:            return "Waiting for the tablet…"
            case .streaming:          return "Sharing to Android tablet"
            case .failed(let why):    return "Android display failed: \(why)"
            }
        }
    }

    /// Delivered on the main queue so the menu can update without hopping.
    public var onStateChange: ((State) -> Void)?

    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            Log.write(state.summary)
            let new = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(new) }
        }
    }

    public var isRunning: Bool { state != .stopped }

    private var display: VirtualDisplayManager?
    private var capture: ScreenCapture?
    private var server: StreamingServer?
    private let touch = TouchInjector()

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        state = .starting
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.bringUp()
            } catch {
                Log.write("android display failed to start: \(error.localizedDescription)")
                self.tearDown()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        tearDown()
        state = .stopped
    }

    // MARK: Bring-up

    private func bringUp() async throws {
        let width = Prefs.androidWidth
        let height = Prefs.androidHeight
        let port = Prefs.androidPort

        // 0. Check this first. It's the most common reason a first run fails,
        //    and asking before creating a display avoids putting one up and
        //    tearing it straight back down in front of the user.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Failure.needsScreenRecording
        }

        // 1. A display for the tablet to be. Nothing can be captured until this
        //    exists and macOS has registered it.
        let manager = VirtualDisplayManager()
        try manager.createDisplay(width: width, height: height, refreshRate: 60,
                                  hiDPI: Prefs.androidHiDPI, name: "Android Tablet")
        guard let displayID = manager.displayID, manager.verifyDisplayRegistered() else {
            manager.destroyDisplay()
            throw Failure.displayNotRegistered
        }
        display = manager

        // 2. Capture it.
        let capture = try await ScreenCapture()
        try await capture.setupForVirtualDisplay(displayID, refreshRate: 60)
        self.capture = capture

        // 3. The server the tablet talks to.
        let server = StreamingServer(port: port)
        server.touchEnabled = Prefs.androidTouch
        server.onTouchEvent = { [weak self] x, y, action, pointers, x2, y2 in
            self?.touch.handle(x: x, y: y, action: action, pointerCount: pointers,
                               x2: x2, y2: y2, on: displayID)
        }
        server.onClientConnected = { [weak self] in self?.state = .streaming }
        server.onClientDisconnected = { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.state = .waiting
        }
        try await server.start()
        self.server = server

        // 4. Over the cable, the tablet reaches us through adb's reverse
        //    forward. Wireless clients dial the Mac directly and need none of
        //    this, so a missing adb is a warning rather than a failure.
        if Prefs.androidUSB { setUpReverseForwarding(port: port) }

        capture.startStreaming(to: server,
                               bitrateMbps: Prefs.androidBitrate,
                               quality: "medium", gamingBoost: false, frameRate: 60)
        state = .waiting
    }

    private func tearDown() {
        capture?.stopStreaming()
        server?.stop()
        display?.destroyDisplay()
        capture = nil
        server = nil
        display = nil
    }

    // MARK: adb

    /// Discovered rather than hard-coded, same as the launchd agents in the
    /// recovery ladder — Homebrew and Android Studio put adb in different places.
    private func adbPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) { return found }
        let which = shell("/usr/bin/which", ["adb"])
        let path = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return which.status == 0 && !path.isEmpty ? path : nil
    }

    private func setUpReverseForwarding(port: UInt16) {
        guard let adb = adbPath() else {
            Log.write("adb not found — USB tablets can't reach us. brew install android-platform-tools")
            return
        }
        guard !StatusDetector.usbDevices().isEmpty else {
            Log.write("no Android device on USB yet — plug it in with USB debugging enabled")
            return
        }
        let result = shell(adb, ["reverse", "tcp:\(port)", "tcp:\(port)"])
        Log.write(result.status == 0
            ? "adb reverse set up on port \(port)"
            : "adb reverse failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: Errors

    enum Failure: LocalizedError {
        case displayNotRegistered
        case needsScreenRecording

        var errorDescription: String? {
            switch self {
            case .displayNotRegistered:
                return "macOS accepted the virtual display but never registered it. "
                     + "Use “Copy Diagnostics” — CGVirtualDisplay may have changed."
            case .needsScreenRecording:
                return "Screen Recording permission is needed to send the screen. "
                     + "Allow it in System Settings › Privacy & Security › Screen Recording, then try again."
            }
        }
    }
}
