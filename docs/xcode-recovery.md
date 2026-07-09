# If the Xcode project won't open ("damaged")

Fallback that always works — build a fresh project and drop the source files in:

1. Xcode → **File → New → Project… → macOS → App** → Next.
   - Product Name: **MusicDeduper**, Interface: **SwiftUI**, Language: **Swift**. Create it.
2. In the new project, delete the auto-generated `ContentView.swift` and the
   `…App.swift` file (Move to Trash).
3. Drag the four files from the **`MusicDeduper/`** folder
   (`MusicDeduperApp.swift`, `Engine.swift`, `DedupStore.swift`, `ContentView.swift`)
   into the project's yellow group, ticking **Copy items if needed**.
4. Press **▶ Run**.
