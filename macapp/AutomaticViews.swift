import AppKit
import SwiftUI

// The screens of Automatic mode. The pane strip takes the bookmark bar's place, in
// the same material and height, so switching modes changes what is in the window
// and not the shape of it. Status is a tinted capsule with coloured type -- never a
// stripe down the side of a row -- and controls that cannot do anything right now
// are hidden rather than shown disabled.

private enum Tint {
    static let ok = Theme.green
    static let busy = Theme.blue
    static let warn = Theme.orange
    static let bad = Theme.red
    static let check = Color(nsColor: .systemPurple)
}

struct AutomaticView: View {
    @ObservedObject var model: AutomaticModel
    @ObservedObject var settings: AppSettings
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.configured {
                AutoPaneBar(model: model)
                Divider().overlay(Theme.hairline)
                AutoBanners(model: model, openSettings: openSettings)
                ZStack {
                    switch model.pane {
                    case .following: AutoFollowingView(model: model)
                    case .upcoming: AutoComingUpView(model: model)
                    case .seedbox: AutoSeedboxView(model: model)
                    case .blocked: AutoBlockedView(model: model)
                    case .suggestions: AutoSuggestionsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AutoSetupView(hasAddress: settings.automaticBase != nil, openSettings: openSettings)
            }
        }
        .background(Theme.surface)
    }
}

/// Where the bookmark bar would be: one chip per pane, then the NAS's state.
private struct AutoPaneBar: View {
    @ObservedObject var model: AutomaticModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AutoPane.allCases) { pane in
                Button { model.pane = pane } label: {
                    HStack(spacing: 5) {
                        Image(systemName: pane.symbol).font(.system(size: 10.5, weight: .medium))
                        Text(pane.title).font(.system(size: 11.5, weight: .medium))
                        if let n = model.count(pane) {
                            Text("\(n)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.12)))
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 21)
                }
                .buttonStyle(QBTabButtonStyle(selected: model.pane == pane))
            }
            Spacer(minLength: 8)
            AutoHealthLine(model: model)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.chrome)
    }
}

private struct AutoHealthLine: View {
    @ObservedObject var model: AutomaticModel

    var body: some View {
        HStack(spacing: 12) {
            if let h = model.health {
                dot(h.sonarr ? "Sonarr" : (h.streaming == true ? "Sonarr paused for Plex" : "Sonarr not answering"),
                    h.sonarr ? Tint.ok : (h.streaming == true ? Tint.warn : Tint.bad),
                    help: h.sonarrError ?? "")
                dot(h.seedboxBlocked ? "Seedbox refused the sign-in" : (h.seedboxLogin ? "Seedbox" : "Seedbox sign-in needed"),
                    h.seedboxLogin && !h.seedboxBlocked ? Tint.ok : Tint.warn, help: h.seedboxError ?? "")
                if let free = h.freeBytes {
                    Text("\(AutoFormat.bytes(free)) free").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            } else if model.error != nil {
                dot("NAS unreachable", Tint.bad, help: model.error ?? "")
            }
        }
    }

    private func dot(_ text: String, _ color: Color, help: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .help(help)
    }
}

private struct AutoBanners: View {
    @ObservedObject var model: AutomaticModel
    let openSettings: () -> Void
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        let show = model.error != nil || model.needsSeedboxLogin || model.notice != nil
        VStack(spacing: 8) {
            if let err = model.error {
                AutoBanner(symbol: "wifi.exclamationmark", text: err, tint: Tint.bad,
                           action: ("Settings\u{2026}", openSettings))
            } else if model.needsSeedboxLogin {
                AutoBanner(symbol: "key",
                           text: sendError ?? "The NAS needs the seedbox's qBittorrent sign-in before it can download anything. Magnet can send the one it uses for magnets.",
                           tint: Tint.warn,
                           action: sending ? nil : ("Send Sign-In", send))
            }
            if let notice = model.notice {
                AutoBanner(symbol: "info.circle", text: notice, tint: Tint.busy, action: ("OK", { model.notice = nil }))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, show ? 12 : 0)
    }

    private func send() {
        sending = true
        Task {
            sendError = await model.sendSeedboxLogin()
            sending = false
        }
    }
}

// MARK: - Components

struct AutoChip: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.13)))
        .fixedSize()
    }
}

private struct AutoPoster: View {
    let url: String?
    var width: CGFloat = 140

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(Theme.pillFill)
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
    }

    private var placeholder: some View {
        Image(systemName: "tv").font(.system(size: width / 4, weight: .light)).foregroundStyle(.tertiary)
    }
}

private struct AutoEmpty: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

private struct AutoBanner: View {
    let symbol: String
    let text: String
    var tint: Color = Tint.warn
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action { Button(action.title, action: action.run).controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
    }
}

private struct AutoHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 22, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutoSetupView: View {
    let hasAddress: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
            Text("Automatic downloads run on your NAS").font(.system(size: 17, weight: .semibold))
            Text(hasAddress
                 ? "Magnet has the NAS address but no API token. Run nas/automatic/deploy.sh --token, or paste the token in Settings \u{2192} Automatic."
                 : "Deploy nas/automatic to the NAS, then give Magnet its address and API token in Settings \u{2192} Automatic. New episodes of the shows you follow are then found and downloaded to the seedbox on their own.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Settings\u{2026}", action: openSettings).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Following

private struct AutoFollowingView: View {
    @ObservedObject var model: AutomaticModel
    @State private var query = ""
    @State private var confirmUnfollow: AutoShow?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 20, alignment: .top)]
    private var searchingNow: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    AutoHeader(title: "Following", subtitle: "New episodes of these shows download to the seedbox as they air.")
                    searchField
                }
                if searchingNow {
                    results
                } else if let shows = model.overview?.following {
                    if shows.isEmpty {
                        AutoEmpty(symbol: "tv", title: "Not following anything yet",
                                  message: "Search to follow a show, or look in Suggestions for the ones you have been picking in the browser.")
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(shows, id: \.stableID) { show in
                                AutoShowCard(show: show)
                                    .contextMenu { Button("Stop Following") { confirmUnfollow = show } }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .confirmationDialog("Stop following \(confirmUnfollow?.title ?? "")?", isPresented: Binding(
            get: { confirmUnfollow != nil }, set: { if !$0 { confirmUnfollow = nil } })) {
            Button("Stop Following", role: .destructive) {
                if let s = confirmUnfollow { Task { await model.unfollow(s) } }
            }
        } message: {
            Text("New episodes stop downloading. Nothing already downloaded is deleted.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Follow a show", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit { Task { await model.search(query) } }
            if searchingNow {
                Button { query = ""; model.searchResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 240, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.pillFill))
    }

    @ViewBuilder private var results: some View {
        if model.searching {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
        } else if let err = model.searchError {
            AutoBanner(symbol: "exclamationmark.triangle", text: err, tint: Tint.bad)
        } else if model.searchResults.isEmpty {
            Text("Press Return to search for \u{201C}\(query)\u{201D}.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(model.searchResults, id: \.stableID) { show in
                    AutoSearchRow(model: model, show: show)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }
}

private struct AutoShowCard: View {
    let show: AutoShow
    var action: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AutoPoster(url: show.poster)
            Text(show.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
            nextLine
            if let why = show.why {
                Text(why).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let action { action.padding(.top, 2) }
        }
        .frame(width: 140, alignment: .leading)
    }

    @ViewBuilder private var nextLine: some View {
        if let next = show.nextDate {
            Text("Next \(AutoFormat.relativeDay(next)), \(AutoFormat.airTime(next))")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else if show.status == "upcoming" {
            Text("Premiere not announced").font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else {
            Text("Between seasons").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}

private struct AutoSearchRow: View {
    @ObservedObject var model: AutomaticModel
    let show: AutoShow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AutoPoster(url: show.poster, width: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(show.title).font(.system(size: 13, weight: .semibold))
                    if let y = show.year, y > 0 { Text(String(y)).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Text([show.network, show.status?.capitalized].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let o = show.overview, !o.isEmpty {
                    Text(o).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if show.following == true {
                AutoChip(text: "Following", tint: Tint.ok, symbol: "checkmark")
            } else if show.status == "ended" {
                AutoChip(text: "Ended")
            } else if model.busy.contains(show.stableID) {
                ProgressView().controlSize(.small)
            } else {
                Button("Follow") { Task { await model.follow(show) } }.controlSize(.small)
            }
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Coming Up

private struct AutoComingUpView: View {
    @ObservedObject var model: AutomaticModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AutoHeader(title: "Coming Up", subtitle: "The last three days and the next four weeks of the shows you follow.")
                let eps = (model.overview?.upcoming ?? []).sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }
                if model.overview != nil && eps.isEmpty {
                    AutoEmpty(symbol: "calendar", title: "Nothing scheduled",
                              message: model.health?.sonarr == false
                                ? (model.health?.sonarrError ?? "Sonarr is not answering.")
                                : "None of the shows you follow has an episode in the next four weeks.")
                }
                ForEach(groups(eps), id: \.0) { day, items in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(day).font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
                        ForEach(items) { ep in
                            AutoEpisodeRow(ep: ep, seedbox: onSeedbox(ep))
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func groups(_ eps: [AutoEpisode]) -> [(String, [AutoEpisode])] {
        var out: [(String, [AutoEpisode])] = []
        for ep in eps {
            let day = ep.airDate.map { AutoFormat.relativeDay($0) } ?? "Date not announced"
            if out.last?.0 == day { out[out.count - 1].1.append(ep) } else { out.append((day, [ep])) }
        }
        return out
    }

    // An episode on the seedbox is not in Sonarr's library until it is brought to the
    // NAS, so it is matched up here by show and episode number.
    private func onSeedbox(_ ep: AutoEpisode) -> AutoTorrent? {
        model.overview?.seedbox.torrents.first {
            $0.series == ep.series && $0.season == ep.season && $0.episode == ep.episode && $0.verdict != "rejected"
        }
    }
}

private struct AutoEpisodeRow: View {
    let ep: AutoEpisode
    let seedbox: AutoTorrent?

    var body: some View {
        HStack(spacing: 12) {
            Text(ep.airDate.map(AutoFormat.airTime) ?? "")
                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.series ?? "").font(.system(size: 12.5, weight: .semibold))
                Text([ep.code, ep.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            status
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private var status: some View {
        if ep.hasFile {
            AutoChip(text: "On the NAS", tint: Tint.ok, symbol: "checkmark")
        } else if let t = seedbox {
            if t.isComplete { AutoChip(text: "On the seedbox", tint: Tint.busy, symbol: "tray.full") }
            else { AutoChip(text: "Downloading \(Int((t.progress ?? 0) * 100))%", tint: Tint.busy, symbol: "arrow.down") }
        } else if let d = ep.airDate, d < Date() {
            AutoChip(text: "Aired, waiting for a release", tint: Tint.warn, symbol: "clock")
        } else {
            AutoChip(text: "Not aired yet")
        }
    }
}

// MARK: - Seedbox

private struct AutoSeedboxView: View {
    @ObservedObject var model: AutomaticModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AutoHeader(title: "Seedbox", subtitle: subtitle)
                let torrents = model.overview?.seedbox.torrents ?? []
                if model.overview != nil && torrents.isEmpty {
                    AutoEmpty(symbol: "arrow.down.circle", title: "Nothing downloaded yet",
                              message: "Episodes appear here as they download. Nothing moves to the NAS until you choose Bring to NAS.")
                }
                VStack(spacing: 0) {
                    ForEach(torrents) { t in
                        AutoTorrentRow(model: model, t: t, failure: lastFailure(t))
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(24)
        }
    }

    private var subtitle: String {
        let days = model.overview?.scout?.windowDays ?? 7
        var s = "The first copy of each episode downloads as soon as one exists; for the next \(days) days a better one replaces it, Dolby Vision first. Bring an episode to the NAS when you want it in Plex."
        if let free = model.overview?.seedbox.freeBytes { s += " \(AutoFormat.bytes(free)) free on the seedbox." }
        return s
    }

    private func lastFailure(_ t: AutoTorrent) -> String? {
        guard let tr = model.overview?.transfers.first(where: { $0.hash == t.hash }), tr.status == "failed" else { return nil }
        return tr.message.isEmpty ? "The copy to the NAS failed." : tr.message
    }
}

private struct AutoTorrentRow: View {
    @ObservedObject var model: AutomaticModel
    let t: AutoTorrent
    let failure: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(t.name ?? t.hash).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !t.badges.isEmpty || t.lookingUntil != nil {
                    HStack(spacing: 5) {
                        ForEach(t.badges, id: \.self) { b in
                            AutoChip(text: b.text, tint: b.isDV ? Tint.check : .secondary)
                        }
                        if let until = t.lookingUntil {
                            Text("Looking for a better copy until \(AutoFormat.relativeDay(until))")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 1)
                }
                if let failure {
                    Text(failure).font(.system(size: 10.5)).foregroundStyle(Tint.bad).lineLimit(2)
                }
                if !t.isComplete && t.verdict == "approved" && t.checking != true {
                    ProgressView(value: t.progress ?? 0).progressViewStyle(.linear).frame(maxWidth: 300).padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            Text(AutoFormat.bytes(t.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            status
            if t.canBringToNAS {
                if model.busy.contains(t.hash) {
                    ProgressView().controlSize(.small).frame(width: 96)
                } else {
                    Button("Bring to NAS") { Task { await model.bringToNAS(t) } }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var title: String {
        if let s = t.series {
            return [s, AutoFormat.code(t.season, t.episode), t.episodeTitle].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: "  ")
        }
        return t.name ?? t.hash
    }

    @ViewBuilder private var status: some View {
        switch t.verdict {
        case "held": AutoChip(text: "Checking the files", tint: Tint.check, symbol: "doc.text.magnifyingglass")
        case "waiting": AutoChip(text: "Waiting for space", tint: Tint.warn, symbol: "externaldrive.badge.exclamationmark")
        case "rejected": AutoChip(text: "Blocked", tint: Tint.bad, symbol: "hand.raised")
        default:
            if t.onNAS { AutoChip(text: "On the NAS", tint: Tint.ok, symbol: "checkmark") }
            else if t.transferring { AutoChip(text: "Copying to the NAS", tint: Tint.busy, symbol: "arrow.right") }
            else if t.checking == true {
                AutoChip(text: t.progressText ?? "Checking", tint: Tint.check, symbol: "checkmark.circle.badge.questionmark")
            }
            else if t.isComplete { AutoChip(text: "Ready", tint: Tint.ok, symbol: "tray.full") }
            else { downloadingChip }
        }
    }

    /// While it is not finished, the word qBittorrent's own list would show.
    @ViewBuilder private var downloadingChip: some View {
        let pct = "\(Int((t.progress ?? 0) * 100))%"
        switch t.stateLabel ?? "Downloading" {
        case "Stalled":
            AutoChip(text: "Stalled \(pct)", tint: Tint.warn, symbol: "pause.circle")
        case "Queued":
            AutoChip(text: "Queued \(pct)", symbol: "clock")
        case "Stopped":
            AutoChip(text: "Stopped \(pct), restarting", tint: Tint.warn, symbol: "playpause")
        case "Errored", "Missing Files", "Unknown":
            AutoChip(text: "\(t.stateLabel ?? "Errored"), rechecking", tint: Tint.bad, symbol: "exclamationmark.triangle")
        case let label where label.contains("metadata"):
            AutoChip(text: "Fetching the file list", tint: Tint.check, symbol: "doc.text.magnifyingglass")
        default:
            AutoChip(text: [pct, AutoFormat.eta(t.eta)].compactMap { $0 }.joined(separator: " \u{00B7} "),
                     tint: Tint.busy, symbol: "arrow.down")
        }
    }
}

// MARK: - Blocked

private struct AutoBlockedView: View {
    @ObservedObject var model: AutomaticModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AutoHeader(title: "Blocked",
                           subtitle: "Releases refused before they downloaded (anything carrying an .exe or another executable, or without an episode-size video), and downloads dropped because they stopped moving. Sonarr blocklists each one and takes the next best.")
                let items = model.overview?.blocked ?? []
                if model.overview != nil && items.isEmpty {
                    AutoEmpty(symbol: "hand.raised", title: "Nothing blocked",
                              message: "Every release so far has been video and subtitles only.")
                }
                VStack(spacing: 0) {
                    ForEach(items) { b in
                        AutoBlockedRow(b: b)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct AutoBlockedRow: View {
    let b: AutoBlocked
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.name.isEmpty ? b.hash : b.name).font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(b.reason.prefix(1).uppercased() + b.reason.dropFirst())
                        .font(.system(size: 11.5)).foregroundStyle(Tint.bad)
                }
                Spacer(minLength: 10)
                if let at = b.at.flatMap(AutoDate.parse) {
                    Text(at.formatted(.relative(presentation: .named))).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if b.blocklisted {
                    AutoChip(text: "Blocklisted in Sonarr")
                } else if b.telling == true {
                    AutoChip(text: "Telling Sonarr", tint: Tint.warn)
                } else {
                    AutoChip(text: "Not a Sonarr grab")
                }
            }
            if !b.files.isEmpty {
                DisclosureGroup(isExpanded: $open) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(b.files, id: \.self) { f in
                            Text(f).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text(b.files.count == 1 ? "1 file" : "\(b.files.count) files").font(.system(size: 10.5))
                }
            }
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Suggestions

private struct AutoSuggestionsView: View {
    @ObservedObject var model: AutomaticModel
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 20, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    AutoHeader(title: "Suggestions",
                               subtitle: "Shows still airing that you picked by hand in the browser, or have been watching in Plex.")
                    if model.suggestionsLoaded && !model.suggestionsLoading {
                        ChromeButton(symbol: "arrow.clockwise", help: "Look again") {
                            Task { await model.loadSuggestions() }
                        }
                    }
                }
                if model.suggestionsLoading && model.suggestions.isEmpty {
                    ProgressView("Matching your picks to shows\u{2026}").controlSize(.small)
                        .frame(maxWidth: .infinity).padding(40)
                } else if let err = model.suggestionsError {
                    AutoBanner(symbol: "exclamationmark.triangle", text: err, tint: Tint.bad,
                               action: ("Try Again", { Task { await model.loadSuggestions() } }))
                } else if model.suggestionsLoaded && model.suggestions.isEmpty {
                    AutoEmpty(symbol: "sparkles.tv", title: "You are following everything you watch",
                              message: "New picks in the browser and new shows in Plex will turn up here.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(model.suggestions, id: \.stableID) { show in
                            AutoShowCard(show: show, action: AnyView(followButton(show)))
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { if !model.suggestionsLoaded { await model.loadSuggestions() } }
    }

    @ViewBuilder private func followButton(_ show: AutoShow) -> some View {
        if model.busy.contains(show.stableID) {
            ProgressView().controlSize(.small)
        } else {
            Button("Follow") { Task { await model.follow(show) } }.controlSize(.small)
        }
    }
}
