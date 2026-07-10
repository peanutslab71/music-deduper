//
//  PerfectView.swift
//  MusicDeduper
//
//  The Perfect screen: choose a library → diagnose → review → commit.
//  Phase 1 slice: junk, empty folders, DRM. Review-gated, quarantine on commit.
//

import SwiftUI

struct PerfectView: View {
    @ObservedObject var store: PerfectStore
    @State private var expanded: Set<String> = []   // all sections collapsed initially — reads as a summary
    @State private var showSettings = false
    @State private var queueIndex = 0                // position in the step-through review queue
    @State private var showApplyConfirm = false      // the final "confirm before commit" dialog

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
        .sheet(isPresented: $showApplyConfirm) { applyConfirmSheet }
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

    private var diagnosing: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(store.progress.isEmpty ? "Exploring…" : store.progress)
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
                    if store.groups.isEmpty && store.artists.isEmpty && store.renames.isEmpty && !store.checkingTags {
                        allClean
                    }
                    albumCarousel
                    categoryBar
                    reviewQueueSection
                    artistsSection
                    if !store.renames.isEmpty { renamesSection }
                    ForEach(store.groups, id: \.kind.rawValue) { group in
                        section(group.kind, group.items)
                    }
                    identifySection
                }
                .padding(16)
            }
            history
            Divider()
            footer
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

                    ArtworkView(key: p.url.deletingLastPathComponent().path, sampleURL: p.url, size: 96, corner: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
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

    // Bulk category toggles — the mockup's on/off buttons. Coarse control; the
    // detail stays in each section below.
    @ViewBuilder private var categoryBar: some View {
        let namesN = store.proposals.filter { $0.hasChange }.count
        let artN = store.proposals.filter { $0.canAddArt }.count
        let credN = store.proposals.filter { !($0.enrichment?.isEmpty ?? true) }.count
        let mergeN = store.artists.filter { store.artistHasApplicableWork($0) }.count
        let renameN = store.renames.count
        let junkN = store.findings.filter { $0.kind == .junk }.count
        let emptyN = store.findings.filter { $0.kind == .emptyFolder }.count
        if namesN + artN + credN + mergeN + renameN + junkN + emptyN > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    if namesN > 0 { categoryPill("Identify names", namesN, .blue, on: store.applyNames) { store.applyNames.toggle() } }
                    if artN > 0 { categoryPill("Add artwork", artN, .pink, on: store.applyArtwork) { store.applyArtwork.toggle() } }
                    if credN > 0 { categoryPill("Fill credits", credN, Color(red: 0.13, green: 0.6, blue: 0.3), on: store.applyCredits) { store.applyCredits.toggle() } }
                    if mergeN > 0 {
                        let on = store.artists.allSatisfy { $0.accepted }
                        categoryPill("Merge artists", mergeN, .purple, on: on) {
                            for i in store.artists.indices { store.artists[i].accepted = !on }
                        }
                    }
                    if renameN > 0 {
                        let on = store.renames.allSatisfy { $0.accepted }
                        categoryPill("Tidy folders", renameN, .orange, on: on) {
                            for i in store.renames.indices { store.renames[i].accepted = !on }
                        }
                    }
                    if junkN > 0 { findingsPill("Remove junk", junkN, .gray, kind: .junk) }
                    if emptyN > 0 { findingsPill("Empty folders", emptyN, .gray, kind: .emptyFolder) }
                }
                .padding(.horizontal, 2).padding(.bottom, 2)
            }
        }
    }

    private func findingsPill(_ label: String, _ count: Int, _ color: Color, kind: FixKind) -> some View {
        let on = store.findings.filter { $0.kind == kind }.allSatisfy { $0.accepted }
        return categoryPill(label, count, color, on: on) {
            for i in store.findings.indices where store.findings[i].kind == kind { store.findings[i].accepted = !on }
        }
    }

    private func categoryPill(_ label: String, _ count: Int, _ color: Color, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).foregroundStyle(on ? color : Color.secondary)
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.15)))
            .opacity(on ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    // Album cover carousel — the media-first overview of what's being tidied.
    @ViewBuilder private var albumCarousel: some View {
        let albums = store.albumChanges
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack").foregroundStyle(.purple)
                    Text("\(albums.count) album(s)").fontWeight(.semibold)
                    Text("identified from the audio").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(albums) { a in albumCard(a) }
                    }
                    .padding(.horizontal, 2).padding(.bottom, 6)
                }
            }
        }
    }

    private func albumCard(_ a: PerfectStore.AlbumChange) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(key: a.id, sampleURL: a.sampleURL, size: 150, corner: 10)
                HStack(spacing: 4) {
                    if a.names { cardTag("Names", .blue) }
                    if a.artwork { cardTag("+ Art", .pink) }
                    if a.credits { cardTag("+ Credits", Color(red: 0.13, green: 0.6, blue: 0.3)) }
                }
                .padding(7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.caption).fontWeight(.medium).lineLimit(1)
                Text("\(a.subtitle) · \(a.trackCount) track(s)").font(.caption2)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 150)
    }

    private func cardTag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
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

    // Identify — fingerprint tracks and propose the correct names. Its own pass
    // (slow + online), so it's triggered explicitly, not part of Explore.
    @ViewBuilder private var identifySection: some View {
        let isOpen = expanded.contains("identify")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !store.proposals.isEmpty {
                    Button {
                        if isOpen { expanded.remove("identify") } else { expanded.insert("identify") }
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Image(systemName: "waveform.and.magnifyingglass").foregroundStyle(.teal)
                Text("Identify tracks").fontWeight(.semibold)
                if store.identifying {
                    Text("listening…").font(.caption).foregroundStyle(.secondary)
                } else if !store.proposals.isEmpty {
                    Text("\(store.proposals.count) with suggested names").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("match the audio, correct the names").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.identifying {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(store.identifyProgress).font(.caption).foregroundStyle(.secondary) }
                    Button("Cancel") { store.cancel() }.controlSize(.small)
                } else if !store.hasAcoustIDKey {
                    Text("needs an AcoustID key").font(.caption2).foregroundStyle(.orange)
                } else if store.enriching {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(store.enrichProgress).font(.caption).foregroundStyle(.secondary) }
                    Button("Cancel") { store.cancel() }.controlSize(.small)
                } else {
                    if !store.proposals.isEmpty {
                        let allOn = store.proposals.allSatisfy { $0.accepted }
                        Button(allOn ? "Deselect all" : "Select all") {
                            for i in store.proposals.indices { store.proposals[i].accepted = !allOn }
                        }.controlSize(.small)
                        Button("Fill credits") { store.enrich() }.controlSize(.small)
                            .help("Look up composer, label and performers on MusicBrainz (slower)")
                    }
                    Button(store.proposals.isEmpty ? "Identify" : "Re-identify") {
                        expanded.insert("identify"); store.identify()
                    }.controlSize(.small)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.07)))

            if store.identifying { workingFeed }

            if !store.proposals.isEmpty && isOpen {
                Text("Each track was identified from its audio. Artist and title are reliable; album is only a suggestion — it defaults to your existing album, with alternatives to pick from. Applied changes are reversible.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8).padding(.horizontal, 6)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.proposals) { p in proposalRow(p) }
                }
                .padding(.top, 6).padding(.leading, 6)
            }
        }
    }

    // Live feed while identify runs — watch it match tracks by sound.
    @ViewBuilder private var workingFeed: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("\(store.identifyMatched)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.teal).contentTransition(.numericText())
                Text("matched by sound").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.recentFinds, id: \.self) { f in
                Text(f).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(f.hasPrefix("✎") ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10).padding(.horizontal, 8)
        .animation(.easeOut(duration: 0.25), value: store.recentFinds)
    }

    private func proposalRow(_ p: TrackProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { p.accepted },
                set: { v in if let i = store.proposals.firstIndex(where: { $0.id == p.id }) { store.proposals[i].accepted = v } }
            )).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.relPath).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Text(String(format: "%.0f%%", p.score * 100)).font(.caption2)
                        .foregroundStyle(p.score >= 0.9 ? .green : .orange)
                }
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

    private var footer: some View {
        let acc = store.artists.filter { $0.accepted }
        let mergeCount = acc.reduce(0) { $0 + $1.folderMerges }
        let tagCount = store.tagWritingEnabled ? acc.reduce(0) { $0 + $1.tagRewrites } : 0
        let idCount = store.tagWritingEnabled ? store.proposals.filter { $0.accepted && $0.hasChange }.count : 0
        var bits = ["\(store.acceptedCount) cleanup(s)"]
        if mergeCount > 0 { bits.append("\(mergeCount) folder merge(s)") }
        if tagCount > 0 { bits.append("\(tagCount) tag fix(es)") }
        if idCount > 0 { bits.append("\(idCount) identified") }
        let summary = bits.joined(separator: ", ") + " selected"
        return HStack {
            if store.hasWork {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Protected tracks are listed for information and are never removed.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                showApplyConfirm = true
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
