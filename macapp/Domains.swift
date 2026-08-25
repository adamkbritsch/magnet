import Foundation

/// Suffixes that hand every customer their own subdomain.
///
/// These matter because the length rule below cannot see them: `evil.pages.dev` and
/// `a-mirror.pages.dev` both reduce to `pages.dev`, so a single mirror or bookmark
/// hosted on one of these would vouch for every stranger on the same platform --
/// enough for an advert there to count as a site you already trust. Not the full
/// Public Suffix List, which is a large moving file to bundle; these are the hosts a
/// mirror list realistically lands on.
let multiTenantSuffixes: Set<String> = [
    "pages.dev", "workers.dev", "github.io", "gitlab.io", "netlify.app", "netlify.com",
    "vercel.app", "web.app", "firebaseapp.com", "herokuapp.com", "glitch.me",
    "blogspot.com", "wordpress.com", "surge.sh", "onrender.com", "fly.dev",
    "repl.co", "replit.app", "codeberg.page", "sourceforge.io", "translate.goog",
    "s3.amazonaws.com", "cloudfront.net", "azurewebsites.net", "appspot.com",
    "r2.dev", "trycloudflare.com", "ngrok.io", "ngrok-free.app",
]

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

    // A shared platform is a public suffix, so its tenants keep a label of their own.
    for depth in [3, 2] where parts.count > depth {
        if multiTenantSuffixes.contains(parts.suffix(depth).joined(separator: ".")) {
            return parts.suffix(depth + 1).joined(separator: ".")
        }
    }
    // Two-part suffixes like .co.uk keep one more label.
    if parts.count >= 3, parts[parts.count - 2].count <= 3, parts[parts.count - 1].count <= 3 {
        return parts.suffix(3).joined(separator: ".")
    }
    return parts.suffix(2).joined(separator: ".")
}
