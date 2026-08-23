import AppKit
import SwiftUI
import WebKit

/// Compiles the converted uBlock Origin lists into WebKit's native content blocker.
///
/// WKWebView cannot run a Firefox extension, but WebKit ships the same engine
/// Safari content blockers use. Compilation is cached on disk by identifier, so the
/// ~5s first run happens once per list version and later launches are instant.
@MainActor
final class ContentBlocker: ObservableObject {
    @Published private(set) var ruleLists: [WKContentRuleList] = []
    @Published private(set) var status: String = "Loading filters…"
    @Published private(set) var ruleCount: Int = 0

    private let store = WKContentRuleListStore.default()

    func load() async {
        guard let store else { status = "Content blocker unavailable"; return }
        guard let resources = Bundle.main.resourceURL else { return }

        let files = ((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.hasPrefix("blocklist-") && $0.hasSuffix(".json") }
            .sorted()
        if files.isEmpty { status = "No filter lists bundled"; return }

        var loaded: [WKContentRuleList] = []
        var total = 0
        for file in files {
            let url = resources.appendingPathComponent(file)
            // Version the identifier by content size so a rebuilt list recompiles
            // instead of silently serving the stale cached bytecode.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let identifier = "\(file).\(size)"

            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                loaded.append(cached)
                continue
            }
            guard let json = try? String(contentsOf: url, encoding: .utf8) else { continue }
            total += json.reduce(0) { $1 == "{" ? $0 + 1 : $0 }
            if let compiled = try? await store.compileContentRuleList(forIdentifier: identifier,
                                                                      encodedContentRuleList: json) {
                loaded.append(compiled)
            }
        }
        ruleLists = loaded
        ruleCount = total
        status = loaded.isEmpty ? "Filters failed to load" : "\(loaded.count) filter lists active"
    }
}

@MainActor
final class WebController: NSObject, ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var toast: String?
    @Published private(set) var toastIsError = false
    /// True while Cloudflare's interstitial is on screen. It renders 1337x's own
    /// nav bar with zero listings for ~6s, which reads as a broken page rather than
    /// a loading one — so the UI covers it instead of showing a half-page.
    @Published private(set) var isChallenged = false

    /// Reported when a load fails in a way that suggests the route is blocked.
    var onLoadFailure: ((String) -> Void)?

    private(set) var webView: WKWebView!
    /// What the current navigation chain came from, carried across its redirects.
    /// An on-site redirector defeats any per-hop rule, so the chain is what is judged.
    private var chain = RedirectGuard.Chain(appInitiated: true, anchorDomain: nil)
    /// True between starting a navigation and finishing it.
    private var navigationInFlight = false
    /// Whether the navigation now in flight began with a click. A file offered by a
    /// navigation nobody started is a different thing from one you asked for, and by
    /// the time the response arrives that distinction is no longer visible.
    private var navigationWasClicked = false
    /// A destination the user has been warned about, and how recently. Clicking the
    /// same link again inside the window lets it through.
    private var pendingConfirm: (url: URL, at: Date)?
    private static let confirmWindow: TimeInterval = 12
    private var observations: [NSKeyValueObservation] = []
    private var toastClear: DispatchWorkItem?
    private var challengeTimeout: DispatchWorkItem?
    private let sender = MagnetSender()

    /// Where magnet links are pushed. Often a reverse proxy in front of the client
    /// rather than the client itself, which is what makes this work on networks that
    /// block the client's own port. Nil until configured.
    var qbBase: URL? { AppSettings.shared.qbBase }

    override init() {
        super.init()
        rebuild(proxies: [], ruleLists: [])
    }

    /// WKWebView reads proxy settings when its data store is set up, so switching
    /// routes means building a new web view. Cookies and the content blocker are
    /// unaffected — the data store is the shared default one.
    func rebuild(proxies: [ProxyConfiguration], ruleLists: [WKContentRuleList]) {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.default()
        store.proxyConfigurations = proxies
        config.websiteDataStore = store
        for list in ruleLists { config.userContentController.add(list) }

        // Self-hosted banners, which no filter list can reach. Added regardless of the
        // restyling toggle: it is blocking, not decoration.
        config.userContentController.addUserScript(BannerBlocker.userScript())

        // One stylesheet across every site, when asked for. Injected here rather than
        // per-navigation so it is present before the first paint.
        if AppSettings.shared.unifiedStyleEnabled,
           let style = SiteStyle.userScript(css: AppSettings.shared.effectiveSiteCSS) {
            config.userContentController.addUserScript(style)
        }

        let old = webView
        let fresh = WKWebView(frame: .zero, configuration: config)
        fresh.allowsBackForwardNavigationGestures = true
        fresh.allowsMagnification = true
        // Sites are drawn larger than they ship. Page zoom reflows the layout, unlike
        // magnification, which scales the finished picture and pushes the right-hand
        // side of a table off the window.
        fresh.pageZoom = AppSettings.shared.effectiveSiteZoom
        fresh.underPageBackgroundColor = .windowBackgroundColor
        // Trackers serve different (worse) pages to anything that looks automated.
        fresh.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        fresh.navigationDelegate = self
        fresh.uiDelegate = self

        observations = [
            fresh.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.progress = v.estimatedProgress }
            },
            fresh.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.isLoading = v.isLoading }
            },
            fresh.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.canGoBack = v.canGoBack }
            },
        ]
        webView = fresh
        old?.stopLoading()
    }

    /// Zoom is a property of the view rather than of its data store, so changing it
    /// needs neither a fresh web view nor a reload -- the page reflows in place.
    func applyZoom() {
        webView.pageZoom = AppSettings.shared.effectiveSiteZoom
    }

    /// Whatever is on screen, so a rebuild can put the user back where they were.
    var currentURL: URL? { webView.url }

    /// The sites you actually use: everything in the bar, plus every domain of any
    /// mirror set the destination belongs to. This is the allow-list, drawn from your
    /// configuration rather than from a filter list.
    private func knownDomains(for destination: URL) -> Set<String> {
        var domains = DownloadManager.shared.knownSources()
        if let set = MirrorDirectory.shared.set(owning: destination) {
            for candidate in set.candidates {
                if let host = candidate.host { domains.insert(registrableDomain(host)) }
            }
        }
        return domains
    }

    func load(_ url: URL) {
        // The app asked for this, so trust it and every redirect it triggers -- that is
        // what lets a mirror 302 to its canonical domain.
        chain = RedirectGuard.Chain(appInitiated: true,
                                    anchorDomain: url.host.map(registrableDomain))
        webView.load(URLRequest(url: url))
    }
    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func stop() { webView.stopLoading() }

    func showToast(_ text: String, isError: Bool) {
        toast = text
        toastIsError = isError
        toastClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    fileprivate func handleMagnet(_ url: URL) {
        // Only a magnet claims to carry an info hash. A .torrent link is an ordinary
        // URL that the client fetches itself -- checking it for a hash rejected every
        // real one, which is a bug this guard introduced.
        if url.scheme?.lowercased() == "magnet", !MagnetSender.isValidMagnet(url) {
            showToast("That link is not a real magnet — nothing was sent.", isError: true)
            return
        }
        let name = MagnetSender.displayName(for: url)
        showToast("Sending \(name)…", isError: false)
        guard let base = qbBase else {
            showToast("No torrent client configured \u{2014} open Settings", isError: true)
            return
        }
        QBCredentialStore.withCredentials { [weak self] creds in
            guard let self else { return }
            guard let creds else {
                self.showToast("No qBittorrent sign-in saved — open Settings", isError: true)
                return
            }
            Task {
                let result = await self.sender.send(url, base: base, credentials: creds)
                await MainActor.run {
                    switch result {
                    case .added(let n): self.showToast("Sent to qBittorrent: \(n)", isError: false)
                    case .failed(let why): self.showToast("Couldn't send: \(why)", isError: true)
                    }
                }
            }
        }
    }
}

extension WebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }

        // Carried to the response, which cannot see it. A server redirect keeps the
        // click that started the chain -- following one is still something you asked
        // for -- so this is only cleared by a navigation that began without one.
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted, .backForward, .reload:
            navigationWasClicked = true
        case .other:
            // A redirect arrives as `.other` with no way to tell it from a script
            // navigation, so a chain that began with a click keeps its click.
            if !navigationInFlight { navigationWasClicked = false }
        @unknown default:
            navigationWasClicked = false
        }

        // A page sending the window somewhere else entirely, which is what a redirect
        // ad does on the first click anywhere.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, url.scheme?.lowercased() != "magnet" {
            let kind: RedirectGuard.NavigationKind
            switch navigationAction.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted: kind = .userLink
            case .backForward, .reload: kind = .history
            default: kind = .script
            }

            // Back and forward are always the user, and a browser that will not go back
            // is worse than any advert.
            if kind != .history {
                let confirmed = pendingConfirm.flatMap {
                    Date().timeIntervalSince($0.at) < Self.confirmWindow ? $0.url : nil
                }
                switch RedirectGuard.decide(from: webView.url, to: url, navigationType: kind,
                                            chain: chain, known: knownDomains(for: url),
                                            confirmedTarget: confirmed) {
                case .allow:
                    pendingConfirm = nil
                    // Only now. Setting the anchor before the decision aimed the chain
                    // at the very URL being judged, so `anchor == destination` always
                    // held and every click was allowed -- which is why a link straight
                    // to an advertiser sailed through, and the block you saw was a
                    // later hop, once the page was already there.
                    if kind == .userLink {
                        chain = RedirectGuard.Chain(
                            appInitiated: false,
                            anchorDomain: url.host.map(registrableDomain))
                    }
                case .block:
                    // Silently. A redirect you never asked for is not an event worth
                    // reporting -- announcing the block is its own interruption, and
                    // it arrives exactly as often as the adverts do.
                    decisionHandler(.cancel)
                    return
                case .confirm:
                    pendingConfirm = (url, Date())
                    showToast("\(url.host ?? "That site") is not one of yours \u{2014} "
                              + "click again to go there", isError: false)
                    decisionHandler(.cancel)
                    return
                }
            }
        }

        // The whole point of the old Torrent Control extension, done natively.
        //
        // Only from an actual link activation. A torrent handed to the client is a
        // download that starts, and a page that can reach this by assigning to
        // `location` gets to start one whenever you click anything at all -- which is
        // how a click on something unrelated turns into a torrent you did not choose.
        // A real magnet link is an anchor, and clicking an anchor is `.linkActivated`;
        // script-driven navigation is not.
        let activated: Bool
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted: activated = true
        default: activated = false
        }
        if url.scheme?.lowercased() == "magnet" {
            if activated { handleMagnet(url) }
            decisionHandler(.cancel)
            return
        }
        // A .torrent file link is the other way trackers hand over a torrent.
        if url.pathExtension.lowercased() == "torrent" {
            if activated { handleMagnet(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Anna's Archive serves its files as ordinary navigations, so without this
        // they either render as junk or silently do nothing.
        switch DownloadManager.shared.disposition(navigationResponse,
                                                  pageURL: webView.url,
                                                  userInitiated: navigationWasClicked) {
        case .capture:
            // Asked here rather than after the download object exists, so a refusal
            // never opens a connection at all.
            let url = navigationResponse.response.url
            if DownloadManager.shared.isPreApproved(url) {
                decisionHandler(.download)
                return
            }
            let size = navigationResponse.response.expectedContentLength
            let approved = DownloadManager.approve(
                filename: url?.lastPathComponent ?? "",
                host: url?.host ?? "an unknown host",
                bytes: size > 0 ? size : nil)
            decisionHandler(approved ? .download : .cancel)
        case .refuse(let why):
            // Cancelled, not allowed: allowing an unrenderable response paints the
            // raw bytes into the window.
            showToast(why, isError: true)
            decisionHandler(.cancel)
        case .allow:
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        admit(download, page: webView.url)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        // This path skips the response policy step entirely, so the check has to be
        // repeated here or it is not a check at all.
        admit(download, page: webView.url)
    }

    /// Take the download, or cancel it. Nothing is written without an answer.
    private func admit(_ download: WKDownload, page: URL?) {
        let url = download.originalRequest?.url
        let manager = DownloadManager.shared
        if let why = manager.refusalReason(forDownloadOf: url, page: page,
                                           userInitiated: navigationWasClicked) {
            download.cancel(nil)
            showToast(why, isError: true)
            return
        }
        // A host approved once is not asked about again; everything else asks.
        if !manager.isPreApproved(url) {
            let approved = DownloadManager.approve(
                filename: url?.lastPathComponent ?? "",
                host: url?.host ?? "an unknown host",
                bytes: download.progress.totalUnitCount > 0
                    ? download.progress.totalUnitCount : nil)
            guard approved else {
                download.cancel(nil)
                return
            }
        }
        manager.attach(download, page: page)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationInFlight = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Spent. It covered this navigation and its redirects; it does not extend to
        // whatever the page does once it is on screen.
        chain.appInitiated = false
        chain.anchorDomain = webView.url?.host.map(registrableDomain) ?? chain.anchorDomain
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationInFlight = false
        // The challenge page reloads itself when solved, so this fires again with
        // the real page and clears the flag.
        webView.evaluateJavaScript("document.title") { [weak self] value, _ in
            guard let self else { return }
            let title = ((value as? String) ?? "").lowercased()
            let challenged = title.contains("just a moment")
                || title.contains("attention required")
                || title.contains("checking your browser")
            self.isChallenged = challenged
            self.challengeTimeout?.cancel()
            if challenged {
                // Never hold the cover indefinitely — if the challenge stalls, show
                // the page so the user can interact with it (some need a click).
                let work = DispatchWorkItem { [weak self] in self?.isChallenged = false }
                self.challengeTimeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationInFlight = false
        isChallenged = false
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationInFlight = false
        isChallenged = false
        report(error)
    }

    /// Failures that mean the domain itself is not answering, rather than the site
    /// answering with something unwelcome. Only these justify moving to another
    /// domain: an HTTP-level rejection -- a Cloudflare 403 above all -- still
    /// proves the domain is alive, and switching away from it would be wrong.
    private static let transportFailures: Set<Int> = [
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorTimedOut,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorNetworkConnectionLost,
    ]

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 101 || ns.code == 102) { return }

        // A chip pointing at a site that has gone away used to do nothing at all:
        // the only consumer of onLoadFailure is an empty closure, so the previous
        // page simply stayed on screen and the click looked ignored. Only main-frame
        // navigations reach here — blocked subresources never do — so this stays
        // quiet during normal browsing.
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }

        // A site that publishes several domains gets moved to one that answers
        // rather than reported as broken.
        if ns.domain == NSURLErrorDomain, Self.transportFailures.contains(ns.code),
           let failing, let set = MirrorDirectory.shared.set(owning: failing) {
            showToast("\(set.name) is not answering on \(failing.host ?? "that domain") — trying another…",
                      isError: false)
            Task {
                if let alternate = await MirrorDirectory.shared.alternate(for: failing) {
                    self.load(alternate)
                } else {
                    self.showToast("No working domain found for \(set.name)", isError: true)
                }
            }
            onLoadFailure?(ns.localizedDescription)
            return
        }

        if let host = failing?.host {
            showToast("\(host) — \(ns.localizedDescription)", isError: true)
        } else {
            showToast(ns.localizedDescription, isError: true)
        }
        onLoadFailure?(ns.localizedDescription)
    }
}

extension WebController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Tracker sites monetise with popunders. Unlike the qBittorrent app — where
        // an unrecognised link is handed to the default browser — here that would
        // BE the ad behaviour, so target=_blank is dropped entirely. Magnets are
        // still caught, because they arrive through the navigation delegate.
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "magnet" {
            handleMagnet(url)
        }
        // Download links commonly open in a new tab, so dropping every target=_blank
        // would kill the download along with the ads. Loading it in THIS view keeps
        // the popunder defence intact -- nothing new is opened, and the response
        // still has to satisfy the download check to be captured. Deliberately not
        // handed to the default browser: on a tracker page that IS the ad behaviour.
        if let url = navigationAction.request.url,
           DownloadManager.shared.mayBeDownload(url, pageURL: webView.url) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        // Ad scripts love alert(). Swallow rather than interrupt.
        completionHandler()
    }
}

struct WebPane: NSViewRepresentable {
    let controller: WebController
    /// Changing this forces SwiftUI to swap in the rebuilt web view after a
    /// route switch, which otherwise keeps showing the old one.
    let generation: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(controller.webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(controller.webView, to: container)
        }
    }

    private func attach(_ web: WKWebView, to container: NSView) {
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
