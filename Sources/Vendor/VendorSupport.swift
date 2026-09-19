//  VendorSupport.swift — the glue the vendored Side Screen files expect.
//
//  Those files are kept byte-identical to upstream so they can be diffed and
//  refreshed, which means anything they reference from outside their own set has
//  to be supplied here rather than by editing them.

import Foundation

/// Upstream defines this in its own AppDelegate, which we don't vendor. Pointing
/// it at our log puts the streaming engine's diagnostics in the same file and the
/// same "Recent Activity" menu as everything else.
///
/// Except the per-second ones. The engine logs a throughput line every second
/// while streaming, which drowned everything else: 1013 of 1070 lines in a real
/// log, rolling the file every quarter of an hour and evicting the Sidecar
/// history it exists to keep. Those numbers are already live in the menu, so
/// nothing is lost by keeping them out of the file.
private let highFrequencyPrefixes = ["Pipeline:"]

func debugLog(_ message: String) {
    guard !highFrequencyPrefixes.contains(where: message.hasPrefix) else { return }
    Log.write(message)
}
