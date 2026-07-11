//
//  LibraryWindows.swift
//  MusicDeduper
//
//  The "Library" menu's three tool windows: Library Viewer (browse the library
//  with tags + the built-in player), Runs (every applied run, revert any), and
//  Logs (each run's change log, list on the left, content on the right).
//

import SwiftUI
import AppKit

// MARK: - Library Viewer

struct LibraryViewerView: View {
    @EnvironmentObject private var perfect: PerfectStore
    @ObservedObject private var audio = AudioPreview.shared
    @State private var tracks: [Track] = []
    @State private var loading = false
    @State private var search = ""

    private var filtered: [Track] {
        guard !search.isEmpty else { return tracks }
        let q = search.lowercased()
        return tracks.filter {
            $0.title.lowercased().contains(q) || $0.displayArtist.lowercased().contains(q)
                || $0.album.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").foregroundStyle(.purple)
                Text(perfect.root?.lastPathComponent ?? "Library Viewer").font(.headline)
                Text("\(tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Search title / artist / album", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(perfect.root == nil || loading)
            }
            .padding(10)
            Divider()
            if perfect.root == nil {
                placeholder("Open a music library in the main window first.")
            } else if loading {
                VStack(spacing: 10) { ProgressView(); Text("Reading tags…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                placeholder("No audio files found.")
            } else {
                trackTable
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { if tracks.isEmpty { load() } }
    }

    private var trackTable: some View {
        Table(filtered) {
            TableColumn("") { t in
                Button { audio.toggle(t.url) } label: {
                    Image(systemName: audio.playingURL == t.url ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(audio.playingURL == t.url ? .red : .teal)
                }.buttonStyle(.plain)
            }.width(28)
            TableColumn("#") { t in
                Text(t.trackNo > 0 ? (t.discNo > 1 ? "\(t.discNo)-\(t.trackNo)" : "\(t.trackNo)") : "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(44)
            TableColumn("Title", value: \.title)
            TableColumn("Artist") { t in Text(t.displayArtist) }
            TableColumn("Album", value: \.album)
            TableColumn("Time") { t in Text(fmtDur(t.duration)).monospacedDigit().foregroundStyle(.secondary) }.width(52)
            TableColumn("Format") { t in Text(t.formatLabel).font(.caption).monospaced().foregroundStyle(.secondary) }.width(90)
        }
    }

    private func placeholder(_ msg: String) -> some View {
        Text(msg).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        guard let root = perfect.root else { return }
        loading = true
        Task {
            let fm = FileManager.default
            var built: [Track] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in en {
                    guard PerfectStore.isAudio(u) else { continue }
                    if PerfectStore.rel(u, root).hasPrefix("Music Librarian Quarantine") { continue }
                    let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    var t = await readMetadata(url: u, size: size)
                    t.id = built.count
                    if t.title.isEmpty { t.title = u.deletingPathExtension().lastPathComponent }
                    built.append(t)
                }
            }
            let sorted = built.sorted {
                ($0.displayArtist.lowercased(), $0.album.lowercased(), $0.discNo, $0.trackNo)
                    < ($1.displayArtist.lowercased(), $1.album.lowercased(), $1.discNo, $1.trackNo)
            }
            await MainActor.run { tracks = sorted; loading = false }
        }
    }
}

// MARK: - Runs

struct RunsView: View {
    @EnvironmentObject private var perfect: PerfectStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.purple)
                Text("Runs").font(.headline)
                if perfect.root != nil { Text("\(perfect.runs.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { perfect.loadRuns() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(perfect.root == nil)
            }
            .padding(10)
            Divider()
            if perfect.root == nil {
                placeholder("Open a music library in the main window first.")
            } else if perfect.runs.isEmpty {
                placeholder("No runs yet — nothing has been applied to this library.")
            } else {
                List(perfect.runs) { run in runRow(run) }
                    .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { perfect.loadRuns() }
    }

    private func runRow(_ run: RunRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.df.string(from: run.date)).fontWeight(.medium).monospacedDigit()
                Text(run.summary).font(.caption).foregroundStyle(.secondary)
                Text(breakdown(run)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Change log") {
                NSWorkspace.shared.open(run.folder.appendingPathComponent("changelog.txt"))
            }.controlSize(.small)
            Button("Show") {
                NSWorkspace.shared.activateFileViewerSelecting([run.folder])
            }.controlSize(.small)
            Button(role: .destructive) { perfect.undo(run) } label: { Text("Revert") }
                .controlSize(.small).disabled(perfect.busy)
        }
        .padding(.vertical, 4)
    }

    private func breakdown(_ r: RunRecord) -> String {
        var bits: [String] = []
        if !r.ops.isEmpty { bits.append("\(r.ops.count) moves") }
        if !r.tagEdits.isEmpty { bits.append("\(r.tagEdits.count) tags") }
        if !r.perfEdits.isEmpty { bits.append("\(r.perfEdits.count) credits") }
        let art = r.artEdits.count + r.artPromotions.count + r.artReplacements.count
        if art > 0 { bits.append("\(art) artwork") }
        return bits.isEmpty ? "—" : bits.joined(separator: " · ")
    }

    private func placeholder(_ msg: String) -> some View {
        Text(msg).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - Logs

private struct LogFile: Identifiable, Hashable {
    let id: String        // path
    let title: String
    let subtitle: String
    let url: URL
}

struct LogsView: View {
    @EnvironmentObject private var perfect: PerfectStore
    @State private var logs: [LogFile] = []
    @State private var selected: String?
    @State private var content = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text("Logs").font(.headline); Spacer()
                    Button { loadLogs() } label: { Image(systemName: "arrow.clockwise") } }
                    .padding(10)
                Divider()
                if logs.isEmpty {
                    Text("No logs yet.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(logs, selection: $selected) { log in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(log.title).font(.system(size: 12, weight: .medium))
                            Text(log.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }.tag(log.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 220, maxWidth: 300)

            VStack(spacing: 0) {
                Divider()
                ScrollView {
                    Text(content.isEmpty ? "Select a log on the left." : content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minWidth: 360)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { loadLogs() }
        .onChange(of: selected) { id in
            guard let log = logs.first(where: { $0.id == id }) else { content = ""; return }
            content = (try? String(contentsOf: log.url, encoding: .utf8)) ?? "(couldn't read this log)"
        }
    }

    private func loadLogs() {
        var found: [LogFile] = []
        let fm = FileManager.default
        if let root = perfect.root {
            let qroot = root.appendingPathComponent("Music Librarian Quarantine")
            if let subs = try? fm.contentsOfDirectory(at: qroot, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for sub in subs {
                    let log = sub.appendingPathComponent("changelog.txt")
                    guard fm.fileExists(atPath: log.path) else { continue }
                    found.append(LogFile(id: log.path, title: sub.lastPathComponent,
                                         subtitle: "change log", url: log))
                }
            }
        }
        found.sort { $0.title > $1.title }   // newest run first
        // the credits diagnostic log lives in the home folder
        let credits = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("musicdeduper-credits.log"))
        if fm.fileExists(atPath: credits.path) {
            found.append(LogFile(id: credits.path, title: "Credits lookup", subtitle: "diagnostic", url: credits))
        }
        logs = found
        if selected == nil { selected = found.first?.id }
    }
}
