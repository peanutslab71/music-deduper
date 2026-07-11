//
//  MusicDeduperApp.swift
//  MusicDeduper
//
//  App entry point + custom About window.
//

import SwiftUI

@main
struct MusicDeduperApp: App {
    // One shared Perfect session for the whole app, so the Library / Runs / Logs
    // windows see the same library and run history as the main window.
    @StateObject private var perfect = PerfectStore()

    init() {
        // Opt the app out of App Nap entirely. App Nap throttles disk/network
        // I/O when the window is covered or minimized, and there are documented
        // cases (Apple dev forums #679178) of it engaging despite a held
        // beginActivity assertion — this per-app default is the fix Apple DTS
        // endorsed there. Long unattended copies matter more to this app than
        // the energy saving.
        UserDefaults.standard.set(true, forKey: "NSAppSleepDisabled")
    }

    var body: some Scene {
        WindowGroup("Music Library Deduper") {
            ContentView().environmentObject(perfect)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            // A "Library" menu for the three tool windows.
            CommandMenu("Library") {
                LibraryMenuButton("Library Viewer", "libraryViewer", "l")
                LibraryMenuButton("Runs", "runs", "r")
                LibraryMenuButton("Logs", "logs", "g")
            }
            CommandGroup(replacing: .help) {
                Button("Music Deduper Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/peanutslab71/music-deduper/blob/main/HELP.md")!)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("About Music Deduper", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Library Viewer", id: "libraryViewer") {
            LibraryViewerView().environmentObject(perfect)
        }
        Window("Runs", id: "runs") {
            RunsView().environmentObject(perfect)
        }
        Window("Logs", id: "logs") {
            LogsView().environmentObject(perfect)
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
        Button("About Music Deduper") { openWindow(id: "about") }
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

            Text("Music Deduper").font(.title2).fontWeight(.semibold)
            Text(version).font(.caption).foregroundStyle(.secondary)

            Text("by Neil Cotty")
                .font(.callout)

            Divider().frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                aboutLink("Usage guide",
                          "https://github.com/peanutslab71/music-deduper/blob/main/USAGE.md",
                          icon: "book")
                aboutLink("Help — performance & troubleshooting",
                          "https://github.com/peanutslab71/music-deduper/blob/main/HELP.md",
                          icon: "questionmark.circle")
                aboutLink("Source code on GitHub",
                          "https://github.com/peanutslab71/music-deduper",
                          icon: "chevron.left.forwardslash.chevron.right")
                aboutLink("Licence (MIT)",
                          "https://github.com/peanutslab71/music-deduper/blob/main/LICENSE",
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
                 destination: URL(string: "https://github.com/peanutslab71/music-deduper/blob/main/ACKNOWLEDGEMENTS.md")!)
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
