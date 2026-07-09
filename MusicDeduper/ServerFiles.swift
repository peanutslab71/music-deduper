//
//  ServerFiles.swift
//  MusicDeduper
//
//  Two-pane file manager (v1.4). Each pane is a location — this Mac or an
//  SMB server via the app's own network engine — so files can move
//  Mac↔server or around the server itself. Same-share moves and renames are
//  single instant SMB operations, no matter how big the folder.
//

import Foundation
import SwiftUI

// MARK: - One pane = one location

@MainActor
final class PaneModel: ObservableObject {
    struct Item: Identifiable, Hashable {
        let name: String
        let isDir: Bool
        let size: Int64
        let date: Date?
        var id: String { name }
    }

    enum Kind { case local, server }

    @Published var kind: Kind = .local
    @Published var localURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var serverPath: [String] = []
    @Published var items: [Item] = []
    @Published var selection = Set<String>()
    @Published var loading = false
    @Published var errorMsg: String?

    private(set) var client: DirectSMBClient?

    var title: String {
        switch kind {
        case .local: return "This Mac — \(localURL.lastPathComponent.isEmpty ? "/" : localURL.lastPathComponent)"
        case .server: return "\(client?.host ?? "?") / \(client?.share ?? "?")"
        }
    }
    var breadcrumb: String {
        switch kind {
        case .local: return localURL.path
        case .server: return "/" + serverPath.joined(separator: "/")
        }
    }
    var canGoUp: Bool {
        switch kind {
        case .local: return localURL.path != "/"
        case .server: return !serverPath.isEmpty
        }
    }
    var serverDir: String { serverPath.joined(separator: "/") }

    func setLocal(_ url: URL) {
        kind = .local
        localURL = url
        client = nil
        reload()
    }

    func setServer(host: String, share: String, path: [String] = []) {
        guard let c = DirectSMBClient(address: "smb://\(host)/\(share)") else {
            errorMsg = "Bad server address"
            return
        }
        kind = .server
        client = c
        serverPath = path
        reload()
    }

    func reload() {
        selection = []
        errorMsg = nil
        loading = true
        switch kind {
        case .local:
            let url = localURL
            Task.detached {
                let fm = FileManager.default
                let urls = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])) ?? []
                let list = urls.compactMap { u -> Item? in
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    return Item(name: u.lastPathComponent,
                                isDir: v?.isDirectory ?? false,
                                size: Int64(v?.fileSize ?? 0),
                                date: v?.contentModificationDate)
                }
                .sorted {
                    if $0.isDir != $1.isDir { return $0.isDir }
                    return $0.name.lowercased() < $1.name.lowercased()
                }
                await MainActor.run { self.items = list; self.loading = false }
            }
        case .server:
            guard let client else { loading = false; return }
            let dir = serverDir
            Task {
                do {
                    let entries = try await client.listEntries(dir: dir)
                    self.items = entries.map { Item(name: $0.name, isDir: $0.isDir, size: $0.size, date: $0.date) }
                    self.loading = false
                } catch {
                    self.items = []
                    self.errorMsg = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    func open(_ name: String) {
        guard let item = items.first(where: { $0.name == name }), item.isDir else { return }
        switch kind {
        case .local: localURL.appendPathComponent(name)
        case .server: serverPath.append(name)
        }
        reload()
    }

    func up() {
        guard canGoUp else { return }
        switch kind {
        case .local: localURL.deleteLastPathComponent()
        case .server: serverPath.removeLast()
        }
        reload()
    }

    // MARK: write operations (stage 2: create / rename / same-location move)

    func newFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        switch kind {
        case .local:
            do {
                try FileManager.default.createDirectory(at: localURL.appendingPathComponent(n),
                                                        withIntermediateDirectories: false)
                reload()
            } catch { errorMsg = error.localizedDescription }
        case .server:
            guard let client else { return }
            let path = (serverDir.isEmpty ? "" : serverDir + "/") + DirectSMBClient.nfc(n)
            Task {
                do { try await client.createFolder(path); self.reload() }
                catch { self.errorMsg = "Couldn't create the folder: \(error.localizedDescription)" }
            }
        }
    }

    func rename(_ oldName: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != oldName else { return }
        switch kind {
        case .local:
            do {
                try FileManager.default.moveItem(at: localURL.appendingPathComponent(oldName),
                                                 to: localURL.appendingPathComponent(n))
                reload()
            } catch { errorMsg = error.localizedDescription }
        case .server:
            guard let client else { return }
            let base = serverDir.isEmpty ? "" : serverDir + "/"
            Task {
                do {
                    try await client.moveNoReplace(base + oldName, to: base + DirectSMBClient.nfc(n))
                    PaneModel.log("renamed (server): \(base + oldName) → \(base + n)")
                    self.reload()
                } catch { self.errorMsg = "Couldn't rename: \(error.localizedDescription)" }
            }
        }
    }

    /// Everything File Commander changes gets a line in
    /// ~/Library/Logs/MusicDeduper/commander.log — deletions especially.
    static func log(_ s: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MusicDeduper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("commander.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            h.write(Data("\(f.string(from: Date()))  \(s)\n".utf8))
        }
    }

    /// Delete the selection. Local items go to the Trash (recoverable);
    /// server items are gone for good — the view's confirm flow says so.
    func deleteSelection() {
        let names = selection
        guard !names.isEmpty else { return }
        let picked = items.filter { names.contains($0.name) }
        switch kind {
        case .local:
            let fm = FileManager.default
            for item in picked {
                let url = localURL.appendingPathComponent(item.name)
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    Self.log("trashed (local): \(url.path)")
                } catch { errorMsg = error.localizedDescription; break }
            }
            reload()
        case .server:
            guard let client else { return }
            let base = serverDir.isEmpty ? "" : serverDir + "/"
            let label = "\(client.host)/\(client.share)"
            Task {
                var failed: String?
                for item in picked {
                    do {
                        try await client.removeItem(base + item.name, isDir: item.isDir)
                        PaneModel.log("DELETED (server \(label)): \(base + item.name)\(item.isDir ? " [folder + contents]" : "")")
                    } catch {
                        failed = "Couldn't delete “\(item.name)”: \(error.localizedDescription)"
                        break
                    }
                }
                self.errorMsg = failed
                self.reload()
            }
        }
    }

    /// True when a plain move to the other pane is an instant operation
    /// (same share on the same server, or both panes local).
    func canMoveInstantly(to other: PaneModel) -> Bool {
        switch (kind, other.kind) {
        case (.local, .local):
            return true
        case (.server, .server):
            return client?.host == other.client?.host && client?.share == other.client?.share
        default:
            return false
        }
    }

    /// Move the current selection into the other pane's folder (instant paths only).
    func moveSelection(to other: PaneModel) {
        guard canMoveInstantly(to: other), !selection.isEmpty else { return }
        let names = selection
        switch kind {
        case .local:
            for name in names {
                let from = localURL.appendingPathComponent(name)
                let to = other.localURL.appendingPathComponent(name)
                do { try FileManager.default.moveItem(at: from, to: to) }
                catch { errorMsg = error.localizedDescription; break }
            }
            reload(); other.reload()
        case .server:
            guard let client else { return }
            let fromBase = serverDir.isEmpty ? "" : serverDir + "/"
            let toBase = other.serverDir.isEmpty ? "" : other.serverDir + "/"
            Task {
                var failed: String?
                for name in names {
                    do {
                        try await client.moveNoReplace(fromBase + name, to: toBase + name)
                        PaneModel.log("moved (server): \(fromBase + name) → \(toBase + name)")
                    }
                    catch { failed = "Couldn't move “\(name)”: \(error.localizedDescription)"; break }
                }
                self.errorMsg = failed
                self.reload()
                other.reload()
            }
        }
    }
}

// MARK: - The window

struct ServerFilesView: View {
    @StateObject private var left = PaneModel()
    @StateObject private var right = PaneModel()
    @State private var appeared = false

    var body: some View {
        HSplitView {
            PaneView(model: left, other: right, arrow: "arrow.right")
            PaneView(model: right, other: left, arrow: "arrow.left")
        }
        .frame(minWidth: 860, minHeight: 480)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            // left: last wizard source if we have one, else the home folder
            if let src = UserDefaults.standard.stringArray(forKey: "recentSources")?.first {
                left.setLocal(URL(fileURLWithPath: src))
            } else {
                left.setLocal(FileManager.default.homeDirectoryForCurrentUser)
            }
            // right: the wizard's server + destination folder if known
            let addr = UserDefaults.standard.string(forKey: "smbAddress") ?? ""
            if let c = DirectSMBClient(address: addr) {
                let rel = UserDefaults.standard.string(forKey: "destRelSaved") ?? ""
                right.setServer(host: c.host, share: c.share,
                                path: rel.split(separator: "/").map(String.init))
            }
        }
    }
}

// MARK: - One pane

struct PaneView: View {
    @ObservedObject var model: PaneModel
    @ObservedObject var other: PaneModel
    let arrow: String

    @State private var showPicker = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showRename = false
    @State private var renameFrom = ""
    @State private var renameTo = ""
    @State private var confirmDelete1 = false
    @State private var confirmDelete2 = false

    private var deleteSummary: (files: Int, folders: Int, bytes: Int64) {
        let picked = model.items.filter { model.selection.contains($0.name) }
        return (picked.filter { !$0.isDir }.count,
                picked.filter { $0.isDir }.count,
                picked.filter { !$0.isDir }.reduce(0) { $0 + $1.size })
    }
    private var deleteDetail: String {
        let s = deleteSummary
        var parts: [String] = []
        if s.files > 0 { parts.append("\(s.files) file(s) · \(fmtBytes(s.bytes))") }
        if s.folders > 0 { parts.append("\(s.folders) folder(s) including everything inside") }
        return parts.joined(separator: ", plus ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // location + breadcrumb bar
            HStack(spacing: 8) {
                Menu {
                    Button("This Mac — Home") { model.setLocal(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("This Mac — Music") {
                        model.setLocal(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music"))
                    }
                    Divider()
                    Button("Choose server…") { showPicker = true }
                } label: {
                    Label(model.title, systemImage: model.kind == .local ? "desktopcomputer" : "server.rack")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button { model.up() } label: { Image(systemName: "arrow.up") }
                    .disabled(!model.canGoUp)
                    .help("Up one level")
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Text(model.breadcrumb)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 4)
            Divider()

            // listing
            Table(model.items, selection: $model.selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.isDir ? "folder.fill" : "music.note")
                        .labelStyle(.titleAndIcon)
                }
                TableColumn("Size") { item in
                    Text(item.isDir ? "—" : fmtBytes(item.size))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 60, ideal: 76, max: 100)
                TableColumn("Modified") { item in
                    Text(item.date.map { Self.df.string(from: $0) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 120, max: 150)
            }
            .contextMenu(forSelectionType: String.self) { sel in
                if sel.count == 1, let name = sel.first {
                    Button("Rename…") { beginRename(name) }
                }
                if !sel.isEmpty && model.canMoveInstantly(to: other) {
                    Button("Move to other pane") {
                        model.selection = sel
                        model.moveSelection(to: other)
                    }
                }
                if !sel.isEmpty {
                    Button(model.kind == .local ? "Move to Trash" : "Delete…", role: .destructive) {
                        model.selection = sel
                        confirmDelete1 = true
                    }
                }
            } primaryAction: { sel in
                if sel.count == 1, let name = sel.first { model.open(name) }
            }
            .overlay {
                if model.loading { ProgressView() }
            }

            Divider()
            // pane toolbar
            HStack(spacing: 8) {
                Button { newFolderName = ""; showNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    if let name = model.selection.first { beginRename(name) }
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(model.selection.count != 1)
                Button {
                    model.moveSelection(to: other)
                } label: {
                    Label("Move", systemImage: arrow)
                }
                .disabled(model.selection.isEmpty || !model.canMoveInstantly(to: other))
                .help(model.canMoveInstantly(to: other)
                      ? "Move the selection into the other pane's folder (instant)"
                      : "Move needs both panes on the same share (transfers between locations come in a later update)")
                Button(role: .destructive) {
                    confirmDelete1 = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.selection.isEmpty)
                .help(model.kind == .local
                      ? "Move the selection to the Trash"
                      : "Delete from the server — there is no Trash there, this is permanent")
                Spacer()
                if let e = model.errorMsg {
                    Text(e).font(.caption).foregroundStyle(.red)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text("\(model.items.count) items\(model.selection.isEmpty ? "" : " · \(model.selection.count) selected")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .sheet(isPresented: $showPicker) {
            ServerPickerSheet { host, share in
                model.setServer(host: host, share: share)
            }
        }
        .sheet(isPresented: $showNewFolder) {
            namePrompt(title: "New folder", text: $newFolderName, confirm: "Create") {
                model.newFolder(newFolderName)
            }
        }
        .sheet(isPresented: $showRename) {
            namePrompt(title: "Rename “\(renameFrom)”", text: $renameTo, confirm: "Rename") {
                model.rename(renameFrom, to: renameTo)
            }
        }
        .alert(model.kind == .local ? "Move to Trash?" : "Delete from the server?",
               isPresented: $confirmDelete1) {
            if model.kind == .local {
                Button("Move to Trash", role: .destructive) { model.deleteSelection() }
            } else {
                Button("Continue…", role: .destructive) { confirmDelete2 = true }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(model.kind == .local
                 ? "Move \(deleteDetail) to the Trash? You can restore from there."
                 : "Delete \(deleteDetail) from \(model.title)?")
        }
        .alert("This cannot be undone", isPresented: $confirmDelete2) {
            Button("Delete permanently", role: .destructive) { model.deleteSelection() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Servers have no Trash — \(deleteDetail) will be permanently deleted from \(model.title). Are you absolutely sure?")
        }
    }

    private func beginRename(_ name: String) {
        renameFrom = name
        renameTo = name
        showRename = true
    }

    private func namePrompt(title: String, text: Binding<String>, confirm: String,
                            action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { action(); dismissSheets() }
            HStack {
                Spacer()
                Button("Cancel") { dismissSheets() }.keyboardShortcut(.cancelAction)
                Button(confirm) { action(); dismissSheets() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func dismissSheets() {
        showNewFolder = false
        showRename = false
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}
