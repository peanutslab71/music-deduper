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
    let summary: String
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

    // persistent run history (each run's quarantine folder holds a run.json)
    @Published var runs: [RunRecord] = []

    @Published var checkingTags = false
    @Published var tagProgress = ""

    // identify (acoustic fingerprint → AcoustID → proposed correct names)
    @Published var proposals: [TrackProposal] = []
    @Published var identifying = false
    @Published var identifyProgress = ""
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
        findings = []; renames = []; artists = []; folderGroups = []; tagGroups = []; proposals = []
        diagnosed = false
        lastRunSummary = nil
        loadRuns()
        if autoRun {
            explore()
        } else {
            status = "Ready — press Run to explore \(url.lastPathComponent)."
        }
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

    func cancel() { cancelFlag.cancelled = true }

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

    // MARK: Commit — apply accepted removals + merges as a log of reversible moves

    var hasWork: Bool {
        findings.contains { $0.accepted && $0.kind.safe }
            || renames.contains { $0.accepted && $0.newName != $0.oldName }
            || artists.contains { $0.accepted && artistHasApplicableWork($0) }
            || (tagWritingEnabled && proposals.contains { $0.accepted && $0.hasChange })
    }

    // MARK: Identify — fingerprint each track and propose the correct names

    func identify() {
        guard let root, hasAcoustIDKey, !identifying else { return }
        identifying = true; proposals = []; identifyProgress = "Identifying…"
        let box = cancelFlag; box.cancelled = false
        let id = Identifier(apiKey: Identifier.configuredKey)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // collect audio files
            var files: [URL] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = en.nextObject() as? URL { if Self.isAudio(u) { files.append(u) } }
            }
            var found: [TrackProposal] = []
            var done = 0
            for u in files {
                if box.cancelled { break }
                let rel = Self.rel(u, root)
                let curA = Self.readField(u, "artist") ?? ""
                let curT = Self.readField(u, "title") ?? ""
                let curAl = Self.readField(u, "album") ?? ""
                if let p = try? await id.identify(url: u, relPath: rel,
                                                  curArtist: curA, curTitle: curT, curAlbum: curAl),
                   p.hasChange {
                    found.append(p)
                }
                done += 1
                if done % 3 == 0 { await self.setIdentifyProgress("Identified \(done)/\(files.count)…") }
                // AcoustID asks for max 3 requests/second per key
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            await self.finishIdentify(proposals: found, total: files.count, cancelled: box.cancelled)
        }
    }

    private func setIdentifyProgress(_ s: String) { identifyProgress = s }

    private func finishIdentify(proposals p: [TrackProposal], total: Int, cancelled: Bool) {
        identifying = false; identifyProgress = ""
        proposals = p.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        if !cancelled {
            status = p.isEmpty
                ? "Identified \(total) tracks — nothing to correct."
                : "Identified \(total) tracks — \(p.count) with suggested corrections."
        }
    }

    func commit() {
        guard let root, hasWork else { return }
        busy = true; status = "Applying changes…"
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
        for p in proposals where p.accepted && p.hasChange {
            if p.artistChanged { accTagEdits.append((p.url, p.relPath, "artist", p.curArtist, p.newArtist)) }
            if p.titleChanged  { accTagEdits.append((p.url, p.relPath, "title",  p.curTitle,  p.newTitle)) }
            if p.albumChanged  { accTagEdits.append((p.url, p.relPath, "album",  p.curAlbum,  p.chosenAlbum)) }
        }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []   // recorded moves (root-relative)
            var tagEdits: [(rel: String, field: String, old: String)] = []  // recorded tag rewrites
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
                do {
                    try Self.writeField(url, field, to: new)
                    tagEdits.append((rel, field, old))
                    log += "TAG: \(rel)  \(field) '\(old)' → '\(new)'\n"
                } catch { log += "FAILED tag \(rel) \(field): \(error.localizedDescription)\n" }
            }

            // 1) merges — move each non-canonical source's contents into the canonical
            //    folder, then quarantine the emptied source folder.
            for (canonical, sources) in accMerges {
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
            for (rel, kind) in removals.sorted(by: { $0.0.count > $1.0.count }) {
                if move(rel, qRel + "/" + rel) { log += "QUARANTINED (\(kind)): \(rel)\n" }
            }

            // 3) rename untidy folders (deepest first; nested renames were excluded
            //    at detection so no parent-rename invalidates a child path)
            for (rel, newName) in accRenames.sorted(by: { $0.0.count > $1.0.count }) {
                let parent = (rel as NSString).deletingLastPathComponent
                let toRel = parent.isEmpty ? newName : parent + "/" + newName
                if move(rel, toRel) { log += "RENAMED: \(rel) → \(toRel)\n" }
            }

            let total = ops.count + tagEdits.count
            log += "\n\(total) change(s). Restore with 'Undo this run'.\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)

            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "\(total) change(s) applied",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            }
            await self.finishCommit(count: total, quarantine: quarantine)
        }
    }

    private func finishCommit(count: Int, quarantine: URL) {
        busy = false
        lastQuarantine = quarantine
        lastRunSummary = "Applied \(count) change(s)."
        findings.removeAll { $0.accepted && $0.kind.safe }
        renames.removeAll { $0.accepted && $0.newName != $0.oldName }
        artists.removeAll { $0.accepted && artistHasApplicableWork($0) }
        proposals.removeAll { $0.accepted && $0.hasChange }
        status = lastRunSummary ?? status
        loadRuns()
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
                let n = ops.count + tagEdits.count
                found.append(RunRecord(id: sub.lastPathComponent, folder: sub, date: date,
                                       ops: ops, tagEdits: tagEdits,
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
        let folder = run.folder, ops = run.ops, tagEdits = run.tagEdits
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
