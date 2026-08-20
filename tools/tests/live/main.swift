import Foundation

// Hits the real Wikipedia API and probes the domains it publishes.
let sem = DispatchSemaphore(value: 0)
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

Task {
    do {
        let urls = try await WikipediaInfobox.urls(page: "Anna's Archive")
        print("  upstream lists \(urls.count) domains: \(urls.joined(separator: ", "))")
        check("live API parsed", !urls.isEmpty)
        check("no citation URLs leaked",
              !urls.contains { $0.contains("torrentfreak") || $0.contains("vertsluisants") })

        var anyAnswers = false
        for u in urls where await Reachability.answers(URL(string: u)!) { anyAnswers = true }
        check("at least one published domain answers", anyAnswers)

        // The bulk list, fetched the way the app fetches it.
        let sets = try await FMHYList.fetch()
        print("  FMHY published \(sets.count) usable mirror groups")
        check("FMHY parsed from the live endpoint", sets.count > 200, "got \(sets.count)")
        let x = sets.values.first { $0.candidates.contains { $0.host.map(registrableDomain) == "1337x.to" } }
        check("1337x present in the live list", x != nil)

        // The app opens 1337x behind a Cloudflare challenge, which must read as
        // reachable or the app would switch domains on every launch.
        let home = await Reachability.answers(URL(string: "https://1337x.to/home/")!)
        check("challenged 1337x still probes as reachable", home)

        // Control: a domain that cannot resolve must probe as unreachable, or the
        // fallback would never trigger.
        let bogus = await Reachability.answers(URL(string: "https://nx-\(UInt32.random(in: 0...9_999_999)).invalid/")!)
        check("an unresolvable domain probes as unreachable", !bogus)
    } catch {
        failures += 1
        print("  FAIL  live fetch threw: \(error)")
    }
    sem.signal()
}
sem.wait()
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
