import Foundation
import WebKit

// Every shipped list must COMPILE.
//
// WebKit's rule compiler is all-or-nothing: one malformed rule fails the entire list,
// and the app swallows that with `try?`. Four bad rules out of 144,000 silently took
// two of the four lists out of service -- roughly half the blocking gone, while the
// shield still read "Blocking". Nothing about the app's behaviour said so.
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/macapp"

let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    .filter { $0.hasPrefix("blocklist-") && $0.hasSuffix(".json") }.sorted()

print("Every shipped filter list compiles")
if files.isEmpty {
    print("  SKIP  no lists generated yet (run tools/build-blocklist.py)")
    exit(0)
}

// A block that matches everything and is scoped to nothing.
//
// `*$ping,third-party` meant "block third-party beacons". WebKit has no beacon type,
// the nearest is `raw`, and `raw` is every XHR and fetch there is -- so one rule became
// "block ALL third-party XHR on every site". That is most of the modern web, and
// specifically the request Cloudflare's challenge makes, so no protected site would
// load. Nothing in the app said anything was wrong; the shield read "Blocking".
print("No rule blocks everything")
var universal: [String] = []
for f in files {
    let url = URL(fileURLWithPath: dir + "/" + f)
    guard let data = try? Data(contentsOf: url),
          let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { continue }
    for rule in rules {
        guard let action = rule["action"] as? [String: Any],
              (action["type"] as? String) == "block",
              let trigger = rule["trigger"] as? [String: Any],
              let filter = trigger["url-filter"] as? String else { continue }
        if [".*", "^.*", "."].contains(filter), trigger["if-domain"] == nil {
            universal.append("\(f): \(trigger)")
        }
    }
}
check("no block rule matches every URL on every site", universal.isEmpty,
      universal.prefix(3).joined(separator: " | "))

MainActor.assumeIsolated {
    guard let store = WKContentRuleListStore.default() else {
        print("  SKIP  no rule list store on this machine"); exit(0)
    }
    var pending = files.count
    for f in files {
        let url = URL(fileURLWithPath: dir + "/" + f)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
            check("\(f) is readable", false); pending -= 1; continue
        }
        // A fresh identifier each run, so a cached success cannot mask a broken list.
        store.compileContentRuleList(forIdentifier: "test.\(f).\(size)",
                                     encodedContentRuleList: json) { list, err in
            check("\(f) compiles", err == nil && list != nil,
                  err?.localizedDescription ?? "no list returned")
            pending -= 1
            if pending == 0 {
                print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
                exit(failures == 0 ? 0 : 1)
            }
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(300))
    print("  FAIL  timed out with \(pending) still compiling")
    exit(1)
}
