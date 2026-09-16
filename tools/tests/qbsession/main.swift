import Foundation

// Signing in to qBittorrent, as 5.2 actually does it.
//
// Two changes between 5.1 and 5.2 each broke the connection on their own, and both
// were pinned to a literal this code had written down as if it were permanent.
var failures = 0
func check(_ n: String, _ c: Bool, _ d: @autoclosure () -> String = "") {
    if c { print("  PASS  \(n)") } else { failures += 1; print("  FAIL  \(n)   \(d())") }
}

print("A sign-in is accepted by its status, not by a body that says Ok")
// 5.2 answers 204 No Content with an EMPTY body. Requiring 200 AND a body beginning
// "Ok" read a perfectly good sign-in as a rejection, and the app showed disconnected.
check("204 No Content is a yes", QBSession.accepted(204))
check("200 still is too", QBSession.accepted(200))
check("205 and friends as well", QBSession.accepted(205))
check("403 is not", !QBSession.accepted(403))
check("401 is not", !QBSession.accepted(401))
check("500 is not", !QBSession.accepted(500))
check("a redirect is not a sign-in", !QBSession.accepted(302))

print("\nThe session cookie is found by shape, not by a name that moved")
// It was `SID`. It is `QBT_SID_<port>` now -- QBT_SID_8080 on this seedbox -- so a
// lookup for the name "SID" finds nothing at all.
check("the name it has now", QBSession.isSession("QBT_SID_8080"))
check("on any other port", QBSession.isSession("QBT_SID_9091"))
check("the name it used to have", QBSession.isSession("SID"))
check("case does not matter", QBSession.isSession("qbt_sid_8080"))
check("an unrelated cookie is not the session", !QBSession.isSession("csrftoken"))
check("nor is one that merely contains it", !QBSession.isSession("NOT_A_SID_COOKIE"))

print("\nThe cookie is carried back under its own name")
let base = URL(string: "http://client.example:8890/")!
let http = HTTPURLResponse(
    url: base, statusCode: 204, httpVersion: "HTTP/1.1",
    headerFields: ["Set-Cookie": "QBT_SID_8080=abc123XYZ; HttpOnly; path=/"])!
let header = QBSession.cookieHeader(from: http, base: base)
// Sending it back as `SID=abc123` would be ignored however good the sign-in was.
check("the header carries the real name", header == "QBT_SID_8080=abc123XYZ",
      header ?? "nil")
let noCookie = HTTPURLResponse(url: base, statusCode: 204, httpVersion: "HTTP/1.1",
                               headerFields: ["Content-Length": "0"])!
check("no cookie means no session", QBSession.cookieHeader(from: noCookie, base: base) == nil)
let legacy = HTTPURLResponse(
    url: base, statusCode: 200, httpVersion: "HTTP/1.1",
    headerFields: ["Set-Cookie": "SID=legacy999; path=/"])!
check("an older client still works", QBSession.cookieHeader(from: legacy, base: base) == "SID=legacy999",
      QBSession.cookieHeader(from: legacy, base: base) ?? "nil")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
