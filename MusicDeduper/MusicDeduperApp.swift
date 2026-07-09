//
//  MusicDeduperApp.swift
//  MusicDeduper
//
//  App entry point.
//

import SwiftUI

@main
struct MusicDeduperApp: App {
    var body: some Scene {
        WindowGroup("Music Library Deduper") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
