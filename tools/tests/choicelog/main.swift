import Foundation

// What was searched for, read back out of the page URL.
//
// The choice on its own is a filename. Paired with the query it came from it reads
// as "looked for this, chose that", which is the only part worth keeping.
var failures = 0
func check(_ n: String, _ c: Bool, _ d: @autoclosure () -> String = "") {
    if c { print("  PASS  \(n)") } else { failures += 1; print("  FAIL  \(n)   \(d())") }
}
func q(_ s: String) -> String? { ChoiceLog.query(from: URL(string: s)!) }

print("Search terms come back out of a results URL")
// The shapes these sites actually use.
check("1337x puts the terms in the path",
      q("https://1337x.to/search/dune+part+two/1/") == "dune part two", q("https://1337x.to/search/dune+part+two/1/") ?? "nil")
check("and the page number after them is not the query",
      q("https://1337x.to/search/interstellar/2/") == "interstellar", q("https://1337x.to/search/interstellar/2/") ?? "nil")
check("Nyaa uses a query parameter",
      q("https://nyaa.si/?f=0&c=0_0&q=frieren") == "frieren", q("https://nyaa.si/?f=0&c=0_0&q=frieren") ?? "nil")
check("so does a plain ?s= search",
      q("https://audiobookbay.lu/?s=sanderson") == "sanderson", q("https://audiobookbay.lu/?s=sanderson") ?? "nil")
check("percent-encoded spaces decode",
      q("https://x.example/search/the%20thing/") == "the thing", q("https://x.example/search/the%20thing/") ?? "nil")

print("\nA page that is not a search has no query")
check("a torrent detail page", q("https://1337x.to/torrent/123456/Some.Release/") == nil,
      q("https://1337x.to/torrent/123456/Some.Release/") ?? "nil")
check("a home page", q("https://1337x.to/home/") == nil, q("https://1337x.to/home/") ?? "nil")
check("a bare domain", q("https://eztvx.to/") == nil, q("https://eztvx.to/") ?? "nil")
check("nothing at all", ChoiceLog.query(from: nil) == nil)
// A trailing /search/ with no terms is a form, not a search that happened.
check("an empty search path", q("https://1337x.to/search/") == nil, q("https://1337x.to/search/") ?? "nil")

print("\nThe torrent is identified by its info hash, not its label")
// `dn` is whatever the page felt like calling it; two pages list the same torrent
// under different names, and the hash is what makes them one thing.
let a = URL(string: "magnet:?xt=urn:btih:0123456789ABCDEF0123456789abcdef01234567&dn=A.Name")!
let b = URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Totally.Different&tr=http%3A%2F%2Fx")!
check("a hash is extracted", MagnetSender.infoHash(for: a) != nil)
check("the same torrent under two labels is one hash",
      MagnetSender.infoHash(for: a) == MagnetSender.infoHash(for: b),
      "\(MagnetSender.infoHash(for: a) ?? "nil") vs \(MagnetSender.infoHash(for: b) ?? "nil")")
check("a different torrent is a different hash",
      MagnetSender.infoHash(for: a)
        != MagnetSender.infoHash(for: URL(string: "magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff")!))
check("a magnet with no hash has none",
      MagnetSender.infoHash(for: URL(string: "magnet:?dn=Free+Download")!) == nil)
check("a .torrent URL is not a magnet hash",
      MagnetSender.infoHash(for: URL(string: "https://x.example/a.torrent")!) == nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
