# If the Xcode project won't open ("damaged")

## First, restore the project file from git — this is almost always the fix

The Xcode project (`MusicLibrarian.xcodeproj/project.pbxproj`) is version-controlled, so
a corrupted or half-edited one is repaired by checking the committed version back out:

```
git checkout -- MusicLibrarian.xcodeproj
```

If it was broken by an edit you haven't committed, that restores the last good copy. If a
committed change broke it, `git log -- MusicLibrarian.xcodeproj` finds the last working
commit and `git checkout <commit> -- MusicLibrarian.xcodeproj` brings it back.

## Rebuilding from scratch (last resort)

The old "make a fresh SwiftUI app and drop four files in" recipe no longer applies — the
app is much larger and depends on a C++ tag library and two Swift packages, so a bare app
project won't build. If you genuinely have to reconstruct the project, it needs:

1. **All source files** from `MusicLibrarian/`: `MusicLibrarianApp.swift`, `ContentView.swift`,
   `WizardUI.swift`, `DedupStore.swift`, `Engine.swift`, `Organise.swift`, `Perfect.swift`,
   `PerfectView.swift`, `Identify.swift`, `APIKeys.swift`, `LibraryWindows.swift`,
   `DirectSMB.swift`, `ServerFiles.swift` — plus `Assets.xcassets` and `Info.plist`.
2. **The local `MDTagShim` Swift package** (in the repo root) added as a local package
   dependency. It's a C++/Swift-interop package wrapping TagLib, so the target needs C++
   interoperability enabled.
3. **The remote Swift-package dependencies**: `ChromaSwift`
   (<https://github.com/wallisch/ChromaSwift>) and the AMSMB2 fork
   (<https://github.com/peanutslab71/AMSMB2>, branch `guest-anonymous-session`).
4. **Build settings** the committed project carries: Hardened Runtime on, the
   `Secrets.xcconfig`-based key config (Debug only — Release blanks the keys), and the
   macOS 13 deployment target.

In practice, restoring the `.pbxproj` from git (above) is far quicker and always correct;
reach for a full rebuild only if the git history itself is unavailable.
