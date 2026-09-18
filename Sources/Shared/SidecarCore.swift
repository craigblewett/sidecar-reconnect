//  SidecarCore.swift — a typed wrapper around macOS's private SidecarCore
//  framework, which is how we connect without scraping any UI.
//
//  Everything here is unsupported API. Apple can rename or reshape it in any
//  release, so the code probes for selectors instead of assuming them, and
//  `Sidecar.dump()` exists to show what the current macOS actually exposes.

import Foundation

// MARK: - Objective-C runtime plumbing
//
// Swift won't let us call objc_msgSend directly and NSInvocation is gone, so we
// fish the symbol out of the loaded runtime and give it a type. Needed for the
// calls `perform(_:with:)` can't express: primitive arguments and the
// three-argument wired-connect selector.

private let selfHandle = dlopen(nil, RTLD_LAZY)
private let msgSendPtr = dlsym(selfHandle, "objc_msgSend")

private func msgSend<T>(_ type: T.Type) -> T? {
    guard let ptr = msgSendPtr else { return nil }
    return unsafeBitCast(ptr, to: type)
}

private typealias MsgBool = @convention(c) (AnyObject, Selector) -> Bool
private typealias MsgInt = @convention(c) (AnyObject, Selector) -> Int
private typealias MsgVoidInt = @convention(c) (AnyObject, Selector, Int) -> Void
private typealias MsgConnect = @convention(c) (
    AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void
) -> Void
private typealias MsgConnectConfig = @convention(c) (
    AnyObject, Selector, AnyObject, AnyObject, @convention(block) (NSError?) -> Void
) -> Void

// MARK: - Public surface

public enum Transport: String, CaseIterable {
    case wired, wireless, auto

    public var label: String {
        switch self {
        case .wired:    return "Wired (USB-C)"
        case .wireless: return "Wireless"
        case .auto:     return "Automatic"
        }
    }
}

public struct SidecarDevice {
    public let object: AnyObject
    public let name: String
    /// `nil` when this macOS exposes no connection-state selector we recognise.
    /// Reported honestly rather than guessed, so callers can fall back instead
    /// of trusting a made-up `false`.
    public let connected: Bool?
}

/// Error codes SidecarCore itself returns. Observed on macOS 26.2; they decide
/// whether climbing the ladder can possibly help, so they're named rather than
/// left as bare integers at the call site.
public enum SidecarCode {
    public static let domain = "SidecarErrorDomain"
    /// The device list hasn't settled yet — typical in the first minute after a
    /// wake. Retrying and bouncing the session does clear it.
    public static let deviceNotFound = -200
    /// The link came up, pairing succeeded, and the iPad then answered nothing.
    /// Every rung in the ladder acts on the Mac, so none of them can fix this.
    public static let deviceTimedOut = -201
    /// The Mac has no session for this device.
    public static let notConnected = -102
}

public enum SidecarError: LocalizedError {
    case frameworkMissing
    case classMissing(String)
    case selectorMissing(String)
    case noDevices
    case ambiguousDevice([String])
    case deviceNotFound(String, [String])
    case timedOut(String)
    case failed(String, NSError)

    public var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            return "Could not load SidecarCore. This needs macOS with Sidecar support."
        case .classMissing(let name):
            return "\(name) is missing on this macOS. Use “Copy Diagnostics” and check the private API."
        case .selectorMissing(let name):
            return "SidecarCore has no \(name) on this macOS. It has probably changed in a system update."
        case .noDevices:
            return "macOS can't see any Sidecar devices. Check the cable, and that the iPad is unlocked and trusts this Mac."
        case .ambiguousDevice(let names):
            return "Several devices are available — pick one: \(names.joined(separator: ", "))"
        case .deviceNotFound(let wanted, let names):
            return names.isEmpty
                ? "“\(wanted)” isn't available, and neither is anything else."
                : "“\(wanted)” isn't available. Visible: \(names.joined(separator: ", "))"
        case .timedOut(let name):
            return "Connecting to “\(name)” timed out."
        case .failed(let name, let error):
            return "“\(name)”: \(error.localizedDescription) (\(error.domain) \(error.code))"
        }
    }

    /// The underlying SidecarCore code, when this wraps one. `nil` for our own
    /// errors, which carry no code from the framework.
    public var sidecarCode: Int? {
        guard case .failed(_, let error) = self,
              error.domain == SidecarCode.domain else { return nil }
        return error.code
    }
}

public enum Sidecar {

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"

    @discardableResult
    private static func load() -> Bool {
        if NSClassFromString("SidecarDisplayManager") != nil { return true }
        return dlopen(frameworkPath, RTLD_LAZY) != nil
    }

    private static func manager() throws -> AnyObject {
        guard load() else { throw SidecarError.frameworkMissing }
        guard let cls = NSClassFromString("SidecarDisplayManager") else {
            throw SidecarError.classMissing("SidecarDisplayManager")
        }
        guard let mgr = (cls as AnyObject).perform(Selector(("sharedManager")))?
            .takeUnretainedValue() else {
            throw SidecarError.classMissing("SidecarDisplayManager.sharedManager")
        }
        return mgr
    }

    // MARK: State probing

    /// Selectors that have, across releases, meant "is this device currently
    /// driving a session". Probed in order; `nil` if none of them exist.
    ///
    /// Deliberately *not* on this list: `SidecarDevice.status`, which is the
    /// only state-ish selector left on macOS 26. It is a bitfield, not a state
    /// enum — it reads 0x1880306 on an idle iPad and 0x80_0188_0306 after a
    /// failed connect, so the `!= 0` test below would report a disconnected
    /// device as connected. Until someone decodes the bits it is worse than no
    /// answer at all.
    private static let connectedSelectors = ["isConnected", "connected", "isConnectedDevice"]
    private static let stateSelectors = ["state", "connectionState", "sessionState"]

    /// The manager's own list of live sessions. Authoritative where it exists —
    /// it's the list macOS maintains, not a flag we have to interpret — so it's
    /// consulted before the per-device selectors. `nil` means this macOS has no
    /// such selector, not that nothing is connected.
    private static func connectedObjects() -> [AnyObject]? {
        guard let mgr = try? manager() else { return nil }
        let sel = Selector(("connectedDevices"))
        guard mgr.responds(to: sel) else { return nil }
        return mgr.perform(sel)?.takeUnretainedValue() as? [AnyObject] ?? []
    }

    /// - Parameter knownConnected: the manager's connected list, already
    ///   fetched, so listing N devices doesn't re-ask N times. `nil` means
    ///   "not available" and falls through to the per-device probing.
    private static func connectionState(of object: AnyObject,
                                        knownConnected: [AnyObject]?) -> Bool? {
        if let connected = knownConnected {
            return connected.contains { $0.isEqual(object) }
        }
        for name in connectedSelectors {
            let sel = Selector((name))
            if object.responds(to: sel), let send = msgSend(MsgBool.self) {
                return send(object, sel)
            }
        }
        for name in stateSelectors {
            let sel = Selector((name))
            if object.responds(to: sel), let send = msgSend(MsgInt.self) {
                // Every layout seen so far uses 0 for idle/disconnected.
                return send(object, sel) != 0
            }
        }
        return nil
    }

    private static func connectionState(of object: AnyObject) -> Bool? {
        connectionState(of: object, knownConnected: connectedObjects())
    }

    // MARK: Devices

    public static func devices() -> [SidecarDevice] {
        guard let mgr = try? manager(),
              let raw = mgr.perform(Selector(("devices")))?.takeUnretainedValue()
                as? [AnyObject] else {
            return []
        }
        let connected = connectedObjects()
        return raw.map { object in
            let name = (object.perform(Selector(("name")))?.takeUnretainedValue() as? String)
                ?? "(unnamed)"
            return SidecarDevice(object: object, name: name,
                                 connected: connectionState(of: object,
                                                            knownConnected: connected))
        }
    }

    public static func connectedDevice() -> SidecarDevice? {
        devices().first { $0.connected == true }
    }

    /// Resolve by name, case-insensitively. With no name, pick the only device
    /// if there is exactly one — the common case, and what lets the app work
    /// without anyone configuring an iPad name that may change.
    public static func resolve(_ wanted: String?) throws -> SidecarDevice {
        let all = devices()
        guard !all.isEmpty else { throw SidecarError.noDevices }

        guard let wanted = wanted, !wanted.isEmpty else {
            if all.count == 1 { return all[0] }
            if let connected = all.first(where: { $0.connected == true }) { return connected }
            throw SidecarError.ambiguousDevice(all.map(\.name))
        }
        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return exact
        }
        // Matched both ways round: the same iPad reports as "iPad" during a
        // connect and "iPad (3)" once discovery settles, so a name saved from
        // the menu can be longer *or* shorter than the one we're handed now.
        if let fuzzy = all.first(where: {
            $0.name.localizedCaseInsensitiveContains(wanted)
                || wanted.localizedCaseInsensitiveContains($0.name)
        }) {
            return fuzzy
        }
        throw SidecarError.deviceNotFound(wanted, all.map(\.name))
    }

    // MARK: Connect / disconnect
    //
    // Both are asynchronous with a completion block. Callers run on a
    // background queue, so blocking on a semaphore here is safe — the
    // completion is delivered on the main queue, which stays free.

    private static func wiredConfig() -> AnyObject? {
        guard let cls = NSClassFromString("SidecarDisplayConfig") else { return nil }
        // alloc/init through the runtime: we can't assume a `required init()`
        // that Swift would let us call on the metatype. The +1 from alloc is
        // never released, which is immaterial for one short-lived object.
        guard let allocated = (cls as AnyObject).perform(Selector(("alloc")))?
                .takeUnretainedValue(),
              let config = allocated.perform(Selector(("init")))?
                .takeUnretainedValue() else { return nil }
        let sel = Selector(("setTransport:"))
        guard config.responds(to: sel), let send = msgSend(MsgVoidInt.self) else { return nil }
        send(config, sel, 2)   // 2 == wired transport
        return config
    }

    @discardableResult
    public static func connect(_ device: SidecarDevice,
                               transport: Transport,
                               timeout: TimeInterval = 30) throws -> Bool {
        let mgr = try manager()
        let semaphore = DispatchSemaphore(value: 0)
        var failure: NSError?
        let completion: @convention(block) (NSError?) -> Void = { error in
            failure = error
            semaphore.signal()
        }

        let wiredSel = Selector(("connectToDevice:withConfig:completion:"))
        let plainSel = Selector(("connectToDevice:completion:"))

        var usedWired = false
        if transport != .wireless,
           mgr.responds(to: wiredSel),
           let config = wiredConfig(),
           let send = msgSend(MsgConnectConfig.self) {
            usedWired = true
            send(mgr, wiredSel, device.object, config, completion)
        } else if mgr.responds(to: plainSel), let send = msgSend(MsgConnect.self) {
            send(mgr, plainSel, device.object, completion)
        } else {
            throw SidecarError.selectorMissing("connectToDevice:completion:")
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw SidecarError.timedOut(device.name)
        }
        if let error = failure {
            // Already being connected is the outcome we wanted, not an error.
            if connectionState(of: device.object) == true { return usedWired }
            throw SidecarError.failed(device.name, error)
        }
        return usedWired
    }

    public static func disconnect(_ device: SidecarDevice,
                                  timeout: TimeInterval = 30) throws {
        let mgr = try manager()
        let sel = Selector(("disconnectFromDevice:completion:"))
        guard mgr.responds(to: sel), let send = msgSend(MsgConnect.self) else {
            throw SidecarError.selectorMissing("disconnectFromDevice:completion:")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var failure: NSError?
        // Bound to a local of explicit @convention(block) type, not passed as a
        // trailing closure: Swift treats a closure literal handed to a
        // @convention(c) function as non-escaping, and SidecarCore stores it
        // until the disconnect finishes — which traps at runtime with
        // "closure argument passed as @noescape to Objective-C has escaped".
        let completion: @convention(block) (NSError?) -> Void = { error in
            failure = error
            semaphore.signal()
        }
        send(mgr, sel, device.object, completion)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw SidecarError.timedOut(device.name)
        }
        if let error = failure { throw SidecarError.failed(device.name, error) }
    }

    // MARK: Diagnostics

    /// The private API as it exists on *this* macOS. When a system update
    /// breaks the app, this is what tells you which selector moved.
    /// Every class the loaded SidecarCore actually vends, discovered rather than
    /// listed, so a class Apple adds or renames shows up here instead of being
    /// invisible until someone re-reads the binary.
    private static func allClassNames() -> [String] {
        guard let cls = NSClassFromString("SidecarDisplayManager"),
              let image = class_getImageName(cls) else { return [] }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        return (0..<Int(count)).map { String(cString: names[$0]) }.sorted()
    }

    public static func dump() -> String {
        load()
        var out = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"

        // An inventory first: cheap, and it's what tells you a class has gone
        // missing after a system update.
        let present = allClassNames()
        out += "\nSidecarCore vends \(present.count) classes:\n"
        out += present.map { "  \($0)" }.joined(separator: "\n") + "\n"

        // Then the full method lists, but only for the classes we actually call.
        // Dumping all 33 would bury the four that matter.
        for name in ["SidecarDisplayManager", "SidecarDisplayConfig", "SidecarDevice",
                     "SidecarSession"] {
            guard let cls = NSClassFromString(name) else {
                out += "\n\(name): NOT PRESENT\n"
                continue
            }
            out += "\n\(name)\n"
            var names: [String] = []
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                for i in 0..<Int(count) {
                    names.append("  -" + NSStringFromSelector(method_getName(methods[i])))
                }
                free(methods)
            }
            var metaCount: UInt32 = 0
            if let meta = object_getClass(cls),
               let methods = class_copyMethodList(meta, &metaCount) {
                for i in 0..<Int(metaCount) {
                    names.append("  +" + NSStringFromSelector(method_getName(methods[i])))
                }
                free(methods)
            }
            out += names.sorted().joined(separator: "\n") + "\n"
        }
        return out
    }
}
