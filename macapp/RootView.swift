import AppKit
import SwiftUI

struct RootView: View {
    @StateObject private var routes = RouteStore()
    @StateObject private var web = WebController()
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var blocker = ContentBlocker()
    @StateObject private var plugins = SearchPluginSync()
    @State private var generation = 0
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var started = false
    /// The domain actually opened, which may be a mirror of the configured home.
    @State private var homeURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(routes: routes, web: web, bookmarks: bookmarks,
                   blocker: blocker, showSettings: $showSettings, onHome: goHome)
            Divider().overlay(Theme.hairline)
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            SettingsPane(routes: routes, bookmarks: bookmarks, blocker: blocker,
                         plugins: plugins)
        }
        .task {
            guard !started else { return }
            started = true
            web.onLoadFailure = { _ in }
            bookmarks.start()
            DownloadManager.shared.onMessage = { text, isError in
                web.showToast(text, isError: isError)
            }
            // Every site in the bar counts as a download source, so bookmarking a new
            // one in Firefox is all it takes for its downloads to be captured.
            DownloadManager.shared.knownSources = {
                var domains = Set<String>()
                for bm in bookmarks.visible + bookmarks.hiddenBookmarks {
                    if let host = bm.url.host { domains.insert(registrableDomain(host)) }
                }
                return domains
            }
            MirrorDirectory.shared.onSwitch = { name, url in
                web.showToast("\(name) moved to \(url.host ?? url.absoluteString)", isError: false)
            }
            // Independent of the web view, so it must not delay first paint.
            Task { await MirrorDirectory.shared.refresh() }
            // Filters first: a web view built before they compile would browse
            // unprotected until the next rebuild.
            await blocker.load()
            await openHome()
        }
        // A home set for the first time in Settings should take effect without a
        // relaunch, which is the whole first-run path.
        .onChange(of: settings.homeURL) { _, _ in
            Task { await openHome() }
        }
        .onChange(of: routes.status) { _, new in
            if case .live = new { applyRoute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qbHome)) { _ in goHome() }
        .onReceive(NotificationCenter.default.publisher(for: .qbBack)) { _ in web.goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .qbReload)) { _ in
            web.isLoading ? web.stop() : web.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qbSettings)) { _ in showSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .qbRecheck)) { _ in
            Task { await routes.resolve(); applyRoute() }
        }
        .onChange(of: routes.proxyNeedsCredentials) { _, needed in
            if needed {
                web.showToast("The NAS proxy sign-in could not be read, so every site is "
                              + "refused. Open Settings \u{2192} Connection and set it again.",
                              isError: true)
            }
        }
        .onChange(of: settings.siteZoom) { _, _ in web.applyZoom() }
        .modifier(PluginSyncTriggers(bookmarks: bookmarks, settings: settings,
                                     sync: syncPlugins))
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .bottom) {
            if settings.home == nil {
                SetupView { showSettings = true }
            } else {
                switch routes.status {
            case .probing:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Finding a route…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .offline(let why):
                OfflineView(reason: why) {
                    Task { await routes.resolve(); applyRoute() }
                } onSettings: { showSettings = true }
            case .live:
                ZStack {
                    WebPane(controller: web, generation: generation)
                    if web.isChallenged {
                        Color(nsColor: .windowBackgroundColor)
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Clearing Cloudflare's check…")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("The site shows an empty page while this runs.")
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
                }
            }

            if let toast = web.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(
                        Capsule().fill(web.toastIsError
                                       ? Color(nsColor: .systemRed)
                                       : Color(nsColor: .systemGreen))
                    )
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: web.toast)
    }

    /// Settles on a domain before probing routes, so a dead home domain reads as
    /// "use a mirror" rather than "you are offline".
    private func openHome() async {
        guard let configured = settings.home else {
            homeURL = nil
            routes.homeProbeURL = nil
            return
        }
        homeURL = await MirrorDirectory.shared.preferredURL(for: configured)
        routes.homeProbeURL = homeURL
        await routes.resolve()
        applyRoute()
    }

    /// Rebuilds the web view so a stylesheet change takes effect, and puts the user
    /// back on the page they were reading rather than bouncing them home.
    private func applyRoute() {
        web.rebuild(proxies: routes.proxyConfigurations(), ruleLists: blocker.ruleLists)
        generation += 1
        if let homeURL { web.load(homeURL) }
    }

    private func goHome() { if let homeURL { web.load(homeURL) } }

    private func syncPlugins() {
        // The home site counts. Its chip is usually hidden because the Home button
        // already goes there, and it is the site used most of all.
        var sites = bookmarks.visible.map(\.url)
        if let home = settings.home, !sites.contains(where: { $0.host == home.host }) {
            sites.insert(home, at: 0)
        }
        plugins.syncIfNeeded(sites: sites, alsoKnownAs: Self.mirrorDomains)
    }

    /// Every domain a site is also known by, so a chip saved at last month's mirror
    /// still finds its plugin.
    static func mirrorDomains(_ url: URL) -> [String] {
        guard let set = MirrorDirectory.shared.set(owning: url) else { return [] }
        return set.candidates.compactMap(\.host)
    }
}

/// A site added to the bar becomes a search plugin in qBittorrent.
///
/// Driven off the bar rather than off the add button, so a site added on another
/// machine, or one added before the client was configured, is picked up too. Kept in
/// its own modifier because the root view's chain is already long enough that the
/// type checker gives up on it.
private struct PluginSyncTriggers: ViewModifier {
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var settings: AppSettings
    let sync: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: bookmarks.visible.map(\.id)) { _, _ in sync() }
            .onChange(of: settings.qbBaseURL) { _, _ in sync() }
            .onChange(of: settings.syncSearchPlugins) { _, on in if on { sync() } }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var routes: RouteStore
    @ObservedObject var web: WebController
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var blocker: ContentBlocker
    @Binding var showSettings: Bool
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                VisualEffectView()
                WindowDragArea()

                HStack(spacing: 10) {
                    Color.clear.frame(width: Theme.trafficLightGutter, height: 1)

                    ChromeButton(symbol: "chevron.left", help: "Back") { web.goBack() }
                        .opacity(web.canGoBack ? 1 : 0.3)
                        .disabled(!web.canGoBack)

                    Button(action: onHome) {
                        HStack(spacing: 6) {
                            if let icon = NSApp.applicationIconImage {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text("1337x")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.85))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.pillFill))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to the homepage")
                    .contextMenu {
                        if let home = AppSettings.shared.home {
                            InstanceMenuItems(url: home,
                                              open: { web.load($0) },
                                              report: { web.showToast($0, isError: $1) })
                            Button("Copy Address") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    MirrorDirectory.shared.resolve(home).absoluteString,
                                    forType: .string)
                            }
                            Divider()
                        }
                        Button("Reload") { web.reload() }
                        Button("Settings\u{2026}") { showSettings = true }
                    }

                    Spacer(minLength: 8)

                    ShieldPill(blocker: blocker)
                    RoutePill(routes: routes, showSettings: $showSettings)
                    ChromeButton(symbol: web.isLoading ? "xmark" : "arrow.clockwise",
                                 help: web.isLoading ? "Stop" : "Reload") {
                        web.isLoading ? web.stop() : web.reload()
                    }
                    // Settings used to be reachable only from the route pill's menu
                    // and Cmd-comma, which is no way to find a seven-tab pane.
                    ChromeButton(symbol: "gearshape", help: "Settings") {
                        showSettings = true
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: Theme.barHeight)

                if web.isLoading {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * max(0.02, web.progress), height: 2)
                    }
                    .frame(height: 2)
                }
            }
            .frame(height: Theme.barHeight)

            BookmarkBar(bookmarks: bookmarks, web: web)
        }
        .animation(.easeInOut(duration: 0.18), value: web.isLoading)
    }
}

/// The configured Firefox bookmark folder plus any sites added by hand, grouped by
/// what each site is actually for. Grouping is presentation only -- the underlying list, its order,
/// and pinning are untouched, so a pinned chip still leads its own section.
///
/// Chips can be dragged between sections to correct the built-in classification.
private struct BookmarkBar: View {
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var web: WebController
    @ObservedObject private var categories = CategoryStore.shared
    @ObservedObject private var mirrors = MirrorDirectory.shared
    @State private var hoveredID: String?
    @State private var hoveredLabel: String?
    @State private var dropTarget: BookmarkCategory?

    var body: some View {
        ZStack {
            VisualEffectView(material: .titlebar)
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        // Empty sections are kept so there is always somewhere to drop
                        // a chip, even for a category nothing is filed under yet.
                        ForEach(Categoriser.group(bookmarks.visible, includingEmpty: true)) { group in
                            section(group)
                        }
                        if bookmarks.visible.isEmpty {
                            Text(emptyBarMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(height: 30)
    }

    /// With nothing configured the bar is legitimately empty, so this says what to do
    /// rather than reporting a failure.
    private var emptyBarMessage: String {
        if bookmarks.folderName.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No sites yet \u{2014} add one in Settings"
        }
        if let error = bookmarks.lastError { return error }
        return bookmarks.folderFound
            ? "No sites in the \u{201C}\(bookmarks.folderName)\u{201D} folder"
            : "Looking for bookmarks\u{2026}"
    }

    @ViewBuilder
    private func section(_ group: BookmarkGroup) -> some View {
        let targeted = dropTarget == group.category
        let collapsed = categories.isCollapsed(group.category)
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    categories.toggleCollapsed(group.category)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: group.category.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(labelStyle(targeted: targeted, hovered: hoveredLabel == group.id))
                        .frame(width: 16)
                    // Collapsed sections say how much is folded away, so nothing
                    // looks like it has gone missing.
                    if collapsed, !group.items.isEmpty {
                        Text("\(group.items.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .padding(.horizontal, 4)
                            .frame(height: 13)
                            .background(Capsule().fill(Theme.pillFill))
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredLabel = $0 ? group.id : nil }
            .help(collapsed
                  ? "\(group.category.label) \u{2014} click to show"
                  : "\(group.category.label) \u{2014} click to hide")
            .padding(.trailing, collapsed ? 0 : 7)

            if !collapsed {
                HStack(spacing: 6) {
                    ForEach(group.items) { chip($0) }
                }
                // A landing strip, so an empty section is still a target you can hit.
                if group.items.isEmpty {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.pillFill)
                        .frame(width: 30, height: 21)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .padding(.trailing, 14)
        .onDrop(of: [.utf8PlainText], isTargeted: targeting(group.category)) { providers in
            accept(providers, into: group.category)
        }
    }

    private func labelStyle(targeted: Bool, hovered: Bool) -> AnyShapeStyle {
        if targeted { return AnyShapeStyle(Color.accentColor) }
        if hovered { return AnyShapeStyle(Color.primary.opacity(0.75)) }
        return AnyShapeStyle(.tertiary)
    }

    private func targeting(_ category: BookmarkCategory) -> Binding<Bool> {
        Binding(
            get: { dropTarget == category },
            set: { isIn in
                if isIn { dropTarget = category }
                else if dropTarget == category { dropTarget = nil }
            }
        )
    }

    private func accept(_ providers: [NSItemProvider], into category: BookmarkCategory) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, let url = URL(string: text) else { return }
            Task { @MainActor in
                CategoryStore.shared.set(category, for: url)
                // Show the result rather than dropping it into a fold.
                CategoryStore.shared.expand(category)
                dropTarget = nil
            }
        }
        return true
    }

    @ViewBuilder
    private func chip(_ bm: Bookmark) -> some View {
        Button {
            let url = MirrorDirectory.shared.resolve(bm.url)
            // A click here is the deliberate act that re-arms a blocked NAS mount.
            DownloadManager.shared.userOpenedFromBar(url)
            web.load(url)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 5, height: 5)
                Text(bm.chipLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredID == bm.id ? Theme.pillFillHover : Theme.pillFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? bm.id : nil }
        .help(bm.title.isEmpty ? bm.url.absoluteString : bm.title)
        .onDrag { NSItemProvider(object: bm.url.absoluteString as NSString) }
        .contextMenu {
            InstanceMenuItems(url: bm.url,
                              open: { web.load($0) },
                              report: { web.showToast($0, isError: $1) })
            if bookmarks.isPinned(bm) {
                Button("Unpin from Left") { bookmarks.setPinned(bm, false) }
            } else {
                Button("Pin to Left") { bookmarks.setPinned(bm, true) }
            }
            Button("Hide from Bar") { bookmarks.setHidden(bm, true) }
            Divider()
            Menu("Move to Section") {
                ForEach(Categoriser.alwaysShown) { category in
                    Button {
                        categories.set(category, for: bm.url)
                    } label: {
                        Label(category.label, systemImage: category.symbol)
                    }
                }
            }
            if categories.isOverridden(bm.url) {
                Button("Reset Category") { categories.reset(bm.url) }
            }
            Divider()
            Text(bm.url.absoluteString)
        }
    }
}

/// Every domain the app knows for a site, so one can be chosen by hand.
///
/// Automatic picks by probing, and probes run DIRECTLY from this Mac -- on a proxied
/// route that measures the wrong thing, and the domain it settles on may not be the
/// one that actually works. This is the manual override for that.
private struct InstanceMenuItems: View {
    @ObservedObject private var mirrors = MirrorDirectory.shared
    let url: URL
    let open: (URL) -> Void
    let report: (String, Bool) -> Void

    var body: some View {
        if let set = mirrors.set(owning: url), set.candidates.count > 1 {
            Menu("Instance") {
                Button {
                    mirrors.clearOverride(for: set.id)
                    open(mirrors.resolve(url))
                } label: {
                    if mirrors.override(for: set.id) == nil {
                        Label("Automatic", systemImage: "checkmark")
                    } else {
                        Text("Automatic")
                    }
                }
                Divider()
                ForEach(set.candidates, id: \.absoluteString) { candidate in
                    Button {
                        mirrors.use(candidate, for: set.id)
                        open(mirrors.resolve(url))
                    } label: {
                        if candidate.host == mirrors.override(for: set.id)?.host {
                            Label(candidate.host ?? candidate.absoluteString, systemImage: "checkmark")
                        } else {
                            Text(candidate.host ?? candidate.absoluteString)
                        }
                    }
                }
                Divider()
                Button("Check Instances\u{2026}") { survey(set) }
            }
            Divider()
        }
    }

    /// Reports which domains answer, so choosing one is informed rather than a guess.
    private func survey(_ set: MirrorSet) {
        report("Checking \(set.candidates.count) instances of \(set.name)\u{2026}", false)
        Task {
            let results = await mirrors.survey(set.id)
            let live = results.filter(\.answers).compactMap { $0.url.host }
            if live.isEmpty {
                report("None of \(set.name)'s instances answer from this Mac. "
                       + "On a proxied route they may still work \u{2014} pick one by hand.", true)
            } else {
                report("Answering: \(live.joined(separator: ", "))", false)
            }
        }
    }
}

private struct ShieldPill: View {
    @ObservedObject var blocker: ContentBlocker

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: blocker.ruleLists.isEmpty ? "shield.slash" : "shield.lefthalf.filled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(blocker.ruleLists.isEmpty
                                 ? Color(nsColor: .systemRed)
                                 : Color(nsColor: .systemGreen))
            Text(blocker.ruleLists.isEmpty ? "Off" : "Blocking")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.pillFill))
        .help(blocker.status)
    }
}

private struct RoutePill: View {
    @ObservedObject var routes: RouteStore
    @Binding var showSettings: Bool

    private var tint: StatusTint {
        if routes.proxyNeedsCredentials { return .needsAuth }
        switch routes.status {
        case .probing: return .probing
        case .offline: return .offline
        case .live: return .live
        }
    }

    private var title: String {
        // A proxy that cannot authenticate refuses every site, so say so instead of
        // reporting the route as live.
        if routes.proxyNeedsCredentials { return "Sign-in needed" }
        switch routes.status {
        case .probing: return "Checking…"
        case .offline: return "Offline"
        case .live(let r): return r.label
        }
    }

    var body: some View {
        Menu {
            Section("Route") {
                ForEach(X1337Route.allCases) { route in
                    Button {
                        routes.pin(route)
                        NotificationCenter.default.post(name: .qbRecheck, object: nil)
                    } label: {
                        if routes.active == route {
                            Label(route.label, systemImage: "checkmark")
                        } else {
                            Text(route.label)
                        }
                    }
                }
            }
            Divider()
            Button("Choose Automatically") {
                routes.pin(nil)
                NotificationCenter.default.post(name: .qbRecheck, object: nil)
            }
            .disabled(routes.pinned == nil)
            Button("Check Again") {
                NotificationCenter.default.post(name: .qbRecheck, object: nil)
            }
            Divider()
            Button("Settings…") { showSettings = true }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint.color).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.pillFill))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct OfflineView: View {
    let reason: String
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Can't reach the site").font(.system(size: 17, weight: .semibold))
            Text(reason)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            HStack(spacing: 10) {
                Button("Try Again", action: onRetry).keyboardShortcut(.defaultAction)
                Button("Settings…", action: onSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - First run

/// What the window shows before anything is configured. The app ships with no sites,
/// no home and no services, so this is the honest first screen rather than a route
/// probe against nothing.
private struct SetupView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No site set up yet").font(.system(size: 17, weight: .semibold))
            Text("Choose a site to open, and add the ones you use to the bar. "
                 + "A torrent client, a NAS archive and mirror lists are all optional "
                 + "and can be filled in later.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button("Open Settings", action: onOpenSettings)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings

private enum SettingsTab: String, CaseIterable, Identifiable {
    case sites, connection, client, downloads, mirrors, appearance, blocking, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sites: return "Sites"
        case .connection: return "Connection"
        case .client: return "Torrent Client"
        case .downloads: return "Downloads"
        case .mirrors: return "Mirrors"
        case .appearance: return "Appearance"
        case .blocking: return "Blocking"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .sites: return "globe"
        case .connection: return "network"
        case .client: return "arrow.down.circle"
        case .downloads: return "internaldrive"
        case .mirrors: return "arrow.triangle.branch"
        case .appearance: return "paintbrush"
        case .blocking: return "shield.lefthalf.filled"
        case .about: return "info.circle"
        }
    }
}

/// Shared field styling, so every tab reads as one form.
private struct SettingRow<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium))
            content
            if let hint {
                Text(hint)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MonoField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: width)
    }
}

struct SettingsPane: View {
    @ObservedObject var routes: RouteStore
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var blocker: ContentBlocker
    @ObservedObject var plugins: SearchPluginSync
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: SettingsTab = .sites

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                SitesTab(bookmarks: bookmarks, settings: settings)
                    .tabItem { Label(SettingsTab.sites.title, systemImage: SettingsTab.sites.symbol) }
                    .tag(SettingsTab.sites)
                ConnectionTab(routes: routes, settings: settings)
                    .tabItem { Label(SettingsTab.connection.title, systemImage: SettingsTab.connection.symbol) }
                    .tag(SettingsTab.connection)
                ClientTab(settings: settings, plugins: plugins, bookmarks: bookmarks)
                    .tabItem { Label(SettingsTab.client.title, systemImage: SettingsTab.client.symbol) }
                    .tag(SettingsTab.client)
                DownloadsTab(settings: settings)
                    .tabItem { Label(SettingsTab.downloads.title, systemImage: SettingsTab.downloads.symbol) }
                    .tag(SettingsTab.downloads)
                MirrorsTab(settings: settings)
                    .tabItem { Label(SettingsTab.mirrors.title, systemImage: SettingsTab.mirrors.symbol) }
                    .tag(SettingsTab.mirrors)
                AppearanceTab(settings: settings)
                    .tabItem { Label(SettingsTab.appearance.title, systemImage: SettingsTab.appearance.symbol) }
                    .tag(SettingsTab.appearance)
                BlockingTab(blocker: blocker)
                    .tabItem { Label(SettingsTab.blocking.title, systemImage: SettingsTab.blocking.symbol) }
                    .tag(SettingsTab.blocking)
                AboutTab(settings: settings)
                    .tabItem { Label(SettingsTab.about.title, systemImage: SettingsTab.about.symbol) }
                    .tag(SettingsTab.about)
            }
            .padding(.top, 8)

            Divider().overlay(Theme.hairline)
            HStack {
                Text("Changes apply as you make them.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                // Escape as well. A sheet whose only exit is one button is one layout
                // mistake away from being a trap -- which is exactly what happened when
                // this tab outgrew the pane and pushed that button off the bottom.
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 620, height: 580)
    }
}

// MARK: Sites

private struct SitesTab: View {
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var settings: AppSettings
    @State private var newTitle = ""
    @State private var newURL = ""
    @State private var infraText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow(label: "Home site",
                           hint: "Opened at launch and by the Home button. Leave empty and the app shows its setup screen instead.") {
                    MonoField(placeholder: "https://example.com/", text: $settings.homeURL)
                }

                Divider()

                SettingRow(label: "Sites in the bar",
                           hint: bookmarks.extras.isEmpty
                                 ? "None yet. Add one below, or mirror a Firefox bookmark folder."
                                 : "\(bookmarks.extras.count) added by hand.") {
                    if !bookmarks.extras.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(bookmarks.extras) { bm in
                                HStack(spacing: 8) {
                                    Image(systemName: Categoriser.category(for: bm.url).symbol)
                                        .font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 14)
                                    Text(bm.chipLabel).font(.system(size: 11.5))
                                    Text(bm.url.host ?? "")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary).lineLimit(1)
                                    Spacer()
                                    Button {
                                        bookmarks.removeExtra(bm)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillFill))
                    }
                }

                HStack(spacing: 8) {
                    TextField("Name", text: $newTitle).textFieldStyle(.roundedBorder).frame(width: 130)
                    MonoField(placeholder: "https://example.com/", text: $newURL)
                    Button("Add") { addSite() }.disabled(URL(string: newURL.trimmed)?.host == nil)
                }

                Divider()

                SettingRow(label: "Mirror a Firefox bookmark folder",
                           hint: statusLine) {
                    HStack(spacing: 8) {
                        TextField("Folder name", text: $settings.bookmarkFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Refresh") { bookmarks.refresh(force: true) }
                    }
                }

                SettingRow(label: "Never show these hosts",
                           hint: "Comma separated. Your own infrastructure — a seedbox, a NAS — rather than somewhere you get things from. Private, LAN and tailnet addresses are always excluded.") {
                    MonoField(placeholder: "seedbox.example.com", text: $infraText)
                        .onSubmit { commitInfra() }
                }

                if !bookmarks.hiddenBookmarks.isEmpty {
                    Divider()
                    SettingRow(label: "Hidden from the bar",
                               hint: "Hidden with the chip's context menu.") {
                        VStack(spacing: 2) {
                            ForEach(bookmarks.hiddenBookmarks) { bm in
                                HStack {
                                    Text(bm.chipLabel).font(.system(size: 11))
                                    Spacer()
                                    Button("Show") { bookmarks.setHidden(bm, false) }
                                        .buttonStyle(.link).font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .onAppear { infraText = settings.infrastructureHosts.joined(separator: ", ") }
        .onDisappear { commitInfra() }
    }

    private var statusLine: String {
        let folder = settings.bookmarkFolder.trimmed
        if folder.isEmpty { return "Empty means no import. Nothing is read from Firefox." }
        if let error = bookmarks.lastError { return error }
        return "\(bookmarks.bookmarks.count) sites mirrored from “\(folder)”."
    }

    private func addSite() {
        guard let url = URL(string: newURL.trimmed), url.host != nil else { return }
        bookmarks.addExtra(title: newTitle.trimmed, url: url)
        newTitle = ""; newURL = ""
    }

    private func commitInfra() {
        let hosts = infraText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if hosts != settings.infrastructureHosts { settings.infrastructureHosts = hosts }
    }
}

// MARK: Connection

private struct ConnectionTab: View {
    @ObservedObject var routes: RouteStore
    @ObservedObject var settings: AppSettings
    @State private var editingCredentials = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow(label: "Route", hint: routeHint) {
                    Picker("", selection: Binding(
                        get: { routes.pinned },
                        set: { routes.pin($0); NotificationCenter.default.post(name: .qbRecheck, object: nil) }
                    )) {
                        Text("Choose automatically").tag(X1337Route?.none)
                        ForEach(X1337Route.allCases) { route in
                            Text(route.label).tag(X1337Route?.some(route))
                        }
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                }

                SettingRow(label: "This network", hint: networkHint) {
                    HStack(spacing: 8) {
                        Text(routes.network?.label ?? "Not identified")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(routes.network == nil ? .tertiary : .secondary)
                        Spacer()
                        if routes.learned != nil {
                            Button("Forget") {
                                routes.forgetCurrentNetwork()
                                NotificationCenter.default.post(name: .qbRecheck, object: nil)
                            }
                            .font(.system(size: 11))
                        }
                        if routes.knownNetworkCount > 1 {
                            Button("Forget All") { routes.forgetAllNetworks() }
                                .font(.system(size: 11))
                        }
                    }
                }

                Divider()

                SettingRow(label: "Forward proxy",
                           hint: "An HTTP CONNECT proxy, used by the Via NAS route. It must be a FORWARD proxy: a reverse proxy terminates TLS and rewrites the origin, so a Cloudflare challenge behind one never completes. CONNECT tunnels raw TLS straight through, and the challenge solves normally.") {
                    HStack(spacing: 8) {
                        MonoField(placeholder: "proxy host or IP", text: $settings.proxyHost)
                        MonoField(placeholder: "port",
                                  text: Binding(get: { String(settings.proxyPort) },
                                                set: { settings.proxyPort = Int($0) ?? settings.proxyPort }),
                                  width: 70)
                    }
                }

                SettingRow(label: "Proxy sign-in",
                           hint: "Stored in the Keychain, never in a file. Required when the proxy is published through Docker, which rewrites the source address and makes IP allowlisting useless.") {
                    HStack(spacing: 8) {
                        Text(ProxyCredentialStore.exists() ? "Saved" : "Not set")
                            .font(.system(size: 11))
                            .foregroundStyle(ProxyCredentialStore.exists() ? .secondary : .tertiary)
                        Button("Set…") { editingCredentials = true }
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Button("Check Now") {
                        NotificationCenter.default.post(name: .qbRecheck, object: nil)
                    }
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .sheet(isPresented: $editingCredentials) {
            CredentialSheet(title: "Proxy sign-in") { user, pass in
                ProxyCredentialStore.save(user: user, pass: pass)
            }
        }
    }

    /// Says what was learned and what it is used for, or why nothing was learned.
    private var networkHint: String {
        guard routes.network != nil else {
            return "The router could not be identified, so nothing is remembered here "
                + "and both routes are tried in order every time."
        }
        let base = "Networks are remembered by their router rather than by Wi-Fi name, "
            + "which macOS will not hand over without Location access."
        guard let learned = routes.learned else {
            return "Nothing learned here yet. " + base
        }
        return "\(learned.label) worked here last time, so it is tried first — which "
            + "skips the wait for a route that is blocked on this network. It is not "
            + "trusted blindly: the other one still follows if it fails. " + base
    }

    private var routeHint: String {
        "Direct is fastest. Via NAS tunnels through your own proxy for networks that block trackers."
    }

    private var statusText: String {
        switch routes.status {
        case .probing: return "Checking…"
        case .offline(let why): return why
        case .live(let route): return "Live on \(route.label)."
        }
    }
}

// MARK: Torrent client

private struct ClientTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var plugins: SearchPluginSync
    @ObservedObject var bookmarks: BookmarkStore
    @State private var editingCredentials = false
    @State private var testResult: String?

    /// What each site in the bar maps to, worked out locally so the list is honest
    /// before anything is installed rather than only after a sync has run.
    /// Exactly what a sync would act on, so the list below and the button agree.
    private var syncedSites: [URL] {
        var sites = bookmarks.visible.map(\.url)
        if let home = settings.home, !sites.contains(where: { $0.host == home.host }) {
            sites.insert(home, at: 0)
        }
        return sites
    }

    private var coverage: [(site: String, plugin: String?)] {
        var seen = Set<String>()
        var rows: [(String, String?)] = []
        for url in syncedSites {
            guard let host = url.host, SearchPluginPlan.isSearchableSite(host) else { continue }
            let domain = registrableDomain(host)
            guard !seen.contains(domain) else { continue }
            seen.insert(domain)
            let candidates = [domain] + RootView.mirrorDomains(url).map { registrableDomain($0) }
            let match = candidates.lazy.compactMap { SearchPluginCatalogue.plugin(forDomain: $0) }.first
            rows.append((domain, match?.site))
        }
        return rows.map { (site: $0.0, plugin: $0.1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow(label: "qBittorrent Web API",
                           hint: "Magnet and .torrent links are posted here instead of being handed to another app. Often a reverse proxy in front of the client rather than the client's own port, which is what makes this work on networks that block it. Empty means magnets are left alone.") {
                    MonoField(placeholder: "http://host:8080/", text: $settings.qbBaseURL)
                }

                SettingRow(label: "Sign-in",
                           hint: "Stored in the Keychain.") {
                    HStack(spacing: 8) {
                        Text(QBCredentialStore.exists() ? "Saved" : "Not set")
                            .font(.system(size: 11))
                            .foregroundStyle(QBCredentialStore.exists() ? .secondary : .tertiary)
                        Button("Set…") { editingCredentials = true }
                    }
                }

                SettingRow(label: "Keychain service",
                           hint: "Change this to share one saved sign-in with a dedicated qBittorrent app.") {
                    MonoField(placeholder: "\(AppSettings.bundleID).qbittorrent",
                              text: $settings.qbKeychainService)
                }

                Divider()

                Toggle("Add a search plugin when a site is added",
                       isOn: $settings.syncSearchPlugins)
                    .font(.system(size: 12, weight: .medium))
                Text("Sites in the bar are matched against a built-in list of published "
                     + "qBittorrent search plugins, and the missing ones are installed. "
                     + "Only these addresses are ever fetched -- nothing a page suggests. "
                     + "Plugins are never removed.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(plugins.busy ? "Syncing\u{2026}" : "Sync Now") {
                        plugins.syncNow(sites: syncedSites, alsoKnownAs: RootView.mirrorDomains)
                    }
                    .disabled(plugins.busy || settings.qbBase == nil)
                    if !plugins.status.isEmpty {
                        Text(plugins.status).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !coverage.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(coverage, id: \.site) { row in
                            HStack(spacing: 6) {
                                Text(row.site)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .frame(width: 190, alignment: .leading)
                                Text(row.plugin ?? "no published plugin")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(row.plugin == nil ? .tertiary : .secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                Divider()
                HStack(spacing: 8) {
                    Button("Test Reachability") { test() }
                        .disabled(settings.qbBase == nil)
                    if let testResult {
                        Text(testResult).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("Reachability only — a sign-in failure shows when a magnet is actually sent.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(18)
        }
        .sheet(isPresented: $editingCredentials) {
            CredentialSheet(title: "qBittorrent sign-in") { user, pass in
                QBCredentialStore.save(username: user, password: pass)
            }
        }
    }

    private func test() {
        guard let base = settings.qbBase else { return }
        testResult = "Checking…"
        Task {
            let ok = await Reachability.answers(base)
            testResult = ok ? "Answering." : "No answer."
        }
    }
}

// MARK: Downloads

private struct DownloadsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var mountResult: String?
    @State private var hostsText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Files download to this Mac first and move to the share once whole — "
                     + "a download writes incrementally, and doing that over SMB is slow and "
                     + "leaves half-written files when the link drops.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingRow(label: "Staging folder on this Mac",
                           hint: "Anything left here means the share was unreachable; it is swept over on the next successful mount.") {
                    HStack(spacing: 8) {
                        MonoField(placeholder: AppSettings.defaultLocalRoot.path,
                                  text: $settings.archiveLocalPath)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.localRoot])
                        }
                    }
                }

                Divider()

                SettingRow(label: "SMB share",
                           hint: "Mounted only when a download starts. Leave any field empty and downloads simply stay on this Mac.") {
                    HStack(spacing: 8) {
                        MonoField(placeholder: "host", text: $settings.nasHost)
                        MonoField(placeholder: "share", text: $settings.nasShare, width: 130)
                        MonoField(placeholder: "user", text: $settings.nasUser, width: 110)
                    }
                }

                SettingRow(label: "Folder on the share",
                           hint: "Point this at a folder nothing else manages. If it is somewhere a media pipeline watches, captured files get imported, renamed and moved out from under you.") {
                    MonoField(placeholder: "Direct", text: $settings.archiveRoot, width: 180)
                }

                SettingRow(label: "File hosts allowed to send downloads",
                           hint: "A site in the bar can always send you a file, and so "
                               + "can the site you are reading. Anything else is "
                               + "refused — that is what stops a page starting a "
                               + "download off the back of a click you meant for "
                               + "something else. When a real file host is refused, "
                               + "its name is in the message; add it here once. "
                               + "Comma separated.") {
                    MonoField(placeholder: "1fichier.com, datanodes.to", text: $hostsText)
                }

                SettingRow(label: "Where each kind goes",
                           hint: "The site's own category decides; the file extension only breaks the tie for a site that covers several types.") {
                    HStack(spacing: 8) {
                        ForEach(Categoriser.alwaysShown) { category in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(category.label, systemImage: category.symbol)
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).labelStyle(.iconOnly)
                                MonoField(placeholder: category.label,
                                          text: Binding(
                                            get: { settings.categoryFolders[category.rawValue] ?? "" },
                                            set: { settings.categoryFolders[category.rawValue] = $0 }),
                                          width: 92)
                            }
                        }
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Button("Mount Now") { mount() }
                        .disabled(!settings.nasConfigured)
                    if let mountResult {
                        Text(mountResult).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
        .onAppear { hostsText = settings.allowedDownloadHosts.joined(separator: ", ") }
        .onDisappear { commitHosts() }
    }

    /// Stored as registrable domains, so a host added as a full URL or with a `www.`
    /// still matches what a download actually arrives from.
    private func commitHosts() {
        let hosts = hostsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { entry -> String in
                guard let url = URL(string: entry), let host = url.host else { return entry }
                return host
            }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            .map { registrableDomain($0) }
            .filter { !$0.isEmpty && $0.contains(".") }
        if hosts != settings.allowedDownloadHosts { settings.allowedDownloadHosts = hosts }
    }

    private func mount() {
        mountResult = "Mounting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let volume = DownloadManager.ensureMounted()
            DispatchQueue.main.async {
                mountResult = volume == nil ? "Could not mount." : "Mounted."
            }
        }
    }
}

// MARK: Mirrors

private struct MirrorsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var directory = MirrorDirectory.shared
    @State private var newID = ""
    @State private var newName = ""
    @State private var newPage = ""
    @State private var newURLs = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("When a site stops answering, the app moves to another of its domains "
                     + "and remembers the choice. Only a transport failure counts — an HTTP "
                     + "rejection, a Cloudflare challenge above all, proves the domain is alive.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingRow(label: "Your mirror sets",
                           hint: settings.curatedMirrors.isEmpty
                                 ? "None. Add one below to give a site somewhere to fall back to."
                                 : "Checked before anything discovered in bulk.") {
                    if !settings.curatedMirrors.isEmpty {
                        VStack(spacing: 3) {
                            ForEach(settings.curatedMirrors) { set in
                                HStack(spacing: 8) {
                                    Text(set.name).font(.system(size: 11.5, weight: .medium))
                                    if let page = set.page {
                                        Label(page, systemImage: "arrow.clockwise")
                                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    }
                                    Text("\(set.urls.count) domains")
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    Spacer()
                                    Button {
                                        settings.curatedMirrors.removeAll { $0.id == set.id }
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillFill))
                    }
                }

                SettingRow(label: "Add a set",
                           hint: "A Wikipedia article name is optional; when given, the domain list is re-read from that article's infobox, which is how a site that rotates domains keeps working.") {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("id", text: $newID).textFieldStyle(.roundedBorder).frame(width: 110)
                            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 130)
                            TextField("Wikipedia article (optional)", text: $newPage)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            MonoField(placeholder: "https://a.example/, https://b.example/", text: $newURLs)
                            Button("Add") { addSet() }.disabled(newID.trimmed.isEmpty)
                        }
                    }
                }

                Divider()

                Toggle("Also use FMHY's published mirror list", isOn: $settings.fmhyEnabled)
                    .font(.system(size: 11.5))
                Text("Adds mirrors for hundreds of sites in bulk. Your own sets always win.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)

                SettingRow(label: "Re-check upstreams every") {
                    HStack(spacing: 8) {
                        MonoField(placeholder: "6",
                                  text: Binding(get: { String(settings.mirrorRefreshHours) },
                                                set: { settings.mirrorRefreshHours = Int($0) ?? 6 }),
                                  width: 60)
                        Text("hours").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button("Refresh Now") { Task { await directory.refresh(force: true) } }
                    Text(directory.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }

    private func addSet() {
        let urls = newURLs.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let id = newID.trimmed
        guard !id.isEmpty, !settings.curatedMirrors.contains(where: { $0.id == id }) else { return }
        settings.curatedMirrors.append(
            CuratedMirror(id: id,
                          name: newName.trimmed.isEmpty ? id : newName.trimmed,
                          page: newPage.trimmed.isEmpty ? nil : newPage.trimmed,
                          urls: urls))
        newID = ""; newName = ""; newPage = ""; newURLs = ""
    }
}

// MARK: Appearance

private struct AppearanceTab: View {
    @ObservedObject var settings: AppSettings
    /// The field is edited as text and committed on Return, rather than bound straight
    /// to the setting: the page rezooms live, so a half-typed "1" would throw it to the
    /// minimum and back on the way to "105".
    @State private var zoomText = ""

    private var zoomPercent: String {
        String(Int((settings.effectiveSiteZoom * 100).rounded()))
    }

    private func nudgeZoom(_ delta: Double) {
        settings.siteZoom = min(AppSettings.siteZoomRange.upperBound,
                                max(AppSettings.siteZoomRange.lowerBound,
                                    settings.effectiveSiteZoom + delta))
    }

    private func commitZoom() {
        guard let typed = Double(zoomText.trimmingCharacters(in: .whitespaces)), typed > 0
        else { zoomText = zoomPercent; return }
        settings.siteZoom = min(AppSettings.siteZoomRange.upperBound,
                                max(AppSettings.siteZoomRange.lowerBound, typed / 100))
        zoomText = zoomPercent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(label: "Site zoom",
                           hint: "How large pages are drawn. This reflows the layout rather "
                               + "than magnifying the finished picture, so nothing is cut "
                               + "off at the right-hand edge. Pinch on any page to go "
                               + "further still.") {
                    HStack(spacing: 8) {
                        MonoField(placeholder: "105", text: $zoomText, width: 60)
                        Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                        Stepper("",
                                onIncrement: { nudgeZoom(0.05) },
                                onDecrement: { nudgeZoom(-0.05) })
                            .labelsHidden()
                        Spacer()
                        Button("Reset") { settings.siteZoom = AppSettings.defaultSiteZoom }
                            .font(.system(size: 11))
                            .disabled(abs(settings.siteZoom - AppSettings.defaultSiteZoom) < 0.005)
                    }
                    .onSubmit { commitZoom() }
                }
                .onAppear { zoomText = zoomPercent }
                .onChange(of: settings.siteZoom) { _, _ in zoomText = zoomPercent }

                Divider()

                // Sites are shown as their authors built them.
                //
                // There was a restyling engine here that imposed one theme across every
                // site: one typeface, one palette, backgrounds stripped, logos replaced
                // with text. It looked good and it could not be reconciled with the
                // content blocker. Both want authority over the same elements -- the
                // blocker hides things, the restyler repaints everything it can reach --
                // and adverts kept surfacing through the repaint. Blocking wins; it is
                // the one of the two that matters.
                Text("Sites keep their own appearance.")
                    .font(.system(size: 12, weight: .medium))
                Text("Pages are shown as their authors built them. An earlier version "
                     + "imposed a single theme across every site, which fought with the "
                     + "content blocker over the same elements and let adverts through. "
                     + "Blocking is the more important of the two.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }
}


private struct BlockingTab: View {
    @ObservedObject var blocker: ContentBlocker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingRow(label: "Content blocking", hint: blocker.status) {
                    HStack(spacing: 6) {
                        Image(systemName: blocker.ruleLists.isEmpty ? "shield.slash" : "shield.lefthalf.filled")
                            .foregroundStyle(blocker.ruleLists.isEmpty
                                             ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
                        Text(blocker.ruleLists.isEmpty ? "Off" : "Blocking")
                            .font(.system(size: 12, weight: .medium))
                    }
                }

                Text("Converted from uBlock Origin's own filter lists into WebKit's native "
                     + "content blocker. Network and cosmetic rules carry over; uBO scriptlets "
                     + "and procedural filters have no WebKit equivalent.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Rebuild the lists with tools/build-blocklist.py, then rebuild the app.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(18)
        }
    }
}

// MARK: About

private struct AboutTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                row("Name", AppSettings.appName)
                row("Version", (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—")
                row("Bundle id", AppSettings.bundleID)
                row("Settings domain", AppSettings.bundleID)
                row("Staging folder", settings.localRoot.path)
                Divider()
                Text("The bundle id is also where settings are stored and how Keychain items "
                     + "and macOS permissions are matched, so changing it starts over.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 110, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

// MARK: Credentials

/// Writes a username and password straight to the Keychain. Nothing is ever read
/// back for display: a read is an ACL check, and an ACL check the user has not
/// permanently approved is a password box.
private struct CredentialSheet: View {
    let title: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            TextField("Username", text: $user).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $pass).textFieldStyle(.roundedBorder)
            Text("Saved to your login Keychain. Choose “Always Allow” when macOS asks, "
                 + "or it will ask again every time.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(user, pass); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(user.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
