import Foundation

/// Registrable domain: the part that identifies who owns a host.
///
/// `search.extto.com` and `extto.com` are one site; `srv1234.example-host.com` reads as
/// `example-host.com`. Used wherever "is this the same site?" is the question — mirror
/// sets, banner destinations, redirect guards, bookmark categories.
///
/// Deliberately dependency-free and in a file of its own: every one of those callers
/// would otherwise have to drag in the settings store to ask a question about a string.
func registrableDomain(_ host: String) -> String {
    var h = host.lowercased()
    if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
    let parts = h.split(separator: ".").map(String.init)
    guard parts.count >= 2 else { return h }
    // Two-part suffixes like .co.uk keep one more label.
    if parts.count >= 3, parts[parts.count - 2].count <= 3, parts[parts.count - 1].count <= 3 {
        return parts.suffix(3).joined(separator: ".")
    }
    return parts.suffix(2).joined(separator: ".")
}
