import AppKit
import SwiftUI
import WebKit

// qBittorrent's own web interface, in the same window as the browser.
//
// This used to be a separate app sat beside Magnet. It is brought in as a pane rather
// than a mode because the two are used together: pick a torrent on the right, watch it
// arrive on the left. Only qBittorrent comes along -- the old app's ruTorrent switch
// and its Digest sign-in are gone, as are its route menu and click diagnostics. The
// pane reaches qBittorrent at the same address Magnet already sends magnets to
// (Settings -> Torrent Client), with the same saved sign-in.

/// WKWebView that does not eat the first click.
///
/// By default an NSView returns false for `acceptsFirstMouse`, so when the window is not
/// already key the click that activates it is consumed instead of reaching the page.
/// With a qBittorrent context menu open, the swallowed click leaves the menu stranded.
final class QBClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class QBPaneController: NSObject, ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    /// A download that finished, or why sign-in did not happen. Shown in the pane's bar.
    @Published private(set) var note: String?
    @Published private(set) var noteIsWarning = false
    /// True from the moment a load finishes until sign-in has resolved. The pane stays
    /// covered meanwhile, so qBittorrent's login form is never briefly visible.
    @Published private(set) var isAuthenticating = false
    /// Why the last load failed, while nothing else is on screen.
    @Published private(set) var failure: String?

    static let defaultZoom: Double = 1.10
    private static let zoomKey = "qb.pane.zoom"
    /// The pane's own cookie jar, fixed so its sign-in survives relaunch. Separate from
    /// the browser's on purpose: the browser's data store carries the CONNECT proxy
    /// when Via NAS is on, and that proxy only tunnels HTTPS -- qBittorrent's address
    /// is plain HTTP over the tailnet, so sharing a store would break the pane exactly
    /// when the browser is working best.
    private static let storeID = UUID(uuidString: "9C4E2A71-5B0D-4F38-8E2C-3A7D51B6F0C4")!

    let webView: WKWebView

    private var base: URL?
    private var started = false
    private var observations: [NSKeyValueObservation] = []
    private var noteClear: DispatchWorkItem?
    private var gateTimeout: DispatchWorkItem?
    private var hideTask: DispatchWorkItem?
    private var crashRetries = 0

    /// Sign-in is attempted at most once per load, and stops for the launch after two
    /// rejections. qBittorrent bans an IP after a handful of failed logins, and the IP it
    /// would ban is the NAS -- which would cut off Magnet's magnets and the Automatic
    /// mode's gate along with this pane.
    private var attempted: Set<String> = []
    private var rejections = 0
    private var transientFailures = 0
    private var hardDisabled = false
    /// Bumped on every load, so a sign-in result from a superseded load is discarded.
    private var generation = 0
    private var inFlight = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = QBClickThroughWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        // qBittorrent's WebUI is designed dense; a small bump reads better on Retina.
        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        webView.pageZoom = saved > 0 ? saved : Self.defaultZoom
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.progress = v.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.isLoading = v.isLoading }
            },
        ]
        Self.installContextClickFix(on: config)
    }

    // MARK: - Showing and hiding

    /// Loads the first time the pane is shown, not at launch: nothing is fetched, and
    /// no saved sign-in is read, for a pane nobody has opened.
    func setShown(_ shown: Bool, base: URL?) {
        hideTask?.cancel()
        if shown {
            // A hidden web view tells the page it is hidden, and qBittorrent slows its
            // refresh to match; shown again, it catches up at once.
            webView.isHidden = false
            guard let base else { return }
            if !started || self.base != base {
                started = true
                load(base, force: self.base != nil && self.base != base)
            }
        } else {
            // After the slide, not before it, so the pane does not blank mid-animation.
            let task = DispatchWorkItem { [weak self] in self?.webView.isHidden = true }
            hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        }
    }

    /// Whether the keyboard is in this pane, so Reload can go to the side being used.
    var hasKeyboardFocus: Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    // MARK: - Loading

    func load(_ url: URL, force: Bool = false) {
        if !force, base == url, webView.url != nil { return }
        base = url
        failure = nil

        let wasInFlight = inFlight
        generation += 1
        inFlight = false
        // An explicit reload is a fresh chance to sign in; automatic reloads are not.
        // Not while an attempt is outstanding: two concurrent logins are two hits on
        // qBittorrent's ban counter.
        if force && !wasInFlight { attempted.remove(url.absoluteString) }

        isAuthenticating = signInPlausible(for: url)
        if isAuthenticating { startGateTimeout() } else { finishGate() }

        var request = URLRequest(url: url)
        request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        webView.load(request)
    }

    func reload() {
        if let base { load(base, force: true) }
    }

    func toggleReload() {
        if webView.isLoading { webView.stopLoading() } else { reload() }
    }

    /// The saved sign-in changed in Settings: a password rejected earlier gets a clean
    /// slate, and a pane showing the login form tries again.
    func credentialsChanged() {
        attempted.removeAll()
        rejections = 0
        transientFailures = 0
        hardDisabled = false
        setNote(nil)
        if started { reload() }
    }

    private var autoLoginEnabled: Bool {
        UserDefaults.standard.object(forKey: "qb.pane.autoLogin") as? Bool ?? true
    }

    private func signInPlausible(for url: URL) -> Bool {
        autoLoginEnabled
            && !hardDisabled
            && rejections < 2
            && transientFailures < 3
            && !attempted.contains(url.absoluteString)
            // Attributes only: never a password box just to decide whether to try.
            && QBCredentialStore.exists()
    }

    // MARK: - Sign-in

    /// Runs after each finished load, inside the page, so the request carries the page's
    /// own cookies. Asks first whether a session already exists -- which sends nothing,
    /// so it runs on every load and is what hands a used attempt back once signed in.
    /// That matters an hour later, when qBittorrent's session expires and the WebUI
    /// reloads onto its login page: the attempt is there to spend again. The saved
    /// password is read from the Keychain only when there is no session.
    private func attemptSignIn() {
        guard let base, let loaded = webView.url, isServicePage(loaded, base),
              !inFlight, autoLoginEnabled, !hardDisabled else {
            finishGate()
            return
        }
        let gen = generation
        inFlight = true
        webView.callAsyncJavaScript(QBPaneAuthScript.probe, arguments: scriptArguments(base),
                                    in: nil, in: .defaultClient) { [weak self] result in
            guard let self, gen == self.generation else { return }
            self.inFlight = false
            let raw = (try? result.get()) as? String ?? "unknown"
            if raw == "already" {
                self.handle(.alreadySignedIn, base: base)
                return
            }
            if raw != "signed-out" {
                self.handle(QBPaneAuthScript.interpret(raw), base: base)
                return
            }
            guard self.signInPlausible(for: base) else { self.finishGate(); return }
            QBCredentialStore.withCredentials { [weak self] credentials in
                guard let self, gen == self.generation else { return }
                guard let credentials else { self.finishGate(); return }
                guard let loaded = self.webView.url, self.isServicePage(loaded, base),
                      !self.inFlight, self.signInPlausible(for: base) else {
                    self.finishGate()
                    return
                }
                self.attempted.insert(base.absoluteString)
                self.inFlight = true
                var args = self.scriptArguments(base)
                args["u"] = credentials.username
                args["p"] = credentials.password
                // Credentials go in as arguments, never into the script source, and in
                // an isolated content world, so qBittorrent's own scripts cannot see them.
                self.webView.callAsyncJavaScript(QBPaneAuthScript.login, arguments: args,
                                                 in: nil, in: .defaultClient) { [weak self] result in
                    guard let self, gen == self.generation else { return }
                    self.inFlight = false
                    switch result {
                    case .success(let value):
                        self.handle(QBPaneAuthScript.interpret((value as? String) ?? "unknown"), base: base)
                    case .failure(let error):
                        self.handle(.unavailable(error.localizedDescription), base: base)
                    }
                }
            }
        }
    }

    private func scriptArguments(_ base: URL) -> [String: Any] {
        ["expected": Self.origin(of: base), "basePath": Self.basePath(of: base)]
    }

    private func handle(_ outcome: QBPaneLogin, base: URL) {
        switch outcome {
        case .alreadySignedIn:
            // Nothing was sent, so the slot comes back: a session that expires later in
            // the launch can still be signed back into.
            attempted.remove(base.absoluteString)
            rejections = 0
            transientFailures = 0
            if noteIsWarning { setNote(nil) }
            finishGate()
        case .success:
            rejections = 0
            transientFailures = 0
            if noteIsWarning { setNote(nil) }
            // Reload so the WebUI boots signed in rather than sitting on its login page.
            // The cover stays up across the reload.
            webView.reload()
        case .rejected:
            rejections += 1
            setNote("The saved qBittorrent sign-in was refused -- check Settings \u{2192} Torrent Client.",
                    warning: true)
            finishGate()
        case .blocked(let why):
            hardDisabled = true
            setNote(why, warning: true)
            finishGate()
        case .unavailable(let why):
            // Nothing left the process, so the slot comes back, but bounded.
            transientFailures += 1
            if transientFailures < 3 { attempted.remove(base.absoluteString) }
            setNote(why, warning: true)
            finishGate()
        }
    }

    /// Never leave the pane covered. If sign-in has not resolved in time, show the page:
    /// the worst case is qBittorrent's own login form. 10s because the first Keychain
    /// read after the app's signature changes costs macOS several seconds.
    private func startGateTimeout() {
        gateTimeout?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.isAuthenticating = false }
        gateTimeout = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: task)
    }

    private func finishGate() {
        gateTimeout?.cancel()
        gateTimeout = nil
        if isAuthenticating { isAuthenticating = false }
    }

    private func setNote(_ text: String?, warning: Bool = false, clearAfter: Double? = nil) {
        noteClear?.cancel()
        note = text
        noteIsWarning = text != nil && warning
        guard let clearAfter, text != nil else { return }
        let task = DispatchWorkItem { [weak self] in self?.note = nil; self?.noteIsWarning = false }
        noteClear = task
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter, execute: task)
    }

    // MARK: - Where a page belongs

    nonisolated static func origin(of url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "" }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// The path with a guaranteed leading and trailing slash, so a prefix test cannot
    /// match a sibling by accident.
    nonisolated static func basePath(of url: URL) -> String {
        var path = url.path
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    /// Same scheme, host, port and path root as qBittorrent's address. The password is
    /// only ever offered to a page that passes this.
    private func isServicePage(_ loaded: URL, _ base: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        guard loaded.scheme?.lowercased() == base.scheme?.lowercased(),
              loaded.host?.lowercased() == base.host?.lowercased(),
              port(loaded) == port(base) else { return false }
        return Self.basePath(of: loaded).hasPrefix(Self.basePath(of: base))
    }

    // MARK: - Control-click

    /// Makes macOS Control-click behave the way qBittorrent's WebUI expects.
    ///
    /// WebKit dispatches Control-click as mousedown -> contextmenu -> mouseup ->
    /// click(ctrlKey). qBittorrent selects the row on `contextmenu`, then reads the
    /// trailing ctrl-click as "toggle selection" and deselects it again, so every menu
    /// action silently does nothing. The fix suppresses that one trailing click: same
    /// target, within 3px and 700ms, once per gesture. A click on a menu item has a
    /// different target and is never touched.
    private static func installContextClickFix(on config: WKWebViewConfiguration) {
        let js = """
        (function () {
          let at = 0, cx = 0, cy = 0, target = null;
          window.addEventListener('contextmenu', function (e) {
            at = e.timeStamp; cx = e.clientX; cy = e.clientY; target = e.target;
          }, true);
          window.addEventListener('click', function (e) {
            if (!at) return;
            const sameSpot = Math.abs(e.clientX - cx) <= 3 && Math.abs(e.clientY - cy) <= 3;
            if ((e.timeStamp - at) < 700 && e.target === target && sameSpot) {
              at = 0;
              e.stopImmediatePropagation();
              e.preventDefault();
            }
          }, true);
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: - Downloads

    private func uniqueDestination(for suggested: String) -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        // Only the last path component: a suggested name is the server's to choose.
        let cleaned = (suggested as NSString).lastPathComponent
        let name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "download" : cleaned
        var candidate = dir.appendingPathComponent(name)
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        while fm.fileExists(atPath: candidate.path) && n < 500 {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func report(_ error: Error) {
        finishGate()
        let ns = error as NSError
        // -999 is a load replaced or cancelled here; 102 and 101 are a download taking
        // over the navigation. Neither means qBittorrent is down.
        if ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 101) { return }
        let message: String
        switch ns.code {
        case NSURLErrorTimedOut: message = "The connection timed out."
        case NSURLErrorCannotConnectToHost: message = "The NAS refused the connection."
        case NSURLErrorCannotFindHost: message = "That address didn't resolve."
        case NSURLErrorNotConnectedToInternet: message = "This Mac has no network connection."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            message = "App Transport Security blocked the plain-HTTP address."
        case NSURLErrorSecureConnectionFailed: message = "The TLS handshake failed."
        default: message = ns.localizedDescription
        }
        failure = message
    }
}

// MARK: - Navigation

extension QBPaneController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A clicked link to another host (the About box links to qbittorrent.org) goes to
        // the default browser; qBittorrent itself stays in the pane.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let host = url.host, let own = base?.host,
           host.lowercased() != own.lowercased() {
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // Anything WebKit cannot show is a file: a .torrent exported from the list.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishGate()
        guard crashRetries < 2, let base else { return }
        crashRetries += 1
        load(base, force: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        crashRetries = 0
        failure = nil
        attemptSignIn()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        report(error)
    }
}

// MARK: - Panels

extension QBPaneController: WKUIDelegate {
    /// target="_blank": no second window. A web link goes to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// qBittorrent's "Add Torrent File". Without this the file picker never opens.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }
}

// MARK: - Downloads

extension QBPaneController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        completionHandler(uniqueDestination(for: suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        let name = download.progress.fileURL?.lastPathComponent ?? "file"
        setNote("Saved \(name) to Downloads", clearAfter: 6)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        setNote("Download failed: \(error.localizedDescription)", warning: true, clearAfter: 6)
    }
}

// MARK: - Sign-in script

enum QBPaneLogin: Equatable {
    case alreadySignedIn
    case success
    /// qBittorrent answered, and said no. Retrying walks toward its ban threshold.
    case rejected
    /// Do not try again this launch: an IP ban, or the page was not where we thought.
    case blocked(String)
    /// Transient. No password left the process.
    case unavailable(String)
}

/// The JavaScript that signs in, run inside the loaded page.
///
/// Not a native URLSession: a separate session shares no cookie jar with the web view,
/// so it would sign in a session the page never sees. Same-origin inside the page, the
/// cookie lands where the WebUI reads it.
enum QBPaneAuthScript {
    /// Checks shared by both scripts. The Swift side checked the page before running
    /// them, but the document could have changed since -- so the target is asserted
    /// again here, where the request is actually made, and API URLs are built from the
    /// configured address rather than resolved against whatever page is loaded.
    private static let guards = """
    if (location.origin !== expected) { return 'origin-mismatch'; }
    if (basePath && !location.pathname.startsWith(basePath)) { return 'path-mismatch'; }
    const at = (rel) => new URL(rel, expected + (basePath || '/')).toString();
    // redirect: 'error' is load-bearing. 307/308 keep the method AND the body across a
    // cross-origin redirect, and a form POST needs no preflight -- so following one
    // would hand the password to whatever host the Location header names.
    const signedIn = async () => {
        const r = await fetch(at('api/v2/app/version'),
                              { credentials: 'same-origin', redirect: 'error', cache: 'no-store' });
        return r.ok;
    };
    """

    /// Sends nothing: only asks whether this page already has a session.
    static let probe = guards + """
    try { return (await signedIn()) ? 'already' : 'signed-out'; }
    catch (e) { return 'blocked:probe'; }
    """

    /// qBittorrent 5.2 answers a good sign-in with 204 and an empty body, where 5.1 said
    /// 200 "Ok." -- so neither the status nor the body is trusted on its own. A reply
    /// that says "Fails." is a no; anything else is checked by asking for the version
    /// again, which only works if the session cookie really arrived.
    static let login = guards + """
    let res;
    try {
        res = await fetch(at('api/v2/auth/login'), {
            method: 'POST',
            credentials: 'same-origin',
            redirect: 'error',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ username: u, password: p }).toString()
        });
    } catch (e) {
        return 'blocked:login';
    }
    if (res.type !== 'basic') { return 'origin-mismatch'; }
    if (res.status === 403) { return 'denied'; }
    if (!res.ok) { return 'http:' + res.status; }
    const text = (await res.text()).trim().toLowerCase();
    if (text.startsWith('fail')) { return 'rejected'; }
    try { return (await signedIn()) ? 'ok' : 'rejected'; }
    catch (e) { return 'blocked:probe'; }
    """

    static func interpret(_ raw: String) -> QBPaneLogin {
        switch raw {
        case "already": return .alreadySignedIn
        case "ok": return .success
        case "rejected": return .rejected
        case "origin-mismatch": return .blocked("The page changed address mid-sign-in")
        case "path-mismatch": return .unavailable("Not on the qBittorrent page -- sign-in skipped")
        case "denied":
            // 403 on auth/login is qBittorrent's ban, usually from earlier failures.
            return .blocked("qBittorrent refused the sign-in -- the NAS may be rate-limited")
        case "blocked:probe", "blocked:login":
            return .unavailable("qBittorrent redirected the sign-in")
        default:
            if raw.hasPrefix("http:") { return .unavailable("HTTP \(raw.dropFirst(5))") }
            return .unavailable(raw)
        }
    }
}

// MARK: - Views

/// Hosts the controller's web view without owning it, so a layout change re-parents
/// the same WKWebView instead of starting a new WebKit process and signing in again.
struct QBWebPane: NSViewRepresentable {
    let controller: QBPaneController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let web = controller.webView
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

/// The qBittorrent pane: its own bar, then the WebUI.
struct QBPaneView: View {
    @ObservedObject var controller: QBPaneController
    /// The pane's bar is in the window's titlebar row, so it leaves room for the window
    /// buttons and lines its content up with them.
    let inTitlebar: Bool
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider().overlay(Theme.hairline)
            ZStack {
                QBWebPane(controller: controller)
                if let failure = controller.failure, !controller.isLoading {
                    Color(nsColor: .windowBackgroundColor)
                    QBOfflineView(reason: failure,
                                  onRetry: { controller.reload() },
                                  onSettings: onSettings)
                } else if controller.isAuthenticating {
                    Color(nsColor: .windowBackgroundColor)
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Signing in\u{2026}")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var bar: some View {
        ZStack(alignment: .bottom) {
            VisualEffectView()
            if inTitlebar { WindowDragArea() }

            HStack(spacing: 10) {
                if inTitlebar { Color.clear.frame(width: Theme.trafficLightGutter, height: 1) }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                    Text("qBittorrent")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
                .fixedSize()

                Spacer(minLength: 12)

                if let note = controller.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(controller.noteIsWarning
                                         ? Color(nsColor: .systemOrange) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // The note gives way first when the bar is tight.
                        .layoutPriority(-1)
                        .help(note)
                        .transition(.opacity)
                }

                ChromeButton(symbol: controller.isLoading ? "xmark" : "arrow.clockwise",
                             help: controller.isLoading ? "Stop" : "Reload qBittorrent") {
                    controller.toggleReload()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: inTitlebar ? Theme.titlebarBandHeight : Theme.barHeight)
            .frame(maxHeight: .infinity, alignment: .top)

            if controller.isLoading {
                GeometryReader { geo in
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * max(0.02, controller.progress), height: 2)
                }
                .frame(height: 2)
                .transition(.opacity)
            }
        }
        .frame(height: Theme.barHeight)
        .animation(.easeInOut(duration: 0.18), value: controller.isLoading)
        .animation(.easeInOut(duration: 0.2), value: controller.note)
    }
}

private struct QBOfflineView: View {
    let reason: String
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("qBittorrent didn't answer")
                .font(.system(size: 14, weight: .semibold))
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("Try Again", action: onRetry)
                Button("Settings\u{2026}", action: onSettings)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Places the qBittorrent pane and the rest of Magnet using PaneSplit's frames. A Layout
/// rather than switching between an HStack and a VStack, so both children keep their
/// identity when the window crosses the threshold -- nothing reloads, nothing loses
/// its place.
struct QBSplitLayout: Layout {
    var shown: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = PaneSplit.frames(for: bounds.size, shown: shown)
        for (view, frame) in zip(subviews, [frames.pane, frames.magnet]) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
