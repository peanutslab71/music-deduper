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
import SwiftUI

// MARK: - Model

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

/// A committed run, reconstructed from its quarantine folder's run.json, so it
/// can be listed and undone. Every change is one move (from → to), both paths
/// relative to the library root; undo reverses them.
struct RunRecord: Identifiable {
    let id: String          // quarantine subfolder name (timestamp)
    let folder: URL         // the run's quarantine folder
    let date: Date
    let ops: [(from: String, to: String)]   // each move, root-relative
    let summary: String
}

// MARK: - Store

@MainActor
final class PerfectStore: ObservableObject {
    @Published var root: URL?
    @Published var status = "Choose a music library to diagnose."
    @Published var busy = false
    @Published var progress = ""
    @Published var findings: [PerfectFinding] = []
    @Published var merges: [MergeProposal] = []
    @Published var diagnosed = false

    // commit-result summary
    @Published var lastRunSummary: String?
    @Published var lastQuarantine: URL?

    // persistent run history (each run's quarantine folder holds a run.json)
    @Published var runs: [RunRecord] = []

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
                                               fileCounts: counts, accepted: false))
            }

            let (ff, fo, fb) = (files, folders, bytes)
            await self.finishDiagnose(found: found, merges: proposals.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() },
                                      files: ff, folders: fo, bytes: fb, cancelled: box.cancelled)
        }
    }

    private func setProgress(_ s: String) { progress = s }

    private func finishDiagnose(found: [PerfectFinding], merges m: [MergeProposal],
                               files: Int, folders: Int, bytes: Int64, cancelled: Bool) {
        findings = found.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        merges = m
        totalFiles = files; totalFolders = folders; totalBytes = bytes
        busy = false; diagnosed = !cancelled; progress = ""
        let junk = found.filter { $0.kind == .junk }.count
        let empties = found.filter { $0.kind == .emptyFolder }.count
        let drm = found.filter { $0.kind == .drm }.count
        var parts = ["\(files) files · \(folders) folders · \(fmtBytes(bytes))"]
        var found2: [String] = []
        if junk > 0 { found2.append("\(junk) junk") }
        if empties > 0 { found2.append("\(empties) empty folder(s)") }
        if !m.isEmpty { found2.append("\(m.count) duplicate artist(s)") }
        if drm > 0 { found2.append("\(drm) protected track(s)") }
        if !found2.isEmpty { parts.append("found " + found2.joined(separator: ", ")) }
        status = cancelled ? "Diagnosis cancelled." : parts.joined(separator: " — ") + "."
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

    // MARK: Commit — apply accepted removals + merges as a log of reversible moves

    var hasWork: Bool {
        findings.contains { $0.accepted && $0.kind.safe } || merges.contains { $0.accepted }
    }

    func commit() {
        guard let root, hasWork else { return }
        busy = true; status = "Applying changes…"
        let removals = findings.filter { $0.accepted && $0.kind.safe }.map { ($0.relPath, $0.kind.rawValue) }
        let accMerges = merges.filter { $0.accepted }.map { ($0.canonical, $0.sources) }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []   // recorded moves (root-relative)
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

            log += "\n\(ops.count) change(s). Restore with 'Undo this run'.\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)

            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "\(ops.count) change(s) applied",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            }
            await self.finishCommit(count: ops.count, quarantine: quarantine)
        }
    }

    private func finishCommit(count: Int, quarantine: URL) {
        busy = false
        lastQuarantine = quarantine
        lastRunSummary = "Applied \(count) change(s)."
        findings.removeAll { $0.accepted && $0.kind.safe }
        merges.removeAll { $0.accepted }
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
                found.append(RunRecord(id: sub.lastPathComponent, folder: sub, date: date,
                                       ops: ops, summary: obj["summary"] as? String ?? "\(ops.count) changes"))
            }
        }
        runs = found.sorted { $0.date > $1.date }
    }

    /// Reverse a run: move each recorded change back (to → from), newest moves
    /// first, then remove the emptied quarantine folder.
    func undo(_ run: RunRecord) {
        guard let root else { return }
        busy = true; status = "Undoing run…"
        let folder = run.folder, ops = run.ops
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
        status = "Restored \(restored) change(s)" + (failed > 0 ? ", \(failed) failed." : ".") + " Re-diagnose to see them again."
        loadRuns()
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
