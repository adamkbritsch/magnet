import Foundation
import UserNotifications

/// Tells you, outside the window, what Automatic did that you would want to know: an
/// episode is in the library, a better copy replaced one, or something needs you.
///
/// It reads the NAS's activity every couple of minutes while Magnet is open, whichever
/// mode is showing, and only what is new since the last look -- the first look marks
/// everything before it as seen, so turning this on never replays a backlog.
@MainActor
final class AutoNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AutoNotifier()

    /// Opens Automatic, at the show a notification is about when it has one.
    var onOpen: ((Int?) -> Void)?
    /// What needs a person, as of the last look.
    var onAttention: (([AutoAttention]) -> Void)?

    private var task: Task<Void, Never>?
    private var asked = false
    private let interval: Duration = .seconds(120)
    private let lastKey = "automatic.notify.lastEvent"
    private let attentionKey = "automatic.notify.attention"

    func start() {
        guard task == nil else { return }
        UNUserNotificationCenter.current().delegate = self
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))       // let the window settle first
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: self?.interval ?? .seconds(120))
            }
        }
    }

    func poll() async {
        guard let client = AutoClient.current() else { return }
        let d = UserDefaults.standard
        let last = d.integer(forKey: lastKey)
        let feed: AutoActivityFeed
        do {
            feed = try await client.activity(since: last, limit: 100)
        } catch {
            return              // the NAS is not answering; the window says so when it is open
        }
        onAttention?(feed.attention)
        let wanted = Config.notifyArrived || Config.notifyUpgraded || Config.notifyAttention
        if wanted && !asked {
            asked = true
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        let known = Set(d.stringArray(forKey: attentionKey) ?? [])
        defer {
            d.set(feed.latest, forKey: lastKey)
            d.set(feed.attention.map(\.key), forKey: attentionKey)
        }
        guard last > 0 else { return }              // first look: nothing before now is news
        for e in feed.events.reversed() where e.kind == "transferred" {
            let what = [e.series, e.code].compactMap { $0 }.joined(separator: " ")
            let quality = e.badges.map(\.text).joined(separator: " \u{00B7} ")
            if e.upgrade == true {
                guard Config.notifyUpgraded else { continue }
                post(id: "event-\(e.id)", title: "\(what.isEmpty ? "An episode" : what) upgraded",
                     body: quality.isEmpty ? "A better copy replaced the one in your library." : "Now \(quality).",
                     show: e.seriesId)
            } else {
                guard Config.notifyArrived else { continue }
                let body = [e.episodeTitle, quality.isEmpty ? nil : quality].compactMap { $0 }
                    .joined(separator: " \u{00B7} ")
                post(id: "event-\(e.id)", title: "\(what.isEmpty ? "A new episode" : what) is ready",
                     body: body.isEmpty ? "It is in your library." : body, show: e.seriesId)
            }
        }
        if Config.notifyAttention {
            for a in feed.attention where !known.contains(a.key) {
                post(id: "attention-\(a.key)", title: a.title, body: a.detail, show: nil)
            }
        }
    }

    private func post(id: String, title: String, body: String, show: Int?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let show { content.userInfo = ["show": show] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let show = response.notification.request.content.userInfo["show"] as? Int
        Task { @MainActor in
            self.onOpen?(show)
            completionHandler()
        }
    }
}
