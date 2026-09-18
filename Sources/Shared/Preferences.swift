//  Preferences.swift — UserDefaults, shared between the menu bar app and the CLI.

import Foundation

public enum Prefs {
    // A shared suite so `sidecarctl` reads the same settings you picked in the
    // menu, rather than the two disagreeing about the transport.
    public static let suiteName = "io.github.sidecarreconnect"
    private static let defaults = UserDefaults(suiteName: suiteName) ?? .standard

    private enum Key {
        static let device = "device"
        static let transport = "transport"
        static let autoReconnect = "autoReconnectOnWake"
        static let cleanDisconnect = "disconnectBeforeSleep"
        static let wakeDelay = "wakeDelaySeconds"
        static let bounceBluetooth = "bounceBluetooth"
        static let uiFallback = "uiFallback"
        static let notify = "notify"
        static let attempts = "attemptsPerRung"
        // Android second display
        static let androidPort = "androidPort"
        static let androidWidth = "androidWidth"
        static let androidHeight = "androidHeight"
        static let androidHiDPI = "androidHiDPI"
        static let androidBitrate = "androidBitrateMbps"
        static let androidTouch = "androidTouch"
        static let androidUSB = "androidUSB"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.transport: Transport.wired.rawValue,
            Key.autoReconnect: true,
            Key.cleanDisconnect: true,
            Key.wakeDelay: 12.0,
            Key.bounceBluetooth: false,
            Key.uiFallback: false,
            Key.notify: true,
            Key.attempts: 3,
            // 54321 is what Side Screen's Android app offers by default, so
            // their released APK pairs with us without being reconfigured.
            Key.androidPort: 54321,
            Key.androidWidth: 1920,
            Key.androidHeight: 1200,
            Key.androidHiDPI: true,
            Key.androidBitrate: 20,
            Key.androidTouch: true,
            Key.androidUSB: true,
        ])
    }

    // MARK: Android second display

    public static var androidPort: UInt16 {
        get { UInt16(exactly: defaults.integer(forKey: Key.androidPort)) ?? 54321 }
        set { defaults.set(Int(newValue), forKey: Key.androidPort) }
    }

    public static var androidWidth: Int {
        get { max(640, defaults.integer(forKey: Key.androidWidth)) }
        set { defaults.set(newValue, forKey: Key.androidWidth) }
    }

    public static var androidHeight: Int {
        get { max(480, defaults.integer(forKey: Key.androidHeight)) }
        set { defaults.set(newValue, forKey: Key.androidHeight) }
    }

    public static var androidHiDPI: Bool {
        get { defaults.bool(forKey: Key.androidHiDPI) }
        set { defaults.set(newValue, forKey: Key.androidHiDPI) }
    }

    public static var androidBitrate: Int {
        get { max(1, defaults.integer(forKey: Key.androidBitrate)) }
        set { defaults.set(newValue, forKey: Key.androidBitrate) }
    }

    public static var androidTouch: Bool {
        get { defaults.bool(forKey: Key.androidTouch) }
        set { defaults.set(newValue, forKey: Key.androidTouch) }
    }

    /// Whether to set up adb reverse forwarding for a cabled tablet. Harmless
    /// when the tablet is wireless — it just finds no USB device and says so.
    public static var androidUSB: Bool {
        get { defaults.bool(forKey: Key.androidUSB) }
        set { defaults.set(newValue, forKey: Key.androidUSB) }
    }

    /// Empty means "the only device that's visible", which is the common case
    /// and saves anyone having to type their iPad's name.
    public static var device: String {
        get { defaults.string(forKey: Key.device) ?? "" }
        set { defaults.set(newValue, forKey: Key.device) }
    }

    public static var transport: Transport {
        get { Transport(rawValue: defaults.string(forKey: Key.transport) ?? "") ?? .wired }
        set { defaults.set(newValue.rawValue, forKey: Key.transport) }
    }

    public static var autoReconnectOnWake: Bool {
        get { defaults.bool(forKey: Key.autoReconnect) }
        set { defaults.set(newValue, forKey: Key.autoReconnect) }
    }

    /// Close the session deliberately before the Mac sleeps, rather than letting
    /// it be torn down mid-flight. A hung iPad receiver was observed after the
    /// relay logged "Terminated with Active Sessions", so the theory is that the
    /// iPad is left holding a session nobody ever closed.
    public static var disconnectBeforeSleep: Bool {
        get { defaults.bool(forKey: Key.cleanDisconnect) }
        set { defaults.set(newValue, forKey: Key.cleanDisconnect) }
    }

    /// USB re-enumeration and Bluetooth take a few seconds to settle after a
    /// wake; connecting before that just fails on the first rung.
    public static var wakeDelay: TimeInterval {
        get { max(0, defaults.double(forKey: Key.wakeDelay)) }
        set { defaults.set(newValue, forKey: Key.wakeDelay) }
    }

    public static var bounceBluetooth: Bool {
        get { defaults.bool(forKey: Key.bounceBluetooth) }
        set { defaults.set(newValue, forKey: Key.bounceBluetooth) }
    }

    public static var uiFallback: Bool {
        get { defaults.bool(forKey: Key.uiFallback) }
        set { defaults.set(newValue, forKey: Key.uiFallback) }
    }

    public static var notify: Bool {
        get { defaults.bool(forKey: Key.notify) }
        set { defaults.set(newValue, forKey: Key.notify) }
    }

    public static var attempts: Int {
        get { max(1, defaults.integer(forKey: Key.attempts)) }
        set { defaults.set(newValue, forKey: Key.attempts) }
    }
}
