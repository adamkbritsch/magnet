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
