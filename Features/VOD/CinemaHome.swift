import SwiftUI

#if os(tvOS)
// MARK: - Cinema home (Movies / TV Shows redesign, tvOS)
//
// The browse page's top half in the "cinema" look: a blurred artwork wash
// behind the page that follows focus, a Continue Watching row of landscape
// cards, and genre tiles. Plugs into MoviesView in place of the paged hero
// and keeps the hero's focus contract (focusRequest / restoreRequest /
// onHeroFocusChange), so the tab-bar, Menu-to-top and scroll rules that
// MoviesView builds on the hero keep working unchanged.

/// Which Movies / TV Shows tabs are showing their full list (a category,
/// genre or All page) instead of the home rows. HomeView's Menu handler
/// reads it: Menu there must close the list, not jump to the tab bar
/// (which the list hides).
@MainActor
final class TVCinemaBrowseState {
    static let shared = TVCinemaBrowseState()
    var openTabs: Set<String> = []
    private init() {}
}

extension Notification.Name {
    /// userInfo["tab"] = AppTab raw value: close that tab's full list.
    static let aerioCinemaCloseBrowse = Notification.Name("aerio.cinemaCloseBrowse")
}

/// Opens the on-screen keyboard for a text field as soon as it is shown,
/// so pressing a search button lands straight in text entry. On tvOS a
/// focused field still needs Select to start editing; there is no SwiftUI
/// API for that, so the UIKit field underneath is made first responder.
@MainActor
enum TVKeyboard {
    static func open(placeholderPrefix: String, after delay: Double = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            for w in windows where !w.isHidden {
                if let field = find(in: w, prefix: placeholderPrefix) {
                    field.becomeFirstResponder()
                    debugLog("[SEARCH] keyboard opened for '\(placeholderPrefix)'")
                    return
                }
            }
            debugLog("[SEARCH] no text field found for '\(placeholderPrefix)'")
        }
    }

    private static func find(in view: UIView, prefix: String) -> UITextField? {
        if let tf = view as? UITextField {
            let ph = tf.placeholder ?? tf.attributedPlaceholder?.string ?? ""
            if ph.hasPrefix(prefix) { return tf }
        }
        for sub in view.subviews {
            if let hit = find(in: sub, prefix: prefix) { return hit }
        }
        return nil
    }
}

/// Section title in the cinema look: bold white with a trailing chevron
/// when the section leads somewhere.
struct CinemaSectionTitle: View {
    let title: String
    var showsChevron: Bool = false
    /// White text; off inside a heading button, whose style colours it.
    var tinted: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .scaledFont(.system(size: 32, weight: .bold))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))  // glyph beside the title: fixed size
                    .opacity(0.7)
            }
        }
        .foregroundStyle(tinted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.foreground))
    }
}

/// A row heading that opens the full list ("Premiere 25/26 >"), like the
/// Apple TV app: plain title at rest, white pill with dark text on focus.
struct CinemaHeaderButtonStyle: ButtonStyle {
    let title: String
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Drawn here rather than taken from the label: a colour set on the
        // label lost to the title's own, so the focused pill was white on
        // white.
        HStack(spacing: 10) {
            Text(title)
                .scaledFont(.system(size: 32, weight: .bold))
            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .bold))  // glyph beside the title: fixed size
                .opacity(0.7)
        }
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, isFocused ? 18 : 0)
            .padding(.vertical, isFocused ? 6 : 0)
            .background(Capsule().fill(Color.white.opacity(isFocused ? 1 : 0)))
            .scaleEffect(isFocused ? 1.04 : (configuration.isPressed ? 0.97 : 1), anchor: .leading)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Detail-page buttons (Play, Favorites, Mark as Watched). Primary: white
/// pill with dark text. Secondary: frosted pill that turns white on focus.
struct CinemaPillButtonStyle: ButtonStyle {
    var isPrimary: Bool = false
    var height: CGFloat = 76
    /// Stretch to the available width (Play, Mark as Watched) or hug the
    /// label (the small secondary buttons and season pills).
    var fill: Bool = true
    var fontSize: CGFloat = 28
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let lit = isPrimary || isFocused
        return configuration.label
            .font(.system(size: fontSize, weight: .semibold))  // remote-sized button label
            .foregroundColor(lit ? .black : .white)
            .padding(.horizontal, fill ? 34 : 26)
            .frame(height: height)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(Capsule().fill(lit ? Color.white : Color.white.opacity(0.16)))
            .overlay(Capsule().stroke(Color.white.opacity(isPrimary && isFocused ? 0.9 : 0), lineWidth: 4).padding(-6))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .scaleEffect(isFocused ? 1.06 : (configuration.isPressed ? 0.97 : 1))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Shared focus treatment for cinema cards: lift, white ring, deep shadow.
struct CinemaCardFocusStyle: ButtonStyle {
    var cornerRadius: CGFloat = 26
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isFocused ? 0.95 : 0), lineWidth: 4)
            )
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0.25), radius: isFocused ? 30 : 10, y: isFocused ? 20 : 6)
            .scaleEffect(isFocused ? 1.07 : (configuration.isPressed ? 0.97 : 1.0))
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// The page backdrop: the focused title's art, blurred and darkened, fading
/// between titles. Falls back to the plain page colour with no art.
struct CinemaAmbientBackground: View {
    let url: URL?
    var headers: [String: String] = [:]

    var body: some View {
        // The plain colour sets the size; the art is an OVERLAY so it can
        // never size the page. As a ZStack child, an aspect-filled portrait
        // poster made the whole tab ~2900 pt tall and pushed the content
        // ~900 pt off the top of the screen.
        Color.appBackground
            .overlay {
                if let url {
                    AuthPosterImage(url: url, headers: headers, placeholder: .clear, maxPixel: 320)
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 70, opaque: true)
                        .saturation(1.3)
                        .opacity(0.75)
                        .id(url)
                        .transition(.opacity)
                }
            }
            .overlay {
                // Darken toward the bottom so the lower rows stay legible.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.25), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: Color.appBackground.opacity(0.96), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .animation(.easeInOut(duration: 0.6), value: url)
            .ignoresSafeArea()
    }
}

/// Art for a cinema card or the ambient wash: TMDB landscape art when the
/// cache has it, then the provider's backdrop, then the poster.
@MainActor
enum CinemaArt {
    static func landscape(_ item: VODDisplayItem, override: URL? = nil) -> URL? {
        override
            ?? TMDBArtCache.shared.backdropURL(for: item, size: "w780")
            ?? item.backdropURL
            ?? TMDBArtCache.shared.posterURL(for: item)
            ?? item.posterURL
    }

    static func poster(_ item: VODDisplayItem) -> URL? {
        TMDBArtCache.shared.posterURL(for: item) ?? item.posterURL
    }
}

/// Runs `action` when the view (a focusable control) gains focus.
private struct CinemaFocusReporter: ViewModifier {
    let action: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, now in if now { action() } }
    }
}

extension View {
    /// Report focus arriving on this control (drives the ambient backdrop).
    func onCinemaFocus(_ action: @escaping () -> Void) -> some View {
        modifier(CinemaFocusReporter(action: action))
    }
}

// MARK: - Continue Watching row

/// Landscape cards for titles in progress (or, with nothing in progress,
/// the newest additions). Select resumes; long press offers Play from
/// Beginning, Details, Watchlist and Remove. Owns the hero focus contract.
struct CinemaContinueRow: View {
    @ObservedObject private var themeLive = ThemeManager.shared
    @ObservedObject private var art = TMDBArtCache.shared
    let title: String
    let pages: [MoviesHeroPage]
    var headers: [String: String] = [:]
    /// Owner sets true to focus the first card; reset here.
    var focusRequest: Binding<Bool> = .constant(false)
    /// Owner sets true to focus the card that held focus last.
    var restoreRequest: Binding<Bool> = .constant(false)
    /// True while any card in the row has focus.
    var onHeroFocusChange: ((Bool) -> Void)? = nil
    /// A card gained focus (drives the ambient backdrop).
    var onFocusPage: ((MoviesHeroPage) -> Void)? = nil
    let onPrimary: (MoviesHeroPage) -> Void
    let onPlayFromStart: (MoviesHeroPage) -> Void
    let onDetails: (MoviesHeroPage) -> Void
    let onRemove: (MoviesHeroPage) -> Void
    var isOnWatchlist: ((MoviesHeroPage) -> Bool)? = nil
    var onToggleWatchlist: ((MoviesHeroPage) -> Void)? = nil

    @FocusState private var focusedID: String?
    @FocusState private var catcherFocused: Bool
    @State private var lastFocusedID: String?

    static let cardWidth: CGFloat = 420
    static let cardHeight: CGFloat = 236

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CinemaSectionTitle(title: title, showsChevron: false)
                .padding(.horizontal, 60)
            // Down from the tab bar lands on this strip and is forwarded to
            // the first card, so geometry never picks a card that is half
            // off screen. Only present while the row has no focus, so Up
            // from a card goes straight to the tab bar.
            if focusedID == nil {
                Color.clear
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
                    .focusable(true)
                    .focused($catcherFocused)
                    .onChange(of: catcherFocused) { _, focused in
                        guard focused else { return }
                        focusedID = pages.first?.id
                    }
            } else {
                Color.clear.frame(height: 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(pages) { page in
                        Button { onPrimary(page) } label: { card(page) }
                            .buttonStyle(CinemaCardFocusStyle(cornerRadius: 26))
                            .focused($focusedID, equals: page.id)
                            .contextMenu { menu(page) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 34)
            }
        }
        .onChange(of: focusedID) { _, id in
            if let id {
                lastFocusedID = id
                if let page = pages.first(where: { $0.id == id }) { onFocusPage?(page) }
            }
            onHeroFocusChange?(id != nil)
        }
        .onChange(of: focusRequest.wrappedValue) { _, wanted in
            guard wanted else { return }
            focusedID = pages.first?.id
            focusRequest.wrappedValue = false
        }
        .onChange(of: restoreRequest.wrappedValue) { _, wanted in
            guard wanted else { return }
            if let last = lastFocusedID, pages.contains(where: { $0.id == last }) {
                focusedID = last
            } else {
                focusedID = pages.first?.id
            }
            restoreRequest.wrappedValue = false
        }
    }

    @ViewBuilder
    private func menu(_ page: MoviesHeroPage) -> some View {
        if page.progress != nil {
            Button { onPlayFromStart(page) } label: {
                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
            }
        }
        Button { onDetails(page) } label: { Label("Details", systemImage: "info.circle") }
        if let onToggleWatchlist {
            let on = isOnWatchlist?(page) ?? false
            Button { onToggleWatchlist(page) } label: {
                Label(on ? "Remove from Watchlist" : "Add to Watchlist",
                      systemImage: on ? "heart.slash" : "heart")
            }
        }
        if page.progress != nil {
            Button(role: .destructive) { onRemove(page) } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    private func card(_ page: MoviesHeroPage) -> some View {
        let _ = art.version
        return ZStack(alignment: .bottomLeading) {
            Color.cardBackground
            AuthPosterImage(url: CinemaArt.landscape(page.item, override: page.backdropOverride),
                            headers: headers, placeholder: .clear, maxPixel: 900)
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0.3),
                .init(color: .black.opacity(0.85), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text(page.item.displayName)
                    .scaledFont(.system(size: 30, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))  // glyph in the meta line: fixed size
                    if let fraction = Self.fraction(page.progress) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(Color.white)
                                .frame(width: 84 * fraction)
                        }
                        .frame(width: 84, height: 7)
                    }
                    if let meta = Self.meta(page) {
                        Text(meta)
                            .scaledFont(.system(size: 22, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundColor(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private static func fraction(_ p: WatchProgress?) -> CGFloat? {
        guard let p, p.durationMs > 0 else { return nil }
        return min(1, max(0.03, CGFloat(p.positionMs) / CGFloat(p.durationMs)))
    }

    /// "S9, E7 · 21m left" for episodes, "1h 12m left" for movies, the year
    /// for a title that is not in progress.
    private static func meta(_ page: MoviesHeroPage) -> String? {
        guard let p = page.progress else {
            let y = page.item.releaseYear
            return y.isEmpty ? nil : y
        }
        var parts: [String] = []
        if p.seasonNumber > 0 { parts.append("S\(p.seasonNumber), E\(p.episodeNumber)") }
        if p.durationMs > 0 {
            let left = max(0, Int((p.durationMs - p.positionMs) / 60_000))
            parts.append(left >= 60 ? "\(left / 60)h \(left % 60)m left" : "\(left)m left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Genre tiles

/// One genre tile: the category name over a colour wash, with three of its
/// posters fanned out on the right.
struct CinemaGenreTile: View {
    let name: String
    let posters: [URL]
    var headers: [String: String] = [:]

    static let width: CGFloat = 400
    static let height: CGFloat = 190

    /// Stable colour per name, so a genre keeps its tile colour.
    private var tint: (Color, Color) {
        let palette: [(String, String)] = [
            ("8C3B2A", "3A1410"), ("2F5FA8", "152B55"), ("5E6B73", "2A3136"), ("8A63B8", "45285E"),
            ("3F7A55", "16301F"), ("A8577E", "4E2238"), ("33415C", "141B2B"), ("A8742F", "4A2E0C")
        ]
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let pick = palette[Int(h % UInt32(palette.count))]
        return (Color(hex: pick.0), Color(hex: pick.1))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [tint.0, tint.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 12) {
                ForEach(Array(posters.prefix(3).enumerated()), id: \.offset) { _, url in
                    AuthPosterImage(url: url, headers: headers, placeholder: .white.opacity(0.08), maxPixel: 300)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 92, height: 138)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
                }
            }
            .rotationEffect(.degrees(14))
            .offset(x: Self.width - 250, y: 6)
            LinearGradient(stops: [
                .init(color: tint.1.opacity(0.85), location: 0),
                .init(color: tint.1.opacity(0), location: 0.6)
            ], startPoint: .leading, endPoint: .trailing)
            Text(name)
                .scaledFont(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: Self.width * 0.55, alignment: .leading)
                .padding(.leading, 36)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

/// The genre tiles row: real genres (Action, Drama, ...) from the
/// provider's genre text and TMDB's, counted in the local catalog (no
/// network). Selecting a tile opens that genre's full list.
struct CinemaGenreRow: View {
    let kind: VODItemType
    var hiddenGroups: Set<String> = []
    var hiddenTitleKeys: Set<String> = []
    var headers: [String: String] = [:]
    let onSelect: (String) -> Void
    var onFocus: ((URL?) -> Void)? = nil

    @ObservedObject private var store = VODStore.shared
    @ObservedObject private var art = TMDBArtCache.shared
    @State private var tiles: [Tile] = []
    /// nil until the first load finishes; false = this kind has no genres.
    @State private var hasGenres: Bool?

    struct Tile: Identifiable, Equatable {
        let name: String
        let count: Int
        let posters: [URL]
        var id: String { name }
    }

    private var loadKey: String {
        "\(store.catalogKey ?? "")|\(kind)|\(store.catalogRevision / 25)|\(art.genreRevision / 5)|"
            + hiddenGroups.sorted().joined(separator: ",") + "|\(hiddenTitleKeys.count)"
    }

    var body: some View {
        // A real container, not a Group: with no tiles yet a Group is an
        // EmptyView, which never appears, so the loading task never ran.
        VStack(alignment: .leading, spacing: 0) {
            if hasGenres == nil {
                // Same height as the loaded row, so the rows below never
                // move when the tiles arrive (moved views keep stale focus
                // frames on tvOS, see CinemaCategoryRows).
                VStack(alignment: .leading, spacing: 18) {
                    CinemaSectionTitle(title: "Genres").padding(.horizontal, 60).opacity(0.4)
                    HStack(spacing: 36) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: CinemaGenreTile.width, height: CinemaGenreTile.height)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 30)
                }
            } else if !tiles.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    CinemaSectionTitle(title: "Genres")
                        .padding(.horizontal, 60)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 36) {
                            ForEach(tiles) { tile in
                                Button { onSelect(tile.name) } label: {
                                    CinemaGenreTile(name: tile.name, posters: tile.posters, headers: headers)
                                }
                                .buttonStyle(CinemaCardFocusStyle(cornerRadius: 30))
                                .onCinemaFocus { onFocus?(tile.posters.first) }
                                .accessibilityLabel("\(tile.name), \(tile.count) titles")
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 30)
                    }
                }
                .focusSection()
            }
        }
        .task(id: loadKey) {
            let rows = await store.genreOverview(kind: kind, hiddenGroups: hiddenGroups,
                                                 hiddenTitleKeys: hiddenTitleKeys)
            guard !Task.isCancelled else { return }
            // Most-stocked genres first; tiny ones (a stray tag) left out.
            let next = rows.filter { $0.count >= 3 }
                .sorted { $0.count > $1.count }
                .map { Tile(name: $0.name, count: $0.count, posters: $0.items.compactMap { CinemaArt.poster($0) }) }
            if next != tiles { tiles = next }
            hasGenres = !next.isEmpty
        }
    }
}

/// A row of posters: Favorites, or one of the provider's categories with a
/// "See all" card at the end that opens the full category.
struct CinemaPosterRow: View {
    let title: String
    let items: [VODDisplayItem]
    var headers: [String: String] = [:]
    let onOpen: (VODDisplayItem) -> Void
    var onSeeAll: (() -> Void)? = nil
    var onFocus: ((VODDisplayItem) -> Void)? = nil
    var isFavorite: ((VODDisplayItem) -> Bool)? = nil
    var onToggleFavorite: ((VODDisplayItem) -> Void)? = nil

    @ObservedObject private var art = TMDBArtCache.shared

    static let posterWidth: CGFloat = 232
    static let posterHeight: CGFloat = 348

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let onSeeAll {
                // The heading itself opens the full list (Apple TV app style).
                Button(action: onSeeAll) { Text(title) }
                .buttonStyle(CinemaHeaderButtonStyle(title: title))
                .accessibilityLabel("\(title), show all")
                .padding(.horizontal, 60)
            } else {
                CinemaSectionTitle(title: title)
                    .padding(.horizontal, 60)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) {
                    ForEach(items) { item in
                        Button { onOpen(item) } label: { poster(item) }
                            .buttonStyle(CinemaCardFocusStyle(cornerRadius: 22))
                            .onCinemaFocus { onFocus?(item) }
                            .contextMenu {
                                if let onToggleFavorite {
                                    let on = isFavorite?(item) ?? false
                                    Button { onToggleFavorite(item) } label: {
                                        Label(on ? "Remove from Favorites" : "Add to Favorites",
                                              systemImage: on ? "heart.slash" : "heart")
                                    }
                                }
                            }
                            .accessibilityLabel(item.displayName)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
            }
        }
        .focusSection()
    }

    private func poster(_ item: VODDisplayItem) -> some View {
        let _ = art.version
        return ZStack(alignment: .bottom) {
            Color.cardBackground
            // Under the art: shows when there is no poster or it fails to load.
            Text(item.displayName)
                .scaledFont(.system(size: 26, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let url = CinemaArt.poster(item) {
                AuthPosterImage(url: url, headers: headers, placeholder: .clear, maxPixel: 500)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.posterWidth, height: Self.posterHeight)
                    .clipped()
            }
        }
        .frame(width: Self.posterWidth, height: Self.posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

}

/// One row per provider category, loaded lazily from the local catalog.
struct CinemaCategoryRows: View {
    let kind: VODItemType
    let categories: [String]
    var hiddenTitleKeys: Set<String> = []
    var headers: [String: String] = [:]
    let onOpen: (VODDisplayItem) -> Void
    let onSeeAll: (String) -> Void
    var onFocus: ((VODDisplayItem) -> Void)? = nil
    var isFavorite: ((VODDisplayItem) -> Bool)? = nil
    var onToggleFavorite: ((VODDisplayItem) -> Void)? = nil
    /// The last row: "All Movies" with the week's top titles; its heading
    /// opens the whole library.
    var allTitle: String? = nil
    var onAll: (() -> Void)? = nil
    var hiddenGroups: Set<String> = []

    @ObservedObject private var store = VODStore.shared
    @State private var rows: [String: [VODDisplayItem]] = [:]
    @State private var loaded = false
    @State private var allItems: [VODDisplayItem] = []

    private var loadKey: String {
        "\(store.catalogKey ?? "")|\(kind)|\(store.catalogRevision / 25)|\(hiddenTitleKeys.count)|"
            + categories.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(categories.filter { !(rows[$0] ?? []).isEmpty }, id: \.self) { name in
                CinemaPosterRow(title: name, items: rows[name] ?? [], headers: headers,
                                onOpen: onOpen, onSeeAll: { onSeeAll(name) }, onFocus: onFocus,
                                isFavorite: isFavorite, onToggleFavorite: onToggleFavorite)
            }
            // Only once every row is in: a focusable view that later moves
            // down as rows arrive keeps its OLD frame in the tvOS focus
            // engine (SwiftUI does not refresh it), so Down from the tab bar
            // picked "All Movies" at the top of the page, invisibly.
            if loaded, let allTitle, let onAll, !allItems.isEmpty {
                CinemaPosterRow(title: allTitle, items: allItems, headers: headers,
                                onOpen: onOpen, onSeeAll: onAll, onFocus: onFocus,
                                isFavorite: isFavorite, onToggleFavorite: onToggleFavorite)
            }
        }
        .task(id: loadKey) {
            var next: [String: [VODDisplayItem]] = [:]
            for name in categories {
                let items = await store.sample(kind: kind, category: name,
                                               hiddenTitleKeys: hiddenTitleKeys, limit: 15)
                guard !Task.isCancelled else { return }
                next[name] = items
                // Show rows as they arrive instead of after the last one.
                if next.count % 6 == 0 { rows = next }
            }
            rows = next
            allItems = await topTitles()
            loaded = true
        }
    }

    /// The All row: this week's TMDB trending titles that the library has
    /// (matched by title), topped up with the newest additions.
    private func topTitles() async -> [VODDisplayItem] {
        var out: [VODDisplayItem] = []
        var seen = Set<String>()
        if TMDBPosters.isEnabled, let key = TMDBPosters.apiKey {
            let trending = await TMDBService.trending(isMovie: kind == .movie, apiKey: key)
            // Exact: library titles the poster lookup matched to these TMDB
            // ids. Fallback: the provider's title equals TMDB's.
            let clean = TMDBArtCache.shared.cleanTitles(forTMDBIDs: trending.map(\.id), isMovie: kind == .movie)
            let byClean = await store.itemsByCleanTitles(kind: kind, cleanTitles: Array(Set(clean.values)))
            let byTitle = await store.itemsByNormalizedTitle(
                kind: kind, titles: trending.map { VODCatalogStore.normalized($0.title) }, requireNoTMDBID: false)
            for t in trending {
                let hit = clean[t.id].flatMap { byClean[$0] } ?? byTitle[VODCatalogStore.normalized(t.title)]
                if let hit, seen.insert(hit.id).inserted { out.append(hit) }
                if out.count >= 15 { break }
            }
            debugLog("[CINEMA] All row: \(out.count) of \(trending.count) trending titles in the library")
        }
        if out.count < 15 {
            let recent = await store.recentlyAdded(kind: kind, hiddenGroups: hiddenGroups,
                                                   hiddenTitleKeys: hiddenTitleKeys)
            for r in recent where out.count < 15 && seen.insert(r.id).inserted { out.append(r) }
        }
        let prefix = (kind == .series ? "series" : "movie") + "|"
        let hidden = Set(hiddenTitleKeys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        return out.filter { !hidden.contains($0.id) }
    }
}

#endif
