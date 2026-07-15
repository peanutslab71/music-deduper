//
//  Normalize.swift — Phase 1 of Perfect v2: the headless cross-folder normalizer.
//
//  Pure planning, Foundation-only (unit-testable via Tests/run.sh): given every
//  music file's tags plus the junk/empties the scan found, produce ONE reversible
//  run — artist-spelling unification (folders AND tags), edition/disc-split
//  merges, junk + empty-folder quarantine, and a full Organiser.plan placement
//  pass — that leaves the library a strict one-folder-per-album tree. It never
//  touches disk itself; the caller applies the plan via applyLibraryRun (which
//  writes tags first, then moves — the order this plan assumes) and idempotency
//  falls out: a second plan over the normalized library proposes nothing.
//

import Foundation

enum Normalizer {

    /// Everything the normalizer needs to know about the library, pre-read by the
    /// caller (organiseInputsFromDisk + a junk/empties walk) so planning stays pure.
    struct Input {
        var tracks: [OrganiseInput]
        var junkRels: [String] = []       // junk files (.DS_Store, ._*, …) → quarantine
        var emptyDirRels: [String] = []   // folders with no audio anywhere inside → quarantine
    }

    /// One artist whose name appears under several spellings ("Buzzcocks" vs
    /// "The Buzzcocks", folder or tag). Surfaced for the confirm step; the plan
    /// writes `canonical` (overridable per key) everywhere.
    struct ArtistUnification: Identifiable {
        let key: String                              // Organiser.artistKey grouping key
        let canonical: String                        // chosen spelling (most files back it)
        let variants: [(name: String, count: Int)]   // every spelling + its backing
        var id: String { key }
    }

    /// The one reversible run.
    struct Plan {
        var tagWrites: [(rel: String, field: String, value: String)] = []
        var moves: [(from: String, to: String)] = []   // empty `to` = quarantine
        var unifications: [ArtistUnification] = []     // where the artist writes came from
        var mergeGroups: [Organiser.MergeGroup] = []   // edition merges folded into the plan
        var isEmpty: Bool { tagWrites.isEmpty && moves.isEmpty }
    }

    /// A many-artists album that LOOKS like a compilation (same shape as the batch
    /// heuristic): ≥2 distinct primary artists and no dominant non-VA album-artist.
    /// Surfaced for confirmation — never flagged silently; a confirmed candidate's
    /// foldKeys feed Organiser.plan's `compilations` so its tracks group under
    /// Various Artists across folders.
    struct CompilationCandidate: Identifiable {
        let key: String            // canonicalAlbumKey (stable across editions)
        let display: String        // most common raw album name
        let foldKeys: Set<String>  // fold(stripDiscSuffix(...)) variants Organiser.plan matches on
        let artists: Int
        let tracks: Int
        var id: String { key }
    }

    static func compilationCandidates(_ tracks: [OrganiseInput]) -> [CompilationCandidate] {
        var byAlbum: [String: [OrganiseInput]] = [:]
        for t in tracks where !Organiser.albumOrEmpty(t.album).isEmpty {
            byAlbum[Organiser.canonicalAlbumKey(t.album), default: []].append(t)
        }
        var out: [CompilationCandidate] = []
        for (key, ts) in byAlbum {
            guard ts.count >= 3 else { continue }
            if ts.contains(where: { $0.isCompilation }) { continue }   // already flagged → groups anyway
            let primaries = Set(ts.map {
                Organiser.artistKey(Organiser.primaryArtist($0.artist.isEmpty ? $0.albumArtist : $0.artist))
            }.filter { !$0.isEmpty })
            guard primaries.count >= 2 else { continue }
            let aa = ts.map { $0.albumArtist }.filter { !$0.isEmpty }
            let counts = Dictionary(grouping: aa, by: { $0 }).mapValues { $0.count }
            let dominant = counts.max { (a: (key: String, value: Int), b: (key: String, value: Int)) -> Bool in
                if a.value != b.value { return a.value < b.value }
                return a.key.count > b.key.count
            }
            let agree = dominant.map { Double($0.value) / Double(ts.count) } ?? 0
            let isVA = dominant.map { Organiser.artistKey($0.key) == "variousartists" } ?? false
            guard dominant == nil || isVA || agree < 0.6 else { continue }
            let names = ts.map { Organiser.albumOrEmpty($0.album) }.filter { !$0.isEmpty }
            let display = Dictionary(grouping: names, by: { $0 })
                .max { $0.value.count < $1.value.count }?.key ?? key
            out.append(CompilationCandidate(key: key, display: display,
                                            foldKeys: Set(names.map { Organiser.fold(Organiser.stripDiscSuffix($0).clean) }),
                                            artists: primaries.count, tracks: ts.count))
        }
        return out.sorted { $0.display.lowercased() < $1.display.lowercased() }
    }

    /// Name-level junk that is safe to quarantine on sight: OS metadata litter and
    /// interrupted-operation debris. Zero-byte and stray non-music files are the
    /// scanner's judgement, not this list's.
    static func isJunkFileName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == ".ds_store" || n == "thumbs.db" || n == "desktop.ini" { return true }
        if n.hasPrefix("._") || n.hasPrefix(".smbdelete") { return true }
        return false
    }

    /// Build the Phase-1 plan. Order inside the run (matching performLibraryOps):
    /// tag writes (artist unification + the placement pass's self-describing tags)
    /// first, while files sit at their original paths; then every move.
    static func plan(_ input: Input,
                     canonicalArtistOverrides: [String: String] = [:],   // key → user's pick
                     declinedMerges: Set<String> = [],
                     confirmedCompilations: Set<String> = [],
                     composerFirstForClassical: Bool = false,
                     renumber: Bool = false) -> Plan {
        var plan = Plan()

        // ---- 1. Artist unification. Count every spelling an artist appears under —
        // artist tag, album-artist tag, and the top-level folder name (each file
        // backs its folder's spelling) — grouped by the folded artistKey. Any key
        // with >1 spelling gets ONE canonical form, written to every differing tag;
        // the placement pass below then files everything under it, which is what
        // merges the split artist FOLDERS too.
        var groups: [String: [String: Int]] = [:]   // key → spelling → backing
        func add(_ name: String) {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            let k = Organiser.artistKey(n)
            guard !k.isEmpty else { return }
            groups[k, default: [:]][n, default: 0] += 1
        }
        for t in input.tracks {
            add(t.artist); add(t.albumArtist)
            let comps = (t.rel as NSString).pathComponents
            if comps.count >= 3 { add(comps[0]) }   // Artist/Album/file layout only
        }
        var canonicalByKey: [String: String] = [:]
        for (key, spellings) in groups where spellings.count > 1 {
            let ranked = spellings.sorted { $0.value != $1.value ? $0.value > $1.value
                                                                 : $0.key.lowercased() < $1.key.lowercased() }
            let canonical = canonicalArtistOverrides[key] ?? ranked[0].key
            canonicalByKey[key] = canonical
            plan.unifications.append(ArtistUnification(key: key, canonical: canonical,
                                                       variants: ranked.map { ($0.key, $0.value) }))
        }
        plan.unifications.sort { $0.canonical.lowercased() < $1.canonical.lowercased() }

        var tracks = input.tracks
        for i in tracks.indices {
            if !tracks[i].artist.isEmpty, let c = canonicalByKey[Organiser.artistKey(tracks[i].artist)],
               tracks[i].artist != c {
                plan.tagWrites.append((tracks[i].rel, "artist", c)); tracks[i].artist = c
            }
            if !tracks[i].albumArtist.isEmpty, let c = canonicalByKey[Organiser.artistKey(tracks[i].albumArtist)],
               tracks[i].albumArtist != c {
                plan.tagWrites.append((tracks[i].rel, "albumartist", c)); tracks[i].albumArtist = c
            }
        }

        // ---- 2. Junk + pre-existing empty folders → quarantine (recorded, undoable;
        // deepest empties first so a nested shell empties its parent's turn).
        for rel in input.junkRels.sorted() { plan.moves.append((rel, "")) }
        for rel in input.emptyDirRels.sorted(by: { $0.count > $1.count }) { plan.moves.append((rel, "")) }

        // ---- 3. Edition merges + VA grouping + the full placement pass, in ONE
        // Organiser.plan call over the unified tags. Confirmed compilations group
        // under Various Artists; detected edition merges (minus the user's declines)
        // fold split folders; every file gets its self-describing tags.
        plan.mergeGroups = Organiser.albumMergeCandidates(tracks)
            .filter { !declinedMerges.contains($0.key) }
        let placements = Organiser.plan(tracks,
                                        composerFirstForClassical: composerFirstForClassical,
                                        renumber: renumber,
                                        compilations: confirmedCompilations,
                                        mergeAlbums: Set(plan.mergeGroups.map { $0.key }))
        for p in placements.sorted(by: { $0.rel < $1.rel }) {
            for (field, value) in p.tagWrites { plan.tagWrites.append((p.rel, field, value)) }
            if let target = p.targetRel, target != p.rel { plan.moves.append((p.rel, target)) }
        }
        return plan
    }

    /// Everything the user decided on the Phase-1 confirm surface, persisted per
    /// library so a re-run (or the v2 driver) seeds from the same choices.
    struct Choices: Codable {
        var artistOverrides: [String: String] = [:]   // artistKey → chosen spelling
        var declinedMerges: [String] = []             // canonicalAlbumKey of declined edition merges
        var declinedCompilations: [String] = []       // CompilationCandidate.key of declined groupings
    }

    enum ChoicesStore {
        private static func hash(_ s: String) -> String {
            var h: UInt64 = 5381; for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }; return String(h, radix: 16)
        }
        private static func file(_ rootPath: String) -> URL? {
            let fm = FileManager.default
            guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true) else { return nil }
            let dir = base.appendingPathComponent("Music Librarian/normalize-choices", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("\(hash(rootPath)).json")
        }
        static func load(_ rootPath: String) -> Choices {
            guard let u = file(rootPath), let d = try? Data(contentsOf: u),
                  let c = try? JSONDecoder().decode(Choices.self, from: d) else { return Choices() }
            return c
        }
        static func save(_ rootPath: String, _ c: Choices) {
            guard let u = file(rootPath), let d = try? JSONEncoder().encode(c) else { return }
            try? d.write(to: u)
        }
    }

    /// Test/preview helper: apply a plan to the in-memory inputs the way
    /// performLibraryOps would to disk (tag writes first, then moves; unchanged
    /// values are no-ops). Lets tests assert idempotency — plan(apply(plan)) is
    /// empty — without touching a filesystem.
    static func simulate(_ input: Input, applying plan: Plan) -> Input {
        var byRel = Dictionary(uniqueKeysWithValues: input.tracks.map { ($0.rel, $0) })
        for w in plan.tagWrites {
            guard var t = byRel[w.rel] else { continue }
            switch w.field {
            case "artist":      t.artist = w.value
            case "albumartist": t.albumArtist = w.value
            case "album":       t.album = w.value
            case "title":       t.title = w.value
            case "disc":        t.discNo = Int(w.value) ?? t.discNo
            case "track":       t.trackNo = Int(w.value) ?? t.trackNo
            default: break
            }
            byRel[w.rel] = t
        }
        var out = Input(tracks: [], junkRels: [], emptyDirRels: [])
        var moved: [String: String] = [:]
        for m in plan.moves { moved[m.from] = m.to }   // empty to = quarantined (gone)
        for (rel, t) in byRel {
            guard let to = moved[rel] else { out.tracks.append(t); continue }
            if to.isEmpty { continue }                 // quarantined
            out.tracks.append(OrganiseInput(rel: to, ext: t.ext, artist: t.artist,
                                            albumArtist: t.albumArtist, album: t.album,
                                            title: t.title, trackNo: t.trackNo, discNo: t.discNo,
                                            isClassical: t.isClassical, composer: t.composer,
                                            isCompilation: t.isCompilation))
        }
        out.tracks.sort { $0.rel < $1.rel }
        return out
    }
}
