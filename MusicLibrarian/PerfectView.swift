//
//  PerfectView.swift
//  MusicLibrarian
//
//  The Perfect screen: choose a library → diagnose → review → commit.
//  Phase 1 slice: junk, empty folders, DRM. Review-gated, quarantine on commit.
//

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// An album cover: the file's embedded art if it has one, else the cover we
/// *found* (Cover Art Archive) if art is going to be added, else a placeholder.
/// The playback seek bar. Observes ONLY AudioProgress, so the 4×/second tick
/// re-renders just this bar, not the whole screen. Seeks on RELEASE (not on every
/// drag value), so dragging is smooth instead of fighting the player.
struct ScrubBar: View {
    @ObservedObject private var prog = AudioProgress.shared
    @ObservedObject private var audio = AudioPreview.shared
    let url: URL
    @State private var dragging = false
    @State private var dragValue = 0.0

    private var playing: Bool { audio.playingURL == url }
    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    var body: some View {
        let shown = dragging ? dragValue : (playing ? prog.progress : 0)
        return HStack(spacing: 8) {
            Text(playing ? fmt(shown * audio.duration) : "0:00")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Slider(value: Binding(get: { shown }, set: { dragValue = $0 }), in: 0...1,
                   onEditingChanged: { editing in
                       guard playing else { return }
                       dragging = editing
                       if !editing { audio.seek(to: dragValue) }   // apply on release only
                   })
                .controlSize(.mini).tint(.teal).disabled(!playing)
            Text(playing && audio.duration > 0 ? fmt(audio.duration) : "—:—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .opacity(playing ? 1 : 0.5)
    }
}

struct AlbumCover: View {
    // Observe ONLY the lightweight refresh signal (bumped on cache clear), not the
    // image caches — so a fetch completing elsewhere doesn't re-render this card.
    @ObservedObject private var refresh = ArtRefresh.shared
    let key: String
    let sampleURL: URL?
    let foundMBID: String?
    var foundArtist: String = ""
    var foundAlbum: String = ""
    var wantsArt: Bool = false          // this album has art-less tracks → preview the cover it'll get
    let size: CGFloat
    var corner: CGFloat = 12

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
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
        // reload when the inputs change OR the caches were cleared (refresh.gen) —
        // fixes the "only updates when you scroll" staleness.
        .task(id: "\(key)|\(sampleURL?.path ?? "")|\(foundMBID ?? "")|\(wantsArt)|\(refresh.gen)") {
            image = await Self.bestImage(key: key, sampleURL: sampleURL, mbid: foundMBID,
                                         artist: foundArtist, album: foundAlbum, wantsArt: wantsArt)
        }
    }

    /// Prefer good embedded art; if it's missing OR a tiny thumbnail, use the
    /// higher-resolution service cover instead (fixes 60×50 pixelated cards).
    static func bestImage(key: String, sampleURL: URL?, mbid: String?,
                          artist: String, album: String, wantsArt: Bool) async -> NSImage? {
        // a cover the user picked in the Artwork step (not yet written) previews first
        if let d = await MainActor.run(body: { ArtworkChoices.shared.image(artist: artist, album: album) }),
           let img = NSImage(data: d) { return img }
        // otherwise ONLY what's already embedded in the files — never a fetched
        // guess. Art is chosen deliberately in the Artwork step; the grid must not
        // pull covers off the internet (that's what put wrong covers on Identify).
        return await ArtworkCache.shared.image(key: key, sampleURL: sampleURL)
    }
}

struct PerfectView: View {
    @ObservedObject var store: PerfectStore
    @ObservedObject private var audio = AudioPreview.shared
    @State private var expanded: Set<String> = []   // all sections collapsed initially — reads as a summary
    @State private var showSettings = false
    @State private var queueIndex = 0                // position in the step-through review queue
    // A/B preview: a ~30s clip of the PROPOSED match, so a queue item can be checked
    // by ear against the original file. Fetched on demand, cached per proposal.
    @State private var previewURL: [UUID: URL] = [:]
    @State private var previewLoading: Set<UUID> = []
    @State private var previewMissing: Set<UUID> = []   // no preview found for these
    @State private var savedFlash = false            // brief "Saved" toast after a queue decision
    @State private var showResetConfirm = false      // "Start over" confirmation
    @ObservedObject private var creds = APICredentials.shared   // live API-key status
    // The legacy artist-name/folder reconciliation panel. Its job (merging
    // AC-DC/AC_DC, picking one spelling) is now done by Organise + Identify, and
    // it flashed distractingly on entry while tags were read. Hidden from the UI;
    // the code is kept intact behind this flag.
    private let showLegacyArtistsPanel = false
    @State private var keysBannerDismissed = false   // per-launch dismiss of the "no key" banner
    @State private var fullCover: NSImage?           // full-size cover shown when the album-sheet art is clicked
    @State private var proposalExtras: [UUID: [(label: String, value: String)]] = [:]  // current tags for the album sheet
    // One sheet driver. SwiftUI only honours the LAST `.sheet` modifier on a view,
    // so two stacked sheets meant Apply silently never opened — hence a single enum.
    @State private var activeSheet: PerfectSheet? = nil

    enum PerfectSheet: Identifiable, Equatable {
        case apply                 // the final "confirm before commit" dialog
        case album(String)         // an album whose tracks are shown in a dialog
        case applying              // live progress while a commit/organise/dedup runs
        case done                  // "all done" summary after the final Apply
        var id: String {
            switch self {
            case .apply: return "apply"
            case .album(let a): return "album:\(a)"
            case .applying: return "applying"
            case .done: return "done"
            }
        }
    }

    // The step the user is on. It NEVER advances on its own — running a pass
    // (Scan/Identify/Credits) stays on its step and shows the results; the user
    // presses Next to move on. Back is the step chips.
    private var step: Int { store.wizardStep }   // persisted in the plan so a mid-run resumes in place

    // A step is reachable once every earlier step's pass has completed (or skipped).
    private func canReach(_ n: Int) -> Bool {
        switch n {
        case 1:  return true
        case 2:  return store.diagnosed              // Scan done
        case 3:  return store.didIdentify            // Identify done/skipped
        case 4:  return store.enriched               // Details done/skipped → Duplicates
        case 5:  return store.dedupStageDone         // Duplicates done/skipped → Organise
        case 6:  return store.organiseStageDone      // Organise done/skipped → Artwork
        case 7:  return store.artworkStageDone       // Artwork done/skipped → Review
        default: return false
        }
    }
    private let lastStep = 7                          // Review; Apply is the footer
    // The current step's own pass has finished (so Next may light up).
    private var stepDone: Bool { canReach(step + 1) }

    /// Advance to the next step, marking the skippable stages done as we leave them
    /// (whether or not they were applied).
    private func advance() {
        if step == 4 { store.dedupStageDone = true }
        if step == 5 { store.organiseStageDone = true }
        if step == 6 { store.artworkStageDone = true }
        store.wizardStep = min(step + 1, lastStep)
        store.savePlan()   // persist how far through the wizard we are
    }
    // Steps 1–3 need their pass done (Identify/Details are skippable via their own
    // Skip button); the skippable stages (4 Duplicates, 5 Organise, 6 Artwork) can
    // always be moved past; Review (7) uses Apply instead of Next.
    private var showNext: Bool {
        switch step {
        case 1, 2, 3: return canReach(step + 1)
        case 4, 5, 6: return true
        default:      return false
        }
    }
    private var nextLabel: String {
        if step == 4 { return store.deduped ? "Next" : "Skip →" }
        if step == 5 { return store.organised ? "Next" : "Skip →" }
        if step == 6 { return store.artworkStagePlanned ? "Next" : "Skip →" }
        return "Next"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !creds.acoustIDIsSet && !keysBannerDismissed {
                keysBanner
                Divider()
            }
            if store.root == nil {
                intro
            } else {
                stepBar
                Divider()
                phasedMiddle
                Divider()
                perfectFooter
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .apply: applyConfirmSheet
            case .album(let id): albumSheetView(id)
            case .applying: applyingSheet
            case .done: doneSheet
            }
        }
        .alert("Set up track identification?", isPresented: $store.showKeyReminder) {
            Button("Open Settings…") { openAppSettings() }
            Button("Continue without identification", role: .cancel) { }
        } message: {
            Text("Music Librarian identifies tracks by their sound using AcoustID — a free service. Without a key it still cleans tags, removes duplicates and organises your library, but it can't identify unknown tracks, fill credits, or fetch missing cover art.\n\nAdd a free key in Settings, then re-scan.")
        }
        // (setRoot resets the step for a new library, or restores it for a resume)
        // show/hide the progress dialog as any apply (commit/organise/dedup) runs;
        // when the FINAL commit finishes, swap straight to the "all done" summary.
        .onChange(of: store.committing) { running in
            if running { activeSheet = .applying }
            else if store.showCompletionSummary { activeSheet = .done }
            else if activeSheet == .applying { activeSheet = nil }
        }
        .overlay(alignment: .top) {
            if savedFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.green))
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Persistent (per-launch dismissible) notice when identification can't run
    /// because there's no AcoustID key. One click opens Settings to add one.
    private var keysBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.slash").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Track identification is off").font(.callout).fontWeight(.medium)
                Text("Add a free AcoustID key to identify unknown tracks, fill credits and fetch missing artwork. Cleaning, de-duplication and organising still work without it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add key in Settings…") { openAppSettings() }
            Button { keysBannerDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    /// A normal progress dialog shown while a commit/organise/dedup runs, so the
    /// apply is never invisible and can always be stopped. A proper sheet (not a
    /// screen-dimming overlay).
    private var applyingSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.purple)
            Text("Applying your changes").font(.headline)
            if store.commitTotal > 0 {
                ProgressView(value: Double(min(store.commitDone, store.commitTotal)),
                             total: Double(store.commitTotal))
                    .frame(width: 300)
                Text("\(min(store.commitDone, store.commitTotal)) of \(store.commitTotal)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 300)
            }
            Text(store.commitPhase.isEmpty ? "Working…" : store.commitPhase)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: 320)
            Text("Everything is written to a recoverable quarantine — you can Undo the whole run afterwards.")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(width: 320)
            Button(role: .cancel) { store.cancel() } label: {
                Label("Cancel", systemImage: "stop.fill").frame(minWidth: 120)
            }
            .controlSize(.large)
            .disabled(store.cancelRequested)
        }
        .padding(28)
        .frame(width: 380)
        .interactiveDismissDisabled()   // must use Cancel, not Escape/click-away
    }

    /// Shown after the final Review → Apply: what happened, a reminder that it's all
    /// reversible + logged, then Close resets the wizard to the new-library screen.
    private var doneSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 42)).foregroundStyle(.green)
            Text("All done").font(.title2).fontWeight(.semibold)
            Text(store.lastRunSummary ?? "Your changes have been applied.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Everything is reversible — you can Undo this whole run at any time.",
                      systemImage: "arrow.uturn.backward")
                Label("A full change log was written beside your library (in the quarantine folder).",
                      systemImage: "doc.text")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            if !store.missingTrackReports.isEmpty { missingTracksSummary }
            if !store.damagedTrackReports.isEmpty { damagedTracksSummary }
            HStack(spacing: 8) {
                if let q = store.lastQuarantine {
                    Button {
                        NSWorkspace.shared.open(q.appendingPathComponent("changelog.txt"))
                    } label: { Label("Change log", systemImage: "doc.text") }
                }
                if let run = store.currentRuns.first {
                    Button(role: .destructive) {
                        activeSheet = nil; store.showCompletionSummary = false; store.undo(run)
                    } label: { Label("Undo this run", systemImage: "arrow.uturn.backward") }
                }
                Spacer()
                Button {
                    activeSheet = nil
                    store.resetWizard()
                } label: { Text("Close").frame(minWidth: 80) }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    /// After Apply: albums the run found to be incomplete. Read-only — there's nothing
    /// to write for a track you don't have; the gaps are remembered so the Album
    /// Inspector greys them out. The full list is in the change log.
    private var missingTracksSummary: some View {
        let reports = store.missingTrackReports
        let totalMissing = reports.reduce(0) { $0 + $1.missing }
        return VStack(alignment: .leading, spacing: 6) {
            Label("\(totalMissing) missing track(s) across \(reports.count) album(s)",
                  systemImage: "questionmark.square.dashed")
                .font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(reports) { r in
                        Text("\(r.artist.isEmpty ? "" : r.artist + " — ")\(r.album): missing \(r.missing) of \(r.total)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 120)
            Text("Open an album in the Library to see exactly which tracks are missing (greyed out).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }

    /// After Apply: files that look truncated/damaged (much shorter than their album's
    /// typical length). Nothing was removed — this is for you to check and re-rip.
    private var damagedTracksSummary: some View {
        let reports = store.damagedTrackReports
        let total = reports.reduce(0) { $0 + $1.lines.count }
        return VStack(alignment: .leading, spacing: 6) {
            Label("\(total) track(s) look unusually short — possibly damaged, kept for you to check",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(reports) { r in
                        ForEach(r.lines, id: \.self) { line in
                            Text("\(r.album.isEmpty ? "" : r.album + " · ")\(line)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 100)
            Text("Nothing was deleted. Re-rip or replace these if they really are broken.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
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
            if store.root != nil {
                Button(role: .cancel) { showResetConfirm = true } label: {
                    Label("Start over", systemImage: "xmark.circle")
                }
                .disabled(store.busy)
                .help("Close this library and go back to the start")
            }
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .confirmationDialog("Start over?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Discard & choose another library", role: .destructive) { store.resetWizard() }
            Button("Keep working", role: .cancel) { }
        } message: {
            Text("This clears the current review (nothing already applied is undone — use Runs for that) and returns to the choose-a-library screen.")
        }
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
                stepChip(3, "Details"); stepDash()
                stepChip(4, "Duplicates"); stepDash()
                stepChip(5, "Organise"); stepDash()
                stepChip(6, "Artwork"); stepDash()
                stepChip(7, "Review"); stepDash()
                stepChip(8, "Apply")
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stepTitle).font(.system(size: 15, weight: .semibold))
                    Text(stepSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                stepAction
                if showNext {
                    Button { advance() } label: {
                        Label(nextLabel, systemImage: "arrow.right").frame(minWidth: 64)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
                }
            }
            if step == 7, reviewQueueCount > 0 { needsBanner }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 13)
    }

    private func stepChip(_ n: Int, _ label: String) -> some View {
        // "done" = this step's own pass has finished (its next step is reachable).
        let done = n < 7 && canReach(n + 1) && n != step
        let now = step == n, reachable = canReach(n)
        return Button {
            if reachable { store.wizardStep = n; store.savePlan() }
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
        case 3: return "Step 3 — Details"
        case 4: return "Step 4 — Duplicates"
        case 5: return "Step 5 — Organise"
        case 6: return "Step 6 — Artwork"
        default: return "Step 7 — Review"
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
        case 3: return "Filling in missing details — composer, label and other credits — for tracks that lack them."
        case 4: return "Find duplicate tracks and keep the best copy — or skip if you don't need it."
        case 5: return "Rebuild a clean Album Artist / Album / ## Title tree from the tags — or skip it."
        case 6: return "Your existing covers are kept. Choose art only for albums that are missing or mixed — or skip."
        default:
            let act = store.proposals.filter { $0.isActionable }.count
            return "\(act) track(s) with a suggested change. \(reviewQueueCount) worth checking before you apply."
        }
    }

    @ViewBuilder private var stepAction: some View {
        if store.identifying || store.enriching || (store.busy && !store.diagnosed) {
            Button("Cancel") { store.cancel() }.controlSize(.large)
        } else if step == 1 {
            passButton(stepDone ? "Re-scan" : "Scan library", "magnifyingglass") { store.explore() }
        } else if step == 2 && !store.hasAcoustIDKey {
            Button("Add AcoustID key…") { openAppSettings() }
                .controlSize(.large)
                .help("Identification needs a free AcoustID key — add it in Settings, then re-scan.")
            Button("Skip →") { store.didIdentify = true }.controlSize(.large)
        } else if step == 2 {
            passButton(stepDone ? "Re-identify" : "Identify tracks", "waveform.and.magnifyingglass") { store.identify() }
            if !stepDone { Button("Skip →") { store.didIdentify = true }.controlSize(.large) }
        } else if step == 3 {
            passButton(stepDone ? "Re-fill details" : "Fill details", "text.badge.plus") { store.enrich() }
            if !stepDone { Button("Skip details →") { store.enriched = true }.controlSize(.large) }
        } else if step == 4 {
            passButton(store.deduped ? "Re-scan duplicates" : "Find duplicates", "square.on.square") { store.dedup() }
        } else if step == 5 {
            passButton(store.organised ? "Re-plan tree" : "Preview clean tree", "eye") { store.organise() }
        } else if step == 6 {
            passButton(store.artworkStagePlanned ? "Re-check artwork" : "Review artwork", "photo.on.rectangle.angled") { store.planArtworkStage() }
        } else {
            EmptyView()   // Review just uses the footer Apply
        }
    }

    // The step's own pass button — prominent while it's the thing to do, quiet
    // once done (Next becomes the prominent button then).
    @ViewBuilder private func passButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        if stepDone {
            Button(action: action) { Label(title, systemImage: icon) }
                .controlSize(.large).buttonStyle(.bordered)
        } else {
            Button(action: action) { Label(title, systemImage: icon) }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
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
        switch step {
        case 1:
            if store.busy && !store.diagnosed { workingMiddle(title: "Scanning your library", sub: "reading tags, finding junk and duplicate artists") }
            else if store.diagnosed { cleanupMiddle }   // Scan results
            else { scanPrompt }                          // not scanned yet
        case 2:
            if store.identifying {
                if store.identifyListening {
                    workingMiddle(title: "listening to your library", sub: store.identifyProgress, live: true, listening: true)
                } else {
                    workingMiddle(title: "matched by sound", sub: store.identifyProgress, live: true)
                }
            }
            else { reviewMiddle }                        // name suggestions (or prompt if not run)
        case 3:
            if store.enriching { workingMiddle(title: "looking up credits", sub: store.enrichProgress, live: true, credits: true) }
            else { reviewMiddle }                        // credit adds (or prompt if not run)
        case 4:
            dedupMiddle                                  // Duplicates stage
        case 5:
            organiseMiddle                               // Organise stage
        case 6:
            artworkMiddle                                // Artwork stage
        default:
            reviewMiddle                                 // Review (step 7)
        }
    }

    private var dedupMiddle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                dedupSection
                if store.deduped && store.dedupClusters.isEmpty {
                    Text("No duplicates found — press Next to carry on.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
            .padding(16)
        }
    }

    private var proposedTree: [FileTreeNode] {
        FileTree.from(store.organisePlans.map { (path: $0.targetRel ?? $0.rel, planID: $0.id) })
    }
    private var currentTree: [FileTreeNode] {
        FileTree.from(store.organisePlans.map { (path: $0.rel, planID: $0.id) })
    }

    @ViewBuilder private var organiseMiddle: some View {
        let moves = store.organisePlans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }
        let flagged = store.organisePlans.filter { $0.targetRel == nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.purple)
                Text("Clean tree").fontWeight(.semibold)
                Text("Album Artist / Album / ## Title").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Renumber 1…N per album", isOn: $store.renumberTracks)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Assign clean sequential track numbers within each album/disc. Best on complete albums; preview shows the result and it's reversible.")
                    .onChange(of: store.renumberTracks) { _ in
                        if !store.organisePlans.isEmpty { store.organise() }
                    }
                Toggle("Check for missing tracks", isOn: $store.checkMissingTracks)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("After the clean tree is built, check each album online (MusicBrainz, Discogs, Deezer) and remember which tracks it's missing, so the Album Inspector can grey them out. Uses the network — turn off for a quick offline run.")
                Toggle("Composer-first for classical", isOn: $store.composerFirstClassical)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: store.composerFirstClassical) { _ in
                        if !store.organisePlans.isEmpty { store.organise() }
                    }
            }
            if store.organising {
                HStack(spacing: 8) { ProgressView().controlSize(.small)
                    Text(store.organiseProgress.isEmpty ? "Planning…" : store.organiseProgress)
                        .font(.caption).foregroundStyle(.secondary) }
                Spacer()
            } else if store.organisePlans.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 40, weight: .light)).foregroundStyle(.purple)
                    Text("Preview the clean tree").font(.title3).fontWeight(.semibold)
                    Text("Press “Preview clean tree” above to see exactly where every file would go, side by side with where it is now.\nNothing moves until the final Apply — or skip this stage.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                albumMergePanel
                compilationsPanel
                Text("\(moves.count) file(s) to reorganise on Apply · \(flagged.count) left in place · rename folders/files on the right if you like")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    treePanelColumn(title: "NOW", subtitle: "on disk",
                                    panel: OrganiseTreePanel(nodes: currentTree, editable: false))
                    Divider()
                    treePanelColumn(title: "PROPOSED", subtitle: "click ✎ to rename a folder or file",
                                    panel: OrganiseTreePanel(nodes: proposedTree, editable: true,
                                        onRenameFolder: { store.renameOrganiseFolder($0, to: $1) },
                                        onRenameFile: { store.renameOrganiseFile(planID: $0, to: $1) }))
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
            }
        }
        .padding(16)
    }

    // Albums that look like various-artists compilations. Flagged ones (TCMP/cpil) are
    // filed under "Various Artists" automatically; flag-less guesses need a tick to confirm.
    @ViewBuilder private var compilationsPanel: some View {
        let cands = store.compilationCandidates
        if !cands.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.square.stack").foregroundStyle(.orange)
                    Text("Compilations").fontWeight(.semibold)
                    Text("filed under “Various Artists” instead of split across each artist")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(cands) { c in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { store.confirmedCompilations.contains(c.id) },
                            set: { store.toggleCompilation(c.id, on: $0) }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .disabled(c.flagged)
                            .help(c.flagged ? "Tagged as a compilation — filed automatically." : "Tick to file this as a Various Artists compilation.")
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(c.album).fontWeight(.medium)
                                if c.flagged {
                                    Text("tagged").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("\(c.trackCount) tracks · \(c.artists.count) artists: \(c.artists.prefix(4).joined(separator: ", "))\(c.artists.count > 4 ? "…" : "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
        }
    }

    // Differently-named folders of the same album ("Legends" + "Legends [Sony]", or a
    // "[Castle]" edition) that will be folded into one. On by default; untick to keep apart.
    @ViewBuilder private var albumMergePanel: some View {
        let cands = store.albumMergeCandidates
        if !cands.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(.blue)
                    Text("Album editions to merge").fontWeight(.semibold)
                    Text("same album under different folder names — combined into one, keeping the best of each")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(cands) { m in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { !store.declinedAlbumMerges.contains(m.key) },
                            set: { store.toggleAlbumMerge(m.key, on: $0) }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .help("Merge these into one album folder. Untick to keep them separate.")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(m.artist.isEmpty ? "" : m.artist + " — ")\(m.display)").fontWeight(.medium)
                            Text("folders: \(m.rawNames.joined(separator: "  ·  "))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.25)))
        }
    }

    private func treePanelColumn(title: String, subtitle: String, panel: OrganiseTreePanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            panel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.purple)
            Text("Ready to scan").font(.title3).fontWeight(.semibold)
            Text(store.root?.lastPathComponent ?? "").font(.callout).foregroundStyle(.secondary)
            Text("Press “Scan library” above to read the tags and find junk, empty folders and duplicate artists. Nothing is changed.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Scan's output — the structural cleanups, shown as their own step (not hidden).
    private var cleanupMiddle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What the scan found — junk files, empty folders and duplicate artists. These merge/clean on disk when you Apply.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.renames.isEmpty && store.groups.isEmpty && !store.checkingTags {
                    Text("Nothing to clean up — the folder structure is already tidy.").foregroundStyle(.secondary).padding(.top, 8)
                }
                if showLegacyArtistsPanel { artistsSection }
                if !store.renames.isEmpty { renamesSection }
                ForEach(store.groups, id: \.kind.rawValue) { group in section(group.kind, group.items) }
            }
            .padding(16)
        }
    }

    private func workingMiddle(title: String, sub: String, live: Bool = false, credits: Bool = false, listening: Bool = false) -> some View {
        let bigNumber = listening ? store.identifyListened : (credits ? store.enrichDone : store.identifyMatched)
        return VStack(spacing: 10) {
            Spacer()
            if live {
                Text("\(bigNumber)")
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
                if step == 7, let summary = store.lastRunSummary { committedBanner(summary) }
                if step == 7 && store.organiseStale { organiseStaleBanner }
                if step == 2 || step == 7 { nameChangeSummary }
                if step == 2 || step == 3 { identifiedNote }
                if step == 7 && !store.artworkNeedsReview.isEmpty { artworkReviewSection }
                if step == 7 { anyAlbumArtworkDisclosure }
                if visibleAlbums.isEmpty && !store.identifying && !store.enriching {
                    emptyStageNote
                }
                if step == 7 { reviewQueueSection }   // the decision queue only on Review
                albumGrid
            }
            .padding(16)
        }
    }

    /// Shown on Review when a confirmed album/name change happened after Organise
    /// already ran — one click re-files the affected tracks (reversibly) so the
    /// tree matches your decisions before the final Apply.
    private var organiseStaleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("A confirmed change affects the folder layout").font(.system(size: 13, weight: .semibold))
                Text("You accepted an album or name change after organising. Re-organise to move those tracks into the right folders before applying.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Re-organise") { store.reorganiseStragglers() }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(store.busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
    }

    /// Explains why a step shows fewer tracks than were scanned: only tracks that
    /// AcoustID matched by sound get a proposal, so unmatched tracks aren't here.
    @ViewBuilder private var identifiedNote: some View {
        if store.totalFiles > 0 {
            let identified = max(store.identifyMatched, store.proposals.count)
            let unmatched = max(0, store.totalFiles - identified)
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("\(identified) of \(store.totalFiles) tracks identified by sound"
                     + (unmatched > 0 ? " · \(unmatched) couldn't be matched, so they're left as they are" : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // Albums shown depend on which step you're viewing, so stepping back to
    // Identify or Credits shows what THAT step did, not the whole thing.
    private var visibleAlbums: [PerfectStore.AlbumChange] {
        let all = store.albumChanges
        switch step {
        case 2: return all.filter { $0.names }                       // name/album fixes
        case 3: return all.filter { $0.credits }                     // credit fills (art is its own step now)
        default: return all
        }
    }

    // ── Artwork step (step 4) ──
    // Keep-existing is the default; this step only surfaces albums that are
    // missing a cover or carry different covers, and lets you pick one (from the
    // album's own covers, a file, or an online search). Every choice is applied
    // reversibly as its own run.
    private var artworkMiddle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your existing covers are kept as they are. This step is only for albums that are missing a cover or have different covers on different tracks — pick one and it goes on every track (reversible).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if !store.artworkStagePlanned {
                    Text("Press “Review artwork” above to find the albums that need a cover.")
                        .foregroundStyle(.secondary).padding(.top, 6)
                } else if store.artworkNeedsReview.isEmpty {
                    Label("Every album already has a cover — nothing to choose here. Press Next.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green).padding(.top, 6)
                } else {
                    artworkReviewSection
                }

                if store.artworkStagePlanned {
                    Divider().padding(.vertical, 4)
                    Text("Want to change a cover that's already there? Pick its album to review it:")
                        .font(.caption).foregroundStyle(.secondary)
                    artworkAllAlbumsGrid
                }
            }
            .padding(16)
        }
    }

    // EVERY album the scan found (folder-based), so any one can be opened for a cover
    // change — not just the AcoustID-matched ones. Where identify corrected an album's
    // name, that name is shown; unidentified albums show by their folder. This is what
    // lets you fix a cover that's present but wrong on an album we never matched.
    private var artAlbumGroups: [(artist: String, album: String, files: [String])] {
        // Prefer the FINAL organise plan so the grid shows the corrected tree — one card per
        // album AS IT WILL BE after Apply (editions merged, duplicates folded, husks gone) —
        // instead of the raw pre-Perfect folders. Group by the destination Album Artist/Album
        // folder; carry each track's ORIGINAL path (art is embedded before the move).
        if !store.organisePlans.isEmpty {
            var byAlbum: [String: (artist: String, album: String, files: [String])] = [:]
            for p in store.organisePlans {
                let finalRel = p.targetRel ?? p.rel
                if finalRel.hasPrefix("Music Librarian Quarantine") { continue }   // being discarded
                let folder = (finalRel as NSString).deletingLastPathComponent
                guard !folder.isEmpty, folder != "." else { continue }
                let album = (folder as NSString).lastPathComponent
                let artist = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
                var e = byAlbum[folder] ?? (artist, album, [])
                e.files.append(p.rel)
                byAlbum[folder] = e
            }
            if !byAlbum.isEmpty {
                return byAlbum.values.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
            }
        }

        // Fallbacks when Organise hasn't been previewed (files are still in their scanned
        // folders): use the scan list, with identify's corrected names where we have them.
        var nameByFolder: [String: (artist: String, album: String)] = [:]
        for p in store.proposals {
            let folder = p.url.deletingLastPathComponent().path
            let artist = p.newArtist.isEmpty ? p.curArtist : p.newArtist
            let album = Organiser.stripDiscSuffix(p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum).clean
            if !album.isEmpty, nameByFolder[folder] == nil { nameByFolder[folder] = (artist, album) }
        }
        if !store.scannedAlbums.isEmpty {
            return store.scannedAlbums.map { a in
                let named = nameByFolder[a.id]
                return (named?.artist ?? a.artist, named?.album ?? a.album, a.files)
            }.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
        }
        var byAlbum: [String: (artist: String, album: String, files: [String])] = [:]
        for p in store.proposals {
            let artist = p.newArtist.isEmpty ? p.curArtist : p.newArtist
            let album = Organiser.stripDiscSuffix(p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum).clean
            let key = "\(artist.lowercased())|\(album.lowercased())"
            var e = byAlbum[key] ?? (artist, album, [])
            e.files.append(p.relPath)
            byAlbum[key] = e
        }
        return byAlbum.values.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
    }

    /// On the final Review: spotted a cover that's wrong (even one that's present)?
    /// Every album is here — pick it to choose a new cover, identified or not.
    @ViewBuilder private var anyAlbumArtworkDisclosure: some View {
        let groups = artAlbumGroups
        if !groups.isEmpty {
            DisclosureGroup {
                artworkAllAlbumsGrid.padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
                    Text("Change a cover on any album (\(groups.count))").font(.callout)
                    Text("including ones with a cover that's just wrong").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
        }
    }

    private var artworkAllAlbumsGrid: some View {
        let groups = artAlbumGroups
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(groups.indices, id: \.self) { i in
                let g = groups[i]
                let inReview = store.artworkNeedsReview.contains { $0.artist == g.artist && $0.album == g.album }
                Button { store.reviewAlbumArt(artist: g.artist, album: g.album, files: g.files) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: inReview ? "photo.badge.checkmark" : "photo").foregroundStyle(inReview ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(g.album.isEmpty ? "Unknown Album" : g.album).font(.callout).lineLimit(1)
                            Text(g.artist.isEmpty ? "Unknown Artist" : g.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
                .buttonStyle(.plain).disabled(inReview)
            }
        }
    }

    // Remove duplicate tracks, keeping the best copy and merging in what it's missing.
    @ViewBuilder private var dedupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square").foregroundStyle(.purple)
                Text("Duplicates").fontWeight(.semibold)
                Text("keep the best copy, merge in its missing art/tags").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if store.deduping {
                HStack(spacing: 8) { ProgressView().controlSize(.small)
                    Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } else if store.dedupClusters.isEmpty {
                Text(store.deduped ? "No duplicates found — press Next to carry on."
                                   : "Press “Find duplicates” above to match tracks by content and tags; you pick which copy to keep.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(store.dedupClusters.count) group(s) · \(store.dedupRemovableCount) file(s) will be removed on Apply — pick which copy to keep.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.dedupClusters) { cluster in dedupClusterRow(cluster) }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
    }

    private func dedupClusterRow(_ cluster: Cluster) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let k = store.dedupTrack(cluster.keeperID) {
                Text("\(k.displayArtist) — \(k.title)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Text("\(cluster.memberIDs.count) copies · \(cluster.reason) · click a copy to keep it")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(cluster.memberIDs, id: \.self) { tid in
                if let t = store.dedupTrack(tid) {
                    let keep = cluster.keeperID == tid
                    HStack(spacing: 8) {
                        Image(systemName: keep ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(keep ? .green : .secondary)
                        Text(keep ? "KEEP" : "remove").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(keep ? .green : .orange).frame(width: 48, alignment: .leading)
                        Text(t.url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(bitrateLabel(t)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Text(fmtBytes(t.size)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.setDedupKeeper(clusterID: cluster.id, trackID: tid) }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.4)))
    }

    // Codec + bitrate for the dedup rows. When the exact rate didn't read, show the
    // effective rate (size over duration) with a ~ so you can still compare quality.
    private func bitrateLabel(_ t: Track) -> String {
        let codec = t.codec.uppercased()
        if t.lossless { return "◆ \(codec)" }
        if t.bitrate > 0 { return "\(codec) \(t.bitrate)k" }
        let eff = Int(t.effectiveKbps.rounded())
        return eff > 0 ? "\(codec) ~\(eff)k" : codec
    }

    // Rebuild the clean Album Artist / Album / ## Title tree from tags.
    @ViewBuilder private var organiseSection: some View {
        let moves = store.organisePlans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }
        let flagged = store.organisePlans.filter { $0.targetRel == nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.purple)
                Text("Organise into a clean tree").fontWeight(.semibold)
                Text("Album Artist / Album / ## Title").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Composer-first for classical", isOn: $store.composerFirstClassical)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: store.composerFirstClassical) { _ in
                        if !store.organisePlans.isEmpty { store.organise() }   // re-plan on toggle
                    }
            }
            if store.organising {
                HStack(spacing: 8) { ProgressView().controlSize(.small)
                    Text(store.organiseProgress.isEmpty ? "Planning…" : store.organiseProgress)
                        .font(.caption).foregroundStyle(.secondary) }
            } else if store.organisePlans.isEmpty {
                HStack(spacing: 10) {
                    Button { store.organise() } label: { Label("Preview clean tree", systemImage: "eye") }
                        .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple).disabled(store.busy)
                    Text("See exactly where every file would go — nothing moves until you apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("\(moves.count) file(s) to reorganise · \(flagged.count) left in place (couldn't place from tags)")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(moves.prefix(60)) { p in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.rel).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                    Text(p.targetRel ?? "").font(.system(size: 11, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    if !p.tagWrites.isEmpty {
                                        Text("+\(p.tagWrites.map { $0.field }.joined(separator: ","))")
                                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.purple)
                                    }
                                }
                            }
                        }
                        if moves.count > 60 {
                            Text("…and \(moves.count - 60) more").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxHeight: 240)
                HStack {
                    Button { store.organise() } label: { Label("Re-plan", systemImage: "arrow.clockwise") }
                        .controlSize(.small).disabled(store.busy)
                    Spacer()
                    Button { store.applyOrganise() } label: {
                        Label("Organise \(moves.count) file(s)", systemImage: "checkmark.circle.fill")
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(store.busy || moves.isEmpty)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
    }

    // Albums whose art couldn't be resolved during Apply — pick a cover by hand.
    private var artworkReviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.orange)
                Text("Artwork needs your choice").fontWeight(.semibold)
                Text("mixed or missing covers, no match found online").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.artworkNeedsReview) { item in
                ArtworkReviewCard(store: store, item: item)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.07)))
    }

    private var emptyStageNote: some View {
        Text(emptyStageMsg).foregroundStyle(.secondary).padding(.top, 8)
    }
    private var emptyStageMsg: String {
        switch step {
        case 2:
            return store.proposals.isEmpty
                ? "Press “Identify tracks” above to match your library by sound."
                : "No name or album corrections — your tags already matched the audio."
        case 3:
            return store.enriched
                ? "No credits or artwork were found to add."
                : "Press “Fill details” above to add composer, label and other credits (or Skip)."
        default: return "Nothing to change — this library is already tidy."
        }
    }

    // ── BOTTOM: status + apply (locked until Review) ──
    private var perfectFooter: some View {
        HStack(spacing: 14) {
            perfectStatus
            Spacer()
            if let run = store.currentRuns.first {
                Button("Undo last run") { store.undo(run) }.disabled(store.busy)
            }
            Button {
                activeSheet = .apply
            } label: { Label("Apply changes", systemImage: "checkmark.circle") }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(!canReach(7) || !store.hasWork || store.busy)
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
        let props = store.proposals.filter { store.albumGroupKey($0) == id && $0.isActionable }
        let a = store.albumChanges.first(where: { $0.id == id })
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                AlbumCover(key: id, sampleURL: (props.first(where: { $0.curHasArt }) ?? props.first)?.url,
                           foundMBID: a?.artReleaseMBID,
                           foundArtist: a?.subtitle ?? "", foundAlbum: a?.title ?? "",
                           wantsArt: a?.artwork ?? false, size: 52, corner: 8)
                    .onTapGesture {
                        loadFullCover((props.first(where: { $0.curHasArt }) ?? props.first)?.url,
                                      mbid: a?.artReleaseMBID, artist: a?.subtitle ?? "", album: a?.title ?? "")
                    }
                    .help("Click to see the cover full size")
                VStack(alignment: .leading, spacing: 1) {
                    Text(a?.title ?? "Album").font(.headline)
                    Text("\(a?.subtitle ?? "") · \(props.count) track(s)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { activeSheet = nil }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(props) { p in proposalRow(p) }
                }.padding(16)
            }
        }
        .frame(width: 620, height: 560)
        .overlay { fullCoverOverlay }
        .onAppear { loadProposalExtras(props) }
        .onDisappear { audio.stop(); fullCover = nil }
    }

    /// A tap-to-dismiss full-size view of the album cover, over the album sheet.
    @ViewBuilder private var fullCoverOverlay: some View {
        if let img = fullCover {
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480, maxHeight: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 24)
                    Text("\(Int(img.size.width)) × \(Int(img.size.height)) · click to close")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .padding(24)
            }
            .contentShape(Rectangle())
            .onTapGesture { fullCover = nil }
        }
    }

    /// Read the album's full-resolution embedded cover (not the downscaled cache) for the overlay.
    /// Show the album's cover full size — whatever is actually on screen: the
    /// embedded art if the file has it, otherwise the fetched service cover (so
    /// the click works for albums whose shown cover was fetched, not embedded).
    private func loadFullCover(_ url: URL?, mbid: String?, artist: String, album: String) {
        Task {
            var img: NSImage? = nil
            if let url {
                let asset = AVURLAsset(url: url)
                if let meta = try? await asset.load(.commonMetadata) {
                    let items = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork)
                    if let item = items.first, let data = try? await item.load(.dataValue) { img = NSImage(data: data) }
                }
            }
            if img == nil || max(img!.size.width, img!.size.height) < 180 {
                if let f = await FoundArtCache.shared.image(mbid: mbid, artist: artist, album: album) { img = f }
            }
            if let img { await MainActor.run { fullCover = img } }
        }
    }

    /// Read the current tags for the album's tracks so the review rows show them all.
    private func loadProposalExtras(_ props: [TrackProposal]) {
        Task {
            var out: [UUID: [(label: String, value: String)]] = [:]
            for p in props { out[p.id] = TagReader.chips(p.url) }
            await MainActor.run { proposalExtras = out }
        }
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

                    AlbumCover(key: p.url.deletingLastPathComponent().path, sampleURL: p.url,
                               foundMBID: p.enrichment?.releaseMBID,
                               foundArtist: p.newArtist.isEmpty ? p.curArtist : p.newArtist,
                               foundAlbum: p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum,
                               wantsArt: !p.curHasArt, size: 96, corner: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(p.newTitle.isEmpty ? p.curTitle : p.newTitle).font(.headline)
                            Text(String(format: "%.0f%% by sound", p.score * 100))
                                .font(.caption2).foregroundStyle(p.score >= 0.9 ? .green : .orange)
                            Spacer()
                            changeKindTags(p)
                        }
                        // A/B: play your file vs a preview of the proposed match — hear
                        // both; picking one switches playback (one player) so you can
                        // confirm the identification is really the same song.
                        HStack(spacing: 8) {
                            playButton(p.url)
                            Text("your file").font(.caption2).foregroundStyle(.teal)
                            Text("vs").font(.caption2).foregroundStyle(.tertiary)
                            proposedPlayButton(p)
                            Spacer()
                        }
                        scrubber(audio.playingURL ?? p.url)
                        // who/what this track is — so a decision is possible even with no cover
                        Text("\(p.newArtist.isEmpty ? p.curArtist : p.newArtist) · \(p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        // before → after for every field that actually changes
                        VStack(alignment: .leading, spacing: 5) {
                            if p.titleChanged  { changeRow("Title",  p.curTitle,  p.newTitle) }
                            if p.artistChanged { changeRow("Artist", p.curArtist, p.newArtist) }
                            if p.albumChanged  { changeRow("Album",  p.curAlbum,  p.chosenAlbum) }
                        }
                        .padding(.vertical, 2)
                        if p.artistChanged {
                            Text("A genuine artist change — check it's the same act, not a different one, before accepting.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if !p.titleChanged && !p.albumChanged {
                            Text("Low-confidence match (\(String(format: "%.0f%%", p.score * 100))) — worth a glance before applying.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Spacer()
                            Button("Don't apply") { resolveQueueItem(p, accept: false) }
                                .controlSize(.small)
                            Button("Keep change →") { resolveQueueItem(p, accept: true) }
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
        let albums = visibleAlbums
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.purple)
                    Text("\(albums.count) album(s)").fontWeight(.semibold)
                    Text(albumGridSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 210), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    ForEach(albums) { a in albumCard(a) }
                }
            }
        }
    }
    private var albumGridSubtitle: String {
        switch step {
        case 2: return "names & albums corrected from the audio · click to see tracks"
        case 3: return "composer, label & other credits added · click to see tracks"
        default: return "everything to change · click an album to see and hear its tracks"
        }
    }

    private func albumCard(_ a: PerfectStore.AlbumChange) -> some View {
        Button {
            activeSheet = .album(a.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    AlbumCover(key: a.id, sampleURL: a.sampleURL, foundMBID: a.artReleaseMBID,
                               foundArtist: a.subtitle, foundAlbum: a.title, wantsArt: a.artwork, size: 176)
                    HStack(spacing: 5) {
                        if a.names { cardTag("Names", .blue) }
                        if a.credits { cardTag("+ Credits", Color(red: 0.13, green: 0.6, blue: 0.3)) }
                        // '+ Art' only from the Artwork step onward — art isn't decided
                        // on Identify/Details, so advertising it there is premature.
                        if a.artwork && step >= 6 { cardTag("+ Art", .pink) }
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

    private var scrubBar: some View { ScrubBar(url: audio.playingURL ?? URL(fileURLWithPath: "/")) }

    private func playButton(_ url: URL) -> some View {
        let playing = audio.playingURL == url
        let drm = url.pathExtension.lowercased() == "m4p"
        return Button { if !drm { audio.toggle(url) } } label: {
            Image(systemName: drm ? "lock.circle" : (playing ? "stop.circle.fill" : "play.circle"))
                .font(.system(size: 18)).foregroundStyle(drm ? Color.secondary : (playing ? Color.red : Color.teal))
        }.buttonStyle(.plain).disabled(drm)
        .help(drm ? "Protected (DRM) — this file can't be played or re-encoded" : (playing ? "Stop" : "Listen"))
    }

    /// Play a ~30s preview of the PROPOSED match (from iTunes/Deezer), so you can
    /// hear whether it's really the same song as your file. Playing it switches
    /// playback away from the original (one player), which is the A/B compare.
    @ViewBuilder private func proposedPlayButton(_ p: TrackProposal) -> some View {
        let loading = previewLoading.contains(p.id)
        let missing = previewMissing.contains(p.id)
        let tmp = previewURL[p.id]
        let playing = tmp != nil && audio.playingURL == tmp
        Button { playProposedPreview(p) } label: {
            HStack(spacing: 3) {
                if loading { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18, height: 18) }
                else {
                    Image(systemName: missing ? "waveform.slash" : (playing ? "stop.circle.fill" : "waveform.circle"))
                        .font(.system(size: 18))
                        .foregroundStyle(missing ? Color.secondary : (playing ? Color.red : Color.purple))
                }
                Text("match").font(.caption2).foregroundStyle(missing ? Color.secondary : Color.purple)
            }
        }
        .buttonStyle(.plain).disabled(loading || missing)
        .help(missing ? "No online preview found for the proposed match"
                      : "Hear a short preview of the proposed match to check it's the same song")
    }

    private func playProposedPreview(_ p: TrackProposal) {
        if let tmp = previewURL[p.id] { audio.toggle(tmp); return }
        guard !previewLoading.contains(p.id), !previewMissing.contains(p.id) else { return }
        let artist = p.newArtist.isEmpty ? p.curArtist : p.newArtist
        let title = p.newTitle.isEmpty ? p.curTitle : p.newTitle
        previewLoading.insert(p.id)
        Task {
            let url = await CoverArtClient().trackPreview(artist: artist, title: title)
            await MainActor.run {
                previewLoading.remove(p.id)
                if let url { previewURL[p.id] = url; audio.toggle(url) }
                else { previewMissing.insert(p.id) }
            }
        }
    }

    /// A seek bar so you can skip through the track while reviewing it.
    private func scrubber(_ url: URL) -> some View { ScrubBar(url: url) }

    /// Record the review decision and drop the item from the queue (it disappears
    /// because `needsReview` now returns false). Stops any preview that's playing.
    private func resolveQueueItem(_ p: TrackProposal, accept: Bool) {
        audio.stop()
        if let i = store.proposals.firstIndex(where: { $0.id == p.id }) {
            store.proposals[i].accepted = accept
            store.proposals[i].reviewed = true
        }
        // (No organise-stale flag needed now: the final Apply re-plans the tree from
        // the settled tags, so a late-accepted change lands in the right folder.)
        store.savePlan()   // remember the decision across app restarts
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation { savedFlash = false }
        }
    }

    // Summary of the name changes by type, with bulk on/off for the safe kinds so
    // cosmetic tidies and version-detail additions don't need per-track review.
    @ViewBuilder private var nameChangeSummary: some View {
        let named = store.proposals.filter { $0.hasChange }
        let cosmetic = named.filter { $0.dominantNameKind == .cosmetic }.count
        let additive = named.filter { $0.dominantNameKind == .additive }.count
        let substantive = named.filter { $0.dominantNameKind == .substantive }.count
        if cosmetic + additive + substantive > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name changes").fontWeight(.semibold)
                if cosmetic > 0 {
                    nameSummaryRow(.gray, "\(cosmetic) cosmetic", "case & punctuation", toggle: $store.applyCosmeticNames)
                }
                if additive > 0 {
                    nameSummaryRow(.blue, "\(additive) add detail", "e.g. (Single Version), feat.", toggle: $store.applyAdditiveNames)
                }
                if substantive > 0 {
                    nameSummaryRow(.orange, "\(substantive) different", "reviewed individually", toggle: nil)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        }
    }

    @ViewBuilder private func nameSummaryRow(_ colour: Color, _ title: String, _ sub: String,
                                             toggle: Binding<Bool>?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 9, height: 9)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(sub).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let toggle {
                Toggle(isOn: toggle) {
                    Text(toggle.wrappedValue ? "applying" : "keeping originals")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).controlSize(.mini)
            } else {
                Text("↓ in the queue").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // Coloured labels telling you WHAT kind of change each field is, so you can
    // scan an album and only stop on the ones that matter.
    /// One "FIELD  old → new" row for the review card, so the exact before/after
    /// is visible (not just that "something" changed).
    private func changeRow(_ label: String, _ old: String, _ new: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(old.isEmpty ? "(blank)" : old).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(new).font(.callout).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private func changeKindTags(_ p: TrackProposal) -> some View {
        HStack(spacing: 4) {
            if p.titleChanged  { changeKindTag("Title",  p.titleChangeKind) }
            if p.artistChanged { changeKindTag("Artist", p.artistChangeKind) }
            if p.albumChanged  { changeKindTag("Album",  p.albumChangeKind) }
        }
    }

    @ViewBuilder private func changeKindTag(_ field: String, _ kind: ChangeKind) -> some View {
        if kind != .none {
            let colour: Color = {
                switch kind {
                case .cosmetic:    return .gray
                case .additive:    return .blue
                case .substantive: return .orange
                case .none:        return .clear
                }
            }()
            Text("\(field): \(kind.label)")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(colour.opacity(0.16)))
                .foregroundStyle(colour)
        }
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
                    changeKindTags(p)
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
                    }.labelsHidden().frame(maxWidth: 300, alignment: .leading)
                    if p.albumChanged { Text("change").font(.caption2).foregroundStyle(.blue) }
                    Spacer(minLength: 0)
                }
                TagChipsView(pairs: proposalExtras[p.id] ?? [])   // the file's current tags
                creditChips(p)                                     // green "+" for what credits will add
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
                Text(new.isEmpty ? old : new).font(.caption2).foregroundStyle(.primary)
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
        let chosen = ArtworkChoices.shared.byKey.count
        if chosen > 0 { rows.append(("Set your chosen cover on \(chosen) album(s)", .pink)) }
        if store.deduped, store.dedupRemovableCount > 0 {
            rows.append(("Remove \(store.dedupRemovableCount) duplicate(s), keeping the best copy", .purple))
        }
        if store.organised {
            let n = store.organisePlans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }.count
            if n > 0 { rows.append(("Reorganise \(n) file(s) into the clean tree", .purple)) }
        }
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
                Button("Cancel") { activeSheet = nil }
                Button("Confirm & apply") { activeSheet = nil; store.commit() }
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
            if let run = store.currentRuns.first {
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

    // Recent runs — the most recent few (capped so a long history can't overflow
    // the window and hide the controls); the full list lives in Library ▸ Runs.
    @ViewBuilder private var history: some View {
        let recent = Array(store.runs.prefix(6))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("RECENT RUNS").font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    if store.runs.count > recent.count {
                        Text("+\(store.runs.count - recent.count) more · see Library ▸ Runs")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                ForEach(recent) { run in
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
            .frame(maxWidth: 760)
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

// MARK: - Organise tree (current vs proposed, editable)

/// A folder/file node in the organise tree.
struct FileTreeNode: Identifiable {
    let id: String          // full path for folders, plan id for files
    let name: String
    let fullPath: String
    let isFile: Bool
    let planID: String
    var children: [FileTreeNode]
}

enum FileTree {
    /// Build a nested tree from a flat list of (path, planID).
    static func from(_ items: [(path: String, planID: String)]) -> [FileTreeNode] {
        build(items.map { (comps: $0.path.split(separator: "/").map(String.init), planID: $0.planID) }, prefix: "")
    }

    private static func build(_ entries: [(comps: [String], planID: String)], prefix: String) -> [FileTreeNode] {
        var folderKids: [String: [(comps: [String], planID: String)]] = [:]
        var folderOrder: [String] = []
        var files: [FileTreeNode] = []
        for e in entries {
            if e.comps.count <= 1 {
                let nm = e.comps.first ?? ""
                let full = prefix.isEmpty ? nm : prefix + "/" + nm
                files.append(FileTreeNode(id: e.planID.isEmpty ? full : e.planID, name: nm,
                                          fullPath: full, isFile: true, planID: e.planID, children: []))
            } else {
                if folderKids[e.comps[0]] == nil { folderOrder.append(e.comps[0]) }
                folderKids[e.comps[0], default: []].append((Array(e.comps.dropFirst()), e.planID))
            }
        }
        var nodes: [FileTreeNode] = []
        for folder in folderOrder.sorted() {
            let full = prefix.isEmpty ? folder : prefix + "/" + folder
            nodes.append(FileTreeNode(id: full, name: folder, fullPath: full, isFile: false,
                                      planID: "", children: build(folderKids[folder]!, prefix: full)))
        }
        return nodes + files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A scrollable, expandable folder/file tree. When `editable`, each folder/file has
/// a ✎ to rename it (a folder rename cascades to everything under it).
struct OrganiseTreePanel: View {
    let nodes: [FileTreeNode]
    var editable: Bool = false
    var onRenameFolder: (String, String) -> Void = { _, _ in }
    var onRenameFile: (String, String) -> Void = { _, _ in }

    @State private var collapsed: Set<String> = []
    @State private var editingID: String? = nil
    @State private var editText: String = ""

    private struct FRow: Identifiable { let node: FileTreeNode; let depth: Int; var id: String { node.id } }
    private func flat() -> [FRow] {
        var out: [FRow] = []
        func walk(_ ns: [FileTreeNode], _ d: Int) {
            for n in ns {
                out.append(FRow(node: n, depth: d))
                if !n.isFile && !collapsed.contains(n.id) { walk(n.children, d + 1) }
            }
        }
        walk(nodes, 0)
        return out
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(flat()) { row in rowView(row.node, depth: row.depth) }
            }
            .padding(8)
        }
    }

    @ViewBuilder private func rowView(_ n: FileTreeNode, depth: Int) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            if n.isFile {
                Image(systemName: "music.note").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 12)
            } else {
                Button {
                    if collapsed.contains(n.id) { collapsed.remove(n.id) } else { collapsed.insert(n.id) }
                } label: {
                    Image(systemName: collapsed.contains(n.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).frame(width: 12)
                Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(.blue.opacity(0.7))
            }
            if editingID == n.id {
                TextField("", text: $editText, onCommit: { commit(n) })
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 240)
                    .onExitCommand { editingID = nil }
            } else {
                Text(n.name).font(.system(size: 11, weight: n.isFile ? .regular : .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                if editable {
                    Button { editingID = n.id; editText = n.name } label: {
                        Image(systemName: "pencil").font(.system(size: 8))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(0.5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 0.5)
    }

    private func commit(_ n: FileTreeNode) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != n.name {
            if n.isFile { onRenameFile(n.planID, new) } else { onRenameFolder(n.fullPath, new) }
        }
        editingID = nil
    }
}

/// One flagged album in the manual artwork picker: choose from the covers already
/// on its tracks, drop in your own image, re-search online, or leave it as-is.
private struct PickImage: Identifiable { let id = UUID(); let img: NSImage }

struct ArtworkReviewCard: View {
    @ObservedObject var store: PerfectStore
    let item: ArtworkReviewItem
    @State private var covers: [Data] = []           // covers already embedded on the tracks
    @State private var serviceCovers: [Data] = []    // candidates fetched from the cover services
    @State private var loadingService = true
    @State private var selected: Data?               // the cover the user picked (border), applied on Accept
    @State private var full: PickImage?              // shown full size in a popover from the "+" button
    @State private var searchArtist: String
    @State private var searchAlbum: String
    @State private var searching = false

    init(store: PerfectStore, item: ArtworkReviewItem) {
        self.store = store; self.item = item
        _searchArtist = State(initialValue: item.artist)
        _searchAlbum = State(initialValue: item.album)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(item.artist) — \(item.album)").fontWeight(.medium)
                    Text("\(item.files.count) track(s) · click a cover to select, then Accept").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Leave as-is") { store.skipArtworkReview(item) }.controlSize(.small)
                Button("Accept") { if let s = selected { store.chooseArtwork(item: item, image: s) } }
                    .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(selected == nil || store.busy)
            }

            // From the cover services — the real choices (Cover Art Archive + iTunes)
            HStack(spacing: 6) {
                Text("From the cover services — click to select, + to view full size:").font(.caption).foregroundStyle(.secondary)
                if loadingService { ProgressView().controlSize(.mini) }
            }
            if serviceCovers.isEmpty && !loadingService {
                Text("No cover found online — edit the artist/album and search again, choose a file, or use one already on the tracks.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                coverStrip(serviceCovers, size: 148)
            }

            // Fallback: a cover already embedded on one of the tracks
            if !covers.isEmpty {
                Text("Or a cover already on these tracks:").font(.caption).foregroundStyle(.secondary)
                coverStrip(covers, size: 96)
            }

            HStack(spacing: 8) {
                TextField("Artist", text: $searchArtist).textFieldStyle(.roundedBorder).frame(width: 120).controlSize(.small)
                TextField("Album", text: $searchAlbum).textFieldStyle(.roundedBorder).frame(width: 140).controlSize(.small)
                Button { research() } label: { Label("Search again", systemImage: "magnifyingglass") }
                    .controlSize(.small).disabled(searching || searchAlbum.isEmpty)
                if searching { ProgressView().controlSize(.mini) }
                Divider().frame(height: 16)
                Button { chooseFile() } label: { Label("Choose file…", systemImage: "folder") }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
        .popover(item: $full) { pi in
            VStack(spacing: 8) {
                Image(nsImage: pi.img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 460, maxHeight: 460)
                Text("\(Int(pi.img.size.width)) × \(Int(pi.img.size.height))").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .task {
            covers = store.existingCovers(for: item)
            serviceCovers = []
            // progressive: each cover appears in order as it downloads (CAA first, then iTunes)
            await store.streamServiceCovers(for: item) { d in serviceCovers.append(d) }
            loadingService = false
        }
    }

    /// A horizontal strip of candidate covers — click to SELECT (border), "+" to
    /// view at native size. Applying happens on the Accept button, not on click.
    @ViewBuilder private func coverStrip(_ data: [Data], size: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                    if let img = NSImage(data: d) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selected == d ? Color.orange : Color.black.opacity(0.12),
                                                  lineWidth: selected == d ? 3 : 1))
                                .onTapGesture { selected = d }
                                .help("Click to select")
                            Button { full = PickImage(img: img) } label: {
                                Image(systemName: "plus.magnifyingglass").font(.system(size: 12, weight: .bold))
                                    .padding(5).background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain).padding(5).help("View full size")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.message = "Choose a cover image for \(item.album)"
        if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) {
            store.chooseArtwork(item: item, image: d)   // recorded, applied with the rest on Apply
        }
    }

    private func research() {
        searching = true
        selected = nil              // old selection may not be in the new results
        serviceCovers = []
        Task { @MainActor in
            await store.streamServiceCovers(artist: searchArtist, album: searchAlbum, mbids: item.mbids) { d in
                serviceCovers.append(d)
            }
            searching = false
        }
    }
}
