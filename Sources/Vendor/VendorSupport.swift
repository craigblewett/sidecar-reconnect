//  VendorSupport.swift — the glue the vendored Side Screen files expect.
//
//  Those files are kept byte-identical to upstream so they can be diffed and
//  refreshed, which means anything they reference from outside their own set has
//  to be supplied here rather than by editing them.

import Foundation

/// Upstream defines this in its own AppDelegate, which we don't vendor. Pointing
/// it at our log puts the streaming engine's diagnostics in the same file and the
/// same "Recent Activity" menu as everything else.
func debugLog(_ message: String) {
    Log.write(message)
}
