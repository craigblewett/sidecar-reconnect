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

    /// Same suite as every other preference, so the auth token doesn't end up
    /// in a second domain nobody thinks to clear.
    private static let defaults = UserDefaults(suiteName: Prefs.suiteName) ?? .standard

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

    /// What to type into the tablet to pair it the first time. `nil` once a
    /// tablet is connected, or before the server is up.
    public struct Pairing {
        public let code: String
        public let address: String
        public let port: UInt16
        /// True when `address` is a cable rather than the WiFi network.
        public let overCable: Bool

        /// One line, ready to put in a menu item.
        public var instruction: String {
            "Pair: \(address):\(port)   code \(PairingCode.display(code))"
                + (overCable ? "   (over USB)" : "")
        }
    }

    /// The virtual display's ID while a session is up, so the arrangement menu
    /// can tell which screen is the tablet.
    public var displayID: CGDirectDisplayID? { display?.displayID }

    public private(set) var pairing: Pairing?

    /// Tablets that have paired before. They hold a token and reconnect without
    /// a code, so the menu shouldn't wave a fresh one at the user as if the
    /// pairing had been lost.
    public var knownDevices: [String] {
        PairedDeviceStore(defaults: Self.defaults).all()
            .sorted { $0.lastConnected > $1.lastConnected }
            .map(\.name)
    }

    /// Live figures from the engine, for the menu. Frames per second actually
    /// delivered, and the bitrate they cost.
    public private(set) var throughput: (fps: Double, mbps: Double)?

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

    private static var askedForScreenRecording = false

    private var display: VirtualDisplayManager?
    private var capture: ScreenCapture?
    private var server: StreamingServer?
    private let touch = TouchInjector()

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        Prefs.androidWasSharing = true
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
        Prefs.androidWasSharing = false
        guard isRunning else { return }
        tearDown()
        state = .stopped
    }

    /// Bring sharing back after a relaunch if it was on when we quit. Delayed a
    /// little: the display server and network aren't necessarily ready the
    /// instant a login item starts.
    public func restoreIfWasSharing() {
        guard Prefs.androidWasSharing, !isRunning else { return }
        Log.write("restoring the Android display — it was sharing when we last quit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.start()
        }
    }

    // MARK: Bring-up

    private func bringUp() async throws {
        let width = Prefs.androidWidth
        let height = Prefs.androidHeight
        let port = Prefs.androidPort
        let fps = Prefs.androidFrameRate

        // 0. Check this first. It's the most common reason a first run fails,
        //    and asking before creating a display avoids putting one up and
        //    tearing it straight back down in front of the user.
        guard CGPreflightScreenCaptureAccess() else {
            // Ask once per launch. CGRequestScreenCaptureAccess opens System
            // Settings, and calling it on every retry means the pane reopens
            // each time — infuriating when the user is already looking at it.
            if !Self.askedForScreenRecording {
                Self.askedForScreenRecording = true
                CGRequestScreenCaptureAccess()
            }
            throw Failure.needsScreenRecording
        }

        // 1. A display for the tablet to be. Nothing can be captured until this
        //    exists and macOS has registered it.
        let manager = VirtualDisplayManager()
        try manager.createDisplay(width: width, height: height, refreshRate: fps,
                                  hiDPI: Prefs.androidHiDPI, name: "Android Tablet")
        guard let displayID = manager.displayID, manager.verifyDisplayRegistered() else {
            manager.destroyDisplay()
            throw Failure.displayNotRegistered
        }
        display = manager
        place(Arrangement(rawValue: Prefs.androidArrangement) ?? .right)

        // 2. Capture it.
        let capture = try await ScreenCapture()
        try await capture.setupForVirtualDisplay(displayID, refreshRate: fps)
        self.capture = capture

        // 3. The server the tablet talks to.
        let server = StreamingServer(port: port)
        server.touchEnabled = Prefs.androidTouch

        // Wireless mode. Without an auth token the server drops every client
        // that isn't on loopback, which would restrict us to tablets reachable
        // through adb — and that needs USB debugging turned on, which not every
        // tablet will allow. With it, the tablet can arrive over WiFi or over
        // USB tethering, neither of which needs developer options.
        server.expectedAuthToken = WirelessAuth.loadOrCreate(defaults: Self.defaults)
        server.pairingMacName = Host.current().localizedName ?? "Mac"
        server.onPairingSuccess = { [weak self] device in
            Log.write("paired with \(device)")
            PairedDeviceStore(defaults: Self.defaults)
                .upsert(name: device, lastConnected: Date())
            self?.issuePairingCode(on: server)
        }
        server.onPairingCodeExhausted = { [weak self] in
            Log.write("too many wrong pairing codes — issuing a fresh one")
            self?.issuePairingCode(on: server)
        }
        server.onStats = { [weak self] fps, mbps in
            self?.throughput = (fps, mbps)
        }
        // Honour the codec the tablet asks for. Without this the tablet can
        // request H.264 - often the cheaper decode on an older chip - and get
        // H.265 regardless, because ScreenCapture doesn't wire this itself.
        server.onCodecNegotiated = { [weak self, weak server] codec in
            guard let capture = self?.capture, let server = server else { return }
            capture.negotiate(codec: codec, clientLimit: server.clientDecodeLimits)
            let encoded = capture.encodeSize(for: codec)
            server.setDesktopSize(width: width, height: height)
            server.setDisplaySize(width: encoded.width, height: encoded.height,
                                  rotation: 0, flipHorizontal: false, flipVertical: false)
            Log.write("codec negotiated: \(codec), encoding at \(encoded.width)x\(encoded.height)")
        }
        // A client that has lost sync asks for a fresh keyframe; ignoring it
        // leaves the tablet showing a frozen or smeared picture until the next
        // periodic one.
        server.onKeyframeRequested = { [weak self] force in
            self?.capture?.requestKeyframeOrReplayCachedFrame(force: force)
        }
        server.onTouchEvent = { [weak self] x, y, action, pointers, x2, y2 in
            self?.touch.handle(x: x, y: y, action: action, pointerCount: pointers,
                               x2: x2, y2: y2, on: displayID)
        }
        server.onClientConnected = { [weak self] in
            self?.pairing = nil          // paired and connected; stop advertising a code
            self?.state = .streaming
        }
        server.onClientDisconnected = { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.state = .waiting
        }
        try await server.start()
        self.server = server
        issuePairingCode(on: server)

        // 4. Over the cable, the tablet reaches us through adb's reverse
        //    forward. Wireless clients dial the Mac directly and need none of
        //    this, so a missing adb is a warning rather than a failure.
        if Prefs.androidUSB { setUpReverseForwarding(port: port) }

        capture.startStreaming(to: server,
                               bitrateMbps: Prefs.androidBitrate,
                               quality: "medium", gamingBoost: false, frameRate: fps)
        state = .waiting
    }

    /// Codes are single-use: one is issued when the server comes up, and a new
    /// one after each success or after the attempt budget is spent, so a code
    /// seen over someone's shoulder is worth nothing twice.
    private func issuePairingCode(on server: StreamingServer) {
        let code = PairingCode.generate()
        server.expectedPairingCode = code
        let best = NetworkAddresses.preferred()
        let address = best?.address ?? LANAddressResolver.primaryIPv4() ?? "this Mac's IP address"
        pairing = Pairing(code: code, address: address, port: Prefs.androidPort,
                          overCable: best?.isDirectLink ?? false)
        if let best = best, best.isDirectLink {
            Log.write("pairing over the cable (\(best.interface)) — \(address):\(Prefs.androidPort) code \(PairingCode.display(code))")
        } else {
            Log.write("pairing code ready — \(address):\(Prefs.androidPort) code \(PairingCode.display(code))")
        }
        let current = state
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(current) }
    }

    private func tearDown() {
        capture?.stopStreaming()
        server?.stop()
        display?.destroyDisplay()
        capture = nil
        server = nil
        display = nil
        pairing = nil
    }

    // MARK: Arrangement

    public enum Arrangement: String, CaseIterable {
        case left, right, above, below

        public var label: String {
            switch self {
            case .left:  return "Left of Main Screen"
            case .right: return "Right of Main Screen"
            case .above: return "Above Main Screen"
            case .below: return "Below Main Screen"
            }
        }
    }

    /// Put the tablet where the user asked, relative to the main screen.
    /// macOS treats a virtual display as new every time it appears, so this is
    /// reapplied on every start rather than remembered by the system.
    public func place(_ arrangement: Arrangement) {
        Prefs.androidArrangement = arrangement.rawValue
        guard let display = display, let id = display.displayID else { return }

        let main = CGDisplayBounds(CGMainDisplayID())
        let size = CGDisplayBounds(id).size
        let origin: CGPoint
        switch arrangement {
        case .right: origin = CGPoint(x: main.maxX, y: main.minY)
        case .left:  origin = CGPoint(x: main.minX - size.width, y: main.minY)
        case .above: origin = CGPoint(x: main.minX, y: main.minY - size.height)
        case .below: origin = CGPoint(x: main.minX, y: main.maxY)
        }
        do {
            try display.setDisplayPosition(x: Int32(origin.x), y: Int32(origin.y))
            Log.write("tablet placed \(arrangement.rawValue) of the main screen")
        } catch {
            Log.write("couldn't place the tablet: \(error.localizedDescription)")
        }
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
                return "Screen Recording permission is needed. If SidecarReconnect is "
                     + "already listed and switched on there, the entry is stale: remove it "
                     + "with the “−” button, then start sharing again to be asked afresh."
            }
        }
    }
}
