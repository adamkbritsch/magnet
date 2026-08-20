import Foundation

// Every catalogue URL, fetched for real.
//
// A plugin URL that has rotted fails silently in production: qBittorrent accepts the
// install request, fetches nothing, and simply ends up without the plugin. There is
// no error to notice, so the only way to know is to look -- which is what this does.
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

let session: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 30
    return URLSession(configuration: cfg)
}()

struct Verdict { let ok: Bool; let detail: String }

func fetch(_ plugin: SearchPluginSource) async -> Verdict {
    guard let url = plugin.sourceURL else { return Verdict(ok: false, detail: "unparseable URL") }
    do {
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse else { return Verdict(ok: false, detail: "no response") }
        guard http.statusCode == 200 else { return Verdict(ok: false, detail: "HTTP \(http.statusCode)") }
        guard let text = String(data: data, encoding: .utf8) else {
            return Verdict(ok: false, detail: "not text")
        }
        // qBittorrent loads the file as a Python module and instantiates a class named
        // after the engine, so those two things are what make it a plugin.
        guard text.contains("def search") else { return Verdict(ok: false, detail: "no search method") }
        // qBittorrent loads an engine with `from engines.<name> import <name>`, so the
        // module must expose that exact lowercase name -- as the class itself, or as
        // an alias for a capitalised one, which several plugins use.
        let exposesEngine = text.contains("class \(plugin.id)")
            || text.range(of: "(?m)^\(NSRegularExpression.escapedPattern(for: plugin.id)) *=",
                          options: .regularExpression) != nil
        guard exposesEngine else {
            return Verdict(ok: false, detail: "nothing named \(plugin.id) at module level -- the "
                           + "engine name is wrong, so it would be reinstalled on every sync")
        }
        return Verdict(ok: true, detail: "\(data.count) bytes")
    } catch {
        return Verdict(ok: false, detail: (error as NSError).localizedDescription)
    }
}

print("Every plugin in the catalogue is still published")
let results = await withTaskGroup(of: (SearchPluginSource, Verdict).self) { group in
    for plugin in SearchPluginCatalogue.all {
        group.addTask { (plugin, await fetch(plugin)) }
    }
    var out: [(SearchPluginSource, Verdict)] = []
    for await r in group { out.append(r) }
    return out.sorted { $0.0.id < $1.0.id }
}
for (plugin, verdict) in results {
    check("\(plugin.site) (\(plugin.id))", verdict.ok, verdict.detail)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
