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
import SFBAudioEngine
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

/// A proposed merge of several folders whose names mean the same artist
/// (e.g. "Buzzcocks" + "The Buzzcocks"). The user picks which name to keep.
struct MergeProposal: Identifiable {
    let id = UUID()
    let key: String                 // normalized collision key
    var canonical: String           // chosen folder name to keep (one of `sources`)
    let sources: [String]           // the colliding top-level folder names
    let fileCounts: [Int]           // audio-file count per source (same order)
    var accepted: Bool
}

/// One file caught in a tag-level artist split, with the exact artist spelling
/// currently written in it — kept so a fix can be applied and exactly reversed.
struct TagMember {
    let url: URL
    let relPath: String
    let oldName: String
}

/// One artist that appears in the embedded tags under several spellings
/// (e.g. "Buzzcocks" and "The Buzzcocks") — a tag-level split that servers
/// like Roon read as two different artists. The user picks the one correct
/// spelling; every other spelling's tags are rewritten to it.
struct TagArtistGroup: Identifiable {
    let id = UUID()
    let key: String
    let variants: [(name: String, count: Int)]   // spelling → track count
    var canonical: String                        // editable — the spelling to keep
    var accepted: Bool
    let members: [TagMember]                      // every file in the group
    var willChange: Int { members.filter { $0.oldName != canonical }.count }
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
    let tagEdits: [(rel: String, old: String)]  // each artist-tag rewrite, for exact undo
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
    @Published var status = "Choose a music library to diagnose."
    @Published var busy = false
    @Published var progress = ""
    @Published var findings: [PerfectFinding] = []
    @Published var merges: [MergeProposal] = []
    @Published var renames: [RenameProposal] = []
    @Published var diagnosed = false

    // commit-result summary
    @Published var lastRunSummary: String?
    @Published var lastQuarantine: URL?

    // persistent run history (each run's quarantine folder holds a run.json)
    @Published var runs: [RunRecord] = []

    // tag-level artist inconsistencies (Phase 2 preview — read-only for now)
    @Published var tagGroups: [TagArtistGroup] = []
    @Published var checkingTags = false
    @Published var tagProgress = ""

    private let cancelFlag = CancelBox()

    // scanned totals for the header
    @Published var totalFiles = 0
    @Published var totalFolders = 0
    @Published var totalBytes: Int64 = 0

    func setRoot(_ url: URL) {
        root = url
        findings = []
        diagnosed = false
        lastRunSummary = nil
        status = "Ready to diagnose \(url.lastPathComponent)."
        loadRuns()
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
                for case let u as URL in en {
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
                    } else if Self.isAudio(u), Self.isDRM(u) {
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
            var proposals: [MergeProposal] = []
            let topDirs = allDirs.filter { $0.deletingLastPathComponent().path == root.path
                                           && $0.lastPathComponent != "Music Librarian Quarantine" }
            var byKey: [String: [URL]] = [:]
            for d in topDirs { byKey[Self.artistKey(d.lastPathComponent), default: []].append(d) }
            for (key, dirs) in byKey where dirs.count > 1 {
                let names = dirs.map { $0.lastPathComponent }
                let counts = dirs.map { d in
                    (fm.enumerator(at: d, includingPropertiesForKeys: nil)?
                        .allObjects.compactMap { $0 as? URL }.filter { Self.isAudio($0) }.count) ?? 0
                }
                // default: keep the name with the most audio (ties: the "The …" form)
                let best = zip(names, counts).max { a, b in
                    a.1 != b.1 ? a.1 < b.1 : (!a.0.lowercased().hasPrefix("the ") && b.0.lowercased().hasPrefix("the "))
                }?.0 ?? names[0]
                proposals.append(MergeProposal(key: key, canonical: best, sources: names,
                                               fileCounts: counts, accepted: true))
            }

            // bad folder names — safe cosmetic tidy. Skip empties (being removed)
            // and anything under a merge source (its contents move during merge).
            let emptyPaths = Set(found.filter { $0.kind == .emptyFolder }.map { $0.url.path })
            let mergeSrcRoots = proposals.flatMap { p in p.sources.map { root.appendingPathComponent($0).path + "/" } }
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
            await self.finishDiagnose(found: found,
                                      merges: proposals.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() },
                                      renames: filteredRenames.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() },
                                      files: ff, folders: fo, bytes: fb, cancelled: box.cancelled)
        }
    }

    private func setProgress(_ s: String) { progress = s }

    private func finishDiagnose(found: [PerfectFinding], merges m: [MergeProposal],
                               renames r: [RenameProposal],
                               files: Int, folders: Int, bytes: Int64, cancelled: Bool) {
        findings = found.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        // gate by thoroughness (junk/empties/DRM always; renames Standard+; merges Thorough)
        merges = thoroughness.doesMerges ? m : []
        renames = thoroughness.doesRenames ? r : []
        totalFiles = files; totalFolders = folders; totalBytes = bytes
        busy = false; diagnosed = !cancelled; progress = ""
        let junk = found.filter { $0.kind == .junk }.count
        let empties = found.filter { $0.kind == .emptyFolder }.count
        let drm = found.filter { $0.kind == .drm }.count
        var parts = ["\(files) files · \(folders) folders · \(fmtBytes(bytes))"]
        var found2: [String] = []
        if junk > 0 { found2.append("\(junk) junk") }
        if empties > 0 { found2.append("\(empties) empty folder(s)") }
        if !merges.isEmpty { found2.append("\(merges.count) duplicate artist(s)") }
        if !renames.isEmpty { found2.append("\(renames.count) untidy name(s)") }
        if drm > 0 { found2.append("\(drm) protected track(s)") }
        if !found2.isEmpty { parts.append("found " + found2.joined(separator: ", ")) }
        status = cancelled ? "Diagnosis cancelled." : parts.joined(separator: " — ") + "."
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
        checkingTags = true; tagGroups = []; tagProgress = "Reading tags…"
        let box = cancelFlag
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var counts: [String: Int] = [:]     // exact artist string → track count
            var filesByName: [String: [URL]] = [:]  // exact artist string → its files
            var seen = 0
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let u as URL in en {
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
            let groups = byKey.compactMap { (k, v) -> TagArtistGroup? in
                guard v.count > 1 else { return nil }
                let variants = v.sorted { $0.1 > $1.1 }
                let canonical = variants[0].0          // default: the most common spelling
                let members = variants.flatMap { (name, _) in
                    (filesByName[name] ?? []).map { TagMember(url: $0, relPath: Self.rel($0, root), oldName: name) }
                }
                return TagArtistGroup(key: k, variants: variants, canonical: canonical,
                                      accepted: true, members: members)
            }.sorted { $0.variants[0].name.lowercased() < $1.variants[0].name.lowercased() }
            await self.finishTagCheck(groups: groups, tracks: seen, cancelled: box.cancelled)
        }
    }

    private func setTagProgress(_ s: String) { tagProgress = s }

    private func finishTagCheck(groups: [TagArtistGroup], tracks: Int, cancelled: Bool) {
        checkingTags = false; tagProgress = ""
        tagGroups = groups
        if !cancelled {
            status = groups.isEmpty
                ? "Read \(tracks) tags — no split artist spellings found."
                : "Read \(tracks) tags — \(groups.count) artist(s) split across different spellings."
        }
    }

    /// Read the artist tag from a file's embedded metadata. Uses the same
    /// engine (SFBAudioEngine/TagLib) that writes it, so a recorded "old" value
    /// exactly matches what a rewrite would overwrite — undo is then exact.
    nonisolated static func readArtist(_ url: URL) -> String? {
        guard let f = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return nil }
        let s = f.metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Write the artist tag, preserving all other metadata.
    nonisolated static func writeArtist(_ url: URL, to value: String) throws {
        let f = try AudioFile(readingPropertiesAndMetadataFrom: url)
        f.metadata.artist = value
        try f.writeMetadata()
    }

    // MARK: Commit — apply accepted removals + merges as a log of reversible moves

    var hasWork: Bool {
        findings.contains { $0.accepted && $0.kind.safe }
            || merges.contains { $0.accepted }
            || renames.contains { $0.accepted && $0.newName != $0.oldName }
            || tagGroups.contains { $0.accepted && $0.willChange > 0 }
    }

    func commit() {
        guard let root, hasWork else { return }
        busy = true; status = "Applying changes…"
        let removals = findings.filter { $0.accepted && $0.kind.safe }.map { ($0.relPath, $0.kind.rawValue) }
        let accMerges = merges.filter { $0.accepted }.map { ($0.canonical, $0.sources) }
        let accRenames = renames.filter { $0.accepted && $0.newName != $0.oldName }
            .map { ($0.relPath, $0.newName) }
        // tag rewrites: (file, relPath, oldArtist, newArtist) for every member
        // whose current spelling differs from the chosen canonical one
        let accTagEdits: [(URL, String, String, String)] = tagGroups
            .filter { $0.accepted && $0.willChange > 0 }
            .flatMap { g in g.members.filter { $0.oldName != g.canonical }
                .map { ($0.url, $0.relPath, $0.oldName, g.canonical) } }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []   // recorded moves (root-relative)
            var tagEdits: [(rel: String, old: String)] = []  // recorded artist rewrites
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

            // 0) artist-tag rewrites — done first, while the files are still at
            //    their original locations (before any merge/rename moves them).
            //    Record the original path + old spelling so undo is exact.
            for (url, rel, old, new) in accTagEdits {
                do {
                    try Self.writeArtist(url, to: new)
                    tagEdits.append((rel, old))
                    log += "TAG: \(rel)  artist '\(old)' → '\(new)'\n"
                } catch { log += "FAILED tag \(rel): \(error.localizedDescription)\n" }
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
                "tagEdits": tagEdits.map { ["rel": $0.rel, "old": $0.old] },
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
        merges.removeAll { $0.accepted }
        renames.removeAll { $0.accepted && $0.newName != $0.oldName }
        tagGroups.removeAll { $0.accepted && $0.willChange > 0 }
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
                let tagEdits = (obj["tagEdits"] as? [[String: String]] ?? []).compactMap { d -> (String, String)? in
                    guard let r = d["rel"], let o = d["old"] else { return nil }; return (r, o)
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
                do { try Self.writeArtist(url, to: edit.old); restored += 1 } catch { failed += 1 }
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
    nonisolated static func isDRM(_ u: URL) -> Bool {
        if u.pathExtension.lowercased() == "m4p" { return true }   // fast path
        let ext = u.pathExtension.lowercased()
        guard ext == "m4a" || ext == "mp4" || ext == "aac" else { return false }
        return AVURLAsset(url: u).hasProtectedContent
    }
}
