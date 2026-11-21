import Foundation

// MARK: - Paged VOD catalog models (GH #109 Apple parity)
//
// The Movies / TV Shows catalog used to be two `[VODDisplayItem]` arrays on
// `VODStore` plus one JSON snapshot per kind per server. A 350,000 title
// Dispatcharr library cannot live in memory on an Apple TV HD (1 GB of RAM,
// a ~650 MB jetsam ceiling for the app): the arrays alone ran past it long
// before the grid drew a single poster.
//
// The catalog now lives in a SQLite file under `AppCacheDirectory` (Caches on
// tvOS, which is the only writable place there) and the UI reads WINDOWS of
// it, exactly the way the Android app reads windows of its Room-backed store.
// These are the value types that model runs across that boundary; the store
// itself is `Shared/VODCatalogStore.swift`.

/// A sweep's saved position, as the catalog remembers it.
///
/// Apple's sweep walks Dispatcharr categories round-robin one page at a
/// time, so a lane's position is a 1-based page number plus whether that
/// category reached the end of its collection. Same semantics the old
/// `VODSweepProgress` file carried, now transactional with the rows.
struct VODSweepPlan: Sendable {
    /// The sweep that owns the rows being written. A finished sweep deletes
    /// rows from older generations; an interrupted one deletes nothing.
    var generation: Int64
    /// True when an open generation was picked back up rather than started.
    var resumed: Bool
    /// Category name to the next 1-based page to fetch.
    var nextPage: [String: Int]
    /// Categories whose walk already reached the end.
    var done: Set<String>
}

/// What a kind's sweep bookkeeping looks like on disk.
struct VODSweepState: Sendable {
    var generation: Int64
    var isOpen: Bool
    /// When a sweep of this kind last finished cleanly. `nil` = never.
    var completedAt: Date?
    /// Dispatcharr change probe recorded by the sweep that last finished:
    /// the collection count and the newest row's `created_at`. The
    /// background sweep re-probes and sweeps early when either moved.
    var remoteCount: Int?
    var remoteNewest: String?
}

/// Everything the grid needs to turn the catalog into one ordered list.
/// Run in SQL, never in Swift: on a 350k library the old in-memory filter
/// plus sort was both the memory ceiling and the scroll stutter.
struct VODCatalogQuery: Sendable, Hashable {
    var playlistKey: String
    var kind: VODItemType
    /// Manage Groups: category names the user switched off.
    var hiddenGroups: Set<String>
    /// Long-press Hide: `HiddenVODStore` keys, "<type>:<id>".
    var hiddenTitleKeys: Set<String>
    /// A group name, or `nil` for All. Never the Hidden pill label.
    var genre: String?
    /// The Hidden category is selected: show ONLY hidden titles.
    var onlyHidden: Bool
    /// Raw value of `MoviesSortOrder`.
    var sortRaw: String
    /// A real genre (`CinemaGenres` name), from the provider's genre text
    /// or TMDB's. Independent of `genre`, which is a provider category.
    var genreTag: String? = nil
}

// MARK: - Real genres (cinema home)

/// One genre tile: its label and the genre names (provider or TMDB) that
/// count as it. TMDB names movies "Science Fiction" and shows "Sci-Fi &
/// Fantasy", providers copy either, so one tile matches all spellings.
struct CinemaGenreDef: Sendable, Hashable {
    let name: String
    let tokens: [String]
}

enum CinemaGenres {
    static func list(for kind: VODItemType) -> [CinemaGenreDef] {
        kind == .series ? series : movies
    }

    static func def(named name: String, kind: VODItemType) -> CinemaGenreDef? {
        list(for: kind).first { $0.name == name }
    }

    private static let movies: [CinemaGenreDef] = [
        .init(name: "Action", tokens: ["Action", "Action & Adventure"]),
        .init(name: "Comedy", tokens: ["Comedy"]),
        .init(name: "Drama", tokens: ["Drama"]),
        .init(name: "Thriller", tokens: ["Thriller"]),
        .init(name: "Horror", tokens: ["Horror"]),
        .init(name: "Sci-Fi", tokens: ["Science Fiction", "Sci-Fi", "Sci-Fi & Fantasy"]),
        .init(name: "Adventure", tokens: ["Adventure", "Action & Adventure"]),
        .init(name: "Animation", tokens: ["Animation"]),
        .init(name: "Family", tokens: ["Family", "Kids"]),
        .init(name: "Crime", tokens: ["Crime"]),
        .init(name: "Romance", tokens: ["Romance"]),
        .init(name: "Fantasy", tokens: ["Fantasy", "Sci-Fi & Fantasy"]),
        .init(name: "Mystery", tokens: ["Mystery"]),
        .init(name: "Documentary", tokens: ["Documentary"]),
        .init(name: "War", tokens: ["War", "War & Politics"]),
        .init(name: "History", tokens: ["History"]),
        .init(name: "Western", tokens: ["Western"]),
        .init(name: "Music", tokens: ["Music"]),
    ]

    private static let series: [CinemaGenreDef] = [
        .init(name: "Drama", tokens: ["Drama"]),
        .init(name: "Comedy", tokens: ["Comedy"]),
        .init(name: "Crime", tokens: ["Crime"]),
        .init(name: "Action & Adventure", tokens: ["Action & Adventure", "Action", "Adventure"]),
        .init(name: "Sci-Fi & Fantasy", tokens: ["Sci-Fi & Fantasy", "Science Fiction", "Sci-Fi", "Fantasy"]),
        .init(name: "Mystery", tokens: ["Mystery", "Thriller"]),
        .init(name: "Animation", tokens: ["Animation"]),
        .init(name: "Kids & Family", tokens: ["Kids", "Family"]),
        .init(name: "Documentary", tokens: ["Documentary"]),
        .init(name: "Reality", tokens: ["Reality"]),
        .init(name: "War & Politics", tokens: ["War & Politics", "War"]),
        .init(name: "Western", tokens: ["Western"]),
        .init(name: "Soap", tokens: ["Soap"]),
    ]

    /// "Action & Adventure / Animation" or "Action, Drama" ->
    /// "Action & Adventure|Animation". nil when there is nothing.
    static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(whereSeparator: { $0 == "/" || $0 == "," || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }
}

/// A tab's grid list backed by the catalog. Only the row ids and the rail
/// bucket letters live in memory (9 bytes per title, so a 350,000 title
/// library costs about 3 MB here); rows are read a window at a time into the
/// store's shared LRU cache and dropped again as the scroll moves on.
///
/// A class, and `Equatable` by IDENTITY on purpose: the synthesized
/// collection `==` walks every element, which here would read the whole
/// catalog the moment SwiftUI compared two libraries in a `@State` write.
final class VODWindowList: RandomAccessCollection, Equatable, @unchecked Sendable {

    typealias Element = VODDisplayItem
    typealias Index = Int

    /// Stable catalog row ids, in display order.
    let rowIDs: [Int64]
    /// ASCII rail bucket per row, parallel to `rowIDs`.
    private let buckets: [UInt8]
    private weak var store: VODCatalogStore?

    init(store: VODCatalogStore?, rowIDs: [Int64], buckets: [UInt8]) {
        self.store = store
        self.rowIDs = rowIDs
        self.buckets = buckets
    }

    static let empty = VODWindowList(store: nil, rowIDs: [], buckets: [])

    var startIndex: Int { 0 }
    var endIndex: Int { rowIDs.count }

    subscript(position: Int) -> VODDisplayItem {
        let id = rowIDs[position]
        let hit = store?.cachedRow(id) ?? {
            store?.loadWindow(rowIDs: rowIDs, around: position)
            return store?.cachedRow(id)
        }()
        store?.prefetchWindow(rowIDs: rowIDs, around: position)
        // A row a finished sweep deleted after this list was built: a blank
        // placeholder until the rebuild that sweep triggers lands.
        return hit ?? VODWindowList.placeholder(id)
    }

    /// The SwiftUI row anchor for `index`, used by the alphabet rail's
    /// scroll-to. Index based, not item-id based: reading an id would read
    /// the row, and the rail must not touch the database to know where to go.
    static func anchorID(_ index: Int) -> String { "grid-row-\(index)" }

    /// Rail letters present in this list. Computed once, no row reads.
    lazy var railLetters: Set<String> = Set(buckets.map { String(UnicodeScalar($0)) })

    /// First row anchor per rail letter. No row reads.
    lazy var firstAnchorByLetter: [String: String] = {
        var out: [String: String] = [:]
        for (i, b) in buckets.enumerated() {
            let letter = String(UnicodeScalar(b))
            if out[letter] == nil { out[letter] = VODWindowList.anchorID(i) }
        }
        return out
    }()

    static func == (lhs: VODWindowList, rhs: VODWindowList) -> Bool { lhs === rhs }

    private static func placeholder(_ id: Int64) -> VODDisplayItem {
        VODDisplayItem(movie: VODMovie(
            id: "catalog-gone-\(id)", name: "", posterURL: nil, backdropURL: nil,
            rating: "", plot: "", genre: "", releaseDate: "", duration: "",
            cast: "", director: "", imdbID: "", categoryID: "", categoryName: "",
            streamURL: nil, containerExtension: "", serverID: UUID()))
    }
}
