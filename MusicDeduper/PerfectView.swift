//
//  PerfectView.swift
//  MusicDeduper
//
//  The Perfect screen: choose a library → diagnose → review → commit.
//  Phase 1 slice: junk, empty folders, DRM. Review-gated, quarantine on commit.
//

import SwiftUI

/// An album cover: the file's embedded art if it has one, else the cover we
/// *found* (Cover Art Archive) if art is going to be added, else a placeholder.
struct AlbumCover: View {
    @ObservedObject private var art = ArtworkCache.shared
    @ObservedObject private var found = FoundArtCache.shared
    let key: String
    let sampleURL: URL?
    let foundMBID: String?
    let size: CGFloat
    var corner: CGFloat = 12

    var body: some View {
        Group {
            if let img = art.cached(key) ?? foundMBID.flatMap({ found.cached($0) }) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.32, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.black.opacity(0.08)))
        .onAppear {
            art.request(key: key, sampleURL: sampleURL)
            if let m = foundMBID { found.request(m) }
        }
    }
}

struct PerfectView: View {
    @ObservedObject var store: PerfectStore
    @ObservedObject private var audio = AudioPreview.shared
    @State private var expanded: Set<String> = []   // all sections collapsed initially — reads as a summary
    @State private var showSettings = false
    @State private var queueIndex = 0                // position in the step-through review queue
    @State private var showApplyConfirm = false      // the final "confirm before commit" dialog
    @State private var albumSheet: AlbumRef? = nil   // album whose tracks are shown in a dialog

    struct AlbumRef: Identifiable { let id: String }

    @State private var viewStep: Int? = nil          // a past step the user clicked back to

    // The step the work is actually on…
    private var liveStep: Int {
        if store.busy && !store.diagnosed { return 1 }   // Scan
        if store.identifying { return 2 }                 // Identify
        if store.enriching { return 3 }                   // Credits
        return 4                                          // Review
    }
    // …and the step being shown (a past one if the user clicked back).
    private var step: Int { viewStep ?? liveStep }
    private var viewingPast: Bool { viewStep != nil && viewStep != liveStep }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.root == nil || (!store.diagnosed && !store.busy) {
                intro
            } else {
                stepBar
                Divider()
                phasedMiddle
                Divider()
                perfectFooter
            }
        }
        .sheet(isPresented: $showApplyConfirm) { applyConfirmSheet }
        .sheet(item: $albumSheet) { ref in albumSheetView(ref.id) }
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
                Button { store.explore() } label: { Label("Re-explore", systemImage: "arrow.clockwise") }
                    .disabled(store.busy || store.checkingTags)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("When to analyse").font(.subheadline).fontWeight(.medium)
                Picker("", selection: $store.autoRun) {
                    Text("Automatically").tag(true)
                    Text("Manually").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
                Text(store.autoRun
                     ? "All checks run as soon as you choose a library."
                     : "Nothing runs until you press Run — then every check runs together.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Text("Perfect looks over the whole library and shows what it can tidy — junk files, empty folders, protected (DRM) tracks, duplicate artist folders, and the same artist tagged under different spellings — for you to review before anything is changed. Removed items go to a recoverable quarantine.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button { store.pickRoot() } label: {
                    Label(store.root == nil ? "Choose library…" : "Change…", systemImage: "folder")
                }
                if store.root != nil && !store.autoRun {
                    Button { store.explore() } label: {
                        Label("Run", systemImage: "play.fill").frame(minWidth: 120)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(store.busy)
                }
            }
            Spacer()
            history
        }
        .padding(24)
    }

    // MARK: - The three fixed zones

    // ── TOP: step bar + current action ──
    private var stepBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                stepChip(1, "Scan"); stepDash()
                stepChip(2, "Identify"); stepDash()
                stepChip(3, "Credits"); stepDash()
                stepChip(4, "Review"); stepDash()
                stepChip(5, "Apply")
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stepTitle).font(.system(size: 15, weight: .semibold))
                    Text(stepSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if viewingPast {
                    Button { viewStep = nil } label: { Label("Back to current step", systemImage: "arrow.uturn.forward") }
                        .controlSize(.large)
                } else {
                    stepAction
                }
            }
            if step == 4, !viewingPast, reviewQueueCount > 0 { needsBanner }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 13)
    }

    private func stepChip(_ n: Int, _ label: String) -> some View {
        let done = liveStep > n, now = step == n, reachable = n <= liveStep
        return Button {
            if reachable { viewStep = (n == liveStep ? nil : n) }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(done ? Color.green : (now ? Color.purple : Color.clear))
                        .overlay(Circle().strokeBorder(done || now ? .clear : Color.secondary.opacity(0.35), lineWidth: 1.5))
                        .frame(width: 22, height: 22)
                    if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                    else { Text("\(n)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(now ? .white : .secondary) }
                }
                Text(label).font(.system(size: 12.5, weight: now ? .semibold : .regular))
                    .foregroundStyle(now ? .primary : (done ? .secondary : .tertiary))
            }
        }
        .buttonStyle(.plain).disabled(!reachable)
        .help(reachable ? "View this step" : "Not reached yet")
    }
    private func stepDash() -> some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 26, height: 1.5).padding(.horizontal, 10)
    }

    private var stepTitle: String {
        switch step {
        case 1: return "Step 1 — Scan"
        case 2: return "Step 2 — Identify"
        case 3: return "Step 3 — Fill credits"
        default: return "Step 4 — Review"
        }
    }
    private var stepSubtitle: String {
        switch step {
        case 1:
            if store.diagnosed {
                let junk = store.groups.reduce(0) { $0 + $1.items.count }
                let m = store.artists.filter { store.artistHasApplicableWork($0) }.count
                return "Found \(junk) cleanup item(s), \(m) duplicate artist(s), \(store.renames.count) untidy name(s)."
            }
            return "Reading tags and finding junk, empty folders and duplicate artists."
        case 2: return "Matching each track by its sound. Your tags are trusted; only real gaps get filled."
        case 3: return "Looking up composer, label and cover art for the tracks missing them."
        default:
            let act = store.proposals.filter { $0.isActionable }.count
            return "\(act) track(s) with a suggested change. \(reviewQueueCount) worth checking before you apply."
        }
    }

    @ViewBuilder private var stepAction: some View {
        if store.identifying || store.enriching || (store.busy && !store.diagnosed) {
            Button("Cancel") { store.cancel() }.controlSize(.large)
        } else if !store.hasAcoustIDKey {
            Text("needs an AcoustID key").font(.caption).foregroundStyle(.orange)
        } else if store.proposals.isEmpty {
            Button { store.identify() } label: { Label("Identify tracks", systemImage: "waveform.and.magnifyingglass") }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
        } else {
            Button { store.enrich() } label: { Label("Fill credits", systemImage: "text.badge.plus") }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
            Button { store.identify() } label: { Label("Re-identify", systemImage: "arrow.clockwise") }
                .controlSize(.large)
        }
    }

    private var reviewQueueCount: Int { store.proposals.filter { $0.needsReview }.count }

    private var needsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(reviewQueueCount) need your decision").font(.system(size: 13, weight: .semibold))
                Text("genuine artist changes & low-confidence matches").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("↓ in the queue below").font(.caption).foregroundStyle(.orange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
    }

    // ── MIDDLE: swaps by step ──
    @ViewBuilder private var phasedMiddle: some View {
        if viewStep == nil && store.busy && !store.diagnosed { workingMiddle(title: "Scanning your library", sub: "reading tags, finding junk and duplicate artists") }
        else if viewStep == nil && store.identifying { workingMiddle(title: "matched by sound", sub: store.identifyProgress, live: true) }
        else if viewStep == nil && store.enriching { workingMiddle(title: "looking up credits", sub: store.enrichProgress, live: true, credits: true) }
        else if step == 1 { cleanupMiddle }     // Scan results
        else { reviewMiddle }                    // Identify / Credits / Review
    }

    // Scan's output — the structural cleanups, shown as their own step (not hidden).
    private var cleanupMiddle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What the scan found — junk files, empty folders and duplicate artists. These merge/clean on disk when you Apply.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.artists.isEmpty && store.renames.isEmpty && store.groups.isEmpty && !store.checkingTags {
                    Text("Nothing to clean up — the folder structure is already tidy.").foregroundStyle(.secondary).padding(.top, 8)
                }
                artistsSection
                if !store.renames.isEmpty { renamesSection }
                ForEach(store.groups, id: \.kind.rawValue) { group in section(group.kind, group.items) }
            }
            .padding(16)
        }
    }

    private func workingMiddle(title: String, sub: String, live: Bool = false, credits: Bool = false) -> some View {
        VStack(spacing: 10) {
            Spacer()
            if live {
                Text("\(credits ? store.recentFinds.count : store.identifyMatched)")
                    .font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(.teal)
                    .contentTransition(.numericText())
                Text(title).font(.headline)
            } else {
                ProgressView().controlSize(.large)
                Text(title).font(.title3).fontWeight(.semibold)
            }
            Text(sub.isEmpty ? " " : sub).font(.caption).foregroundStyle(.secondary)
            if live {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.recentFinds, id: \.self) { f in
                        Text(f).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(f.hasPrefix("✎") ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(width: 460, alignment: .leading).padding(.top, 8)
                .animation(.easeOut(duration: 0.25), value: store.recentFinds)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewMiddle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = store.lastRunSummary { committedBanner(summary) }
                if store.proposals.isEmpty && store.artists.isEmpty && store.renames.isEmpty
                    && store.groups.isEmpty && !store.checkingTags { allClean }
                reviewQueueSection      // pinned at the top of the content
                albumGrid
            }
            .padding(16)
        }
    }

    // ── BOTTOM: status + apply (locked until Review) ──
    private var perfectFooter: some View {
        HStack(spacing: 14) {
            perfectStatus
            Spacer()
            if !store.runs.isEmpty, let run = store.runs.first {
                Button("Undo last run") { store.undo(run) }.disabled(store.busy)
            }
            Button {
                showApplyConfirm = true
            } label: { Label("Apply changes", systemImage: "checkmark.circle") }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(liveStep != 4 || !store.hasWork || store.busy)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var perfectStatus: some View {
        if store.busy && !store.diagnosed {
            statusLine("Scanning…", store.progress)
        } else if store.identifying {
            statusLine("Listening…", store.identifyProgress)
        } else if store.enriching {
            statusLine("Looking up credits…", store.enrichProgress)
        } else {
            let act = store.proposals.filter { $0.isActionable }.count
            Text("\(act) change(s) · \(store.acceptedCount) cleanup(s) · all reversible")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func statusLine(_ a: String, _ b: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(b.isEmpty ? a : b).font(.caption).foregroundStyle(.secondary)
        }
    }

    // The album's tracks in a dialog (not stacked in the main frame).
    private func albumSheetView(_ id: String) -> some View {
        let props = store.proposals.filter { $0.url.deletingLastPathComponent().path == id && $0.isActionable }
        let a = store.albumChanges.first(where: { $0.id == id })
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                AlbumCover(key: id, sampleURL: props.first?.url, foundMBID: a?.artReleaseMBID, size: 52, corner: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a?.title ?? "Album").font(.headline)
                    Text("\(a?.subtitle ?? "") · \(props.count) track(s)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { albumSheet = nil }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(props) { p in proposalRow(p) }
                }.padding(16)
            }
        }.frame(width: 620, height: 560)
    }

    // Step-through review queue — the handful that need a decision (genuine artist
    // changes, low-confidence matches), one at a time with left/right nav.
    @ViewBuilder private var reviewQueueSection: some View {
        let queue = store.proposals.filter { $0.needsReview }
        if !queue.isEmpty {
            let idx = max(0, min(queueIndex, queue.count - 1))
            let p = queue[idx]
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                    Text("Review queue").fontWeight(.semibold)
                    Text("the ones that need you").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(idx + 1) of \(queue.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))

                HStack(alignment: .top, spacing: 14) {
                    Button { queueIndex = (idx - 1 + queue.count) % queue.count } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }.buttonStyle(.bordered).disabled(queue.count < 2)

                    AlbumCover(key: p.url.deletingLastPathComponent().path, sampleURL: p.url, foundMBID: p.enrichment?.releaseMBID, size: 96, corner: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            playButton(p.url)
                            Text(p.newTitle.isEmpty ? p.curTitle : p.newTitle).font(.headline)
                            Text(String(format: "%.0f%% by sound", p.score * 100))
                                .font(.caption2).foregroundStyle(p.score >= 0.9 ? .green : .orange)
                        }
                        if p.artistChanged {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("YOUR TAG").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                                    Text(p.curArtist).font(.callout).foregroundStyle(.secondary)
                                }
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("PROPOSED").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                                    Text(p.newArtist).font(.callout).fontWeight(.medium)
                                }
                            }
                            Text("A genuine artist change — check it's the same act, not a different one, before accepting.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Low-confidence match (\(String(format: "%.0f%%", p.score * 100))) — worth a glance before applying.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Toggle("Apply this", isOn: Binding(
                                get: { p.accepted },
                                set: { v in if let i = store.proposals.firstIndex(where: { $0.id == p.id }) { store.proposals[i].accepted = v } }
                            )).toggleStyle(.checkbox)
                            Spacer()
                            Button("Skip") { queueIndex = (idx + 1) % queue.count }.controlSize(.small)
                            Button("Keep & next →") { queueIndex = (idx + 1) % queue.count }
                                .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                        }
                    }

                    Button { queueIndex = (idx + 1) % queue.count } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    }.buttonStyle(.bordered).disabled(queue.count < 2)
                }
                .padding(.top, 10).padding(.horizontal, 4)
            }
        }
    }

    // The single album interface — a grid of cover cards; click one to see its
    // tracks below. Replaces the old carousel + identify tree (no more duplication).
    @ViewBuilder private var albumGrid: some View {
        let albums = store.albumChanges
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.purple)
                    Text("\(albums.count) album(s)").fontWeight(.semibold)
                    Text("identified from the audio · click to see tracks").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 210), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    ForEach(albums) { a in albumCard(a) }
                }
            }
        }
    }

    private func albumCard(_ a: PerfectStore.AlbumChange) -> some View {
        Button {
            albumSheet = AlbumRef(id: a.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    AlbumCover(key: a.id, sampleURL: a.sampleURL, foundMBID: a.artReleaseMBID, size: 176)
                    HStack(spacing: 5) {
                        if a.names { cardTag("Names", .blue) }
                        if a.artwork { cardTag("+ Art", .pink) }
                        if a.credits { cardTag("+ Credits", Color(red: 0.13, green: 0.6, blue: 0.3)) }
                    }
                    .padding(8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                    Text("\(a.subtitle) · \(a.trackCount) track(s)").font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 176)
        }
        .buttonStyle(.plain)
    }

    private func cardTag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    // One artist-centric list — a folder split, a tag split, or both. One "keep"
    // name drives whichever fixes are needed (merge folders and/or rewrite tags).
    @ViewBuilder private var artistsSection: some View {
        // show the section while tags are still being read, or if there's anything to fix
        if store.checkingTags || !store.artists.isEmpty {
            let isOpen = expanded.contains("artists")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if !store.artists.isEmpty {
                        Button {
                            if isOpen { expanded.remove("artists") } else { expanded.insert("artists") }
                        } label: {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                    Image(systemName: "person.2").foregroundStyle(.pink)
                    Text("Artists").fontWeight(.semibold)
                    if store.checkingTags {
                        Text("reading tags…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        let applicable = store.artists.filter { store.artistHasApplicableWork($0) }.count
                        Text("\(applicable) to fix · pick one name each").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.checkingTags {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(store.tagProgress).font(.caption).foregroundStyle(.secondary) }
                    } else if !store.artists.isEmpty {
                        let allOn = store.artists.allSatisfy { $0.accepted }
                        Button(allOn ? "Deselect all" : "Select all") {
                            for i in store.artists.indices { store.artists[i].accepted = !allOn }
                        }.controlSize(.small)
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.07)))

                if !store.artists.isEmpty && isOpen {
                    Text("Each of these is one artist that shows up more than once — as separate folders, tagged under different spellings, or both. Pick the one name to keep; the folders are merged on disk to match.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8).padding(.horizontal, 6)
                    if !store.tagWritingEnabled && store.artists.contains(where: { $0.tagRewrites > 0 }) {
                        Label("Rewriting the tags themselves is paused for now — it can drop other tag data (like the release year), so those files aren't changed yet. Folder merges still apply.",
                              systemImage: "pause.circle")
                            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.artists) { a in artistRow(a) }
                    }
                    .padding(.top, 6).padding(.leading, 6)
                }
            }
        }
    }

    private func artistRow(_ a: ArtistIssue) -> some View {
        let tagOn = store.tagWritingEnabled
        let willMerge = a.folderMerges > 0
        let willTag = tagOn && a.tagRewrites > 0
        let applicable = willMerge || willTag              // anything to do right now
        let tagPaused = a.tagRewrites > 0 && !tagOn        // tag fix wanted but gated off
        // action summary honouring the gate
        var bits: [String] = []
        if willMerge { bits.append("merges \(a.folderSources.count) folders") }
        if willTag { bits.append("rewrites \(a.tagRewrites) tag(s)") }
        let summary = bits.isEmpty ? (tagPaused ? "tag fix paused" : "already consistent")
                                   : bits.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { a.accepted && applicable },
                set: { v in if let i = store.artists.firstIndex(where: { $0.id == a.id }) { store.artists[i].accepted = v } }
            )).labelsHidden().toggleStyle(.checkbox).disabled(!applicable)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { a.canonical },
                        set: { v in if let i = store.artists.firstIndex(where: { $0.id == a.id }) { store.artists[i].canonical = v } }
                    )) {
                        ForEach(a.candidates, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 260).disabled(!applicable)
                    Text(a.kindLabel).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                    Text(summary).font(.caption2).foregroundStyle(applicable ? .secondary : .tertiary)
                    if tagPaused {
                        Image(systemName: "pause.circle").font(.caption2).foregroundStyle(.orange)
                            .help("Rewriting tags is paused until it's proven not to lose other tag data")
                    }
                }
                // show the spellings/folders being unified
                Text(a.candidates.joined(separator: "   ·   "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 1)
        .opacity(applicable ? 1 : 0.6)
    }

    private func fmtTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private var scrubBar: some View {
        HStack(spacing: 8) {
            Text(fmtTime(audio.currentTime)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { audio.progress }, set: { audio.seek(to: $0) }), in: 0...1)
                .controlSize(.mini).tint(.teal)
            Text(fmtTime(audio.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func playButton(_ url: URL) -> some View {
        let playing = audio.playingURL == url
        return Button { audio.toggle(url) } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.system(size: 18)).foregroundStyle(playing ? .red : .teal)
        }.buttonStyle(.plain).help(playing ? "Stop" : "Listen")
    }

    private func proposalRow(_ p: TrackProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            playButton(p.url)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.relPath).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Text(String(format: "%.0f%%", p.score * 100)).font(.caption2)
                        .foregroundStyle(p.score >= 0.9 ? .green : .orange)
                    if let rid = p.recordingID, let url = URL(string: "https://musicbrainz.org/recording/\(rid)") {
                        Link(destination: url) {
                            HStack(spacing: 2) { Text("source"); Image(systemName: "arrow.up.forward.square") }
                                .font(.caption2)
                        }.foregroundStyle(.teal)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { p.accepted },
                        set: { v in if let i = store.proposals.firstIndex(where: { $0.id == p.id }) { store.proposals[i].accepted = v } }
                    )) {
                        Text("Keep original").tag(false)
                        Text("Use suggested").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220).controlSize(.small)
                        .disabled(!p.hasChange && !p.canAddArt)
                }
                if audio.playingURL == p.url { scrubBar }
                fieldChange("Artist", p.curArtist, p.newArtist, p.artistChanged)
                fieldChange("Title", p.curTitle, p.newTitle, p.titleChanged)
                HStack(spacing: 6) {
                    Text("Album").font(.caption2).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { p.chosenAlbum },
                        set: { v in if let i = store.proposals.firstIndex(where: { $0.id == p.id }) { store.proposals[i].chosenAlbum = v } }
                    )) {
                        ForEach(p.albumCandidates, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 300)
                    if p.albumChanged { Text("change").font(.caption2).foregroundStyle(.blue) }
                }
                creditChips(p)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func creditStrings(_ p: TrackProposal) -> [String] {
        var chips: [String] = []
        if p.canAddArt { chips.append("+ Artwork") }
        if let e = p.enrichment {
            if let c = e.composer { chips.append("+ Composer: \(c)") }
            if let l = e.lyricist { chips.append("+ Lyricist: \(l)") }
            if let lb = e.label { chips.append("+ Label: \(lb)") }
            for pf in e.performers.prefix(3) { chips.append("+ \(pf.name) · \(pf.role)") }
        }
        return chips
    }

    // Green "+" chips for the gap-fills (artwork/composer/label/performers).
    @ViewBuilder private func creditChips(_ p: TrackProposal) -> some View {
        let chips = creditStrings(p)
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { c in
                    Text(c).font(.system(size: 10)).foregroundStyle(Color(red: 0.03, green: 0.4, blue: 0.15))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                }
            }
            .padding(.top, 1)
        }
    }

    @ViewBuilder private func fieldChange(_ label: String, _ old: String, _ new: String, _ changed: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
            if changed {
                Text(old).font(.caption2).foregroundStyle(.secondary).strikethrough()
                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(new).font(.caption2).fontWeight(.medium).foregroundStyle(.primary)
            } else {
                Text(new.isEmpty ? old : new).font(.caption2).foregroundStyle(.secondary)
            }
        }
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

    private func applySummaryRows() -> [(text: String, color: Color)] {
        var rows: [(String, Color)] = []
        let acc = store.proposals.filter { $0.accepted }
        if store.applyNames { let n = acc.filter { $0.hasChange }.count; if n > 0 { rows.append(("Correct names on \(n) track(s)", .blue)) } }
        if store.applyArtwork { let n = acc.filter { $0.canAddArt }.count; if n > 0 { rows.append(("Add cover art to \(n) track(s)", .pink)) } }
        if store.applyCredits { let n = acc.filter { !($0.enrichment?.isEmpty ?? true) }.count; if n > 0 { rows.append(("Fill credits on \(n) track(s)", Color(red: 0.13, green: 0.6, blue: 0.3))) } }
        let merges = store.artists.filter { $0.accepted }.reduce(0) { $0 + $1.folderMerges }
        if merges > 0 { rows.append(("Merge \(merges) duplicate artist folder(s)", .purple)) }
        let tagfix = store.artists.filter { $0.accepted }.reduce(0) { $0 + $1.tagRewrites }
        if tagfix > 0 { rows.append(("Unify \(tagfix) artist tag(s)", .teal)) }
        let ren = store.renames.filter { $0.accepted && $0.newName != $0.oldName }.count
        if ren > 0 { rows.append(("Tidy \(ren) folder name(s)", .orange)) }
        let junk = store.findings.filter { $0.accepted && $0.kind == .junk }.count
        if junk > 0 { rows.append(("Remove \(junk) junk file(s)", .gray)) }
        let empty = store.findings.filter { $0.accepted && $0.kind == .emptyFolder }.count
        if empty > 0 { rows.append(("Delete \(empty) empty folder(s)", .gray)) }
        return rows
    }

    private var applyConfirmSheet: some View {
        let rows = applySummaryRows()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                Text("Apply these changes?").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if store.enriching {
                        Label("Credits are still being looked up — applying now writes the names, but not the credits/art still loading. You can wait for it to finish, or apply and run the rest later.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                    }
                    if rows.isEmpty {
                        Text("Nothing selected.").foregroundStyle(.secondary)
                    }
                    ForEach(rows, id: \.text) { r in
                        HStack(spacing: 10) {
                            Circle().fill(r.color).frame(width: 8, height: 8)
                            Text(r.text).font(.callout)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                Label("Removed items go to a recoverable quarantine — every change can be undone.",
                      systemImage: "arrow.uturn.backward")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { showApplyConfirm = false }
                Button("Confirm & apply") { showApplyConfirm = false; store.commit() }
                    .buttonStyle(.borderedProminent).tint(.purple).disabled(rows.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 400)
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
