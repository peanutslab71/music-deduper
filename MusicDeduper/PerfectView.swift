//
//  PerfectView.swift
//  MusicDeduper
//
//  The Perfect screen: choose a library → diagnose → review → commit.
//  Phase 1 slice: junk, empty folders, DRM. Review-gated, quarantine on commit.
//

import SwiftUI

struct PerfectView: View {
    @StateObject private var store = PerfectStore()
    @State private var expanded: Set<String> = []   // all sections collapsed initially — reads as a summary
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.busy && !store.diagnosed {
                diagnosing
            } else if !store.diagnosed {
                intro
            } else {
                review
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Perfect").font(.headline)
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if store.diagnosed {
                Button { store.diagnose() } label: { Label("Re-diagnose", systemImage: "arrow.clockwise") }
                    .disabled(store.busy)
            }
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Thoroughness").font(.subheadline).fontWeight(.medium)
                Picker("", selection: $store.thoroughness) {
                    ForEach(Thoroughness.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(store.thoroughness.blurb).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Removed items go to").font(.caption).foregroundStyle(.secondary)
                Text("“Music Librarian Quarantine” beside the library — recoverable via Undo.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Naming rules, identification providers and cover art arrive with the identify-and-tag step.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 320)
    }

    // MARK: states

    private var intro: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wand.and.stars").font(.system(size: 40, weight: .light)).foregroundStyle(.purple)
            Text(store.root == nil ? "Choose a music library" : store.root!.lastPathComponent)
                .font(.title3).fontWeight(.medium)
            Text("Perfect scans the library and shows what it can tidy — junk files, empty folders, and protected (DRM) tracks — for you to review before anything is changed. Removed items go to a recoverable quarantine.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button { store.pickRoot() } label: {
                    Label(store.root == nil ? "Choose library…" : "Change…", systemImage: "folder")
                }
                Button { store.diagnose() } label: {
                    Label("Diagnose", systemImage: "stethoscope").frame(minWidth: 120)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
                .disabled(store.root == nil || store.busy)
            }
            Spacer()
            history
        }
        .padding(24)
    }

    private var diagnosing: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(store.progress.isEmpty ? "Diagnosing…" : store.progress)
                .foregroundStyle(.secondary)
            Button("Cancel") { store.cancel() }
            Spacer()
        }
    }

    // MARK: review

    private var review: some View {
        VStack(spacing: 0) {
            if let summary = store.lastRunSummary {
                committedBanner(summary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.groups.isEmpty && store.merges.isEmpty && store.renames.isEmpty {
                        allClean
                    }
                    if !store.merges.isEmpty { mergesSection }
                    if !store.renames.isEmpty { renamesSection }
                    ForEach(store.groups, id: \.kind.rawValue) { group in
                        section(group.kind, group.items)
                    }
                    tagPreview
                }
                .padding(16)
            }
            history
            Divider()
            footer
        }
    }

    // Duplicate-artist merges — judgement calls; pick the name to keep
    private var mergesSection: some View {
        let isOpen = expanded.contains("merge")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { expanded.remove("merge") } else { expanded.insert("merge") }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Image(systemName: "person.2").foregroundStyle(.pink)
                Text("Merge duplicate artists").fontWeight(.semibold)
                Text("\(store.merges.count) · review each").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let allOn = store.merges.allSatisfy { $0.accepted }
                Button(allOn ? "Deselect all" : "Select all") {
                    for i in store.merges.indices { store.merges[i].accepted = !allOn }
                }.controlSize(.small)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.07)))

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.merges) { m in mergeRow(m) }
                }
                .padding(.top, 6).padding(.leading, 6)
            }
        }
    }

    private func mergeRow(_ m: MergeProposal) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { m.accepted },
                set: { v in if let i = store.merges.firstIndex(where: { $0.id == m.id }) { store.merges[i].accepted = v } }
            )).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(zip(m.sources, m.fileCounts).map { "\($0.0) (\($0.1))" }.joined(separator: "  +  "))
                    .font(.caption).lineLimit(1)
                HStack(spacing: 6) {
                    Text("keep:").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { m.canonical },
                        set: { v in if let i = store.merges.firstIndex(where: { $0.id == m.id }) { store.merges[i].canonical = v } }
                    )) {
                        ForEach(m.sources, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 260)
                }
            }
            Spacer()
        }
        .padding(.vertical, 1)
    }

    // Tag-level artist splits — the same artist written under several spellings
    // inside the files. Pick one spelling; the rest are rewritten to it.
    @ViewBuilder private var tagPreview: some View {
        let isOpen = expanded.contains("tags")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !store.tagGroups.isEmpty {
                    Button {
                        if isOpen { expanded.remove("tags") } else { expanded.insert("tags") }
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Image(systemName: "tag").foregroundStyle(.brown)
                Text("Artist names in tags").fontWeight(.semibold)
                if store.tagGroups.isEmpty {
                    Text("what your server actually reads").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(store.tagGroups.count) split · pick one spelling").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.checkingTags {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(store.tagProgress).font(.caption).foregroundStyle(.secondary) }
                    Button("Cancel") { store.cancel() }.controlSize(.small)
                } else if store.tagGroups.isEmpty {
                    Button("Check artist tags") { expanded.insert("tags"); store.checkTags() }.controlSize(.small)
                } else {
                    let allOn = store.tagGroups.allSatisfy { $0.accepted }
                    Button(allOn ? "Deselect all" : "Select all") {
                        for i in store.tagGroups.indices { store.tagGroups[i].accepted = !allOn }
                    }.controlSize(.small)
                    Button("Re-check") { store.checkTags() }.controlSize(.small)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.brown.opacity(0.07)))

            if !store.tagGroups.isEmpty && isOpen {
                Text("Each of these artists is tagged under more than one spelling — a server reads each spelling as a separate artist. The most common one is kept by default; change it if the other is correct.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8).padding(.horizontal, 6)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.tagGroups) { g in tagRow(g) }
                }
                .padding(.top, 6).padding(.leading, 6)
            }
        }
    }

    private func tagRow(_ g: TagArtistGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { g.accepted },
                set: { v in if let i = store.tagGroups.firstIndex(where: { $0.id == g.id }) { store.tagGroups[i].accepted = v } }
            )).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.variants.map { "\($0.name) (\($0.count))" }.joined(separator: "   vs   "))
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("keep:").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { g.canonical },
                        set: { v in if let i = store.tagGroups.firstIndex(where: { $0.id == g.id }) { store.tagGroups[i].canonical = v } }
                    )) {
                        ForEach(g.variants, id: \.name) { Text($0.name).tag($0.name) }
                    }.labelsHidden().frame(maxWidth: 260)
                    if g.willChange > 0 {
                        Text("rewrites \(g.willChange) track(s)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 1)
    }

    // Untidy folder names — editable proposed name
    private var renamesSection: some View {
        let isOpen = expanded.contains("rename")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { expanded.remove("rename") } else { expanded.insert("rename") }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Image(systemName: "character.cursor.ibeam").foregroundStyle(.indigo)
                Text("Tidy folder names").fontWeight(.semibold)
                Text("\(store.renames.count) · review each").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let allOn = store.renames.allSatisfy { $0.accepted }
                Button(allOn ? "Deselect all" : "Select all") {
                    for i in store.renames.indices { store.renames[i].accepted = !allOn }
                }.controlSize(.small)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.indigo.opacity(0.07)))
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.renames) { r in renameRow(r) }
                }.padding(.top, 6).padding(.leading, 6)
            }
        }
    }

    private func renameRow(_ r: RenameProposal) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { r.accepted },
                set: { v in if let i = store.renames.firstIndex(where: { $0.id == r.id }) { store.renames[i].accepted = v } }
            )).labelsHidden().toggleStyle(.checkbox)
            Text(r.oldName).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .strikethrough().lineLimit(1)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            TextField("", text: Binding(
                get: { r.newName },
                set: { v in if let i = store.renames.firstIndex(where: { $0.id == r.id }) { store.renames[i].newName = v } }
            )).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(maxWidth: 260)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    private var allClean: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal").font(.system(size: 40, weight: .light)).foregroundStyle(.green)
            Text("Nothing to tidy").font(.title3)
            Text("No junk, empty folders or protected tracks were found.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(_ kind: FixKind, _ items: [PerfectFinding]) -> some View {
        let isOpen = expanded.contains(kind.rawValue)
        let acceptedInGroup = items.filter { $0.accepted }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { expanded.remove(kind.rawValue) } else { expanded.insert(kind.rawValue) }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Image(systemName: icon(kind)).foregroundStyle(color(kind))
                Text(kind.title).fontWeight(.semibold)
                Text(kind.safe ? "\(items.count) · low risk" : "\(items.count) · info only")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if kind.safe {
                    Button(acceptedInGroup == items.count ? "Deselect all" : "Select all") {
                        setAccepted(kind, to: acceptedInGroup != items.count)
                    }.controlSize(.small)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(color(kind).opacity(0.07)))

            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item, kind: kind)
                    }
                }
                .padding(.top, 4).padding(.leading, 6)
            }
        }
    }

    private func row(_ item: PerfectFinding, kind: FixKind) -> some View {
        HStack(spacing: 8) {
            if kind.safe {
                Toggle("", isOn: Binding(
                    get: { item.accepted },
                    set: { v in if let i = store.findings.firstIndex(where: { $0.id == item.id }) { store.findings[i].accepted = v } }
                )).labelsHidden().toggleStyle(.checkbox)
            } else {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.relPath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if item.bytes > 0 {
                Text(fmtBytes(item.bytes)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 1).padding(.trailing, 4)
    }

    private var footer: some View {
        let mergeCount = store.merges.filter { $0.accepted }.count
        let tagCount = store.tagGroups.filter { $0.accepted }.reduce(0) { $0 + $1.willChange }
        return HStack {
            if store.hasWork {
                Text("\(store.acceptedCount) cleanup(s)"
                     + (mergeCount > 0 ? ", \(mergeCount) merge(s)" : "")
                     + (tagCount > 0 ? ", \(tagCount) tag fix(es)" : "") + " selected")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Protected tracks are listed for information and are never removed.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                store.commit()
            } label: {
                Label("Apply changes", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent).tint(.purple)
            .disabled(!store.hasWork || store.busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func committedBanner(_ summary: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(summary).font(.callout)
            Spacer()
            if let run = store.runs.first {
                Button("Undo this run") { store.undo(run) }
                    .controlSize(.small)
                    .disabled(store.busy)
            }
            if let q = store.lastQuarantine {
                Button("Show quarantine") { NSWorkspace.shared.activateFileViewerSelecting([q]) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.1))
    }

    // Recent runs — restore any past run to keep testing repeatable
    @ViewBuilder private var history: some View {
        if !store.runs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RECENT RUNS").font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                ForEach(store.runs) { run in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                        Text(Self.runDate.string(from: run.date)).font(.caption).monospacedDigit()
                        Text(run.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Undo") { store.undo(run) }.controlSize(.small).disabled(store.busy)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([run.folder]) }.controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private static let runDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    private func setAccepted(_ kind: FixKind, to v: Bool) {
        for i in store.findings.indices where store.findings[i].kind == kind {
            store.findings[i].accepted = v
        }
    }

    private func icon(_ k: FixKind) -> String {
        switch k { case .junk: return "trash"; case .emptyFolder: return "folder.badge.minus"; case .drm: return "lock.fill" }
    }
    private func color(_ k: FixKind) -> Color {
        switch k { case .junk: return .blue; case .emptyFolder: return .teal; case .drm: return .orange }
    }
}
