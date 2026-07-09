# Music Library Deduper — native macOS app (SwiftUI)

A real Cocoa/SwiftUI app: native folder pickers, accurate metadata via AVFoundation,
native "Move to Trash", and fast file I/O. No Tkinter, no rendering bugs, no Terminal.

## What it does
- Pick a source folder → scans tags + duration (AVFoundation) → finds duplicates.
- Review duplicate groups; the best copy is marked **KEEP** (click any row to change the keeper).
- **Delete duplicates…** → choose **Trash** or **Permanent**, then confirm **twice**.
- **Copy keepers to…** → rebuilds a clean Artist/Album tree at a destination
  (e.g. a mounted Roon ROCK / NAS share); skips files already there by size.

## How to build & run (first time ~ a few minutes)

You need **Xcode** (free from the Mac App Store).

1. Double-click **`MusicDeduper.xcodeproj`** to open it in Xcode.
2. In the top toolbar, make sure the scheme says **MusicDeduper** and the run
   destination is **My Mac**.
3. Click the **▶ Run** button (or press ⌘R). Xcode compiles it and the app window opens.
   - If Xcode asks about signing, select the target **MusicDeduper** → **Signing & Capabilities**
     tab → set **Team** to your Apple ID (a free personal team is fine), or leave
     "Automatically manage signing" on. For running on your own Mac this is all you need.

That's it — the app runs. To get a standalone `.app` you can keep, use
**Product → Archive** (or find the built app under
`~/Library/Developer/Xcode/DerivedData/MusicDeduper-*/Build/Products/`).

### If the project ever won't open ("damaged")
Fallback that always works — build a fresh project and drop these files in:
1. Xcode → **File → New → Project… → macOS → App** → Next.
   - Product Name: **MusicDeduper**, Interface: **SwiftUI**, Language: **Swift**. Create it.
2. In the new project, delete the auto-generated `ContentView.swift` and the
   `…App.swift` file (Move to Trash).
3. Drag the four files from the **`MusicDeduper/`** folder here
   (`MusicDeduperApp.swift`, `Engine.swift`, `DedupStore.swift`, `ContentView.swift`)
   into the project's yellow group, ticking **Copy items if needed**.
4. Press **▶ Run**.

## Notes
- Minimum macOS: 13 (Ventura) or later.
- The app is **not sandboxed**, so it can read the folder you pick and delete files.
  macOS may prompt once for access to certain folders — click Allow.
- For iCloud sources set to "Optimize Storage," download the files first
  (Finder → right-click the folder → Download Now) or some may read as unreadable.
- No app icon yet (generic). Once it builds, I can add the custom icon.
