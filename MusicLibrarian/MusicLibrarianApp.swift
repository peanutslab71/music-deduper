//
//  MusicLibrarianApp.swift
//  MusicLibrarian
//
//  App entry point + custom About window.
//

import SwiftUI

@main
struct MusicLibrarianApp: App {
    // One shared Perfect session for the whole app, so the Library / Runs / Logs
    // windows see the same library and run history as the main window.
    @StateObject private var perfect = PerfectStore()

    init() {
        // One-time carry-over of saved state from the app's previous bundle id
        // (com.local.musicdeduper). We changed the id to com.local.musiclibrarian,
        // which gives the app a fresh preferences store — without this the
        // remembered libraries and the Runs list would come up empty after the
        // rename. Copies only the keys that matter; window frames etc. reset.
        migrateLegacyDefaults()

        // Opt the app out of App Nap entirely. App Nap throttles disk/network
        // I/O when the window is covered or minimized, and there are documented
        // cases (Apple dev forums #679178) of it engaging despite a held
        // beginActivity assertion — this per-app default is the fix Apple DTS
        // endorsed there. Long unattended copies matter more to this app than
        // the energy saving.
        UserDefaults.standard.set(true, forKey: "NSAppSleepDisabled")
    }

    var body: some Scene {
        WindowGroup("Music Librarian") {
            ContentView().environmentObject(perfect)
                .onAppear { PlayerBarController.shared.start() }   // floating transport bar
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            // Menu for the run/log tool windows (the Library browser is a main-window tab).
            CommandMenu("Library") {
                LibraryMenuButton("Runs", "runs", "r")
                LibraryMenuButton("Logs", "logs", "g")
                Divider()
                Button("Show/Hide Player Bar") { PlayerBarController.shared.toggleManual() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                // Perfect v2, Phase 1 — the cross-folder normalizer.
                LibraryMenuButton("Normalize", "normalize", "n")
                // Headless preview: writes a dry-run report; applies nothing.
                Button("Normalize Preview (Dry Run)…") { NormalizeDryRun.run() }
            }
            CommandGroup(replacing: .help) {
                Button("Music Librarian Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/peanutslab71/music-librarian/blob/main/HELP.md")!)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(APICredentials.shared)
        }

        Window("About Music Librarian", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Runs", id: "runs") {
            RunsView().environmentObject(perfect)
        }
        Window("Logs", id: "logs") {
            LogsView().environmentObject(perfect)
        }
        Window("Normalize", id: "normalize") {
            NormalizeView().environmentObject(perfect)
        }
    }
}

/// Opens one of the Library tool windows (keeps the same window if already open).
private struct LibraryMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String; let id: String; let key: Character
    init(_ title: String, _ id: String, _ key: Character) { self.title = title; self.id = id; self.key = key }
    var body: some View {
        Button(title) { openWindow(id: id) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
    }
}

/// Menu item that replaces the standard "About" and opens the custom window.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Music Librarian") { openWindow(id: "about") }
    }
}

// MARK: - Legacy defaults migration (bundle id rename)

/// Copy the still-relevant preferences from the app's old bundle id the first
/// time this build runs, so the rename from "Music Deduper" doesn't lose the
/// list of libraries the Runs/Logs windows scan. Runs a single time, then marks
/// itself done. Purely additive — never overwrites anything already set.
private func migrateLegacyDefaults() {
    let ud = UserDefaults.standard
    guard !ud.bool(forKey: "didMigrateFromMusicDeduper") else { return }
    ud.set(true, forKey: "didMigrateFromMusicDeduper")
    guard let legacy = UserDefaults(suiteName: "com.local.musicdeduper") else { return }

    // The list of library roots the global Runs/Logs loader scans.
    if ud.stringArray(forKey: PerfectStore.rootsKey) == nil,
       let roots = legacy.stringArray(forKey: PerfectStore.rootsKey) {
        ud.set(roots, forKey: PerfectStore.rootsKey)
    }
    // Last folder opened in the Manage/Library browser (also seeds Runs).
    if ud.string(forKey: "libraryBrowserRoot") == nil,
       let b = legacy.string(forKey: "libraryBrowserRoot") {
        ud.set(b, forKey: "libraryBrowserRoot")
    }
}

// MARK: - About window

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)

            Text("Music Librarian").font(.title2).fontWeight(.semibold)
            Text(version).font(.caption).foregroundStyle(.secondary)

            Text("by Neil Cotty")
                .font(.callout)

            Divider().frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                aboutLink("Usage guide",
                          "https://github.com/peanutslab71/music-librarian/blob/main/USAGE.md",
                          icon: "book")
                aboutLink("Help — performance & troubleshooting",
                          "https://github.com/peanutslab71/music-librarian/blob/main/HELP.md",
                          icon: "questionmark.circle")
                aboutLink("API keys & the services it uses",
                          "https://github.com/peanutslab71/music-librarian/blob/main/docs/API-KEYS.md",
                          icon: "key")
                aboutLink("Source code on GitHub",
                          "https://github.com/peanutslab71/music-librarian",
                          icon: "chevron.left.forwardslash.chevron.right")
                aboutLink("Licence (MIT)",
                          "https://github.com/peanutslab71/music-librarian/blob/main/LICENSE",
                          icon: "doc.text")
                aboutLink("Neil at AllSports.World",
                          "https://allsports.world/profiles/neilcotty/",
                          icon: "person.crop.circle")
            }
            .font(.callout)

            Divider().frame(width: 260)

            Text("© 2026 Neil Cotty. App code MIT licensed —\nprovided as-is, with no warranty of any kind.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Network engine built on AMSMB2 and libsmb2,\n© their authors, LGPL 2.1 — see Acknowledgements.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Link("Acknowledgements & licences",
                 destination: URL(string: "https://github.com/peanutslab71/music-librarian/blob/main/ACKNOWLEDGEMENTS.md")!)
                .font(.caption2)
        }
        .padding(28)
        .frame(width: 340)
    }

    private func aboutLink(_ label: String, _ url: String, icon: String) -> some View {
        Link(destination: URL(string: url)!) {
            SwiftUI.Label(label, systemImage: icon)
        }
    }
}

/// Perfect v2, Phase 1 — the hidden Normalize preview. Choose a library, plan the
/// cross-folder normalize headlessly (Normalizer.plan), and open a dry-run report
/// of every proposed change. NOTHING is applied; the real confirm-and-apply
/// surface arrives with the v2 driver.
enum NormalizeDryRun {
    @MainActor static func run() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Preview Normalize"
        panel.message = "Choose a music library — a dry-run report is written; nothing is changed."
        guard panel.runModal() == .OK, let root = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let scanned = PerfectStore.scanForNormalize(root: root)
            // same choices the Normalize window would use, so the two agree
            let choices = Normalizer.ChoicesStore.load(root.path)
            let confirmedComps = Normalizer.compilationCandidates(scanned.tracks)
                .filter { !choices.declinedCompilations.contains($0.key) }
                .reduce(into: Set<String>()) { $0.formUnion($1.foldKeys) }
            let plan = Normalizer.plan(scanned, canonicalArtistOverrides: choices.artistOverrides,
                                       declinedMerges: Set(choices.declinedMerges),
                                       confirmedCompilations: confirmedComps)

            var report = "Music Librarian — Normalize DRY RUN \(Date())\nLibrary: \(root.path)\n"
            report += "NOTHING has been changed. On apply, unchanged tag values are skipped.\n\n"
            if !plan.unifications.isEmpty {
                report += "ARTIST SPELLINGS TO UNIFY (\(plan.unifications.count)):\n"
                for u in plan.unifications {
                    report += "  → \(u.canonical)   ["
                        + u.variants.map { "\($0.name) ×\($0.count)" }.joined(separator: ", ") + "]\n"
                }
                report += "\n"
            }
            if !plan.mergeGroups.isEmpty {
                report += "EDITION / DISC-SPLIT MERGES (\(plan.mergeGroups.count)):\n"
                for g in plan.mergeGroups {
                    report += "  → \(g.display)   [" + g.rawNames.joined(separator: " | ") + "]\n"
                }
                report += "\n"
            }
            let quarantines = plan.moves.filter { $0.to.isEmpty }
            let realMoves = plan.moves.filter { !$0.to.isEmpty }
            report += "JUNK / EMPTY FOLDERS → QUARANTINE (\(quarantines.count)):\n"
            for q in quarantines { report += "  ✕ \(q.from)\n" }
            report += "\nMOVES (\(realMoves.count)):\n"
            for m in realMoves { report += "  \(m.from)\n    → \(m.to)\n" }
            report += "\nTAG WRITES (\(plan.tagWrites.count); unchanged values are no-ops on apply):\n"
            for w in plan.tagWrites.prefix(1000) { report += "  \(w.rel): \(w.field) = \(w.value)\n" }
            if plan.tagWrites.count > 1000 { report += "  … and \(plan.tagWrites.count - 1000) more\n" }

            let out = fm.temporaryDirectory
                .appendingPathComponent("normalize-dryrun-\(Int(Date().timeIntervalSince1970)).txt")
            try? report.write(to: out, atomically: true, encoding: .utf8)
            await MainActor.run { NSWorkspace.shared.open(out) }
        }
    }
}
