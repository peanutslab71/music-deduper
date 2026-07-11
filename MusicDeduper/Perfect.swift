//
//  Perfect.swift
//  MusicDeduper
//
//  "Perfect" — library restoration. Phase 1 (Tidy): scan a library, diagnose
//  fixable problems, review them, and commit the approved ones — removing
//  items to a recoverable quarantine and writing a before/after change log.
//
//  This first slice handles the unambiguous, locally-detectable classes:
//  junk files, empty folders, and DRM (protected) tracks. Duplicate-folder
//  merges, illegal-character renames, duplicate-recording handling, and the
//  identify/tag phases build on this.
//

import Foundation
import AVFoundation
import MDTagShim
import ChromaSwift
import SwiftUI

// MARK: - Model

enum Thoroughness: String, CaseIterable, Identifiable {
    case light, standard, thorough
    var id: String { rawValue }
    var title: String {
        switch self { case .light: return "Light"; case .standard: return "Standard"; case .thorough: return "Thorough" }
    }
    var blurb: String {
        switch self {
        case .light:    return "Only the safest cleanups — remove junk files and empty folders. Nothing renamed or merged."
        case .standard: return "Safe cleanups plus tidying obviously-untidy folder names. No artist merges."
        case .thorough: return "Everything — cleanups, name tidying, and merging duplicate artist folders. The most consistent result."
        }
    }
    var doesRenames: Bool { self != .light }
    var doesMerges: Bool { self == .thorough }
}

enum FixKind: String {
    case junk           // OS litter / temp / orphan files
    case emptyFolder    // folder with no files anywhere inside
    case drm            // FairPlay-protected, unplayable

    var title: String {
        switch self {
        case .junk:        return "Remove junk files"
        case .emptyFolder: return "Delete empty folders"
        case .drm:         return "Protected (DRM) tracks"
        }
    }
    var safe: Bool { self != .drm }   // drm is informational, never removed
}

struct PerfectFinding: Identifiable {
    let id = UUID()
    let kind: FixKind
    let url: URL
    let relPath: String     // path relative to the library root
    let detail: String      // short reason / description
    let bytes: Int64
    var accepted: Bool
}

/// Raw folder-level detection: top-level folders whose names mean the same
/// artist (e.g. "Buzzcocks" + "The Buzzcocks"). Internal — folded into ArtistIssue.
struct FolderGroup {
    let key: String
    let sources: [String]           // the colliding top-level folder names
    let fileCounts: [Int]           // audio-file count per source (same order)
}

/// One file caught in a tag-level artist split, with the exact artist spelling
/// currently written in it — kept so a fix can be applied and exactly reversed.
struct TagMember {
    let url: URL
    let relPath: String
    let oldName: String
}

/// Raw tag-level detection: one artist written under several spellings in the
/// files' tags. Internal — folded into ArtistIssue.
struct TagGroup {
    let key: String
    let variants: [(name: String, count: Int)]   // spelling → track count
    let members: [TagMember]                      // every file carrying this key
}

/// One artist that needs attention — a folder split, a tag split, or both.
/// The user picks ONE name to keep; applying it does only what's wrong for this
/// artist: merges the differing folders and/or rewrites the differing tags, all
/// to the same name, so the folder on disk and the tags a server reads agree.
struct ArtistIssue: Identifiable {
    let id = UUID()
    let key: String
    var canonical: String            // editable — the one name for folder AND tags
    var accepted: Bool
    let candidates: [String]         // union of folder names + tag spellings, for the picker
    // folder side (empty / single = no folder work)
    let folderSources: [String]
    let folderFileCounts: [Int]
    // tag side
    let tagVariants: [(name: String, count: Int)]
    let tagMembers: [TagMember]

    var hasFolderSplit: Bool { folderSources.count > 1 }
    var hasTagSplit: Bool { tagVariants.count > 1 }
    /// number of tag rewrites this artist would make with the current `canonical`
    var tagRewrites: Int { tagMembers.filter { $0.oldName != canonical }.count }
    /// folders that would be folded away (all sources except the kept one)
    var folderMerges: Int { hasFolderSplit ? folderSources.filter { $0 != canonical }.count : 0 }
    var hasWork: Bool { folderMerges > 0 || tagRewrites > 0 }

    /// one-line summary of what applying this would do
    var actionSummary: String {
        var bits: [String] = []
        if folderMerges > 0 { bits.append("merges \(folderSources.count) folders") }
        if tagRewrites > 0 { bits.append("rewrites \(tagRewrites) tag(s)") }
        return bits.isEmpty ? "already consistent" : bits.joined(separator: " · ")
    }
    /// short kind label
    var kindLabel: String {
        switch (hasFolderSplit, hasTagSplit) {
        case (true, true):  return "folder + tags"
        case (true, false): return "folder"
        case (false, true): return "tags"
        default:            return ""
        }
    }
}

/// A proposed rename of a folder with an obviously untidy name (trailing
/// underscore from a stripped illegal character, stray/double spaces, etc.).
/// The true name including any real illegal character comes later, from the
/// metadata authority — this is only the safe cosmetic tidy.
struct RenameProposal: Identifiable {
    let id = UUID()
    let relPath: String         // current path, root-relative
    let oldName: String
    var newName: String         // editable
    var accepted: Bool
}

/// A committed run, reconstructed from its quarantine folder's run.json, so it
/// can be listed and undone. Every change is one move (from → to), both paths
/// relative to the library root; undo reverses them.
struct RunRecord: Identifiable {
    let id: String          // quarantine subfolder name (timestamp)
    let folder: URL         // the run's quarantine folder
    let date: Date
    let ops: [(from: String, to: String)]   // each move, root-relative
    let tagEdits: [(rel: String, field: String, old: String)]  // each tag rewrite, for exact undo
    let perfEdits: [(rel: String, name: String, role: String)] // each performer credit added, for undo
    let artEdits: [String]                                      // rels where cover art was added, for undo
    let artPromotions: [(rel: String, oldType: Int)]            // existing art retagged to front, for undo
    let artReplacements: [(rel: String, backup: String, oldType: Int)]  // art replaced; backup holds the old image
    let summary: String
}

/// One album's cover-art work: resolve a single image (from any of the album's
/// releases, or iTunes) and apply it to every art-less track in `files`.
struct AlbumArtJob {
    let artist: String
    let album: String
    var mbids: [String]
    var files: [(url: URL, rel: String)]
}

/// An album whose art is mixed/missing but no cover could be fetched — surfaced
/// for the manual artwork picker (choose an existing cover, drop your own,
/// re-search, or leave as-is).
struct ArtworkReviewItem: Identifiable {
    let id = UUID()
    let artist: String
    let album: String
    let files: [String]     // root-relative paths of the album's tracks
}

// MARK: - Found cover art (preview before it's embedded)

/// Fetches Cover Art Archive thumbnails by release MBID so an album whose art we
/// *found* (but haven't embedded yet) shows the real cover in the grid.
@MainActor
final class FoundArtCache: ObservableObject {
    static let shared = FoundArtCache()
    private let images: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 400; return c }()
    private var misses = Set<String>(); private var inflight = Set<String>()

    func cached(_ mbid: String) -> NSImage? { images.object(forKey: mbid as NSString) }

    func request(_ mbid: String) {
        guard images.object(forKey: mbid as NSString) == nil, !misses.contains(mbid), !inflight.contains(mbid) else { return }
        inflight.insert(mbid)
        Task {
            let img = await Self.fetch(mbid)
            self.inflight.remove(mbid)
            if let img { self.images.setObject(img, forKey: mbid as NSString) } else { self.misses.insert(mbid) }
            self.objectWillChange.send()
        }
    }

    nonisolated private static func fetch(_ mbid: String) async -> NSImage? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/front-250") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("MusicDeduper ( neil.cottyincar@gmail.com )", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else { return nil }
        return img
    }
}

// MARK: - Audio preview

/// Plays a track so the user can listen and judge whether a proposed change is
/// right. One at a time; tapping the playing track stops it.
final class AudioPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPreview()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    @Published var playingURL: URL?
    @Published var progress: Double = 0        // 0…1 through the track
    var duration: Double { player?.duration ?? 0 }
    var currentTime: Double { player?.currentTime ?? 0 }

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p; playingURL = url; progress = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        } catch { playingURL = nil }
    }

    func seek(to frac: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = max(0, min(1, frac)) * p.duration
        progress = frac
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil; playingURL = nil; progress = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}

// MARK: - Store

@MainActor
final class PerfectStore: ObservableObject {
    @Published var root: URL?
    // how much Perfect proposes — persisted; defaults to Thorough
    @Published var thoroughness: Thoroughness =
        Thoroughness(rawValue: UserDefaults.standard.string(forKey: "perfectThoroughness") ?? "") ?? .thorough {
        didSet {
            UserDefaults.standard.set(thoroughness.rawValue, forKey: "perfectThoroughness")
            if diagnosed && !busy { diagnose() }   // re-scope the review to the new level
        }
    }
    // run every check automatically on choosing a library, or wait for one Run
    // press — persisted; defaults to automatic. Never task-by-task.
    @Published var autoRun: Bool = (UserDefaults.standard.object(forKey: "perfectAutoRun") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoRun, forKey: "perfectAutoRun") }
    }
    @Published var status = "Choose a music library to explore."
    @Published var busy = false
    // when true, the tag pass runs automatically after the structure scan (one
    // exploration); a thoroughness re-scope re-scans structure only.
    private var chainTags = false
    @Published var progress = ""
    @Published var findings: [PerfectFinding] = []
    @Published var renames: [RenameProposal] = []
    // one artist-centric list, folding folder merges and tag fixes together
    @Published var artists: [ArtistIssue] = []
    // raw detection, kept internally and combined into `artists`
    private var folderGroups: [FolderGroup] = []
    private var tagGroups: [TagGroup] = []
    @Published var diagnosed = false

    // commit-result summary
    @Published var lastRunSummary: String?
    @Published var lastQuarantine: URL?

    // live apply progress (drives the Applying… dialog with its Cancel button)
    @Published var committing = false
    @Published var cancelRequested = false     // Cancel pressed; disables the button
    @Published var commitPhase = ""
    @Published var commitDone = 0
    @Published var commitTotal = 0
    @Published var artworkNeedsReview: [ArtworkReviewItem] = []   // albums needing a manual cover choice
    func setCommitProgress(_ phase: String, done: Int) { commitPhase = phase; commitDone = done }

    // persistent run history (each run's quarantine folder holds a run.json)
    @Published var runs: [RunRecord] = []

    @Published var checkingTags = false
    @Published var tagProgress = ""

    // identify (acoustic fingerprint → AcoustID → proposed correct names)
    @Published var proposals: [TrackProposal] = []
    @Published var identifying = false
    @Published var identifyProgress = ""
    @Published var recentFinds: [String] = []   // live feed of what identify just matched
    @Published var identifyMatched = 0           // running count of tracks matched
    @Published var identifyListened = 0          // Phase 1: files fingerprinted so far
    @Published var identifyListening = false     // true during Phase 1 (listening), false during Phase 2 (matching)
    @Published var enriching = false
    @Published var enrichProgress = ""
    @Published var enrichDone = 0                 // running count of tracks looked up
    @Published var didIdentify = false       // identify pass has completed at least once
    @Published var enriched = false          // credits pass has run (or was skipped)

    // deduplicate (folded in from the old wizard; merge-of-best keeper)
    @Published var dedupClusters: [Cluster] = []
    @Published var dedupTracks: [Track] = []
    @Published var deduped = false
    @Published var deduping = false

    // organise (rebuild the clean Album Artist/Album/## Title tree from tags)
    @Published var organisePlans: [OrganisePlan] = []
    @Published var organised = false          // organise plan has been built at least once
    @Published var organising = false
    @Published var organiseProgress = ""
    @Published var composerFirstClassical = false   // classical → Composer-first folders
    // category-level toggles (the mockup's bulk on/off buttons)
    @Published var applyNames = true       // identify: artist/title/album corrections
    @Published var applyArtwork = true     // add missing cover art
    @Published var applyCredits = true     // composer/label/performers gap-fills
    // per-kind name toggles — auto-apply cosmetic tidies and bulk-accept "adds
    // detail" without cluttering the queue; substantive changes always go through
    // the per-track review.
    @Published var applyCosmeticNames = true
    @Published var applyAdditiveNames = true
    func nameKindEnabled(_ k: ChangeKind) -> Bool {
        switch k {
        case .cosmetic: return applyCosmeticNames
        case .additive: return applyAdditiveNames
        default:        return true
        }
    }
    var hasAcoustIDKey: Bool { !Identifier.configuredKey.isEmpty }

    // Tag writing uses a surgical TagLib shim (MDTagShim) that changes only the
    // artist frame and preserves the ID3 version and every other frame — verified
    // lossless at the frame level. Enabled.
    let tagWritingEnabled = true

    /// work this artist would actually apply right now — folder merges always,
    /// tag rewrites only when tag-writing is enabled
    func artistHasApplicableWork(_ a: ArtistIssue) -> Bool {
        a.folderMerges > 0 || (tagWritingEnabled && a.tagRewrites > 0)
    }

    private let cancelFlag = CancelBox()

    // scanned totals for the header
    @Published var totalFiles = 0
    @Published var totalFolders = 0
    @Published var totalBytes: Int64 = 0

    func setRoot(_ url: URL) {
        root = url
        findings = []; renames = []; artists = []; folderGroups = []; tagGroups = []; proposals = []; didIdentify = false; enriched = false
        diagnosed = false
        lastRunSummary = nil
        loadRuns()
        // Nothing runs automatically — the user triggers Scan (step 1).
        status = "Ready — press Scan to check \(url.lastPathComponent)."
    }

    /// One exploration pass: structure scan followed by the artist-tag scan.
    /// This is the single entry point — there are no per-check buttons.
    func explore() {
        chainTags = true
        diagnose()
    }

    func pickRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose the music library to make perfect"
        if p.runModal() == .OK, let url = p.url { setRoot(url) }
    }

    // One affected album for the carousel, aggregating the pending changes that
    // touch the tracks in a single folder (names / artwork / credits).
    struct AlbumChange: Identifiable {
        let id: String            // album folder path
        let dir: URL
        let title: String
        let subtitle: String
        let sampleURL: URL?
        let trackCount: Int
        var names = false, artwork = false, credits = false
        var artReleaseMBID: String? = nil   // for previewing found (not-yet-embedded) art
    }

    /// Albums touched by identify/enrich, for the cover carousel. Grouped by the
    /// tracks' folder; each carries which kinds of change it will get.
    var albumChanges: [AlbumChange] {
        var byDir: [String: [TrackProposal]] = [:]
        for p in proposals where p.isActionable {
            byDir[p.url.deletingLastPathComponent().path, default: []].append(p)
        }
        return byDir.map { (dirPath, props) -> AlbumChange in
            let dir = URL(fileURLWithPath: dirPath)
            let firstAlbum = props.first(where: { !$0.chosenAlbum.isEmpty })?.chosenAlbum
            return AlbumChange(
                id: dirPath, dir: dir,
                title: firstAlbum ?? dir.lastPathComponent,
                subtitle: props.first?.newArtist ?? "",
                sampleURL: props.first?.url,
                trackCount: props.count,
                names: props.contains { $0.hasChange },
                artwork: props.contains { $0.canAddArt },
                credits: props.contains { !($0.enrichment?.isEmpty ?? true) },
                artReleaseMBID: props.first(where: { $0.canAddArt })?.enrichment?.releaseMBID)
        }.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    // findings grouped by kind, in display order
    var groups: [(kind: FixKind, items: [PerfectFinding])] {
        let order: [FixKind] = [.junk, .emptyFolder, .drm]
        return order.compactMap { k in
            let items = findings.filter { $0.kind == k }
            return items.isEmpty ? nil : (k, items)
        }
    }
    var acceptedCount: Int { findings.filter { $0.accepted && $0.kind.safe }.count }

    // MARK: Diagnose

    func diagnose() {
        guard let root else { return }
        busy = true; diagnosed = false; findings = []
        status = "Diagnosing…"; progress = ""
        cancelFlag.cancelled = false
        let box = cancelFlag
        Task.detached(priority: .userInitiated) {
            var found: [PerfectFinding] = []
            var files = 0, folders = 0
            var bytes: Int64 = 0
            let fm = FileManager.default

            // Enumerate everything once. Track which directories contain any file
            // (anywhere below) so we can flag the truly-empty ones afterwards.
            var dirHasContent = Set<String>()
            var allDirs: [URL] = []

            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                      options: []) {
                while let u = en.nextObject() as? URL {
                    if box.cancelled { break }
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if v?.isDirectory == true {
                        folders += 1
                        allDirs.append(u)
                        continue
                    }
                    files += 1
                    let size = Int64(v?.fileSize ?? 0)
                    bytes += size
                    let rel = Self.rel(u, root)

                    // mark every ancestor directory as having content
                    var p = u.deletingLastPathComponent()
                    while p.path.count >= root.path.count {
                        dirHasContent.insert(p.path)
                        if p.path == root.path { break }
                        p = p.deletingLastPathComponent()
                    }

                    if let junkReason = Self.junkReason(u) {
                        found.append(PerfectFinding(kind: .junk, url: u, relPath: rel,
                                                    detail: junkReason, bytes: size, accepted: true))
                    } else if Self.isAudio(u), await Self.isDRM(u) {
                        found.append(PerfectFinding(kind: .drm, url: u, relPath: rel,
                                                    detail: "FairPlay-protected — most players can't play this",
                                                    bytes: size, accepted: false))
                    }
                    if files % 50 == 0 {
                        await self.setProgress("Scanned \(files) files…")
                    }
                }
            }

            // empty folders = directories with no file anywhere inside
            for d in allDirs where !dirHasContent.contains(d.path) {
                found.append(PerfectFinding(kind: .emptyFolder, url: d, relPath: Self.rel(d, root),
                                            detail: "No audio or files inside", bytes: 0, accepted: true))
            }

            // duplicate-artist folders: top-level folders whose names normalise
            // to the same artist (Buzzcocks / The Buzzcocks; & vs and; "X, The")
            var folderGroups: [FolderGroup] = []
            let topDirs = allDirs.filter { $0.deletingLastPathComponent().path == root.path
                                           && $0.lastPathComponent != "Music Librarian Quarantine" }
            var byKey: [String: [URL]] = [:]
            for d in topDirs { byKey[Self.artistKey(d.lastPathComponent), default: []].append(d) }
            for (key, dirs) in byKey where dirs.count > 1 {
                let names = dirs.map { $0.lastPathComponent }
                let counts = dirs.map { d -> Int in
                    var c = 0
                    if let e = fm.enumerator(at: d, includingPropertiesForKeys: nil) {
                        while let f = e.nextObject() as? URL { if Self.isAudio(f) { c += 1 } }
                    }
                    return c
                }
                folderGroups.append(FolderGroup(key: key, sources: names, fileCounts: counts))
            }

            // bad folder names — safe cosmetic tidy. Skip empties (being removed)
            // and anything under a merge source (its contents move during merge).
            let emptyPaths = Set(found.filter { $0.kind == .emptyFolder }.map { $0.url.path })
            let mergeSrcRoots = folderGroups.flatMap { g in g.sources.map { root.appendingPathComponent($0).path + "/" } }
            var renameProposals: [RenameProposal] = []
            for d in allDirs {
                if emptyPaths.contains(d.path) { continue }
                if d.lastPathComponent == "Music Librarian Quarantine" { continue }
                if mergeSrcRoots.contains(where: { d.path.hasPrefix($0) || d.path + "/" == $0 }) { continue }
                let old = d.lastPathComponent
                let clean = Self.cleanFolderName(old)
                guard clean != old, !clean.isEmpty else { continue }
                // skip if a sibling with the cleaned name already exists (would collide)
                let siblingClean = d.deletingLastPathComponent().appendingPathComponent(clean)
                if fm.fileExists(atPath: siblingClean.path) { continue }
                renameProposals.append(RenameProposal(relPath: Self.rel(d, root), oldName: old,
                                                      newName: clean, accepted: true))
            }

            // drop any rename whose ancestor is also being renamed (keeps commit
            // and undo ordering simple; nested cases resolve on a later re-diagnose)
            let renameRels = Set(renameProposals.map { $0.relPath })
            let filteredRenames = renameProposals.filter { p in
                var parent = (p.relPath as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    if renameRels.contains(parent) { return false }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                return true
            }

            let (ff, fo, fb) = (files, folders, bytes)
            let fg = folderGroups
            await self.finishDiagnose(found: found, folderGroups: fg,
                                      renames: filteredRenames.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() },
                                      files: ff, folders: fo, bytes: fb, cancelled: box.cancelled)
        }
    }

    private func setProgress(_ s: String) { progress = s }

    private func finishDiagnose(found: [PerfectFinding], folderGroups fg: [FolderGroup],
                               renames r: [RenameProposal],
                               files: Int, folders: Int, bytes: Int64, cancelled: Bool) {
        findings = found.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        // gate by thoroughness (junk/empties/DRM always; renames Standard+; merges Thorough)
        folderGroups = fg
        renames = thoroughness.doesRenames ? r : []
        rebuildArtists()
        totalFiles = files; totalFolders = folders; totalBytes = bytes
        busy = false; diagnosed = !cancelled; progress = ""
        let junk = found.filter { $0.kind == .junk }.count
        let empties = found.filter { $0.kind == .emptyFolder }.count
        let drm = found.filter { $0.kind == .drm }.count
        var parts = ["\(files) files · \(folders) folders · \(fmtBytes(bytes))"]
        var found2: [String] = []
        if junk > 0 { found2.append("\(junk) junk") }
        if empties > 0 { found2.append("\(empties) empty folder(s)") }
        if !artists.isEmpty { found2.append("\(artists.count) artist(s) to fix") }
        if !renames.isEmpty { found2.append("\(renames.count) untidy name(s)") }
        if drm > 0 { found2.append("\(drm) protected track(s)") }
        if !found2.isEmpty { parts.append("found " + found2.joined(separator: ", ")) }
        status = cancelled ? "Exploration cancelled." : parts.joined(separator: " — ") + "."
        // second half of a full exploration: read the tags too
        if chainTags && !cancelled {
            chainTags = false
            checkTags()
        } else {
            chainTags = false
        }
    }

    /// Combine the raw folder-level and tag-level detections into one
    /// artist-centric list. Preserves the user's `accepted`/`canonical` edits
    /// across rebuilds (matched by key), so a later tag scan or a thoroughness
    /// change doesn't wipe choices already made.
    private func rebuildArtists() {
        // remember prior user edits
        let prior = Dictionary(uniqueKeysWithValues: artists.map { ($0.key, $0) })

        let folderByKey = Dictionary(uniqueKeysWithValues: folderGroups.map { ($0.key, $0) })
        let tagByKey = Dictionary(uniqueKeysWithValues: tagGroups.map { ($0.key, $0) })
        let allKeys = Set(folderByKey.keys).union(tagByKey.keys)

        var result: [ArtistIssue] = []
        for key in allKeys {
            let fg = folderByKey[key]
            let tg = tagByKey[key]
            // folder side only counts when the level allows folder merges
            let folderSources = (thoroughness.doesMerges ? fg?.sources : nil) ?? []
            let folderCounts  = (thoroughness.doesMerges ? fg?.fileCounts : nil) ?? []
            let tagVariants = tg?.variants ?? []
            let tagMembers = tg?.members ?? []

            let hasFolderSplit = folderSources.count > 1
            let hasTagSplit = tagVariants.count > 1
            guard hasFolderSplit || hasTagSplit else { continue }   // nothing to do

            // candidate names for the picker: union of folder names + tag spellings,
            // ranked by how many files back each name (tags + matching folder)
            var score: [String: Int] = [:]
            for (n, c) in tagVariants { score[n, default: 0] += c }
            for (n, c) in zip(folderSources, folderCounts) { score[n, default: 0] += c }
            let candidates = score.sorted { $0.value != $1.value ? $0.value > $1.value
                                                                 : $0.key.lowercased() < $1.key.lowercased() }.map { $0.key }

            // default kept name: prior choice if still valid, else the top candidate
            let canonical: String = {
                if let p = prior[key], candidates.contains(p.canonical) { return p.canonical }
                return candidates.first ?? (tagVariants.first?.name ?? folderSources.first ?? "")
            }()
            let accepted = prior[key]?.accepted ?? true

            result.append(ArtistIssue(key: key, canonical: canonical, accepted: accepted,
                                      candidates: candidates,
                                      folderSources: folderSources, folderFileCounts: folderCounts,
                                      tagVariants: tagVariants, tagMembers: tagMembers))
        }
        artists = result.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() }
    }

    /// Safe cosmetic tidy of a folder name — trailing underscores (stripped
    /// illegal chars), stray/doubled whitespace, trailing dots. Never invents.
    nonisolated static func cleanFolderName(_ name: String) -> String {
        var n = name
        while n.contains("  ") { n = n.replacingOccurrences(of: "  ", with: " ") }
        n = n.trimmingCharacters(in: .whitespaces)
        while n.hasSuffix("_") || n.hasSuffix(".") || n.hasSuffix(" ") { n = String(n.dropLast()) }
        return n.trimmingCharacters(in: .whitespaces)
    }

    /// Normalise an artist folder name to a collision key: drops a leading
    /// "The"/trailing ", The", unifies & and "and", strips punctuation/spaces.
    nonisolated static func artistKey(_ name: String) -> String {
        var s = name.lowercased()
        s = s.replacingOccurrences(of: " & ", with: " and ")
        if s.hasSuffix(", the") { s = "the " + s.dropLast(5) }
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        return s.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    func cancel() { cancelFlag.cancelled = true; cancelRequested = true }

    // MARK: Tag check (Phase 2 preview) — read artist tags, find split spellings

    func checkTags() {
        guard let root, !checkingTags else { return }
        checkingTags = true; tagProgress = "Reading tags…"
        let box = cancelFlag
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var counts: [String: Int] = [:]     // exact artist string → track count
            var filesByName: [String: [URL]] = [:]  // exact artist string → its files
            var seen = 0
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = en.nextObject() as? URL {
                    if box.cancelled { break }
                    guard Self.isAudio(u) else { continue }
                    seen += 1
                    if let artist = Self.readArtist(u), !artist.isEmpty {
                        counts[artist, default: 0] += 1
                        filesByName[artist, default: []].append(u)
                    }
                    if seen % 25 == 0 { await self.setTagProgress("Read \(seen) tracks…") }
                }
            }
            // group exact spellings by normalised key; keep only real splits
            var byKey: [String: [(String, Int)]] = [:]
            for (name, c) in counts { byKey[Self.artistKey(name), default: []].append((name, c)) }
            let groups = byKey.compactMap { (k, v) -> TagGroup? in
                guard v.count > 1 else { return nil }
                let variants = v.sorted { $0.1 > $1.1 }
                let members = variants.flatMap { (name, _) in
                    (filesByName[name] ?? []).map { TagMember(url: $0, relPath: Self.rel($0, root), oldName: name) }
                }
                return TagGroup(key: k, variants: variants, members: members)
            }
            await self.finishTagCheck(groups: groups, tracks: seen, cancelled: box.cancelled)
        }
    }

    private func setTagProgress(_ s: String) { tagProgress = s }

    private func finishTagCheck(groups: [TagGroup], tracks: Int, cancelled: Bool) {
        checkingTags = false; tagProgress = ""
        if !cancelled { tagGroups = groups; rebuildArtists() }
        if !cancelled {
            let splits = artists.filter { $0.hasTagSplit }.count
            status = splits == 0
                ? "Read \(tracks) tags — no split artist spellings found."
                : "Read \(tracks) tags — \(splits) artist(s) split across different spellings."
        }
    }

    /// Read the artist tag. Uses the same TagLib shim that writes it, so a
    /// recorded "old" value exactly matches what a rewrite would overwrite —
    /// undo is then exact.
    nonisolated static func readArtist(_ url: URL) -> String? { readField(url, "artist") }

    /// Read one tag field ("artist","album","albumartist","title","track").
    nonisolated static func readField(_ url: URL, _ field: String) -> String? {
        guard let c = md_get_field(url.path, field) else { return nil }
        defer { free(c) }
        let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Write one tag field surgically — only that frame changes; the ID3 version
    /// and every other frame (year, rating, cover art, …) are preserved.
    nonisolated static func writeField(_ url: URL, _ field: String, to value: String) throws {
        let rc = md_set_field(url.path, field, value)
        if rc != 0 { throw NSError(domain: "MDTagShim", code: Int(rc),
                                   userInfo: [NSLocalizedDescriptionKey: "tag write failed (\(rc))"]) }
    }

    /// Add a performer credit (name + instrument/role) to the musician-credits list.
    nonisolated static func addPerformer(_ url: URL, name: String, role: String) throws {
        let rc = md_add_performer(url.path, name, role)
        if rc != 0 { throw NSError(domain: "MDTagShim", code: Int(rc),
                                   userInfo: [NSLocalizedDescriptionKey: "credit write failed (\(rc))"]) }
    }

    /// Remove a performer credit (for undo).
    nonisolated static func removePerformer(_ url: URL, name: String, role: String) {
        _ = md_remove_performer(url.path, name, role)
    }

    // MARK: Commit — apply accepted removals + merges as a log of reversible moves

    var hasWork: Bool {
        findings.contains { $0.accepted && $0.kind.safe }
            || renames.contains { $0.accepted && $0.newName != $0.oldName }
            || artists.contains { $0.accepted && artistHasApplicableWork($0) }
            || (tagWritingEnabled && proposals.contains { p in p.accepted && (
                    (applyNames && p.hasChange)
                    || (applyArtwork && p.canAddArt)
                    || (applyCredits && !(p.enrichment?.isEmpty ?? true))) })
    }

    // MARK: Identify — fingerprint each track and propose the correct names

    func identify() {
        guard let root, hasAcoustIDKey, !identifying else { return }
        identifying = true; proposals = []; identifyProgress = "Identifying…"
        recentFinds = []; identifyMatched = 0; identifyListened = 0; identifyListening = true
        didIdentify = false; enriched = false
        let box = cancelFlag; box.cancelled = false
        let id = Identifier(apiKey: Identifier.configuredKey)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // collect audio files
            var files: [URL] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = en.nextObject() as? URL { if Self.isAudio(u) { files.append(u) } }
            }
            let total = files.count

            // Phase 1 — LISTEN. Read tags and fingerprint files in parallel (pure
            // local work, no rate limit), so the CPU/disk cost happens up front
            // instead of stalling in front of every network call. Bounded so a
            // handful of tens-of-MB decodes run at once, not the whole library.
            var ready: [ReadyTrack] = []
            let cap = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            var listened = 0
            await withTaskGroup(of: ReadyTrack?.self) { group in
                var iter = files.makeIterator()
                func addNext() {
                    guard !box.cancelled, let u = iter.next() else { return }
                    group.addTask {
                        let rel = Self.rel(u, root)
                        let a = Self.readField(u, "artist") ?? ""
                        let t = Self.readField(u, "title") ?? ""
                        let al = Self.readField(u, "album") ?? ""
                        let c = Self.readField(u, "composer") ?? ""
                        let l = Self.readField(u, "label") ?? ""
                        let hasArt = md_has_artwork(u.path) == 1
                        guard let fp = id.fingerprint(u) else { return nil }
                        return ReadyTrack(url: u, rel: rel, artist: a, title: t, album: al,
                                          composer: c, label: l, hasArt: hasArt, fp: fp)
                    }
                }
                for _ in 0..<cap { addNext() }
                while let r = await group.next() {
                    listened += 1
                    if let r { ready.append(r) }
                    if listened % 2 == 0 || listened == total { await self.setListened(listened, total) }
                    addNext()
                }
            }
            await self.beginMatching()

            // Phase 2 — MATCH. AcoustID lookups, paced to its 3-requests/second
            // limit. The lookup latency counts toward the gap, so we only wait the
            // remainder — no dead 350ms tacked on after each request.
            var found: [TrackProposal] = []
            var done = 0
            for r in ready {
                if box.cancelled { break }
                let start = DispatchTime.now().uptimeNanoseconds
                if let p = try? await id.resolve(url: r.url, relPath: r.rel, fingerprint: r.fp,
                                                 curArtist: r.artist, curTitle: r.title, curAlbum: r.album,
                                                 curHasArt: r.hasArt, curComposer: r.composer, curLabel: r.label) {
                    await self.pushFind("\(p.newTitle) — \(p.newArtist)", changed: p.hasChange)
                    found.append(p)
                }
                done += 1
                if done % 3 == 0 { await self.setIdentifyProgress("Matched \(done)/\(ready.count)…") }
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let waitMs = 340.0 - elapsedMs
                if waitMs > 0 { try? await Task.sleep(nanoseconds: UInt64(waitMs * 1_000_000)) }
            }
            await self.finishIdentify(proposals: found, total: total, cancelled: box.cancelled)
        }
    }

    /// A file that's been listened to (tags read + fingerprinted) and is ready for
    /// the rate-limited AcoustID lookup.
    private struct ReadyTrack {
        let url: URL; let rel: String
        let artist: String; let title: String; let album: String
        let composer: String; let label: String
        let hasArt: Bool; let fp: AudioFingerprint
    }

    private func setIdentifyProgress(_ s: String) { identifyProgress = s }
    private func setListened(_ done: Int, _ total: Int) {
        identifyListened = done; identifyProgress = "Listening \(done)/\(total)…"
    }
    private func beginMatching() { identifyListening = false; identifyProgress = "Matching…" }

    private func pushFind(_ s: String, changed: Bool) {
        identifyMatched += 1
        recentFinds.insert((changed ? "✎ " : "✓ ") + s, at: 0)
        if recentFinds.count > 7 { recentFinds.removeLast() }
    }

    private func finishIdentify(proposals p: [TrackProposal], total: Int, cancelled: Bool) {
        identifying = false; identifyProgress = ""
        proposals = p.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        if !cancelled {
            didIdentify = true                       // Identify step complete → Next unlocks
            let act = p.filter { $0.isActionable }.count
            status = p.isEmpty
                ? "Identified \(total) tracks — nothing matched."
                : "Identified \(p.count) tracks — \(act) with changes so far · run Fill credits to check the rest."
        }
    }

    // MARK: Enrich — second pass: MusicBrainz relationships (composer/label/credits)

    /// Looks up composer, lyricist, label and performer credits for the identified
    /// tracks. Slower than identify (MusicBrainz allows ~1 request/second), so it's
    /// its own pass and can be cancelled; results attach to each proposal.
    func enrich() {
        guard !proposals.isEmpty, !enriching else { return }
        enriching = true; enrichProgress = "Looking up credits…"
        recentFinds = []; enrichDone = 0
        let box = cancelFlag; box.cancelled = false
        let client = MusicBrainzClient()
        // Look up every identified track. We can't tell from the tag alone whether a
        // track is missing performers or a lyricist (those live in frames we don't
        // pre-read), so we check them all and let the gap-fill decide what to add —
        // nothing complete is ever overwritten.
        let targets = proposals.compactMap { p -> EnrichTarget? in
            guard let rid = p.recordingID else { return nil }
            return EnrichTarget(id: p.id, rid: rid,
                                title: p.newTitle.isEmpty ? p.curTitle : p.newTitle,
                                artist: p.newArtist.isEmpty ? p.curArtist : p.newArtist,
                                album: p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum)
        }
        // Group by album TAG (artist + album), not folder — so it batches even when
        // an album's tracks are loose or one-per-folder. One release lookup then
        // covers the whole album. Tracks with no album tag can't be grouped, so
        // each gets a unique key and takes the direct per-track path. Order is
        // preserved so the feed still moves top-to-bottom.
        var order: [String] = []
        var groups: [String: [EnrichTarget]] = [:]
        for (i, t) in targets.enumerated() {
            let key = t.album.isEmpty ? "single#\(i)" : Self.foldKey(t.artist) + "|" + Self.foldKey(t.album)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        let total = targets.count
        Self.creditsLog("=== Credits run: \(total) tracks in \(order.count) album-group(s) ===", reset: true)
        Task.detached(priority: .userInitiated) {
            var done = 0
            var batchCovered = 0, fellBack = 0, batchedGroups = 0
            for folder in order {
                if box.cancelled { break }
                let tracks = groups[folder] ?? []
                // A lone track isn't worth a batch (2 requests for 1); look it up
                // directly. Real albums (2+ tracks) go through one release lookup.
                let didBatch = tracks.count > 1
                let credits: MusicBrainzClient.AlbumCredits
                if let seed = tracks.first, didBatch {
                    credits = await client.albumCredits(seedRecordingID: seed.rid, albumTitle: seed.album, groupSize: tracks.count)
                    batchedGroups += 1
                } else {
                    credits = MusicBrainzClient.AlbumCredits()
                }
                var covered = 0, missed = 0
                for t in tracks {
                    if box.cancelled { break }
                    // matched by recording id, else by title, else a per-track lookup
                    var e: Enrichment
                    if let hit = credits.byRecording[t.rid] { e = hit; covered += 1 }
                    else if let hit = credits.byTitle[Self.foldKey(t.title)] { e = hit; covered += 1 }
                    else if didBatch {
                        // missed the album batch, but borrow the album's label/date/
                        // artwork and pay only a single recording lookup (not three)
                        e = await client.recordingOnly(recordingID: t.rid)
                        if e.label == nil { e.label = credits.label; e.catalogNumber = credits.catalog }
                        if e.date == nil { e.date = credits.date }
                        if e.releaseMBID == nil { e.releaseMBID = credits.releaseMBID }
                        missed += 1
                    } else {
                        e = await client.enrich(recordingID: t.rid); missed += 1
                    }
                    await self.attachEnrichment(t.id, e)
                    done += 1
                    await self.pushEnrich(t.id, e, done: done, total: total)
                }
                batchCovered += covered; fellBack += missed
                let batchInfo = didBatch ? "batch covered \(covered)/\(tracks.count), \(missed) fell back" : "single (per-track)"
                Self.creditsLog("group '\(folder)' size=\(tracks.count): \(batchInfo)")
            }
            let s = await client.stats()
            Self.creditsLog("--- TOTAL: \(order.count) groups, \(batchedGroups) batched · tracks \(done) (batch-covered \(batchCovered), per-track \(fellBack)) · MusicBrainz requests=\(s.mb), Discogs=\(s.discogs) ---")
            await self.finishEnrich(cancelled: box.cancelled)
        }
    }

    /// Append a line to ~/musicdeduper-credits.log (reset truncates it). Lets us
    /// see whether album-batching is actually engaging on a real library.
    nonisolated static func creditsLog(_ line: String, reset: Bool = false) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("musicdeduper-credits.log")
        if reset {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } else if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = (line + "\n").data(using: .utf8) { h.write(d) }
            try? h.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private struct EnrichTarget { let id: UUID; let rid: String; let title: String; let artist: String; let album: String }
    private nonisolated static func foldKey(_ s: String) -> String { TrackProposal.typoFold(s).lowercased() }

    private func setEnrichProgress(_ s: String) { enrichProgress = s }

    /// Advance the live credits counter/feed as each track is looked up.
    private func pushEnrich(_ id: UUID, _ e: Enrichment, done: Int, total: Int) {
        enrichDone = done
        enrichProgress = "Credits \(done)/\(total)…"
        let title = proposals.first(where: { $0.id == id })?.newTitle ?? "track"
        var bits: [String] = []
        if e.composer != nil { bits.append("composer") }
        if e.lyricist != nil { bits.append("lyricist") }
        if e.label != nil { bits.append("label") }
        if !e.performers.isEmpty { bits.append("\(e.performers.count) performer\(e.performers.count == 1 ? "" : "s")") }
        if e.releaseMBID != nil { bits.append("artwork") }
        let found = bits.isEmpty ? "nothing new" : "+ " + bits.joined(separator: ", ")
        recentFinds.insert((bits.isEmpty ? "✓ " : "✎ ") + "\(title) — \(found)", at: 0)
        if recentFinds.count > 7 { recentFinds.removeLast() }
    }

    private func attachEnrichment(_ id: UUID, _ e: Enrichment) {
        if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].enrichment = e }
    }

    private func finishEnrich(cancelled: Bool) {
        enriching = false; enrichProgress = ""; enriched = true
        let filled = proposals.filter { !($0.enrichment?.isEmpty ?? true) }.count
        if !cancelled { status = "Looked up credits — \(filled) track(s) enriched." }
    }

    // MARK: Organise (rebuild the clean tree from tags)

    /// Build the placement plan — read each track's tags (overlaying any accepted
    /// identify/credits corrections that aren't written to disk yet) and ask
    /// Organiser where each file should live. Preview only; nothing moves.
    func organise() {
        guard let root else { return }
        organising = true; organiseProgress = "Reading tags…"; status = "Planning the clean tree…"
        // in-memory corrections not yet on disk, keyed by root-relative path
        let corrections: [String: (artist: String, album: String, title: String)] =
            Dictionary(proposals.filter { $0.accepted }.map { p in
                (p.relPath, (p.newArtist.isEmpty ? p.curArtist : p.newArtist,
                             p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum,
                             p.newTitle.isEmpty ? p.curTitle : p.newTitle))
            }, uniquingKeysWith: { a, _ in a })
        let composerFirst = composerFirstClassical
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var inputs: [OrganiseInput] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in en {
                    guard Self.isAudio(url) else { continue }
                    let rel = Self.rel(url, root)
                    if rel.hasPrefix("Music Librarian Quarantine") { continue }
                    let c = corrections[rel]
                    let artist = c?.artist ?? (Self.readField(url, "artist") ?? "")
                    let album  = c?.album  ?? (Self.readField(url, "album")  ?? "")
                    let title  = c?.title  ?? (Self.readField(url, "title")  ?? "")
                    let aa     = Self.readField(url, "albumartist") ?? ""
                    let track  = Int((Self.readField(url, "track") ?? "").prefix(while: { $0.isNumber })) ?? 0
                    let disc   = Int((Self.readField(url, "disc")  ?? "").prefix(while: { $0.isNumber })) ?? 0
                    let composer = Self.readField(url, "composer") ?? ""
                    inputs.append(OrganiseInput(rel: rel, ext: url.pathExtension.lowercased(),
                        artist: artist, albumArtist: aa, album: album, title: title,
                        trackNo: track, discNo: disc, isClassical: false, composer: composer))
                }
            }
            let plans = Organiser.plan(inputs, composerFirstForClassical: composerFirst)
            await self.finishOrganise(plans)
        }
    }

    private func finishOrganise(_ plans: [OrganisePlan]) {
        organising = false; organiseProgress = ""; organised = true; organisePlans = plans
        let moves = plans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }.count
        let flagged = plans.filter { $0.targetRel == nil }.count
        status = "Clean tree planned — \(moves) file(s) to reorganise, \(flagged) flagged."
    }

    /// Apply the organise plan: write the guaranteed tags, then move each file to
    /// its clean path. Recorded to run.json (ops + tagEdits) so Undo reverses it.
    func applyOrganise() {
        guard let root else { return }
        let plans = organisePlans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }
        guard !plans.isEmpty else { return }
        busy = true; committing = true; commitPhase = "Reorganising files…"; commitDone = 0
        commitTotal = plans.count; cancelRequested = false
        let box = cancelFlag; box.cancelled = false
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []
            var tagEdits: [(rel: String, field: String, old: String)] = []
            var log = "Music Librarian — organise \(Date())\nLibrary: \(root.path)\n\n"
            var done = 0
            for p in plans {
                if box.cancelled { break }
                guard let target = p.targetRel else { continue }
                let src = root.appendingPathComponent(p.rel)
                guard fm.fileExists(atPath: src.path) else { continue }
                // guaranteed tags (track#, album-artist) — write while at the source
                for (field, value) in p.tagWrites {
                    let old = Self.readField(src, field) ?? ""
                    if old == value { continue }
                    do { try Self.writeField(src, field, to: value)
                         tagEdits.append((p.rel, field, old))
                         log += "TAG: \(p.rel)  \(field) '\(old)' → '\(value)'\n"
                    } catch { log += "FAILED tag \(p.rel) \(field): \(error.localizedDescription)\n" }
                }
                // move to the clean path (never overwrite an existing target)
                let dst = root.appendingPathComponent(target)
                if fm.fileExists(atPath: dst.path) {
                    log += "SKIP (target exists): \(target)\n"
                } else {
                    do {
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: src, to: dst)
                        ops.append((p.rel, target))
                        log += "MOVED: \(p.rel) → \(target)\n"
                    } catch { log += "FAILED move \(p.rel): \(error.localizedDescription)\n" }
                }
                done += 1
                if done % 5 == 0 { await self.setCommitProgress("Reorganising files", done: done) }
            }
            let total = ops.count + tagEdits.count
            log += "\n\(total) change(s)\(box.cancelled ? " (stopped early)" : "").\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "Reorganised \(ops.count) file(s)",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
                "perfEdits": [], "artEdits": [], "artPromotions": [], "artReplacements": [],
            ]
            if total > 0, let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            } else { try? fm.removeItem(at: quarantine) }
            await self.finishOrganiseApply(quarantine: quarantine, moved: ops.count)
        }
    }

    private func finishOrganiseApply(quarantine: URL, moved: Int) {
        busy = false; committing = false; cancelRequested = false
        commitPhase = ""; commitDone = 0; commitTotal = 0
        lastQuarantine = quarantine
        organisePlans.removeAll(); organised = false
        lastRunSummary = "Reorganised \(moved) file(s)."
        status = lastRunSummary ?? status
        loadRuns()
    }

    // MARK: Deduplicate (folded in from the old wizard, with merge-of-best)

    /// Scan the library, read tags, and cluster duplicates (best copy = keeper).
    func dedup() {
        guard let root else { return }
        deduping = true; status = "Finding duplicates…"; dedupClusters = []; dedupTracks = []
        let mode = MatchMode.balanced, tol = 2.0, cross = false
        Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            if let en = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                while let obj = en.nextObject() {
                    guard let u = obj as? URL, Self.isAudio(u) else { continue }
                    if Self.rel(u, root).hasPrefix("Music Librarian Quarantine") { continue }
                    urls.append(u)
                }
            }
            var built: [Track] = []
            for u in urls {
                let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                let m = await readMetadata(url: u, size: size)
                let rel = Self.rel(u, root)
                built.append(Track(id: built.count, url: u, name: u.lastPathComponent,
                    relDir: (rel as NSString).deletingLastPathComponent, size: size, ext: m.ext,
                    title: m.title, artist: m.artist, album: m.album, albumArtist: m.albumArtist,
                    trackNo: m.trackNo, discNo: m.discNo, duration: m.duration,
                    lossless: m.lossless, bitrate: m.bitrate, codec: m.codec))
            }
            var mutable = built
            let cl = buildClusters(&mutable, mode: mode, tol: tol, crossAlbum: cross) { s in
                Task { await self.setDedupStatus(s) }
            }
            await self.finishDedup(tracks: mutable, clusters: cl)
        }
    }

    private func setDedupStatus(_ s: String) { status = s }

    private func finishDedup(tracks: [Track], clusters: [Cluster]) {
        deduping = false; deduped = true; dedupTracks = tracks; dedupClusters = clusters
        let dupes = clusters.reduce(0) { $0 + $1.memberIDs.count - 1 }
        status = "Found \(clusters.count) duplicate group(s) — \(dupes) file(s) can be removed."
    }

    func setDedupKeeper(clusterID: UUID, trackID: Int) {
        guard let i = dedupClusters.firstIndex(where: { $0.id == clusterID }) else { return }
        dedupClusters[i].keeperID = trackID
    }
    func dedupTrack(_ id: Int) -> Track? { dedupTracks.first { $0.id == id } }
    var dedupRemovableCount: Int { dedupClusters.reduce(0) { $0 + $1.memberIDs.count - 1 } }

    /// Apply dedup with MERGE-OF-BEST: the keeper (best-quality copy) inherits any
    /// blank tags and missing cover art from its duplicates, then the duplicates go
    /// to the shared quarantine. Recorded to run.json (ops + tagEdits + artEdits) so
    /// Undo puts the files back and reverses the backfill.
    func applyDedup() {
        guard let root, !dedupClusters.isEmpty else { return }
        busy = true; committing = true; commitPhase = "Merging & removing duplicates…"; commitDone = 0
        commitTotal = dedupClusters.reduce(0) { $0 + $1.memberIDs.count }
        cancelRequested = false; let box = cancelFlag; box.cancelled = false
        let byId = Dictionary(dedupTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        struct DJob { let keeper: URL; let keeperRel: String; let losers: [(url: URL, rel: String)] }
        var jobs: [DJob] = []
        for c in dedupClusters {
            guard let k = byId[c.keeperID] else { continue }
            let losers = c.memberIDs.filter { $0 != c.keeperID }.compactMap { byId[$0] }
                .map { (url: $0.url, rel: Self.rel($0.url, root)) }
            jobs.append(DJob(keeper: k.url, keeperRel: Self.rel(k.url, root), losers: losers))
        }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []
            var tagEdits: [(rel: String, field: String, old: String)] = []
            var artEdits: [String] = []
            var log = "Music Librarian — dedup \(Date())\nLibrary: \(root.path)\n\n"
            var done = 0
            let backfill = ["title", "artist", "album", "albumartist", "composer", "lyricist", "label", "conductor", "date", "track"]
            for job in jobs {
                if box.cancelled { break }
                // merge-of-best: fill each of the keeper's BLANK fields from a loser
                for field in backfill where (Self.readField(job.keeper, field) ?? "").isEmpty {
                    for l in job.losers {
                        let v = Self.readField(l.url, field) ?? ""
                        if !v.isEmpty {
                            do { try Self.writeField(job.keeper, field, to: v)
                                 tagEdits.append((job.keeperRel, field, ""))
                                 log += "MERGE: \(job.keeperRel)  + \(field) '\(v)' (from a duplicate)\n"
                            } catch {}
                            break
                        }
                    }
                }
                // art backfill: if the keeper has none, take a duplicate's cover
                if md_has_artwork(job.keeper.path) == 0 {
                    for l in job.losers {
                        var len: Int32 = 0, ty: Int32 = 0
                        if let b = md_copy_artwork(l.url.path, &len, &ty) {
                            let d = Data(bytes: b, count: Int(len)); free(b)
                            let mime = d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                            let rc = d.withUnsafeBytes { buf in
                                md_set_artwork(job.keeper.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(d.count), mime)
                            }
                            if rc == 0 { artEdits.append(job.keeperRel); log += "MERGE: \(job.keeperRel)  + cover (from a duplicate)\n" }
                            break
                        }
                    }
                }
                done += 1
                // move the duplicates to quarantine
                for l in job.losers {
                    if box.cancelled { break }
                    let src = root.appendingPathComponent(l.rel)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let toRel = qRel + "/" + l.rel
                    let dst = root.appendingPathComponent(toRel)
                    do {
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: src, to: dst)
                        ops.append((l.rel, toRel))
                        log += "DUPLICATE → quarantine: \(l.rel)\n"
                    } catch { log += "FAILED \(l.rel): \(error.localizedDescription)\n" }
                    done += 1
                    if done % 5 == 0 { await self.setCommitProgress("Merging & removing duplicates", done: done) }
                }
            }
            let total = ops.count + tagEdits.count + artEdits.count
            log += "\n\(total) change(s)\(box.cancelled ? " (stopped early)" : "").\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "Removed \(ops.count) duplicate(s)",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
                "perfEdits": [], "artEdits": artEdits, "artPromotions": [], "artReplacements": [],
            ]
            if total > 0, let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            } else { try? fm.removeItem(at: quarantine) }
            await self.finishDedupApply(quarantine: quarantine, removed: ops.count)
        }
    }

    private func finishDedupApply(quarantine: URL, removed: Int) {
        busy = false; committing = false; cancelRequested = false
        commitPhase = ""; commitDone = 0; commitTotal = 0
        lastQuarantine = quarantine
        dedupClusters.removeAll(); dedupTracks.removeAll(); deduped = false
        lastRunSummary = "Removed \(removed) duplicate(s)."
        status = lastRunSummary ?? status
        loadRuns()
    }

    func commit() {
        guard let root, hasWork else { return }
        busy = true; status = "Applying changes…"
        committing = true; commitPhase = "Preparing…"; commitDone = 0; cancelRequested = false
        let box = cancelFlag; box.cancelled = false
        let removals = findings.filter { $0.accepted && $0.kind.safe }.map { ($0.relPath, $0.kind.rawValue) }
        // folder merges from accepted artists that have a folder split
        let accMerges = artists.filter { $0.accepted && $0.folderMerges > 0 }
            .map { ($0.canonical, $0.folderSources) }
        let accRenames = renames.filter { $0.accepted && $0.newName != $0.oldName }
            .map { ($0.relPath, $0.newName) }
        // tag rewrites: (file, relPath, field, oldValue, newValue). Two sources —
        // the artist-split fixer (field "artist") and identify (artist/title/album).
        var accTagEdits: [(URL, String, String, String, String)] = tagWritingEnabled ? artists
            .filter { $0.accepted && $0.tagRewrites > 0 }
            .flatMap { a in a.tagMembers.filter { $0.oldName != a.canonical }
                .map { ($0.url, $0.relPath, "artist", $0.oldName, a.canonical) } } : []
        // identify proposals — each changed field becomes its own reversible edit
        if tagWritingEnabled && applyNames {
            for p in proposals where p.accepted && p.hasChange {
                if p.artistChanged && nameKindEnabled(p.artistChangeKind) { accTagEdits.append((p.url, p.relPath, "artist", p.curArtist, p.newArtist)) }
                if p.titleChanged  && nameKindEnabled(p.titleChangeKind)  { accTagEdits.append((p.url, p.relPath, "title",  p.curTitle,  p.newTitle)) }
                if p.albumChanged  && nameKindEnabled(p.albumChangeKind)  { accTagEdits.append((p.url, p.relPath, "album",  p.curAlbum,  p.chosenAlbum)) }
            }
        }
        // enrichment gap-fills (composer/label/date) — candidate values; only
        // written where the file's field is actually blank (checked at apply time)
        let accEnrich: [(URL, String, [(String, String)])] = (tagWritingEnabled && applyCredits) ? proposals
            .filter { $0.accepted }
            .compactMap { p in
                guard let e = p.enrichment, !e.isEmpty else { return nil }
                var fields: [(String, String)] = []
                if let c = e.composer { fields.append(("composer", c)) }
                if let ly = e.lyricist { fields.append(("lyricist", ly)) }
                if let l = e.label { fields.append(("label", l)) }
                if let d = e.date { fields.append(("date", d)) }
                return fields.isEmpty ? nil : (p.url, p.relPath, fields)
            } : []
        // performer credits from enrichment — added to the credits list, reversibly
        let accPerf: [(URL, String, [(String, String)])] = (tagWritingEnabled && applyCredits) ? proposals
            .filter { $0.accepted }
            .compactMap { p in
                guard let e = p.enrichment, !e.performers.isEmpty else { return nil }
                return (p.url, p.relPath, e.performers.map { ($0.name, $0.role) })
            } : []
        // cover art — grouped PER ALBUM so one image is resolved once and applied to
        // every track in it (kills the per-track patchwork and the duplicate fetches).
        // The album's release MBIDs are pooled for the lookup; empty-album tracks each
        // form their own group.
        var artJobs: [String: AlbumArtJob] = [:]
        if tagWritingEnabled && applyArtwork {
            for p in proposals where p.accepted {
                let artist = p.newArtist.isEmpty ? p.curArtist : p.newArtist
                let album = p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum
                let key = Self.foldKey(artist) + "|" + (album.isEmpty ? "single:" + p.relPath : Self.foldKey(album))
                var job = artJobs[key] ?? AlbumArtJob(artist: artist, album: album, mbids: [], files: [])
                if let m = p.enrichment?.releaseMBID, !job.mbids.contains(m) { job.mbids.append(m) }
                job.files.append((p.url, p.relPath))
                artJobs[key] = job
            }
        }
        let albumArt = Array(artJobs.values)
        // rough total for the progress bar (art files counted; merges/renames add a little)
        commitTotal = accTagEdits.count
            + accEnrich.reduce(0) { $0 + $1.2.count }
            + accPerf.reduce(0) { $0 + $1.2.count }
            + albumArt.reduce(0) { $0 + $1.files.count }
            + removals.count + accRenames.count + accMerges.count
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var done = 0
            @Sendable func bump(_ phase: String) async {
                done += 1
                if done % 5 == 0 { await self.setCommitProgress(phase, done: done) }
            }
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []   // recorded moves (root-relative)
            var tagEdits: [(rel: String, field: String, old: String)] = []  // recorded tag rewrites
            var perfEdits: [(rel: String, name: String, role: String)] = []  // recorded performer credits
            var artEdits: [String] = []                                      // rels where art was added
            var artPromotions: [(rel: String, oldType: Int)] = []            // rels whose art was retagged to front
            var artReplacements: [(rel: String, backup: String, oldType: Int)] = []  // rels whose art was replaced (old art backed up)
            var flaggedArt: [(artist: String, album: String, files: [String])] = []  // mixed albums with no cover found
            var log = "Music Librarian — change log \(Date())\nLibrary: \(root.path)\n\n"

            func move(_ fromRel: String, _ toRel: String) -> Bool {
                let from = root.appendingPathComponent(fromRel), to = root.appendingPathComponent(toRel)
                guard fm.fileExists(atPath: from.path) else { return false }
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: from, to: to)
                    ops.append((fromRel, toRel))
                    return true
                } catch { log += "FAILED \(fromRel): \(error.localizedDescription)\n"; return false }
            }

            // 0) tag rewrites — done first, while the files are still at their
            //    original locations (before any merge/rename moves them). Record
            //    the original path + field + old value so undo is exact.
            for (url, rel, field, old, new) in accTagEdits {
                if box.cancelled { break }
                do {
                    try Self.writeField(url, field, to: new)
                    tagEdits.append((rel, field, old))
                    log += "TAG: \(rel)  \(field) '\(old)' → '\(new)'\n"
                } catch { log += "FAILED tag \(rel) \(field): \(error.localizedDescription)\n" }
                await bump("Writing names & tags")
            }

            // 0b) enrichment gap-fills — only fill a field that is actually BLANK,
            //     never overwrite. Record old = "" so undo clears it again.
            for (url, rel, fields) in accEnrich {
                if box.cancelled { break }
                for (field, value) in fields where (Self.readField(url, field) ?? "").isEmpty {
                    do {
                        try Self.writeField(url, field, to: value)
                        tagEdits.append((rel, field, ""))
                        log += "TAG: \(rel)  + \(field) '\(value)' (was blank)\n"
                    } catch { log += "FAILED enrich \(rel) \(field): \(error.localizedDescription)\n" }
                    await bump("Filling in credits")
                }
            }

            // 0c) performer credits — added to the musician-credits list, recorded
            //     so undo removes exactly what was added.
            for (url, rel, people) in accPerf {
                if box.cancelled { break }
                for (name, role) in people {
                    do {
                        try Self.addPerformer(url, name: name, role: role)
                        perfEdits.append((rel, name, role))
                        log += "CREDIT: \(rel)  + \(name) (\(role))\n"
                    } catch { log += "FAILED credit \(rel): \(error.localizedDescription)\n" }
                    await bump("Adding performer credits")
                }
            }

            // 0d) cover art — UNIFY WHEN MIXED. First promote any non-front art to a
            //     Front Cover (non-destructive retag). Then, per album: if the tracks
            //     already share one cover, leave it. If they're mixed or have gaps,
            //     put the album's real cover (iTunes / Cover Art Archive) on every
            //     track — backing up each replaced image so it's fully reversible. If
            //     no cover can be found for a mixed album, flag it for manual review.
            let artClient = CoverArtClient()
            let artBackupDir = quarantine.appendingPathComponent("artwork-backups", isDirectory: true)
            var artBackupIndex = 0
            // cheap image fingerprint: byte count + a checksum of the first 64 bytes
            func artFingerprint(_ url: URL) -> String? {
                var len: Int32 = 0, type: Int32 = 0
                guard let buf = md_copy_artwork(url.path, &len, &type) else { return nil }
                let d = Data(bytes: buf, count: Int(len)); free(buf)
                return "\(len):" + String(d.prefix(64).reduce(UInt64(0)) { $0 &+ UInt64($1) })
            }
            for job in albumArt {
                if box.cancelled { break }
                // (i) promote non-front art to front cover
                for (url, rel) in job.files {
                    if md_has_artwork(url.path) == 1 && md_has_front_cover(url.path) == 0 {
                        let oldType = Int(md_artwork_type(url.path))
                        if md_set_artwork_type(url.path, 3) == 0 {
                            artPromotions.append((rel, oldType))
                            log += "ART: \(rel)  promoted picture type \(oldType) → front cover\n"
                        }
                    }
                }
                // (ii) assess consistency across the album
                await bump("Checking cover art")
                let prints = job.files.map { (f: $0, p: artFingerprint($0.url)) }
                let hasGap = prints.contains { $0.p == nil }
                let distinct = Set(prints.compactMap { $0.p })
                if !hasGap && distinct.count <= 1 { continue }   // already consistent → leave alone
                // (iii) mixed / gaps → get the album's real cover
                let cover = await artClient.albumCover(releaseMBIDs: job.mbids, artist: job.artist, album: job.album)
                guard let data = cover else {
                    flaggedArt.append((job.artist, job.album, job.files.map { $0.rel }))
                    log += "ART: album '\(job.artist) — \(job.album)' is mixed/missing but no cover was found → flagged for manual review\n"
                    continue
                }
                let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                let coverPrint = "\(data.count):" + String(data.prefix(64).reduce(UInt64(0)) { $0 &+ UInt64($1) })
                for (url, rel) in job.files {
                    await bump("Unifying cover art")
                    let cur = artFingerprint(url)
                    if cur == coverPrint { continue }            // already the album cover
                    // back up any existing art so the replace is reversible
                    if cur != nil {
                        var blen: Int32 = 0, btype: Int32 = 0
                        if let bbuf = md_copy_artwork(url.path, &blen, &btype) {
                            let bdata = Data(bytes: bbuf, count: Int(blen)); free(bbuf)
                            try? fm.createDirectory(at: artBackupDir, withIntermediateDirectories: true)
                            let backupName = "\(artBackupIndex).img"; artBackupIndex += 1
                            try? bdata.write(to: artBackupDir.appendingPathComponent(backupName))
                            artReplacements.append((rel, "artwork-backups/" + backupName, Int(btype)))
                        }
                    }
                    let rc = data.withUnsafeBytes { buf in
                        md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(data.count), mime)
                    }
                    if rc == 0 {
                        if cur == nil { artEdits.append(rel) }   // was empty → undo just strips it
                        log += "ART: \(rel)  ← album cover (\(data.count) bytes)\n"
                    } else { log += "FAILED art \(rel): rc \(rc)\n" }
                }
            }

            // 1) merges — move each non-canonical source's contents into the canonical
            //    folder, then quarantine the emptied source folder.
            if !accMerges.isEmpty || !removals.isEmpty || !accRenames.isEmpty {
                await self.setCommitProgress("Reorganising folders", done: done)
            }
            for (canonical, sources) in accMerges {
                if box.cancelled { break }
                for src in sources where src != canonical {
                    let srcDir = root.appendingPathComponent(src)
                    let children = (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? []
                    for child in children {
                        let fromRel = src + "/" + child
                        let toRel = canonical + "/" + child
                        if fm.fileExists(atPath: root.appendingPathComponent(toRel).path) {
                            // album/file already exists under the canonical — merge its
                            // files in (one level) rather than clobber
                            let sub = (try? fm.contentsOfDirectory(atPath: srcDir.appendingPathComponent(child).path)) ?? []
                            for f in sub {
                                let fFrom = fromRel + "/" + f, fTo = toRel + "/" + f
                                if !fm.fileExists(atPath: root.appendingPathComponent(fTo).path) {
                                    if move(fFrom, fTo) { log += "MERGED: \(fFrom) → \(fTo)\n" }
                                } else { log += "SKIPPED (exists): \(fTo)\n" }
                            }
                        } else if move(fromRel, toRel) {
                            log += "MERGED: \(fromRel) → \(toRel)\n"
                        }
                    }
                    // the source folder should now be empty → quarantine it
                    if move(src, qRel + "/" + src) { log += "QUARANTINED (emptied): \(src)\n" }
                }
            }

            // 2) removals — junk + empty folders → quarantine (deepest first)
            if !box.cancelled {
                for (rel, kind) in removals.sorted(by: { $0.0.count > $1.0.count }) {
                    if move(rel, qRel + "/" + rel) { log += "QUARANTINED (\(kind)): \(rel)\n" }
                }
            }

            // 3) rename untidy folders (deepest first; nested renames were excluded
            //    at detection so no parent-rename invalidates a child path)
            if !box.cancelled {
                for (rel, newName) in accRenames.sorted(by: { $0.0.count > $1.0.count }) {
                    let parent = (rel as NSString).deletingLastPathComponent
                    let toRel = parent.isEmpty ? newName : parent + "/" + newName
                    if move(rel, toRel) { log += "RENAMED: \(rel) → \(toRel)\n" }
                }
            }

            let total = ops.count + tagEdits.count + perfEdits.count + artEdits.count
                        + artPromotions.count + artReplacements.count
            let wasCancelled = box.cancelled
            log += "\n\(total) change(s)\(wasCancelled ? " (stopped early — you pressed Cancel)" : ""). Restore with 'Undo this run'.\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)

            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "\(total) change(s) applied\(wasCancelled ? " (cancelled)" : "")",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
                "perfEdits": perfEdits.map { ["rel": $0.rel, "name": $0.name, "role": $0.role] },
                "artEdits": artEdits,
                "artPromotions": artPromotions.map { ["rel": $0.rel, "oldType": String($0.oldType)] },
                "artReplacements": artReplacements.map { ["rel": $0.rel, "backup": $0.backup, "oldType": String($0.oldType)] },
            ]
            if total > 0, let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            } else if total == 0 {
                // nothing was applied (cancelled before any change) — leave no empty run
                try? fm.removeItem(at: quarantine)
            }
            await self.finishCommit(count: total, quarantine: quarantine, cancelled: wasCancelled,
                                    flagged: flaggedArt.map { ArtworkReviewItem(artist: $0.artist, album: $0.album, files: $0.files) })
        }
    }

    private func finishCommit(count: Int, quarantine: URL, cancelled: Bool = false,
                              flagged: [ArtworkReviewItem] = []) {
        busy = false
        committing = false; cancelRequested = false
        artworkNeedsReview = flagged
        commitPhase = ""; commitDone = 0; commitTotal = 0
        lastQuarantine = quarantine
        lastRunSummary = cancelled ? "Stopped — applied \(count) change(s) before you cancelled."
                                   : "Applied \(count) change(s)."
        findings.removeAll { $0.accepted && $0.kind.safe }
        renames.removeAll { $0.accepted && $0.newName != $0.oldName }
        artists.removeAll { $0.accepted && artistHasApplicableWork($0) }
        proposals.removeAll { $0.accepted && $0.hasChange }
        status = lastRunSummary ?? status
        loadRuns()
    }

    // MARK: Manual artwork review (albums flagged during commit)

    /// The distinct covers already embedded across a flagged album's tracks, so the
    /// picker can offer "use one of these" as thumbnails.
    func existingCovers(for item: ArtworkReviewItem) -> [Data] {
        guard let root else { return [] }
        var seen = Set<String>(); var out: [Data] = []
        for rel in item.files {
            let url = root.appendingPathComponent(rel)
            var len: Int32 = 0, type: Int32 = 0
            guard let buf = md_copy_artwork(url.path, &len, &type) else { continue }
            let d = Data(bytes: buf, count: Int(len)); free(buf)
            let key = "\(len):" + String(d.prefix(64).reduce(UInt64(0)) { $0 &+ UInt64($1) })
            if seen.insert(key).inserted { out.append(d) }
        }
        return out
    }

    /// Re-run the online search for a flagged album (editable artist/album).
    func researchCover(artist: String, album: String) async -> Data? {
        await CoverArtClient().itunesCover(artist: artist, album: album)
    }

    /// Apply a chosen cover to every track of a flagged album — backing up any
    /// existing art so it's reversible — and drop the album from the review list.
    func applyChosenArtwork(item: ArtworkReviewItem, image: Data) {
        guard let root else { return }
        busy = true; status = "Setting cover for \(item.album)…"
        let files = item.files
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let backupDir = quarantine.appendingPathComponent("artwork-backups", isDirectory: true)
            let mime = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            var artEdits: [String] = []
            var artReplacements: [(rel: String, backup: String, oldType: Int)] = []
            var idx = 0
            var log = "Music Librarian — manual artwork \(Date())\nAlbum: \(item.artist) — \(item.album)\n\n"
            for rel in files {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                var l: Int32 = 0, t: Int32 = 0
                if let b = md_copy_artwork(url.path, &l, &t) {
                    let bd = Data(bytes: b, count: Int(l)); free(b)
                    try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    let name = "\(idx).img"; idx += 1
                    try? bd.write(to: backupDir.appendingPathComponent(name))
                    artReplacements.append((rel, "artwork-backups/" + name, Int(t)))
                } else { artEdits.append(rel) }
                let rc = image.withUnsafeBytes { buf in
                    md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(image.count), mime)
                }
                log += rc == 0 ? "ART: \(rel)  ← chosen cover\n" : "FAILED art \(rel): rc \(rc)\n"
            }
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "Cover set for \(item.album) (\(files.count) track(s))",
                "ops": [], "tagEdits": [], "perfEdits": [],
                "artEdits": artEdits,
                "artPromotions": [],
                "artReplacements": artReplacements.map { ["rel": $0.rel, "backup": $0.backup, "oldType": String($0.oldType)] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            }
            await self.finishArtworkChoice(item: item, quarantine: quarantine)
        }
    }

    private func finishArtworkChoice(item: ArtworkReviewItem, quarantine: URL) {
        busy = false
        lastQuarantine = quarantine
        artworkNeedsReview.removeAll { $0.id == item.id }
        status = "Cover set for \(item.album)."
        loadRuns()
    }

    /// Dismiss a flagged album without touching its art ("leave as-is").
    func skipArtworkReview(_ item: ArtworkReviewItem) {
        artworkNeedsReview.removeAll { $0.id == item.id }
    }

    // MARK: Run history + undo

    func loadRuns() {
        guard let root else { runs = []; return }
        let qroot = root.appendingPathComponent("Music Librarian Quarantine", isDirectory: true)
        let fm = FileManager.default
        var found: [RunRecord] = []
        if let subs = try? fm.contentsOfDirectory(at: qroot, includingPropertiesForKeys: nil) {
            for sub in subs {
                guard let data = try? Data(contentsOf: sub.appendingPathComponent("run.json")),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let date = ISO8601DateFormatter().date(from: obj["date"] as? String ?? "") ?? Date(timeIntervalSince1970: 0)
                let ops = (obj["ops"] as? [[String: String]] ?? []).compactMap { d -> (String, String)? in
                    guard let f = d["from"], let t = d["to"] else { return nil }; return (f, t)
                }
                let tagEdits = (obj["tagEdits"] as? [[String: String]] ?? []).compactMap { d -> (String, String, String)? in
                    guard let r = d["rel"], let o = d["old"] else { return nil }
                    return (r, d["field"] ?? "artist", o)   // default field for older runs
                }
                let perfEdits = (obj["perfEdits"] as? [[String: String]] ?? []).compactMap { d -> (String, String, String)? in
                    guard let r = d["rel"], let n = d["name"], let ro = d["role"] else { return nil }; return (r, n, ro)
                }
                let artEdits = obj["artEdits"] as? [String] ?? []
                let artPromotions = (obj["artPromotions"] as? [[String: String]] ?? []).compactMap { d -> (String, Int)? in
                    guard let r = d["rel"] else { return nil }; return (r, Int(d["oldType"] ?? "0") ?? 0)
                }
                let artReplacements = (obj["artReplacements"] as? [[String: String]] ?? []).compactMap { d -> (String, String, Int)? in
                    guard let r = d["rel"], let b = d["backup"] else { return nil }; return (r, b, Int(d["oldType"] ?? "0") ?? 0)
                }
                let n = ops.count + tagEdits.count + perfEdits.count + artEdits.count + artPromotions.count + artReplacements.count
                found.append(RunRecord(id: sub.lastPathComponent, folder: sub, date: date,
                                       ops: ops, tagEdits: tagEdits, perfEdits: perfEdits, artEdits: artEdits,
                                       artPromotions: artPromotions, artReplacements: artReplacements,
                                       summary: obj["summary"] as? String ?? "\(n) changes"))
            }
        }
        runs = found.sorted { $0.date > $1.date }
    }

    /// Reverse a run: move each recorded change back (to → from), newest moves
    /// first, then remove the emptied quarantine folder.
    func undo(_ run: RunRecord) {
        guard let root else { return }
        busy = true; status = "Undoing run…"
        let folder = run.folder, ops = run.ops, tagEdits = run.tagEdits, perfEdits = run.perfEdits, artEdits = run.artEdits
        let artPromotions = run.artPromotions, artReplacements = run.artReplacements
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var restored = 0, failed = 0

            // merge-aware restore: never clobber an existing directory (the emptied
            // source folder of a merge is restored into one the file-restores have
            // already rebuilt) — merge its contents in instead.
            func restore(_ from: URL, _ to: URL) -> Bool {
                let fromIsDir = (try? from.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let toExists = fm.fileExists(atPath: to.path)
                if fromIsDir && toExists {
                    for child in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                        _ = restore(from.appendingPathComponent(child), to.appendingPathComponent(child))
                    }
                    try? fm.removeItem(at: from)   // now-empty source shell
                    return true
                }
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if toExists { try? fm.removeItem(at: to) }
                    try fm.moveItem(at: from, to: to)
                    return true
                } catch { return false }
            }

            // deepest `to` first so files come out before their quarantined parent
            for op in ops.reversed().sorted(by: { $0.to.count > $1.to.count }) {
                let from = root.appendingPathComponent(op.to)     // where it is now
                let to = root.appendingPathComponent(op.from)      // where it belongs
                guard fm.fileExists(atPath: from.path) else { continue }
                if restore(from, to) { restored += 1 } else { failed += 1 }
            }

            // restore tag rewrites — the files are back at their original paths now,
            // so write each old artist spelling back into place.
            for edit in tagEdits {
                let url = root.appendingPathComponent(edit.rel)
                guard fm.fileExists(atPath: url.path) else { failed += 1; continue }
                do { try Self.writeField(url, edit.field, to: edit.old); restored += 1 } catch { failed += 1 }
            }
            // remove any performer credits this run added
            for edit in perfEdits {
                let url = root.appendingPathComponent(edit.rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                Self.removePerformer(url, name: edit.name, role: edit.role); restored += 1
            }
            // strip any cover art this run added
            for rel in artEdits {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                _ = md_remove_artwork(url.path); restored += 1
            }
            // put any promoted picture back to its original type (non-destructive)
            for (rel, oldType) in artPromotions {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                _ = md_set_artwork_type(url.path, Int32(oldType)); restored += 1
            }
            // restore any replaced art from its backup (read BEFORE the quarantine
            // folder is removed below), then put the original picture type back
            for (rel, backup, oldType) in artReplacements {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path),
                      let bdata = try? Data(contentsOf: folder.appendingPathComponent(backup)) else { continue }
                let mime = bdata.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                let rc = bdata.withUnsafeBytes { buf in
                    md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(bdata.count), mime)
                }
                if rc == 0 { _ = md_set_artwork_type(url.path, Int32(oldType)); restored += 1 }
            }

            try? fm.removeItem(at: folder)
            let qroot = root.appendingPathComponent("Music Librarian Quarantine")
            if let empty = try? fm.contentsOfDirectory(atPath: qroot.path), empty.isEmpty {
                try? fm.removeItem(at: qroot)
            }
            await self.finishUndo(restored: restored, failed: failed)
        }
    }

    private func finishUndo(restored: Int, failed: Int) {
        busy = false
        lastRunSummary = nil
        status = "Restored \(restored) change(s)" + (failed > 0 ? ", \(failed) failed." : ".") + " Re-diagnosing…"
        loadRuns()
        // the library changed back — re-scan so the review reflects the restored
        // state accurately (works for undoing any run, recent or from history)
        if diagnosed { diagnose() }
    }

    // MARK: Detection helpers

    nonisolated static func rel(_ u: URL, _ root: URL) -> String {
        let p = u.path, base = root.path
        if p.hasPrefix(base) {
            var r = String(p.dropFirst(base.count))
            if r.hasPrefix("/") { r.removeFirst() }
            return r
        }
        return u.lastPathComponent
    }

    nonisolated static func junkReason(_ u: URL) -> String? {
        let name = u.lastPathComponent
        if name == ".DS_Store" { return "macOS folder metadata" }
        if name.hasPrefix("._") { return "macOS AppleDouble metadata" }
        if name == "Thumbs.db" || name == "desktop.ini" { return "Windows metadata" }
        if name.hasSuffix(".crswap") { return "leftover temporary file" }
        if name.contains("smbdelete") { return "leftover server-delete marker" }
        return nil
    }

    nonisolated static let audioExts: Set<String> = ["mp3","m4a","m4p","aac","flac","wav","aiff","aif","alac","ogg","wma","opus"]
    nonisolated static func isAudio(_ u: URL) -> Bool { audioExts.contains(u.pathExtension.lowercased()) }

    /// FairPlay-protected content is reported by AVFoundation directly.
    nonisolated static func isDRM(_ u: URL) async -> Bool {
        let ext = u.pathExtension.lowercased()
        if ext == "m4p" { return true }   // fast path
        guard ext == "m4a" || ext == "mp4" || ext == "aac" else { return false }
        return (try? await AVURLAsset(url: u).load(.hasProtectedContent)) ?? false
    }
}
