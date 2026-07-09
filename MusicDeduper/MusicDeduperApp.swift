//
//  MusicDeduperApp.swift
//  MusicDeduper
//
//  App entry point + custom About window.
//

import SwiftUI

@main
struct MusicDeduperApp: App {
    var body: some Scene {
        WindowGroup("Music Library Deduper") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }

        Window("About Music Deduper", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
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

            Text("© 2026 Neil Cotty. MIT licensed —\nprovided as-is, with no warranty of any kind.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
