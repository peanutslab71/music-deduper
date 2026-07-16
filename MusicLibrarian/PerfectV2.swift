//
//  PerfectV2.swift — the Perfect v2 driver + library-first carousel (behind the
//  "perfectV2" flag).
//
//  The library IS the carousel: choosing a library loads every album as a card
//  immediately (cover, facts, track table) from a local scan. Run is a visible
//  pipeline — Phase-1 normalize (the strip refreshes once as merges fuse), then
//  the per-album engine walks the strip live: each card pulses while analyzed,
//  then turns ✓ clean or gains its decision blocks in place. Decisions
//  accumulate offline and apply in one batch; every apply is a session-stamped,
//  undoable run; Revert library is always one click.
//
//  Enable with:  defaults write com.local.musiclibrarian perfectV2 -bool YES
//

import SwiftUI
import MDTagShim

extension PerfectStore {
    /// The v2 rollout flag (plan step 5/7). Hidden: set via `defaults write`.
    static var perfectV2Enabled: Bool { UserDefaults.standard.bool(forKey: "perfectV2") }
}

// MARK: - Driver

/// Drives one Perfect v2 session over a library. Owns the card list; all disk
/// work runs off-main, one album at a time, cancellable between albums.
@MainActor
final class PerfectV2Driver: ObservableObject {
    @Published var running = false       // the analysis pipeline
    @Published var applying = false      // the decisions batch
    @Published var progress = ""
    @Published var lines: [String] = []          // session log
    @Published var cards: [AlbumCardModel] = []  // EVERY album — the library itself
    @Published var drmTracks: [String] = []      // protected rels — info only
    private var cancelled = false
    private var sessionID: String?
    private var loadedRoot: URL?

    enum AlbumState { case pending, analyzing, clean, needs }

    /// One track's pending name decision. The default flips with confidence:
    /// a high-score, non-variant proposal pre-selects Accept; a risky one Keep.
    struct TrackDecision: Identifiable {
        var proposal: TrackProposal
        var accept: Bool
        var id: String { proposal.relPath }
        var risky: Bool {
            proposal.score < 0.75
            || TrackProposal.nameVariant(proposal.curTitle, proposal.newTitle)
            || TrackProposal.nameVariant(proposal.curArtist, proposal.newArtist)
        }
    }

    /// A same-recording pair auto-dedup refused to decide (different albums —
    /// a legitimate-repeat candidate): a by-ear verdict on the A-side's card.
    struct EarPair: Identifiable, Sendable {
        let aRel: String, bRel: String
        let aInfo: String, bInfo: String
        let artist: String, title: String
        var id: String { aRel + "|" + bRel }
    }
    struct EarChoice: Identifiable {
        let pair: EarPair
        var verdict: Verdict
        enum Verdict { case keepA, keepB, keepBoth }
        var id: String { pair.id }
    }

    /// One album card — present from the moment the library loads, enriched by
    /// the pipeline as its album is analyzed.
    struct AlbumCardModel: Identifiable {
        let dir: URL
        var files: [URL]
        var state: AlbumState = .pending
        var facts = ""                                     // tracks · format · genre · year
        var thumb: Data? = nil                             // first embedded cover
        var trackList: [(no: String, title: String)] = []  // read-only tag view
        // decision payloads (present when state == .needs)
        var decisions: [TrackDecision] = []
        var albumSuggestion: AlbumFix? = nil               // speculative album-name guess (6a)
        var acceptAlbum = false                            // a guess defaults to NOT accepted
        var earChoices: [EarChoice] = []
        var chosenCover: Data? = nil                       // queued cover pick — applies with the batch
        // artwork: rels + which have art (set after analyze; the chooser is
        // available on every analyzed card — replace is backed up + undoable)
        var art: AlbumArtContext? = nil
        var id: String { dir.path }
        var artist: String { dir.deletingLastPathComponent().lastPathComponent }
        var album: String { dir.lastPathComponent }
        var missingArtRels: [String] {
            guard let art else { return [] }
            return art.rels.filter { art.relArt[$0] == nil }
        }
        var hasPendingDecisions: Bool {
            !decisions.isEmpty || albumSuggestion != nil || !earChoices.isEmpty || chosenCover != nil
        }
    }

    func cancel() { cancelled = true }

    // MARK: library loading — the carousel fills the moment a library is chosen

    func loadLibrary(_ root: URL) {
        guard loadedRoot != root || cards.isEmpty else { return }
        loadedRoot = root
        PerfectStore.rememberRoot(root)
        Task {
            let built = await Task.detached { PerfectV2Driver.buildCards(root: root) }.value
            self.cards = built
            self.drmTracks = built.flatMap { $0.files.filter { $0.pathExtension.lowercased() == "m4p" } }
                .map { PerfectStore.rel($0, root) }
            loadThumbs()
        }
    }

    /// Load cover thumbnails for every card that lacks one — lazily, off-main,
    /// published as they arrive. Called after every card-list (re)build; already
    /// loaded thumbs are kept, so covers never blink out mid-session.
    private func loadThumbs() {
        let missing = cards.filter { $0.thumb == nil }
        guard !missing.isEmpty else { return }
        Task.detached { [weak self] in
            for card in missing {
                guard let first = card.files.first else { continue }
                var len: Int32 = 0, ty: Int32 = 0
                guard let b = md_copy_artwork(first.path, &len, &ty) else { continue }
                let d = Data(bytes: b, count: Int(len)); free(b)
                await MainActor.run { [weak self] in
                    guard let self, let i = self.cards.firstIndex(where: { $0.id == card.id }) else { return }
                    if self.cards[i].thumb == nil { self.cards[i].thumb = d }
                }
            }
        }
    }

    /// Facts + track table from the local scan — no network, instant.
    nonisolated static func buildCards(root: URL) -> [AlbumCardModel] {
        let inputs = PerfectStore.organiseInputsFromDisk(root: root, fm: .default)
        var byDir: [String: [OrganiseInput]] = [:]
        for t in inputs { byDir[(t.rel as NSString).deletingLastPathComponent, default: []].append(t) }
        return byDir.keys.sorted().map { dirRel in
            let ts = byDir[dirRel]!.sorted { ($0.discNo, $0.trackNo, $0.rel) < ($1.discNo, $1.trackNo, $1.rel) }
            let dir = root.appendingPathComponent(dirRel)
            var card = AlbumCardModel(dir: dir, files: ts.map { root.appendingPathComponent($0.rel) })
            let exts = Set(ts.map { $0.ext }).sorted().joined(separator: "/")
            var bits = ["\(ts.count) track\(ts.count == 1 ? "" : "s")", exts]
            if let first = card.files.first {
                if let g = PerfectStore.readField(first, "genre"), !g.isEmpty {
                    bits.append(Organiser.displayGenre(g).lowercased())
                }
                if let d = PerfectStore.readField(first, "date"), d.count >= 4 { bits.append(String(d.prefix(4))) }
            }
            card.facts = bits.joined(separator: " · ")
            card.trackList = ts.map { t in
                let no = t.discNo > 1 ? "\(t.discNo)-\(Organiser.pad2(t.trackNo))"
                        : (t.trackNo > 0 ? Organiser.pad2(t.trackNo) : "–")
                return (no, t.title.isEmpty ? Organiser.titleFromFilename(t.rel) : t.title)
            }
            return card
        }
    }

    // MARK: the run — a visible pipeline over the loaded cards

    func run(root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true; cancelled = false; lines = []
        let thoroughness = store.thoroughness
        let reconcileOnline = store.checkMissingTracks
        let session = UUID().uuidString
        sessionID = session
        defer { running = false; progress = ""; store.loadRuns() }

        // ---- Phase 1: normalize (merges may fuse folders — the strip refreshes)
        progress = "Phase 1 — normalizing folders"
        let scanned = await Task.detached { PerfectStore.scanForNormalize(root: root) }.value
        let choices = Normalizer.ChoicesStore.load(root.path)
        let confirmedComps = Normalizer.compilationCandidates(scanned.tracks)
            .filter { !choices.declinedCompilations.contains($0.key) }
            .reduce(into: Set<String>()) { $0.formUnion($1.foldKeys) }
        var p1Declined = Set(choices.declinedMerges)
        if !thoroughness.doesMerges {
            p1Declined.formUnion(Organiser.albumMergeCandidates(scanned.tracks).map { $0.key })
        }
        let p1 = Normalizer.plan(scanned, canonicalArtistOverrides: choices.artistOverrides,
                                 declinedMerges: p1Declined,
                                 confirmedCompilations: confirmedComps)
        if !p1.isEmpty {
            await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — Phase 1 normalize",
                                                 tagWrites: p1.tagWrites, moves: p1.moves,
                                                 sessionID: session)
            lines.append("Phase 1: \(p1.tagWrites.count) tag write(s), \(p1.moves.count) move(s)")
            // the tree changed — rebuild the strip from the normalized library,
            // KEEPING the thumbnails already loaded (same folder = same cover)
            let oldThumbs = Dictionary(cards.compactMap { c in c.thumb.map { (c.id, $0) } },
                                       uniquingKeysWith: { a, _ in a })
            var rebuilt = await Task.detached { PerfectV2Driver.buildCards(root: root) }.value
            for i in rebuilt.indices { rebuilt[i].thumb = oldThumbs[rebuilt[i].id] }
            cards = rebuilt
            drmTracks = rebuilt.flatMap { $0.files.filter { $0.pathExtension.lowercased() == "m4p" } }
                .map { PerfectStore.rel($0, root) }
            loadThumbs()
        } else {
            lines.append("Phase 1: nothing to normalize")
            for i in cards.indices { cards[i].state = .pending }
        }
        guard !cancelled else { lines.append("Cancelled — applied runs stay undoable from Runs"); return }

        // ---- the per-album loop, live on the strip
        var applied = 0, clean = 0
        var idx = 0
        while idx < cards.count {
            if cancelled { break }
            let card = cards[idx]
            idx += 1
            guard card.state == .pending else { continue }
            setState(card.id, .analyzing)
            progress = "Album \(idx) of \(cards.count) — \(card.album)"
            let cached = AlbumReconcileStore.load(card.dir.path)
            let (fixes, art, reconcile) = await AlbumPerfect.analyze(root: root, files: card.files,
                                                                     reconciledMatch: cached,
                                                                     reconcileOnline: reconcileOnline)
            if let r = reconcile { AlbumReconcileStore.save(card.dir.path, r) }

            var tierFixes = fixes
            let kept = KeptNamesStore.load(card.dir.path)
            var decisions: [TrackDecision] = []
            if let i = tierFixes.firstIndex(where: { $0.kind == .identify && $0.applyable }) {
                var f = tierFixes[i]
                // KEPT proposals never re-queue and never auto-apply
                let dropRels = Set(f.proposals.filter { kept.contains(KeptNamesStore.pairKey($0)) }.map { $0.relPath })
                if !dropRels.isEmpty {
                    f.proposals.removeAll { dropRels.contains($0.relPath) }
                    f.tagWrites.removeAll { dropRels.contains($0.rel) && ($0.field == "title" || $0.field == "artist") }
                    tierFixes[i] = f
                }
                let needing = f.proposals.filter {
                    $0.dominantNameKind == .substantive
                    || TrackProposal.nameVariant($0.curTitle, $0.newTitle)
                    || TrackProposal.nameVariant($0.curArtist, $0.newArtist)
                }
                decisions = needing.map { p in
                    var d = TrackDecision(proposal: p, accept: false)
                    d.accept = !d.risky
                    return d
                }
            }
            let suggestion = tierFixes.first { f in
                guard f.speculative, f.applyable, let v = f.tagWrites.first?.value else { return false }
                return !kept.contains("album>" + Organiser.fold(v))
            }

            if !decisions.isEmpty || suggestion != nil {
                update(card.id) { c in
                    c.decisions = decisions; c.albumSuggestion = suggestion
                    c.art = art; c.state = .needs
                }
                continue   // deferred whole — dependent fixes wait for the verdicts
            }
            let didApply = await applyTierOne(tierFixes, root: root, session: session,
                                              name: card.album, doesRenames: thoroughness.doesRenames)
            if didApply { applied += 1 } else { clean += 1 }
            update(card.id) { c in
                c.art = art
                c.state = c.missingArtRels.isEmpty ? .clean : .needs   // cover gaps are decisions too
            }
        }

        // ---- final pass on the corrected tags + the cross-album dedup sweep
        if !cancelled {
            progress = "Final pass — organising on corrected tags"
            let rescan = await Task.detached { PerfectStore.scanForNormalize(root: root) }.value
            var p2Declined = Set(choices.declinedMerges)
            if !thoroughness.doesMerges {
                p2Declined.formUnion(Organiser.albumMergeCandidates(rescan.tracks).map { $0.key })
            }
            let p2 = Normalizer.plan(rescan, canonicalArtistOverrides: choices.artistOverrides,
                                     declinedMerges: p2Declined,
                                     confirmedCompilations: confirmedComps)
            if !p2.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — final organise",
                                                     tagWrites: p2.tagWrites, moves: p2.moves,
                                                     sessionID: session)
                lines.append("Final pass: \(p2.tagWrites.count) tag write(s), \(p2.moves.count) move(s)")
            }
            progress = "Final pass — removing cross-folder duplicates"
            let dd = await Task.detached { await PerfectV2Driver.libraryDedup(root: root) }.value
            if !dd.moves.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — duplicate removal",
                                                     tagWrites: dd.writes, moves: dd.moves,
                                                     artEmbeds: dd.embeds, sessionID: session)
                lines.append("Duplicates: \(dd.moves.count) removed across folders (best copies kept)")
            }
            // by-ear pairs land on their A-side album's card
            let earKept = KeptNamesStore.load(root.path + "#ear")
            for pair in dd.earPairs where !earKept.contains("ear>" + pair.id) {
                let dirPath = root.appendingPathComponent((pair.aRel as NSString).deletingLastPathComponent).path
                update(dirPath) { c in
                    c.earChoices.append(EarChoice(pair: pair, verdict: .keepBoth))
                    c.state = .needs
                }
            }
        } else {
            lines.append("Cancelled — applied runs stay undoable from Runs")
        }
        let needs = cards.filter { $0.state == .needs }.count
        lines.append("Albums: \(applied) fixed · \(clean) clean · \(needs) with decisions")
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }

    private func setState(_ id: String, _ s: AlbumState) { update(id) { $0.state = s } }
    private func update(_ id: String, _ mutate: (inout AlbumCardModel) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        mutate(&cards[i])
    }

    /// Apply an album's Tier-1 fix set (one reversible run): enabled defaults
    /// honored, compilation flagging excluded (Phase-1 checklist), dependent
    /// renames dropped when the disc fix isn't applied.
    private func applyTierOne(_ fixes: [AlbumFix], root: URL, session: String, name: String,
                              doesRenames: Bool = true) async -> Bool {
        let discOn = fixes.contains { $0.kind == .discOrder && $0.applyable && $0.enabled }
        let chosen = fixes.filter { f in
            f.applyable && f.enabled
            && f.kind != .compilation
            && (doesRenames || f.kind != .filename)
            && !(f.needsDiscOrder && !discOn)
        }
        guard !chosen.isEmpty else { return false }
        await PerfectStore.performLibraryOps(
            root: root, summary: "Perfect v2 — \(name)",
            tagWrites: chosen.flatMap { $0.tagWrites },
            moves: chosen.flatMap { $0.moves },
            artEmbeds: chosen.flatMap { $0.artEmbeds },
            performerAdds: chosen.flatMap { $0.performerAdds },
            sessionID: session)
        return true
    }

    // MARK: batch apply — decisions accumulated across cards

    func applyDecisions(root: URL, store: PerfectStore) async {
        let queue = cards.filter { $0.hasPendingDecisions }
        guard !running, !applying, !queue.isEmpty else { return }
        applying = true
        defer { applying = false; progress = ""; store.loadRuns() }
        let session = sessionID ?? UUID().uuidString
        sessionID = session
        let doesRenames = store.thoroughness.doesRenames
        for (n, card) in queue.enumerated() {
            progress = "Applying decisions — album \(n + 1) of \(queue.count): \(card.album)"
            var writes: [(rel: String, field: String, value: String)] = []
            var keptKeys: [String] = []
            for t in card.decisions {
                let p = t.proposal
                if t.accept {
                    if !p.newTitle.isEmpty, p.newTitle != p.curTitle { writes.append((p.relPath, "title", p.newTitle)) }
                    if !p.newArtist.isEmpty, p.newArtist != p.curArtist { writes.append((p.relPath, "artist", p.newArtist)) }
                } else {
                    keptKeys.append(KeptNamesStore.pairKey(p))
                }
            }
            if let s = card.albumSuggestion {
                if card.acceptAlbum { writes.append(contentsOf: s.tagWrites) }
                else if let v = s.tagWrites.first?.value { keptKeys.append("album>" + Organiser.fold(v)) }
            }
            if !keptKeys.isEmpty { KeptNamesStore.add(card.dir.path, keptKeys) }
            if !writes.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — names for \(card.album)",
                                                     tagWrites: writes, moves: [], sessionID: session)
            }
            if !card.decisions.isEmpty || card.albumSuggestion != nil {
                // dependent fixes from the settled tags — identify pinned off: the
                // verdict is ground truth, a fresh pass could flip and leak
                let cached = AlbumReconcileStore.load(card.dir.path)
                let (fixes, art, reconcile) = await AlbumPerfect.analyze(root: root, files: card.files,
                                                                         reconciledMatch: cached,
                                                                         runIdentify: false)
                if let r = reconcile { AlbumReconcileStore.save(card.dir.path, r) }
                _ = await applyTierOne(fixes, root: root, session: session, name: card.album,
                                       doesRenames: doesRenames)
                update(card.id) { $0.art = art }
            }
            // by-ear verdicts: keep-A/keep-B quarantine the loser; keep-both persists
            var quarantines: [(from: String, to: String)] = []
            var keptEar: [String] = []
            for c in card.earChoices {
                switch c.verdict {
                case .keepA: quarantines.append((c.pair.bRel, ""))
                case .keepB: quarantines.append((c.pair.aRel, ""))
                case .keepBoth: keptEar.append("ear>" + c.pair.id)
                }
            }
            if !keptEar.isEmpty { KeptNamesStore.add(root.path + "#ear", keptEar) }
            if !quarantines.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — duplicate decisions (\(card.album))",
                                                     tagWrites: [], moves: quarantines, sessionID: session)
            }
            // queued cover pick — fills gaps, or replaces (backed up) on covered albums
            if let img = card.chosenCover, let art = cards.first(where: { $0.id == card.id })?.art ?? card.art {
                let mime = img.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                let fm = FileManager.default
                let captured = card.missingArtRels.isEmpty ? art.rels : card.missingArtRels
                var targets: [String] = []
                var lost = 0
                for rel in captured {
                    if fm.fileExists(atPath: root.appendingPathComponent(rel).path) { targets.append(rel); continue }
                    let candidate = card.dir.appendingPathComponent((rel as NSString).lastPathComponent)
                    if fm.fileExists(atPath: candidate.path) { targets.append(PerfectStore.rel(candidate, root)) }
                    else { lost += 1 }
                }
                if lost > 0 { lines.append("Cover: \(lost) track(s) moved since the scan — run again to pick them up") }
                if !targets.isEmpty {
                    await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — cover for \(card.album)",
                                                         tagWrites: [], moves: [],
                                                         artEmbeds: targets.map { ($0, img, mime) },
                                                         sessionID: session)
                    update(card.id) { c in
                        c.thumb = img
                        if var a = c.art {
                            for rel in targets { a.relArt[rel] = (0, img.count) }
                            c.art = a
                        }
                    }
                    lines.append("Cover set on \(targets.count) track\(targets.count == 1 ? "" : "s") — \(card.album)")
                }
            }
            update(card.id) { c in
                c.decisions = []; c.albumSuggestion = nil; c.earChoices = []; c.chosenCover = nil
                c.state = c.missingArtRels.isEmpty ? .clean : .needs
            }
            lines.append("Decisions applied — \(card.artist) — \(card.album)")
        }
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }


    // MARK: cross-album dedup sweep

    nonisolated static func libraryDedup(root: URL) async
        -> (writes: [(rel: String, field: String, value: String)],
            embeds: [(rel: String, image: Data, mime: String)],
            moves: [(from: String, to: String)],
            earPairs: [EarPair]) {
        var tracks = await PerfectStore.buildTracksFromDisk(root: root, fm: .default)
        let clusters = buildClusters(&tracks, mode: .balanced, tol: 2.0, crossAlbum: false)
        var writes: [(rel: String, field: String, value: String)] = []
        var embeds: [(rel: String, image: Data, mime: String)] = []
        var moves: [(from: String, to: String)] = []
        var earPairs: [EarPair] = []
        let backfill = ["title", "artist", "album", "albumartist", "composer",
                        "lyricist", "label", "conductor", "date", "genre", "track", "disc"]
        for c in clusters where c.memberIDs.count > 1 {
            // Legitimate repeat appearances are NEVER auto-removed (plan §E) —
            // they become by-ear verdicts. Only same-album clusters are stray copies.
            let albums = Set(c.memberIDs.map { Organiser.canonicalAlbumKey(tracks[$0].album) })
            guard albums.count == 1 else {
                let k = tracks[c.keeperID]
                func info(_ t: Track) -> String {
                    let alb = t.album.isEmpty ? t.url.deletingLastPathComponent().lastPathComponent : t.album
                    return "\(fmtDur(t.duration)) · \(t.bitrate > 0 ? "\(t.bitrate) kbps" : t.ext) · \(alb)"
                }
                for id in c.memberIDs where id != c.keeperID {
                    let o = tracks[id]
                    earPairs.append(EarPair(aRel: PerfectStore.rel(k.url, root),
                                            bRel: PerfectStore.rel(o.url, root),
                                            aInfo: info(k), bInfo: info(o),
                                            artist: k.displayArtist, title: k.title))
                }
                continue
            }
            let keeper = tracks[c.keeperID]
            let keeperRel = PerfectStore.rel(keeper.url, root)
            for field in backfill where (PerfectStore.readField(keeper.url, field) ?? "").isEmpty {
                for id in c.memberIDs where id != c.keeperID {
                    let v = PerfectStore.readField(tracks[id].url, field) ?? ""
                    if !v.isEmpty { writes.append((keeperRel, field, v)); break }
                }
            }
            if md_has_artwork(keeper.url.path) == 0 {
                for id in c.memberIDs where id != c.keeperID {
                    var len: Int32 = 0, ty: Int32 = 0
                    if let b = md_copy_artwork(tracks[id].url.path, &len, &ty) {
                        let d = Data(bytes: b, count: Int(len)); free(b)
                        embeds.append((keeperRel, d,
                                       d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"))
                        break
                    }
                }
            }
            for id in c.memberIDs where id != c.keeperID {
                moves.append((PerfectStore.rel(tracks[id].url, root), ""))
            }
        }
        return (writes, embeds, moves, earPairs)
    }
}

// MARK: - Kept names (per-album "don't ask again")

/// Proposals the user KEPT: remembered per album folder so an identical
/// suggestion never re-queues (and never auto-applies) on later runs.
enum KeptNamesStore {
    private static func hash(_ s: String) -> String {
        var h: UInt64 = 5381; for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }; return String(h, radix: 16)
    }
    private static func file(_ folderPath: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Music Librarian/kept-names", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(hash(folderPath)).json")
    }
    /// The change a proposal describes, folded — stable across runs and cosmetic drift.
    static func pairKey(_ p: TrackProposal) -> String {
        TrackProposal.hardFold(p.curTitle) + ">" + TrackProposal.hardFold(p.newTitle)
        + "|" + TrackProposal.hardFold(p.curArtist) + ">" + TrackProposal.hardFold(p.newArtist)
    }
    static func load(_ folderPath: String) -> Set<String> {
        guard let u = file(folderPath), let d = try? Data(contentsOf: u),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }
    static func add(_ folderPath: String, _ keys: [String]) {
        guard let u = file(folderPath) else { return }
        let merged = load(folderPath).union(keys)
        if let d = try? JSONEncoder().encode(Array(merged).sorted()) { try? d.write(to: u) }
    }
}

// MARK: - The window

/// The library-first carousel: every album is a card the moment a library is
/// chosen; Run analyzes them live in place; decisions accumulate and batch-apply.
struct PerfectV2View: View {
    @EnvironmentObject private var perfect: PerfectStore
    @StateObject private var driver = PerfectV2Driver()
    @State private var confirmRevert = false
    @State private var cardIndex = 0
    @State private var keyMonitor: Any?
    @State private var needsOnly = false
    @State private var root: URL? = UserDefaults.standard.string(forKey: "libraryBrowserRoot")
        .map { URL(fileURLWithPath: $0) }

    private var visibleIndices: [Int] {
        needsOnly ? driver.cards.indices.filter { driver.cards[$0].state == .needs }
                  : Array(driver.cards.indices)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusline
            if driver.cards.isEmpty {
                Text("Choose a library — every album appears here immediately; Run analyzes them in place.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                carousel
                filmstrip
                Divider()
                bottomLists
            }
        }
        .safeAreaInset(edge: .bottom) { applyBar }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            if let root { driver.loadLibrary(root) }
            // window-level arrow keys: keyboardShortcut on the chevrons dies the
            // moment a card control takes focus, so navigation stopped after one
            // album — a local monitor survives focus changes. Text fields keep
            // their arrows (cover-search typing must not navigate).
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.window?.title == "Perfect v2",
                      !(NSApp.keyWindow?.firstResponder is NSTextView) else { return e }
                let last = max(visibleIndices.count - 1, 0)
                if e.keyCode == 123 { cardIndex = max(min(cardIndex, last) - 1, 0); return nil }
                if e.keyCode == 124 { cardIndex = min(min(cardIndex, last) + 1, last); return nil }
                return e
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Perfect v2").font(.headline)
            if let root { Text(root.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Picker("", selection: $needsOnly) {
                Text("All · \(driver.cards.count)").tag(false)
                Text("Needs decisions · \(driver.cards.filter { $0.state == .needs }.count)").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            .onChange(of: needsOnly) { _ in cardIndex = 0 }
            Button("Choose Library…") { choose() }.disabled(driver.running || driver.applying)
            if driver.running {
                Button("Cancel") { driver.cancel() }
            } else {
                Button("Run") { if let root { Task { await driver.run(root: root, store: perfect) } } }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(root == nil || driver.cards.isEmpty || driver.applying)
            }
        }
        .padding(10)
    }

    @ViewBuilder private var statusline: some View {
        if driver.running || driver.applying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(driver.progress).font(.caption).foregroundStyle(.purple)
                Text("· decide finished albums while this runs").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            Divider()
        }
    }

    private var carousel: some View {
        let ids = visibleIndices
        let pos = min(cardIndex, max(ids.count - 1, 0))
        return HStack(spacing: 0) {
            Button { cardIndex = max(pos - 1, 0) } label: { Image(systemName: "chevron.left").font(.title2) }
                .buttonStyle(.plain).padding(.horizontal, 8)
                .disabled(pos == 0)
            if !ids.isEmpty, pos < ids.count {
                ScrollView {
                    AlbumCardView(card: cardBinding(ids[pos]),
                                  position: (pos + 1, ids.count),
                                  driver: driver, root: root, store: perfect)
                        .padding(.bottom, 8)
                }
                .id(driver.cards[ids[pos]].id)
                .frame(maxWidth: .infinity)
            } else {
                Text(needsOnly ? "No albums need decisions." : "")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            Button { cardIndex = min(pos + 1, ids.count - 1) } label: { Image(systemName: "chevron.right").font(.title2) }
                .buttonStyle(.plain).padding(.horizontal, 8)
                .disabled(pos >= ids.count - 1)
        }
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity)
    }

    private var filmstrip: some View {
        let ids = visibleIndices
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(ids.enumerated()), id: \.element) { pos, i in
                        let c = driver.cards[i]
                        VStack(spacing: 2) {
                            ZStack(alignment: .topTrailing) {
                                frameImage(c)
                                    .frame(width: 46, height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(frameBorder(c, current: pos == min(cardIndex, max(ids.count - 1, 0))),
                                                      lineWidth: pos == min(cardIndex, max(ids.count - 1, 0)) ? 2 : 1))
                                    .opacity(c.state == .pending ? 0.45 : 1)
                                frameBadges(c)
                            }
                            Text(c.album).font(.system(size: 9)).lineLimit(1).frame(width: 52)
                                .foregroundStyle(.secondary)
                        }
                        .id(c.id)
                        .contentShape(Rectangle())
                        .onTapGesture { cardIndex = pos }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .frame(height: 76)
            // the strip FOLLOWS the selection: navigating past the visible frames
            // scrolls the next set into view instead of losing the highlight
            .onChange(of: cardIndex) { _ in
                let ids = visibleIndices
                let pos = min(cardIndex, max(ids.count - 1, 0))
                if pos < ids.count {
                    withAnimation { proxy.scrollTo(driver.cards[ids[pos]].id, anchor: .center) }
                }
            }
        }
    }

    private func frameBorder(_ c: PerfectV2Driver.AlbumCardModel, current: Bool) -> Color {
        if current { return .purple }
        if c.state == .analyzing { return .purple.opacity(0.7) }
        return .secondary.opacity(0.3)
    }

    @ViewBuilder private func frameImage(_ c: PerfectV2Driver.AlbumCardModel) -> some View {
        if let data = c.thumb, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func frameBadges(_ c: PerfectV2Driver.AlbumCardModel) -> some View {
        HStack(spacing: 2) {
            switch c.state {
            case .clean: badge("✓", .teal)
            case .analyzing: badge("…", .purple)
            case .needs:
                if !c.decisions.isEmpty || c.albumSuggestion != nil { badge("N", .orange) }
                if !c.earChoices.isEmpty { badge("2×", .orange) }
                if !c.missingArtRels.isEmpty { badge("C", .purple) }
            case .pending: EmptyView()
            }
        }
        .offset(x: 4, y: -4)
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(c))
    }

    private var bottomLists: some View {
        List {
            if !driver.lines.isEmpty {
                Section("Session") { ForEach(driver.lines, id: \.self) { Text($0).font(.caption) } }
            }
            if !driver.drmTracks.isEmpty {
                Section("Protected (DRM) — listed only, never touched") {
                    HStack {
                        Text("\(driver.drmTracks.count) FairPlay track(s) — can't be played by most servers, fingerprinted or re-tagged. Re-acquire via Apple purchase history / Apple Music / CD.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Export CSV…") { exportDRMList() }.controlSize(.small)
                    }
                }
            }
        }
        .frame(maxHeight: 120)
    }

    @ViewBuilder private var applyBar: some View {
        let pending = driver.cards.filter { $0.hasPendingDecisions }
        if !pending.isEmpty || !driver.lines.isEmpty {
            HStack(spacing: 10) {
                if !pending.isEmpty {
                    let accepts = pending.reduce(0) { $0 + $1.decisions.filter(\.accept).count
                        + $1.earChoices.filter { $0.verdict != .keepBoth }.count
                        + ($1.albumSuggestion != nil && $1.acceptAlbum ? 1 : 0)
                        + ($1.chosenCover != nil ? 1 : 0) }
                    Text("\(pending.count) album\(pending.count == 1 ? "" : "s") · \(accepts) change\(accepts == 1 ? "" : "s") accepted")
                        .fontWeight(.medium)
                }
                Text(driver.running ? "decide freely — Apply unlocks when the run finishes"
                                    : "nothing is written until you apply · every run undoable from Runs")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert library…", role: .destructive) { confirmRevert = true }
                    .disabled(driver.running || driver.applying || perfect.busy || root == nil)
                    .confirmationDialog("Revert this library to before Perfect ran?",
                                        isPresented: $confirmRevert, titleVisibility: .visible) {
                        Button("Revert everything", role: .destructive) {
                            if let root { perfect.undoLibrary(root) }
                        }
                    } message: {
                        Text("Every recorded run for this library is undone, newest first. Files and tags return to their pre-run state.")
                    }
                if !pending.isEmpty {
                    Button("Apply all decisions") {
                        if let root { Task { await driver.applyDecisions(root: root, store: perfect) } }
                    }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(driver.running || driver.applying || root == nil)
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    private func cardBinding(_ i: Int) -> Binding<PerfectV2Driver.AlbumCardModel> {
        let id = driver.cards[i].id
        return Binding(
            get: { driver.cards.first(where: { $0.id == id }) ?? driver.cards[min(i, driver.cards.count - 1)] },
            set: { v in if let j = driver.cards.firstIndex(where: { $0.id == id }) { driver.cards[j] = v } }
        )
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Use Library"
        if panel.runModal() == .OK, let u = panel.url {
            root = u
            driver.loadLibrary(u)
            cardIndex = 0
        }
    }

    /// The DRM manifest: one row per protected track, openable in Numbers/Excel.
    private func exportDRMList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "protected-tracks.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "artist,album,file\n"
        for rel in driver.drmTracks {
            let parts = rel.split(separator: "/").map(String.init)
            let artist = parts.count >= 3 ? parts[parts.count - 3] : ""
            let album = parts.count >= 2 ? parts[parts.count - 2] : ""
            let esc = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            csv += "\(esc(artist)),\(esc(album)),\(esc(parts.last ?? rel))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - One album card

/// One album, everything it needs in one place: big cover (a chooser pick
/// previews onto it instantly), artist-first title, state chips, the track
/// table, then blocks for names, this album's duplicate calls, and the cover
/// chooser (offered on every analyzed album — replacing is backed up, undoable).
struct AlbumCardView: View {
    @Binding var card: PerfectV2Driver.AlbumCardModel
    let position: (Int, Int)
    @ObservedObject var driver: PerfectV2Driver
    let root: URL?
    let store: PerfectStore
    @State private var previewCover: Data?
    @State private var online: [Data] = []
    @State private var searching = false
    @State private var searched = false
    @State private var selectedCover: Data?
    @State private var queryArtist = ""
    @State private var queryAlbum = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                bigCover
                VStack(alignment: .leading, spacing: 4) {
                    (Text(card.artist).foregroundColor(.purple).fontWeight(.semibold)
                     + Text(" — \(card.album)").fontWeight(.semibold))
                        .font(.title3)
                    Text(card.facts).font(.caption).foregroundStyle(.secondary)
                    stateChips
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Album \(position.0) of \(position.1)").font(.caption).foregroundStyle(.secondary)
                    Text("← → keys").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if card.state == .needs || card.state == .clean {
                block(coverTitle) { coverBlock }
            }
            if !card.decisions.isEmpty || card.albumSuggestion != nil {
                block("Names") { namesBlock }
            }
            if !card.earChoices.isEmpty {
                block("Duplicates — the same recording elsewhere") { earBlock }
            }
            DisclosureGroup {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(Array(card.trackList.enumerated()), id: \.offset) { _, t in
                        GridRow {
                            Text(t.no).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            Text(t.title).font(.caption)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("TRACKS & TAGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
    }

    private var bigCover: some View {
        ZStack {
            if let data = previewCover ?? card.chosenCover ?? card.thumb, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.1))
                Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 116, height: 116)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var stateChips: some View {
        HStack(spacing: 6) {
            switch card.state {
            case .pending: chip("not yet analyzed", .secondary)
            case .analyzing: chip("analyzing…", .purple)
            case .clean: chip("✓ clean", .teal)
            case .needs:
                if !card.decisions.isEmpty { chip("\(card.decisions.count) name\(card.decisions.count == 1 ? "" : "s")", .orange) }
                if card.albumSuggestion != nil { chip("album name?", .orange) }
                if !card.earChoices.isEmpty { chip("\(card.earChoices.count) repeat\(card.earChoices.count == 1 ? "" : "s")", .orange) }
                if !card.missingArtRels.isEmpty { chip("cover", .purple) }
            }
        }
    }

    private func chip(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.15)))
            .foregroundStyle(c)
    }

    @ViewBuilder private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
    }

    // ---- names ----

    @ViewBuilder private var namesBlock: some View {
        if card.decisions.count > 1 {
            HStack {
                Spacer()
                Button("Accept all") { setAll(true) }.controlSize(.small).disabled(driver.applying)
                Button("Keep all") { setAll(false) }.controlSize(.small).disabled(driver.applying)
            }
        }
        ForEach($card.decisions) { $d in
            TrackDecisionRow(decision: $d, busy: driver.applying)
        }
        if let s = card.albumSuggestion {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                Text(s.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Picker("", selection: $card.acceptAlbum) {
                    Text("Accept").tag(true)
                    Text("Keep blank").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .disabled(driver.applying)
            }
        }
    }

    private func setAll(_ accept: Bool) {
        for i in card.decisions.indices { card.decisions[i].accept = accept }
    }

    // ---- duplicates ----

    private var earBlock: some View {
        ForEach($card.earChoices) { $c in
            EarChoiceRow(choice: $c, rootURL: root, busy: driver.applying)
        }
    }

    // ---- cover ----

    private var coverTitle: String {
        guard let art = card.art else { return "Cover" }
        if card.missingArtRels.isEmpty { return "Cover — current shown; replace if you prefer (backed up, undoable)" }
        if card.missingArtRels.count == art.rels.count { return "Cover — none on any track (tap to preview)" }
        return "Cover — \(card.missingArtRels.count) of \(art.rels.count) track(s) without art"
    }

    @ViewBuilder private var coverBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let own = card.thumb {
                        CoverThumb(data: own, selected: selectedCover == own, badge: "current")
                            .onTapGesture { selectedCover = own; previewCover = own }
                    }
                    ForEach(Array(online.enumerated()), id: \.offset) { _, data in
                        CoverThumb(data: data, selected: selectedCover == data, badge: "online")
                            .onTapGesture { selectedCover = data; previewCover = data }
                    }
                    if !searched {
                        Button {
                            search()
                        } label: {
                            if searching { ProgressView().controlSize(.small) }
                            else { Label("Find covers online", systemImage: "magnifyingglass") }
                        }
                        .controlSize(.small).disabled(searching)
                    } else if online.isEmpty {
                        Text("nothing found — edit the search below").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if let sel = selectedCover, sel != card.thumb {
                if card.chosenCover == sel {
                    Label("Queued — applies with decisions", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.teal)
                } else {
                    Button("Use this cover") { card.chosenCover = sel }
                        .buttonStyle(.borderedProminent).tint(.teal)
                        .controlSize(.small).disabled(driver.applying)
                }
            }
        }
        if searched {
            HStack(spacing: 6) {
                TextField("Artist", text: $queryArtist).textFieldStyle(.roundedBorder)
                    .font(.caption).frame(width: 160)
                TextField("Album", text: $queryAlbum).textFieldStyle(.roundedBorder)
                    .font(.caption).frame(width: 220)
                Button {
                    search()
                } label: {
                    if searching { ProgressView().controlSize(.small) } else { Text("Search again") }
                }
                .controlSize(.small).disabled(searching)
                Text("edit the search if the match misses").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func search() {
        if queryArtist.isEmpty && queryAlbum.isEmpty {
            // never search on "Various Artists" — the dead end that hid The Specials
            let a = card.art?.artist ?? card.artist
            queryArtist = Organiser.artistKey(a) == "variousartists" ? "" : a
            let al = card.art?.album ?? ""
            queryAlbum = al.isEmpty ? card.album : al
        }
        searching = true
        let a = queryArtist, al = queryAlbum
        Task {
            let found = await CoverArtClient().candidates(releaseMBIDs: [], artist: a, album: al)
            await MainActor.run { online = found; searching = false; searched = true }
        }
    }
}

// MARK: - Track decision row

/// One track's A/B verdict row: old name struck through → proposed name, a
/// change-kind chip, the AcoustID score (amber when risky), ▶A/▶B audition
/// buttons, and the Accept/Keep segmented verdict.
struct TrackDecisionRow: View {
    @Binding var decision: PerfectV2Driver.TrackDecision
    let busy: Bool
    @ObservedObject private var audio = AudioPreview.shared
    @State private var previewURL: URL?
    @State private var previewLoading = false
    @State private var previewMissing = false

    private var p: TrackProposal { decision.proposal }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if !p.newTitle.isEmpty, p.newTitle != p.curTitle {
                    changeLine(from: p.curTitle.isEmpty ? p.url.lastPathComponent : p.curTitle, to: p.newTitle)
                }
                if !p.newArtist.isEmpty, p.newArtist != p.curArtist {
                    changeLine(from: "artist: \(p.curArtist.isEmpty ? "—" : p.curArtist)", to: p.newArtist)
                }
            }
            Text(kindLabel)
                .font(.system(size: 9, weight: .semibold)).textCase(.uppercase)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(decision.risky ? Color.orange.opacity(0.18) : Color.purple.opacity(0.14)))
                .foregroundStyle(decision.risky ? Color.orange : Color.purple)
            Text(String(format: "%.2f", p.score))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(decision.risky ? Color.orange : Color.secondary)
            Button { audio.toggle(p.url) } label: {
                Image(systemName: audio.playingURL == p.url ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(audio.playingURL == p.url ? Color.red : Color.teal)
            }
            .buttonStyle(.plain).help("Play your file")
            Button { playProposed() } label: {
                if previewLoading { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16) }
                else {
                    Image(systemName: previewMissing ? "waveform.slash"
                          : (previewURL != nil && audio.playingURL == previewURL ? "stop.circle.fill" : "waveform.circle"))
                        .foregroundStyle(previewMissing ? Color.secondary
                                         : (previewURL != nil && audio.playingURL == previewURL ? Color.red : Color.purple))
                }
            }
            .buttonStyle(.plain).disabled(previewLoading || previewMissing)
            .help(previewMissing ? "No online preview found for the proposed match" : "Hear the proposed match")
            Spacer()
            Picker("", selection: $decision.accept) {
                Text("Accept").tag(true)
                Text("Keep").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            .disabled(busy)
        }
        .padding(.leading, 8)
    }

    private var kindLabel: String {
        if TrackProposal.nameVariant(p.curTitle, p.newTitle)
            || TrackProposal.nameVariant(p.curArtist, p.newArtist) { return "variant" }
        return p.score < 0.75 ? "low confidence" : "retitle"
    }

    private func changeLine(from: String, to: String) -> some View {
        (Text(from).strikethrough().foregroundColor(.secondary)
         + Text("  →  ").foregroundColor(.secondary)
         + Text(to).fontWeight(.semibold))
            .font(.callout)
            .lineLimit(1)
    }

    private func playProposed() {
        if let u = previewURL { audio.toggle(u); return }
        guard !previewLoading else { return }
        previewLoading = true
        let artist = p.newArtist.isEmpty ? p.curArtist : p.newArtist
        let title = p.newTitle.isEmpty ? p.curTitle : p.newTitle
        Task {
            let url = await CoverArtClient().trackPreview(artist: artist, title: title)
            await MainActor.run {
                previewLoading = false
                if let url { previewURL = url; audio.toggle(url) } else { previewMissing = true }
            }
        }
    }
}

// MARK: - By-ear duplicate row

/// One by-ear duplicate: the two copies with play buttons and vitals, and a
/// Keep A / Keep B / Keep both verdict. "Keep both" is the recommended default —
/// a track on its album AND a hits set is legitimate ownership.
struct EarChoiceRow: View {
    @Binding var choice: PerfectV2Driver.EarChoice
    let rootURL: URL?
    let busy: Bool
    @ObservedObject private var audio = AudioPreview.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(choice.pair.title).fontWeight(.medium)
                Spacer()
                Picker("", selection: $choice.verdict) {
                    Text("Keep A").tag(PerfectV2Driver.EarChoice.Verdict.keepA)
                    Text("Keep B").tag(PerfectV2Driver.EarChoice.Verdict.keepB)
                    Text("Keep both").tag(PerfectV2Driver.EarChoice.Verdict.keepBoth)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .disabled(busy)
            }
            copyLine(label: "A", rel: choice.pair.aRel, info: choice.pair.aInfo)
            copyLine(label: "B", rel: choice.pair.bRel, info: choice.pair.bInfo)
        }
    }

    private func copyLine(label: String, rel: String, info: String) -> some View {
        HStack(spacing: 8) {
            if let rootURL {
                let url = rootURL.appendingPathComponent(rel)
                Button { audio.toggle(url) } label: {
                    Image(systemName: audio.playingURL == url ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(audio.playingURL == url ? Color.red : Color.teal)
                }
                .buttonStyle(.plain).help("Play copy \(label)")
            }
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            Text(info).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(rel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, 8)
    }
}
