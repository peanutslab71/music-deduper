//
//  Perfect.swift
//  MusicLibrarian
//
//  "Perfect" — library restoration. Phase 1 (Tidy): scan a library, diagnose
//  fixable problems, review them, and commit the approved ones — removing
//  items to a recoverable quarantine and writing a before/after change log.
//
//  This first slice handles the unambiguous, locally-detectable classes:
//  junk files, empty folders, and DRM (protected) tracks. Duplicate-folder
//  merges, illegal-character renames, duplicate-recording handling, and the
//  identify/tag phases build on this.
//

import Foundation
import AVFoundation
import Accelerate
import MDTagShim
import ChromaSwift
import SwiftUI

// MARK: - Model

enum Thoroughness: String, CaseIterable, Identifiable {
    case light, standard, thorough
    var id: String { rawValue }
    var title: String {
        switch self { case .light: return "Light"; case .standard: return "Standard"; case .thorough: return "Thorough" }
    }
    var blurb: String {
        switch self {
        case .light:    return "Only the safest cleanups — remove junk files and empty folders. Nothing renamed or merged."
        case .standard: return "Safe cleanups plus tidying obviously-untidy folder names. No artist merges."
        case .thorough: return "Everything — cleanups, name tidying, and merging duplicate artist folders. The most consistent result."
        }
    }
    var doesRenames: Bool { self != .light }
    var doesMerges: Bool { self == .thorough }
}

enum FixKind: String {
    case junk           // OS litter / temp / orphan files
    case emptyFolder    // folder with no files anywhere inside
    case drm            // FairPlay-protected, unplayable

    var title: String {
        switch self {
        case .junk:        return "Remove junk files"
        case .emptyFolder: return "Delete empty folders"
        case .drm:         return "Protected (DRM) tracks"
        }
    }
    var safe: Bool { self != .drm }   // drm is informational, never removed
}

struct PerfectFinding: Identifiable {
    let id = UUID()
    let kind: FixKind
    let url: URL
    let relPath: String     // path relative to the library root
    let detail: String      // short reason / description
    let bytes: Int64
    var accepted: Bool
}

/// Raw folder-level detection: top-level folders whose names mean the same
/// artist (e.g. "Buzzcocks" + "The Buzzcocks"). Internal — folded into ArtistIssue.
struct FolderGroup {
    let key: String
    let sources: [String]           // the colliding top-level folder names
    let fileCounts: [Int]           // audio-file count per source (same order)
}

/// One file caught in a tag-level artist split, with the exact artist spelling
/// currently written in it — kept so a fix can be applied and exactly reversed.
struct TagMember {
    let url: URL
    let relPath: String
    let oldName: String
}

/// Raw tag-level detection: one artist written under several spellings in the
/// files' tags. Internal — folded into ArtistIssue.
struct TagGroup {
    let key: String
    let variants: [(name: String, count: Int)]   // spelling → track count
    let members: [TagMember]                      // every file carrying this key
}

/// One artist that needs attention — a folder split, a tag split, or both.
/// The user picks ONE name to keep; applying it does only what's wrong for this
/// artist: merges the differing folders and/or rewrites the differing tags, all
/// to the same name, so the folder on disk and the tags a server reads agree.
struct ArtistIssue: Identifiable {
    let id = UUID()
    let key: String
    var canonical: String            // editable — the one name for folder AND tags
    var accepted: Bool
    let candidates: [String]         // union of folder names + tag spellings, for the picker
    // folder side (empty / single = no folder work)
    let folderSources: [String]
    let folderFileCounts: [Int]
    // tag side
    let tagVariants: [(name: String, count: Int)]
    let tagMembers: [TagMember]

    var hasFolderSplit: Bool { folderSources.count > 1 }
    var hasTagSplit: Bool { tagVariants.count > 1 }
    /// number of tag rewrites this artist would make with the current `canonical`
    var tagRewrites: Int { tagMembers.filter { $0.oldName != canonical }.count }
    /// folders that would be folded away (all sources except the kept one)
    var folderMerges: Int { hasFolderSplit ? folderSources.filter { $0 != canonical }.count : 0 }
    var hasWork: Bool { folderMerges > 0 || tagRewrites > 0 }

    /// one-line summary of what applying this would do
    var actionSummary: String {
        var bits: [String] = []
        if folderMerges > 0 { bits.append("merges \(folderSources.count) folders") }
        if tagRewrites > 0 { bits.append("rewrites \(tagRewrites) tag(s)") }
        return bits.isEmpty ? "already consistent" : bits.joined(separator: " · ")
    }
    /// short kind label
    var kindLabel: String {
        switch (hasFolderSplit, hasTagSplit) {
        case (true, true):  return "folder + tags"
        case (true, false): return "folder"
        case (false, true): return "tags"
        default:            return ""
        }
    }
}

/// A proposed rename of a folder with an obviously untidy name (trailing
/// underscore from a stripped illegal character, stray/double spaces, etc.).
/// The true name including any real illegal character comes later, from the
/// metadata authority — this is only the safe cosmetic tidy.
struct RenameProposal: Identifiable {
    let id = UUID()
    let relPath: String         // current path, root-relative
    let oldName: String
    var newName: String         // editable
    var accepted: Bool
}

/// A committed run, reconstructed from its quarantine folder's run.json, so it
/// can be listed and undone. Every change is one move (from → to), both paths
/// relative to the library root; undo reverses them.
struct RunRecord: Identifiable {
    let id: String          // full quarantine subfolder path (unique across libraries)
    let folder: URL         // the run's quarantine folder
    let root: URL           // the library it belongs to — DERIVED from the folder's location
    let date: Date
    let ops: [(from: String, to: String)]   // each move, root-relative
    let tagEdits: [(rel: String, field: String, old: String)]  // each tag rewrite, for exact undo
    let perfEdits: [(rel: String, name: String, role: String)] // each performer credit added, for undo
    let artEdits: [String]                                      // rels where cover art was added, for undo
    let artPromotions: [(rel: String, oldType: Int)]            // existing art retagged to front, for undo
    let artReplacements: [(rel: String, backup: String, oldType: Int)]  // art replaced; backup holds the old image
    let summary: String
}

/// The resumable working plan for one library: the (network-expensive) identify
/// + enrich results and the user's decisions, plus how far through the wizard we
/// got. Persisted to Application Support so closing and reopening resumes rather
/// than re-identifying. Distinct from a run.json (which records an APPLIED run).
struct PerfectPlan: Codable {
    let rootPath: String
    let saved: Date
    let totalFiles: Int
    var proposals: [TrackProposal]
    var diagnosed: Bool
    var didIdentify: Bool
    var enriched: Bool
    var artworkStageDone: Bool
    var dedupStageDone: Bool
    var organiseStageDone: Bool
    var artworkChoices: [String: Data] = [:]   // covers picked in the Artwork step, not yet applied
    var wizardStep: Int = 1                     // the step the user was on
    var confirmedCompilations: [String] = []    // albums the user OK'd as various-artists sets
    var declinedAlbumMerges: [String] = []      // edition-merges the user turned off
}

/// One album's cover-art work: resolve a single image (from any of the album's
/// releases, or iTunes) and apply it to every art-less track in `files`.
struct AlbumArtJob {
    let artist: String
    let album: String
    var mbids: [String]
    var files: [(url: URL, rel: String)]
}

/// An album whose art is mixed/missing but no cover could be fetched — surfaced
/// for the manual artwork picker (choose an existing cover, drop your own,
/// re-search, or leave as-is).
struct ArtworkReviewItem: Identifiable {
    let id = UUID()
    let artist: String
    let album: String
    let files: [String]     // root-relative paths of the album's tracks
    var mbids: [String] = [] // release MBIDs (from identify), for Cover Art Archive lookups
}

/// One album folder found by the scan. Derived from the folder layout
/// (…/Artist/Album/track) so it exists for EVERY album, identified or not — the
/// Artwork step uses it to let you replace any cover, even one that's present but wrong.
struct ScannedAlbum: Identifiable {
    let id: String          // album folder path
    let artist: String      // grandparent folder name
    let album: String       // parent folder name
    let files: [String]     // root-relative track paths
}

/// Tracks a Perfect run found suspiciously short with no full-length twin — likely
/// truncated/damaged. Information only; NEVER auto-removed. Mirrors the per-album
/// "Possibly damaged" flag so batch and per-album Perfect surface the same files.
struct DamagedAlbumReport: Identifiable {
    let id = UUID()
    let artist: String
    let album: String
    let lines: [String]   // "“Title” — 0:03 (album typical 2:25)"
}

/// One album a Perfect run found to be incomplete: what release it matched and how
/// many of its tracks are absent. The full matched tracklist is persisted per album
/// folder so the Album Inspector can grey out the missing rows afterwards.
struct MissingAlbumReport: Identifiable {
    let id = UUID()
    let artist: String
    let album: String
    let missing: Int
    let total: Int
    let missingTitles: [String]   // "Disc d · n. Title" for the change log
}

// MARK: - Found cover art (preview before it's embedded)

/// A single lightweight "artwork changed" signal. AlbumCover observes ONLY this
/// (not the image caches themselves), so a cover fetch completing doesn't
/// re-render every card on screen — only a cache clear (after an apply) bumps it,
/// telling visible cards to reload from disk.
@MainActor
final class ArtRefresh: ObservableObject {
    static let shared = ArtRefresh()
    @Published private(set) var gen = 0
    func bump() { gen &+= 1 }
}

/// Cover choices made in the Artwork step, held until the final Apply embeds them
/// all in ONE run (instead of one run per Accept). Previews read this so a chosen
/// cover shows immediately even though nothing's written to disk yet. Keyed by a
/// normalised artist + disc-stripped album, so all discs of a set share a choice.
@MainActor
final class ArtworkChoices: ObservableObject {
    static let shared = ArtworkChoices()
    @Published var byKey: [String: Data] = [:]
    nonisolated static func key(artist: String, album: String) -> String {
        "\(artist.lowercased())|\(Organiser.stripDiscSuffix(album).clean.lowercased())"
    }
    func image(artist: String, album: String) -> Data? { byKey[Self.key(artist: artist, album: album)] }
    func clearAll() { byKey.removeAll() }
}

/// Previews the cover an album will get on Apply — the SAME resolution the commit
/// uses: Cover Art Archive by release MBID, else Apple iTunes by artist+album. So
/// albums that'll be filled from iTunes (Aretha's Gold, Intergalactic…) show their
/// real cover in the grid instead of a placeholder.
@MainActor
final class FoundArtCache: ObservableObject {
    static let shared = FoundArtCache()
    private let images: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 400; return c }()
    private var misses = Set<String>(); private var inflight = Set<String>()

    /// Stable cache key for a (mbid, artist, album) — mbid wins, else an iTunes key.
    static func key(mbid: String?, artist: String, album: String) -> String {
        if let m = mbid, !m.isEmpty { return "mb:\(m)" }
        return "it:\(artist.lowercased())|\(album.lowercased())"
    }

    func cached(_ key: String) -> NSImage? { images.object(forKey: key as NSString) }

    /// Cache-or-fetch a found cover, returning it directly (for AlbumCover's own
    /// async load — no shared objectWillChange storm).
    func image(mbid: String?, artist: String, album: String) async -> NSImage? {
        let k = Self.key(mbid: mbid, artist: artist, album: album)
        if let c = images.object(forKey: k as NSString) { return c }
        if misses.contains(k) { return nil }
        if let img = await Self.resolve(mbid: mbid, artist: artist, album: album) {
            images.setObject(img, forKey: k as NSString); return img
        }
        misses.insert(k); return nil
    }

    /// Drop all cached covers + miss/inflight sets so previews re-resolve. Call
    /// after an apply so the grid reflects what's now on disk, not a stale fetch.
    func clear() {
        images.removeAllObjects(); misses.removeAll(); inflight.removeAll()
        ArtRefresh.shared.bump()
        objectWillChange.send()
    }

    func request(mbid: String?, artist: String, album: String) {
        let k = Self.key(mbid: mbid, artist: artist, album: album)
        guard images.object(forKey: k as NSString) == nil, !misses.contains(k), !inflight.contains(k) else { return }
        inflight.insert(k)
        Task {
            let img = await Self.resolve(mbid: mbid, artist: artist, album: album)
            self.inflight.remove(k)
            if let img { self.images.setObject(img, forKey: k as NSString) } else { self.misses.insert(k) }
            self.objectWillChange.send()
        }
    }

    nonisolated static func resolve(mbid: String?, artist: String, album: String) async -> NSImage? {
        if let m = mbid, !m.isEmpty, let img = await coverArtArchive(m) { return img }
        return await itunes(artist: artist, album: album)
    }

    nonisolated private static func coverArtArchive(_ mbid: String) async -> NSImage? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/front-250") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("MusicLibrarian ( neil.cottyincar@gmail.com )", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else { return nil }
        return img
    }

    nonisolated private static func itunes(artist: String, album: String) async -> NSImage? {
        guard !album.isEmpty else { return nil }
        let term = (artist + " " + album).trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=album&limit=6"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // Only accept a result whose album title actually matches — otherwise iTunes
        // hands back the artist's top album (e.g. "Best of Bowie" → Ziggy Stardust),
        // and a confidently-wrong cover is worse than a placeholder + manual review.
        let want = album.lowercased()
        let wantArtist = artist.lowercased()
        let ranked = results.compactMap { r -> (Int, [String: Any])? in
            let cn = (r["collectionName"] as? String ?? "").lowercased()
            let an = (r["artistName"] as? String ?? "").lowercased()
            let albumScore = cn == want ? 2 : (cn.contains(want) || want.contains(cn) ? 1 : 0)
            let artistOK = !wantArtist.isEmpty && (an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an))
            return (albumScore > 0 && artistOK) ? (albumScore, r) : nil
        }.sorted { $0.0 > $1.0 }
        for (_, r) in ranked {
            guard let art = r["artworkUrl100"] as? String,
                  let iu = URL(string: art.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
                  let (d, ir) = try? await URLSession.shared.data(from: iu),
                  (ir as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: d) else { continue }
            return img
        }
        return nil
    }
}

// MARK: - Audio preview

/// Plays a track so the user can listen and judge whether a proposed change is
/// right. One at a time; tapping the playing track stops it.
/// Playback progress lives on its OWN tiny observable so the 4×/second tick only
/// re-renders the scrub bar — not the whole album grid (which caused the jank
/// while a track played).
final class AudioProgress: ObservableObject {
    static let shared = AudioProgress()
    @Published var progress: Double = 0
}

/// One entry in the play queue, with the bits the floating player shows.
struct PlayItem: Equatable, Sendable {
    let url: URL; let title: String; let artist: String; let album: String
}

enum RepeatMode { case off, all, one }

/// A real-time frequency spectrum for the floating player. Rather than tap the audio
/// output (which AVAudioPlayer can't do), it reads a window of decoded samples from the
/// playing file at the current playhead every frame and runs an FFT (Accelerate/vDSP),
/// grouping the magnitudes into log-spaced bands. Freezes when paused; no effect on
/// transport.
final class SpectrumAnalyzer: ObservableObject {
    static let shared = SpectrumAnalyzer()
    static let bandCount = 28

    @Published var bands: [Float] = Array(repeating: 0, count: bandCount)

    private let fftSize = 4096   // ~10.8 Hz/bin at 44.1kHz — sharper low-end resolution
    private let half = 2048
    private let log2n: vDSP_Length
    private let setup: FFTSetup?
    private var window: [Float]
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var agc: Float = 1e-4   // rolling "full scale" so the display tracks volume

    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var timer: Timer?

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    func open(_ url: URL) {
        close()
        guard AudioPreview.isPlayable(url), let f = try? AVAudioFile(forReading: url) else { return }
        file = f
        buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(fftSize))
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep ticking while menus/scrolling
        timer = t
    }

    func close() {
        timer?.invalidate(); timer = nil; file = nil; buffer = nil
        smoothed = Array(repeating: 0, count: Self.bandCount)
        bands = smoothed
    }

    private func tick() {
        guard let file, let buffer, let setup,
              AudioPreview.shared.playingURL != nil, !AudioPreview.shared.paused else { return }
        let sr = file.processingFormat.sampleRate
        let total = file.length
        let frame = AVAudioFramePosition(AudioPreview.shared.currentTime * sr)
        guard total > AVAudioFramePosition(fftSize) else { return }
        file.framePosition = max(0, min(frame, total - AVAudioFramePosition(fftSize)))
        buffer.frameLength = 0
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(fftSize)) } catch { return }
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }

        // windowed mono samples
        var windowed = [Float](repeating: 0, count: fftSize)
        let n = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        for i in 0..<min(n, fftSize) {
            var s = ch[0][i]
            if chans > 1 { s = (s + ch[1][i]) * 0.5 }
            windowed[i] = s
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Bands spaced by FREQUENCY (equal musical octaves, ~30 Hz → 20 kHz) rather than
        // by raw FFT bin — even 1/3-octave-ish bars, so the low end isn't over-weighted
        // by near-empty sub-bass bins. NORMALIZED linear magnitude (the raw vDSP FFT is
        // unscaled), with a gentle treble tilt so highs read against the bass.
        let nb = Self.bandCount
        let norm = 2 / Float(fftSize)
        let fLow = 30.0, fHigh = min(16_000.0, sr / 2)
        let binPerHz = Double(fftSize) / sr
        var lin = [Float](repeating: 0, count: nb)
        for b in 0..<nb {
            let f0 = fLow * pow(fHigh / fLow, Double(b) / Double(nb))
            let f1 = fLow * pow(fHigh / fLow, Double(b + 1) / Double(nb))
            let lo = max(1, Int(f0 * binPerHz))
            let hi = max(lo + 1, Int(f1 * binPerHz))
            var sum: Float = 0; var c: Float = 0
            for k in lo..<min(hi, half) { sum += sqrt(mags[k]) * norm; c += 1 }
            let tilt = 1 + 1.6 * Float(b) / Float(nb)        // lift higher bands a little
            lin[b] = (c > 0 ? sum / c : 0) * tilt
        }
        // Automatic gain control: scale to the recent loudest band (fast attack, slow
        // release) so the picture auto-adjusts to volume instead of flooding, then a dB
        // curve for the familiar EQ look.
        let frameMax = lin.max() ?? 0
        agc = max(frameMax, agc * 0.992)
        let ref = max(agc, 1e-4)
        var out = [Float](repeating: 0, count: nb)
        for b in 0..<nb {
            let db = 20 * log10(lin[b] / ref + 1e-6)         // ≤ 0 dB
            out[b] = min(1, max(0, (db + 42) / 42))          // -42…0 dB → 0…1
        }
        for i in 0..<nb { smoothed[i] = smoothed[i] * 0.5 + out[i] * 0.5 }
        let snapshot = smoothed
        DispatchQueue.main.async { self.bands = snapshot }
    }
}

final class AudioPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPreview()
    private var player: AVAudioPlayer?
    private var timer: Timer?

    @Published var playingURL: URL?            // changes only on play/stop — cheap to observe
    @Published var paused = false
    @Published var playlist: [PlayItem] = []   // the current queue (album, or a single track)
    @Published var index = 0                   // position within `order`
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Float = 1.0 { didSet { player?.volume = volume } }
    private var order: [Int] = []              // play order into `playlist` (identity, or shuffled)

    var current: PlayItem? { order.indices.contains(index) ? playlist[order[index]] : nil }
    var progress: Double { AudioProgress.shared.progress }
    var duration: Double { player?.duration ?? 0 }
    var currentTime: Double { player?.currentTime ?? 0 }
    var hasNext: Bool { repeatMode != .off || index < order.count - 1 }
    var hasPrev: Bool { index > 0 || repeatMode != .off }

    /// A .m4p is FairPlay-protected: AVAudioPlayer can't decode it, so skip rather
    /// than fail silently (playback jumps to the next playable track).
    static func isPlayable(_ url: URL) -> Bool { url.pathExtension.lowercased() != "m4p" }

    @discardableResult
    private func start(_ item: PlayItem) -> Bool {
        do {
            let p = try AVAudioPlayer(contentsOf: item.url)
            p.delegate = self
            p.volume = volume
            p.play()
            player = p; playingURL = item.url; paused = false; AudioProgress.shared.progress = 0
            SpectrumAnalyzer.shared.open(item.url)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let p = self.player, p.duration > 0, p.isPlaying else { return }
                AudioProgress.shared.progress = p.currentTime / p.duration
            }
            return true
        } catch { return false }
    }

    private func rebuildOrder(currentPlaylistIndex: Int) {
        let idxs = Array(playlist.indices)
        if shuffle {
            var rest = idxs.filter { $0 != currentPlaylistIndex }
            rest.shuffle()
            order = [currentPlaylistIndex] + rest
            index = 0
        } else {
            order = idxs
            index = currentPlaylistIndex
        }
    }

    /// Start a queue (an album, or a single track) at `startAt`, skipping protected files.
    func play(_ items: [PlayItem], startAt: Int = 0) {
        let playable = items.enumerated().filter { Self.isPlayable($0.element.url) }
        guard !playable.isEmpty else { return }
        // remap startAt onto the filtered list
        let startURL = items.indices.contains(startAt) ? items[startAt].url : playable.first!.element.url
        playlist = playable.map { $0.element }
        let pIndex = playlist.firstIndex { $0.url == startURL } ?? 0
        timer?.invalidate(); player?.stop()
        rebuildOrder(currentPlaylistIndex: pIndex)
        _ = start(playlist[order[index]])
    }

    /// Legacy single-file toggle (review queue, tag inspector): a one-item queue.
    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        play([PlayItem(url: url, title: url.deletingPathExtension().lastPathComponent, artist: "", album: "")])
    }

    func playPause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); paused = true } else { p.play(); paused = false }
    }

    func next() {
        if repeatMode == .one, let c = current { _ = start(c); return }
        if index < order.count - 1 { index += 1 }
        else if repeatMode == .all { index = 0 }
        else { stop(); return }
        if !start(playlist[order[index]]) { next() }
    }

    func prev() {
        // restart the current track if we're more than 3s in, else go back one
        if currentTime > 3, let c = current { _ = start(c); return }
        if index > 0 { index -= 1 }
        else if repeatMode == .all { index = order.count - 1 }
        else if let c = current { _ = start(c); return }
        if !start(playlist[order[index]]) { if index > 0 { index -= 1; _ = start(playlist[order[index]]) } }
    }

    func toggleShuffle() {
        shuffle.toggle()
        rebuildOrder(currentPlaylistIndex: order.indices.contains(index) ? order[index] : 0)
    }
    func cycleRepeat() { repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off) }

    func seek(to frac: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = max(0, min(1, frac)) * p.duration
        AudioProgress.shared.progress = frac
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil; playingURL = nil; paused = false; AudioProgress.shared.progress = 0
        playlist = []; order = []; index = 0
        SpectrumAnalyzer.shared.close()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.next() }
    }
}

// MARK: - Store

@MainActor
final class PerfectStore: ObservableObject {
    @Published var root: URL?
    // how much Perfect proposes — persisted; defaults to Thorough
    @Published var thoroughness: Thoroughness =
        Thoroughness(rawValue: UserDefaults.standard.string(forKey: "perfectThoroughness") ?? "") ?? .thorough {
        didSet {
            UserDefaults.standard.set(thoroughness.rawValue, forKey: "perfectThoroughness")
            if diagnosed && !busy { diagnose() }   // re-scope the review to the new level
        }
    }
    // run every check automatically on choosing a library, or wait for one Run
    // press — persisted; defaults to automatic. Never task-by-task.
    @Published var autoRun: Bool = (UserDefaults.standard.object(forKey: "perfectAutoRun") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoRun, forKey: "perfectAutoRun") }
    }
    @Published var status = "Choose a music library to explore."
    @Published var busy = false
    // when true, the tag pass runs automatically after the structure scan (one
    // exploration); a thoroughness re-scope re-scans structure only.
    private var chainTags = false
    @Published var progress = ""
    @Published var findings: [PerfectFinding] = []
    // Every album folder found by the scan (Artist/Album/track layout), so the Artwork
    // step can offer a cover change on ANY album — not only the ones AcoustID matched.
    @Published var scannedAlbums: [ScannedAlbum] = []
    @Published var renames: [RenameProposal] = []
    // one artist-centric list, folding folder merges and tag fixes together
    @Published var artists: [ArtistIssue] = []
    // raw detection, kept internally and combined into `artists`
    private var folderGroups: [FolderGroup] = []
    private var tagGroups: [TagGroup] = []
    @Published var diagnosed = false
    @Published var wizardStep = 1     // the Perfect step the user is on, persisted so a mid-run resumes in place

    // commit-result summary
    @Published var lastRunSummary: String?
    @Published var lastQuarantine: URL?
    @Published var showCompletionSummary = false   // final Review→Apply finished → show the "all done" dialog

    /// Reset the whole Perfect wizard back to the choose-a-library screen.
    func resetWizard() {
        showCompletionSummary = false
        proposals = []; findings = []; artists = []; renames = []; scannedAlbums = []
        diagnosed = false; didIdentify = false; enriched = false; wizardStep = 1
        artworkStagePlanned = false; artworkStageDone = false; artworkNeedsReview = []
        ArtworkChoices.shared.clearAll()
        deduped = false; dedupStageDone = false; organised = false; organiseStageDone = false
        organiseStale = false
        organisePlans = []; dedupClusters = []; dedupTracks = []
        compilationCandidates = []; confirmedCompilations = []
        albumMergeCandidates = []; declinedAlbumMerges = []
        missingTrackReports = []; damagedTrackReports = []
        lastRunSummary = nil
        clearPlan()                      // starting over discards the saved plan for this library
        root = nil                       // → PerfectView shows the intro / new-library screen
        status = "Choose a music library to explore."
    }

    // live apply progress (drives the Applying… dialog with its Cancel button)
    @Published var committing = false
    @Published var cancelRequested = false     // Cancel pressed; disables the button
    @Published var commitPhase = ""
    @Published var commitDone = 0
    @Published var commitTotal = 0
    @Published var artworkNeedsReview: [ArtworkReviewItem] = []   // albums needing a manual cover choice
    func setCommitProgress(_ phase: String, done: Int) { commitPhase = phase; commitDone = done }

    // persistent run history across ALL libraries (each run's quarantine holds run.json)
    @Published var runs: [RunRecord] = []
    // runs belonging to the currently-open library (for the Perfect footer / done dialog)
    var currentRuns: [RunRecord] { guard let r = root else { return [] }; return runs.filter { $0.root.path == r.path } }

    @Published var checkingTags = false
    @Published var tagProgress = ""

    // identify (acoustic fingerprint → AcoustID → proposed correct names)
    @Published var proposals: [TrackProposal] = []
    @Published var identifying = false
    @Published var identifyProgress = ""
    @Published var recentFinds: [String] = []   // live feed of what identify just matched
    @Published var identifyMatched = 0           // running count of tracks matched
    @Published var identifyListened = 0          // Phase 1: files fingerprinted so far
    @Published var identifyListening = false     // true during Phase 1 (listening), false during Phase 2 (matching)
    @Published var enriching = false
    @Published var enrichProgress = ""
    @Published var enrichDone = 0                 // running count of tracks looked up
    @Published var didIdentify = false       // identify pass has completed at least once
    @Published var enriched = false          // credits pass has run (or was skipped)

    // deduplicate (folded in from the old wizard; merge-of-best keeper)
    @Published var dedupClusters: [Cluster] = []
    @Published var dedupTracks: [Track] = []
    @Published var deduped = false
    @Published var deduping = false
    @Published var artworkStagePlanned = false // the Artwork step's planning pass has run
    @Published var artworkStageDone = false     // Artwork step passed (reviewed or skipped) → Duplicates reachable
    @Published var dedupStageDone = false      // stage applied or skipped → Organise reachable
    @Published var organiseStageDone = false   // stage applied or skipped → Review reachable
    @Published var organiseStale = false       // a placement-affecting change was confirmed AFTER Organise ran
    private var pendingReorganiseApply = false // re-plan then auto-apply the straggler moves

    /// Re-plan Organise and apply just the moves that changed — used when a Review
    /// decision (e.g. a confirmed album guess) affects where a file should live
    /// after Organise already ran. Reuses the normal, reversible organise apply.
    func reorganiseStragglers() {
        guard organiseStageDone else { return }
        pendingReorganiseApply = true
        organise()
    }

    /// Plan the Artwork step cheaply from what the scan already knows: any album
    /// with an art-less track needs a cover choice (fill from the album's own
    /// covers, choose a file, or search). Albums whose tracks all have art are
    /// left untouched — keep-existing is the default. Uses curHasArt (no I/O).
    func planArtworkStage() {
        var byAlbum: [String: (artist: String, album: String, files: [String], anyBlank: Bool)] = [:]
        for p in proposals {
            // strip "[Disc N]" so ALL discs of one set are a single review row —
            // otherwise a 3-disc album is 3 rows and 3× the work, and one cover
            // can't be applied across the discs.
            let album = Organiser.stripDiscSuffix(p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum).clean
            // a compilation collapses to "Various Artists" so the whole album is ONE row
            // and its cover is found by album name, not each track's differing artist.
            let artist = artArtistFor(album: album, artist: p.newArtist.isEmpty ? p.curArtist : p.newArtist)
            let key = "\(artist.lowercased())|\(album.lowercased())"
            var e = byAlbum[key] ?? (artist, album, [], false)
            e.files.append(p.relPath)
            if !p.curHasArt { e.anyBlank = true }
            byAlbum[key] = e
        }
        artworkNeedsReview = byAlbum.values.filter { $0.anyBlank }
            .map { ArtworkReviewItem(artist: $0.artist, album: $0.album, files: $0.files,
                                     mbids: mbids(forAlbum: $0.album, artist: $0.artist)) }
            .sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
        artworkStagePlanned = true
    }

    /// Add an album to the artwork review list on demand — so the user can change
    /// a cover they don't like even on an album that wasn't auto-flagged.
    func reviewAlbumArt(artist: String, album: String, files: [String]) {
        guard !artworkNeedsReview.contains(where: { $0.artist == artist && $0.album == album }) else { return }
        artworkNeedsReview.append(ArtworkReviewItem(artist: artist, album: album, files: files,
                                                    mbids: mbids(forAlbum: album, artist: artist)))
    }

    // organise (rebuild the clean Album Artist/Album/## Title tree from tags)
    @Published var organisePlans: [OrganisePlan] = []
    @Published var organised = false          // organise plan has been built at least once
    @Published var organising = false
    @Published var organiseProgress = ""

    // Compilations: albums confirmed as various-artists sets → filed under "Various
    // Artists". Flag (TCMP/cpil) ones are auto; flag-less ones are surfaced as
    // candidates for the user to confirm.
    struct CompilationCandidate: Identifiable {
        let id: String            // fold(stripDiscSuffix(album))
        let album: String
        let artists: [String]
        let trackCount: Int
        let flagged: Bool         // carries the compilation flag → auto, no confirmation needed
    }
    @Published var compilationCandidates: [CompilationCandidate] = []
    @Published var confirmedCompilations: Set<String> = []    // fold-keyed album names the user OK'd

    func toggleCompilation(_ id: String, on: Bool) {
        if on { confirmedCompilations.insert(id) } else { confirmedCompilations.remove(id) }
        organise()   // re-plan with the new set so the tree preview updates
    }

    // Album-edition merges: different-named folders of the SAME album ("Legends" +
    // "Legends [Sony]", or "…[Castle]") folded into one. Surfaced for confirmation;
    // default ON (the edition markers stripped are high-confidence), so we track the
    // ones the user has explicitly DECLINED rather than the ones they've approved.
    @Published var albumMergeCandidates: [Organiser.MergeGroup] = []
    @Published var declinedAlbumMerges: Set<String> = []    // canonical keys the user turned OFF

    func toggleAlbumMerge(_ key: String, on: Bool) {
        if on { declinedAlbumMerges.remove(key) } else { declinedAlbumMerges.insert(key) }
        organise()
    }

    /// Generic album titles shared by many unrelated artists — NOT evidence of a
    /// compilation, and a hint that same-titled albums by different artists are really
    /// separate releases (used by both compilation detection and credit grouping).
    nonisolated static let genericAlbumTitles: Set<String> = [
        "greatest hits", "the greatest hits", "hits", "live", "best of",
        "the best of", "collection", "the collection", "compilation",
        "essential", "the essential", "gold", "anthology"]

    /// Flag-less compilation candidates: an album title shared by ≥2 distinct artists
    /// with NO album-artist on any track, non-generic name. Flagged albums are marked
    /// flagged=true (auto). For the Organise step's confirmation list.
    nonisolated static func compilationCandidates(from inputs: [OrganiseInput]) -> [CompilationCandidate] {
        struct Acc { var album = ""; var artists = Set<String>(); var count = 0; var anyAA = false; var anyFlag = false }
        var by: [String: Acc] = [:]
        for t in inputs {
            let a = Organiser.stripDiscSuffix(t.album).clean
            guard !a.isEmpty, !Organiser.isPlaceholderAlbum(a) else { continue }
            let key = Organiser.fold(a)
            var acc = by[key] ?? Acc(); acc.album = a
            if !t.artist.isEmpty { acc.artists.insert(Organiser.fold(t.artist)) }
            acc.count += 1
            if !t.albumArtist.isEmpty { acc.anyAA = true }
            if t.isCompilation { acc.anyFlag = true }
            by[key] = acc
        }
        return by.compactMap { (key, acc) -> CompilationCandidate? in
            let heuristic = acc.artists.count >= 2 && !acc.anyAA && !Self.genericAlbumTitles.contains(key)
            guard heuristic || acc.anyFlag else { return nil }
            return CompilationCandidate(id: key, album: acc.album, artists: Array(acc.artists).sorted(),
                                        trackCount: acc.count, flagged: acc.anyFlag)
        }.sorted { $0.album.lowercased() < $1.album.lowercased() }
    }
    @Published var composerFirstClassical = false   // classical → Composer-first folders
    @Published var renumberTracks = false           // assign a clean 1…N per album/disc
    // Missing-track reconcile for the whole run: after the clean tree is built, check
    // each real album against MusicBrainz/Discogs/Deezer and remember which tracks it's
    // missing (persisted per album folder so the Album Inspector greys them out later).
    // Network-heavy, so it's a toggle — off means a quick run stays offline.
    @Published var checkMissingTracks: Bool = (UserDefaults.standard.object(forKey: "perfectCheckMissing") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(checkMissingTracks, forKey: "perfectCheckMissing") }
    }
    @Published var missingTrackReports: [MissingAlbumReport] = []   // filled by the last Apply
    @Published var damagedTrackReports: [DamagedAlbumReport] = []    // suspiciously-short files, info-only
    // category-level toggles (the mockup's bulk on/off buttons)
    @Published var applyNames = true       // identify: artist/title/album corrections
    @Published var applyArtwork = true     // add missing cover art
    @Published var applyCredits = true     // composer/label/performers gap-fills
    // per-kind name toggles — auto-apply cosmetic tidies and bulk-accept "adds
    // detail" without cluttering the queue; substantive changes always go through
    // the per-track review.
    @Published var applyCosmeticNames = true
    @Published var applyAdditiveNames = true
    func nameKindEnabled(_ k: ChangeKind) -> Bool {
        switch k {
        case .cosmetic: return applyCosmeticNames
        case .additive: return applyAdditiveNames
        default:        return true
        }
    }
    var hasAcoustIDKey: Bool { !Identifier.configuredKey.isEmpty }
    var hasDiscogsToken: Bool { !APIKeys.discogs.isEmpty }

    // One-time-per-launch reminder that identification needs a free AcoustID key.
    @Published var showKeyReminder = false
    private var remindedThisLaunch = false
    /// Called when a Perfect run begins. If there's no AcoustID key, surface the
    /// reminder dialog once — the run still proceeds (identification just skips).
    func remindKeysIfNeeded() {
        guard !hasAcoustIDKey, !remindedThisLaunch else { return }
        remindedThisLaunch = true
        showKeyReminder = true
    }

    // Tag writing uses a surgical TagLib shim (MDTagShim) that changes only the
    // artist frame and preserves the ID3 version and every other frame — verified
    // lossless at the frame level. Enabled.
    let tagWritingEnabled = true

    /// work this artist would actually apply right now — folder merges always,
    /// tag rewrites only when tag-writing is enabled
    func artistHasApplicableWork(_ a: ArtistIssue) -> Bool {
        a.folderMerges > 0 || (tagWritingEnabled && a.tagRewrites > 0)
    }

    private let cancelFlag = CancelBox()

    // scanned totals for the header
    @Published var totalFiles = 0
    @Published var totalFolders = 0
    @Published var totalBytes: Int64 = 0

    func setRoot(_ url: URL) {
        root = url
        Self.rememberRoot(url)
        findings = []; renames = []; artists = []; folderGroups = []; tagGroups = []; proposals = []; didIdentify = false; enriched = false
        artworkStagePlanned = false; artworkStageDone = false; artworkNeedsReview = []
        deduped = false; dedupStageDone = false; organised = false; organiseStageDone = false
        organiseStale = false
        compilationCandidates = []; confirmedCompilations = []
        albumMergeCandidates = []; declinedAlbumMerges = []
        diagnosed = false
        lastRunSummary = nil
        loadRuns()
        // Resume a saved plan for this library if one exists (identify/enrich results
        // and decisions from a previous session) — so closing and reopening doesn't
        // throw away the network-heavy work.
        if loadPlan() {
            status = "Resumed your last session — \(proposals.count) track(s). Re-scan to start over."
        } else {
            wizardStep = 1
            // Nothing runs automatically — the user triggers Scan (step 1).
            status = "Ready — press Scan to check \(url.lastPathComponent)."
        }
    }

    // MARK: Resumable plan (persist proposals + decisions per library)

    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }
    /// Where a library's resumable plan lives — Application Support, keyed by a
    /// deterministic hash of the library path, so the user's music folder stays clean.
    private static func planURL(forRoot root: URL) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Music Librarian/plans", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(stableHash(root.path)).json")
    }

    /// Write the current working plan for the open library (no-op if nothing to save).
    func savePlan() {
        guard let root, !proposals.isEmpty,
              let url = Self.planURL(forRoot: root) else { return }
        let plan = PerfectPlan(rootPath: root.path, saved: Date(), totalFiles: totalFiles,
                               proposals: proposals, diagnosed: diagnosed, didIdentify: didIdentify,
                               enriched: enriched, artworkStageDone: artworkStageDone,
                               dedupStageDone: dedupStageDone, organiseStageDone: organiseStageDone,
                               artworkChoices: ArtworkChoices.shared.byKey, wizardStep: wizardStep,
                               confirmedCompilations: Array(confirmedCompilations),
                               declinedAlbumMerges: Array(declinedAlbumMerges))
        if let data = try? JSONEncoder().encode(plan) { try? data.write(to: url) }
    }

    /// Restore a saved plan for the open library. Returns true if one was loaded.
    @discardableResult
    func loadPlan() -> Bool {
        guard let root, let url = Self.planURL(forRoot: root),
              let data = try? Data(contentsOf: url),
              let plan = try? JSONDecoder().decode(PerfectPlan.self, from: data),
              plan.rootPath == root.path, !plan.proposals.isEmpty else { return false }
        proposals = plan.proposals
        totalFiles = plan.totalFiles
        diagnosed = true   // we had scanned last time → keep the later steps reachable
        didIdentify = plan.didIdentify
        enriched = plan.enriched
        artworkStageDone = plan.artworkStageDone
        dedupStageDone = plan.dedupStageDone
        organiseStageDone = plan.organiseStageDone
        ArtworkChoices.shared.byKey = plan.artworkChoices
        wizardStep = min(max(plan.wizardStep, 1), 7)
        confirmedCompilations = Set(plan.confirmedCompilations)
        declinedAlbumMerges = Set(plan.declinedAlbumMerges)
        return true
    }

    /// The library of the most recently-saved unfinished plan (a mid-run session
    /// that was cancelled/closed before Apply), so the app can resume it on launch.
    /// Returns nil if there's no lingering plan or its library no longer exists.
    static func resumableLibrary() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let dir = base.appendingPathComponent("Music Librarian/plans", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.first
        guard let f = newest,
              let data = try? Data(contentsOf: f),
              let plan = try? JSONDecoder().decode(PerfectPlan.self, from: data),
              fm.fileExists(atPath: plan.rootPath) else { return nil }
        return URL(fileURLWithPath: plan.rootPath)
    }

    /// Discard the saved plan (after a full apply, or when starting over).
    func clearPlan() {
        guard let root, let url = Self.planURL(forRoot: root) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// One exploration pass: structure scan followed by the artist-tag scan.
    /// This is the single entry point — there are no per-check buttons.
    func explore() {
        remindKeysIfNeeded()
        chainTags = true
        diagnose()
    }

    func pickRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose the music library to make perfect"
        if p.runModal() == .OK, let url = p.url { setRoot(url) }
    }

    // One affected album for the carousel, aggregating the pending changes that
    // touch the tracks in a single folder (names / artwork / credits).
    struct AlbumChange: Identifiable {
        let id: String            // album folder path
        let dir: URL
        let title: String
        let subtitle: String
        let sampleURL: URL?
        let trackCount: Int
        var names = false, artwork = false, credits = false
        var artReleaseMBID: String? = nil   // for previewing found (not-yet-embedded) art
    }

    /// Albums touched by identify/enrich, for the cover carousel. Grouped by the
    /// tracks' folder; each carries which kinds of change it will get.
    /// The album a proposal belongs to — artist + disc-stripped album — so the grid
    /// shows ONE card per album even when its tracks are split across folders/discs.
    func albumGroupKey(_ p: TrackProposal) -> String {
        artKey(artist: p.newArtist.isEmpty ? p.curArtist : p.newArtist,
               album: p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum)
    }

    /// The artist a cover is keyed/looked-up under. A confirmed compilation collapses to
    /// "Various Artists" so ONE cover — found by album name, not any single track's
    /// artist — applies across every track, instead of fragmenting per track artist.
    func artArtistFor(album: String, artist: String) -> String {
        confirmedCompilations.contains(Organiser.fold(Organiser.stripDiscSuffix(album).clean))
            ? "Various Artists" : artist
    }
    func artKey(artist: String, album: String) -> String {
        ArtworkChoices.key(artist: artArtistFor(album: album, artist: artist), album: album)
    }

    var albumChanges: [AlbumChange] {
        var byAlbum: [String: [TrackProposal]] = [:]
        for p in proposals where p.isActionable {
            byAlbum[albumGroupKey(p), default: []].append(p)
        }
        return byAlbum.map { (key, props) -> AlbumChange in
            let p0 = props.first!
            let artist = p0.newArtist.isEmpty ? p0.curArtist : p0.newArtist
            let album = Organiser.stripDiscSuffix(p0.chosenAlbum.isEmpty ? p0.curAlbum : p0.chosenAlbum).clean
            return AlbumChange(
                id: key, dir: p0.url.deletingLastPathComponent(),
                title: album.isEmpty ? "Unknown Album" : album,
                subtitle: artist,
                // sample a track that ACTUALLY HAS art for the thumbnail — otherwise a
                // mixed album whose first track is art-less shows a blank card even
                // though other tracks (and the detail view) have the cover.
                sampleURL: (props.first(where: { $0.curHasArt }) ?? props.first)?.url,
                trackCount: props.count,
                names: props.contains { $0.hasChange },
                artwork: props.contains { !$0.curHasArt },   // any art-less track → art added on apply
                credits: props.contains { !($0.enrichment?.isEmpty ?? true) },
                artReleaseMBID: props.first(where: { $0.enrichment?.releaseMBID != nil })?.enrichment?.releaseMBID)
        }.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    // findings grouped by kind, in display order
    var groups: [(kind: FixKind, items: [PerfectFinding])] {
        let order: [FixKind] = [.junk, .emptyFolder, .drm]
        return order.compactMap { k in
            let items = findings.filter { $0.kind == k }
            return items.isEmpty ? nil : (k, items)
        }
    }
    var acceptedCount: Int { findings.filter { $0.accepted && $0.kind.safe }.count }

    // MARK: Diagnose

    func diagnose() {
        guard let root else { return }
        busy = true; diagnosed = false; findings = []
        // a fresh scan resets the later stages
        dedupStageDone = false; organiseStageDone = false
        status = "Diagnosing…"; progress = ""
        cancelFlag.cancelled = false
        let box = cancelFlag
        Task.detached(priority: .userInitiated) {
            var found: [PerfectFinding] = []
            var files = 0, folders = 0
            var bytes: Int64 = 0
            let fm = FileManager.default

            // Enumerate everything once. Track which directories contain any file
            // (anywhere below) so we can flag the truly-empty ones afterwards.
            var dirHasContent = Set<String>()
            var allDirs: [URL] = []
            var audioByFolder: [String: [URL]] = [:]   // album folder path → its audio files

            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                      options: []) {
                while let u = en.nextObject() as? URL {
                    if box.cancelled { break }
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if v?.isDirectory == true {
                        folders += 1
                        allDirs.append(u)
                        continue
                    }
                    files += 1
                    let size = Int64(v?.fileSize ?? 0)
                    bytes += size
                    let rel = Self.rel(u, root)

                    // mark every ancestor directory as having content
                    var p = u.deletingLastPathComponent()
                    while p.path.count >= root.path.count {
                        dirHasContent.insert(p.path)
                        if p.path == root.path { break }
                        p = p.deletingLastPathComponent()
                    }

                    if Self.isAudio(u) {
                        audioByFolder[u.deletingLastPathComponent().path, default: []].append(u)
                    }
                    if let junkReason = Self.junkReason(u) {
                        found.append(PerfectFinding(kind: .junk, url: u, relPath: rel,
                                                    detail: junkReason, bytes: size, accepted: true))
                    } else if Self.isAudio(u), await Self.isDRM(u) {
                        found.append(PerfectFinding(kind: .drm, url: u, relPath: rel,
                                                    detail: "FairPlay-protected — most players can't play this",
                                                    bytes: size, accepted: false))
                    }
                    if files % 50 == 0 {
                        await self.setProgress("Scanned \(files) files…")
                    }
                }
            }

            // empty folders = directories with no file anywhere inside
            for d in allDirs where !dirHasContent.contains(d.path) {
                found.append(PerfectFinding(kind: .emptyFolder, url: d, relPath: Self.rel(d, root),
                                            detail: "No audio or files inside", bytes: 0, accepted: true))
            }

            // duplicate-artist folders: top-level folders whose names normalise
            // to the same artist (Buzzcocks / The Buzzcocks; & vs and; "X, The")
            var folderGroups: [FolderGroup] = []
            let topDirs = allDirs.filter { $0.deletingLastPathComponent().path == root.path
                                           && $0.lastPathComponent != "Music Librarian Quarantine" }
            var byKey: [String: [URL]] = [:]
            for d in topDirs { byKey[Self.artistKey(d.lastPathComponent), default: []].append(d) }
            for (key, dirs) in byKey where dirs.count > 1 {
                let names = dirs.map { $0.lastPathComponent }
                let counts = dirs.map { d -> Int in
                    var c = 0
                    if let e = fm.enumerator(at: d, includingPropertiesForKeys: nil) {
                        while let f = e.nextObject() as? URL { if Self.isAudio(f) { c += 1 } }
                    }
                    return c
                }
                folderGroups.append(FolderGroup(key: key, sources: names, fileCounts: counts))
            }

            // bad folder names — safe cosmetic tidy. Skip empties (being removed)
            // and anything under a merge source (its contents move during merge).
            let emptyPaths = Set(found.filter { $0.kind == .emptyFolder }.map { $0.url.path })
            let mergeSrcRoots = folderGroups.flatMap { g in g.sources.map { root.appendingPathComponent($0).path + "/" } }
            var renameProposals: [RenameProposal] = []
            for d in allDirs {
                if emptyPaths.contains(d.path) { continue }
                if d.lastPathComponent == "Music Librarian Quarantine" { continue }
                if mergeSrcRoots.contains(where: { d.path.hasPrefix($0) || d.path + "/" == $0 }) { continue }
                let old = d.lastPathComponent
                let clean = Self.cleanFolderName(old)
                guard clean != old, !clean.isEmpty else { continue }
                // skip if a sibling with the cleaned name already exists (would collide)
                let siblingClean = d.deletingLastPathComponent().appendingPathComponent(clean)
                if fm.fileExists(atPath: siblingClean.path) { continue }
                renameProposals.append(RenameProposal(relPath: Self.rel(d, root), oldName: old,
                                                      newName: clean, accepted: true))
            }

            // drop any rename whose ancestor is also being renamed (keeps commit
            // and undo ordering simple; nested cases resolve on a later re-diagnose)
            let renameRels = Set(renameProposals.map { $0.relPath })
            let filteredRenames = renameProposals.filter { p in
                var parent = (p.relPath as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    if renameRels.contains(parent) { return false }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                return true
            }

            // one entry per album folder (…/Artist/Album/track), for the Artwork step's
            // "change any cover" grid — covers albums AcoustID never matched.
            let albums: [ScannedAlbum] = audioByFolder.compactMap { (folder, urls) in
                guard folder != root.path else { return nil }   // loose files at the top aren't an album
                let dir = URL(fileURLWithPath: folder)
                if dir.lastPathComponent == "Music Librarian Quarantine" { return nil }
                return ScannedAlbum(id: folder,
                                    artist: dir.deletingLastPathComponent().lastPathComponent,
                                    album: dir.lastPathComponent,
                                    files: urls.map { Self.rel($0, root) })
            }.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }

            let (ff, fo, fb) = (files, folders, bytes)
            let fg = folderGroups
            await self.finishDiagnose(found: found, folderGroups: fg, albums: albums,
                                      renames: filteredRenames.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() },
                                      files: ff, folders: fo, bytes: fb, cancelled: box.cancelled)
        }
    }

    private func setProgress(_ s: String) { progress = s }

    private func finishDiagnose(found: [PerfectFinding], folderGroups fg: [FolderGroup],
                               albums: [ScannedAlbum], renames r: [RenameProposal],
                               files: Int, folders: Int, bytes: Int64, cancelled: Bool) {
        findings = found.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        if !cancelled { scannedAlbums = albums }
        // gate by thoroughness (junk/empties/DRM always; renames Standard+; merges Thorough)
        folderGroups = fg
        renames = thoroughness.doesRenames ? r : []
        rebuildArtists()
        totalFiles = files; totalFolders = folders; totalBytes = bytes
        busy = false; diagnosed = !cancelled; progress = ""
        let junk = found.filter { $0.kind == .junk }.count
        let empties = found.filter { $0.kind == .emptyFolder }.count
        let drm = found.filter { $0.kind == .drm }.count
        var parts = ["\(files) files · \(folders) folders · \(fmtBytes(bytes))"]
        var found2: [String] = []
        if junk > 0 { found2.append("\(junk) junk") }
        if empties > 0 { found2.append("\(empties) empty folder(s)") }
        if !artists.isEmpty { found2.append("\(artists.count) artist(s) to fix") }
        if !renames.isEmpty { found2.append("\(renames.count) untidy name(s)") }
        if drm > 0 { found2.append("\(drm) protected track(s)") }
        if !found2.isEmpty { parts.append("found " + found2.joined(separator: ", ")) }
        status = cancelled ? "Exploration cancelled." : parts.joined(separator: " — ") + "."
        // second half of a full exploration: read the tags too
        if chainTags && !cancelled {
            chainTags = false
            checkTags()
        } else {
            chainTags = false
        }
    }

    /// Combine the raw folder-level and tag-level detections into one
    /// artist-centric list. Preserves the user's `accepted`/`canonical` edits
    /// across rebuilds (matched by key), so a later tag scan or a thoroughness
    /// change doesn't wipe choices already made.
    private func rebuildArtists() {
        // remember prior user edits
        let prior = Dictionary(uniqueKeysWithValues: artists.map { ($0.key, $0) })

        let folderByKey = Dictionary(uniqueKeysWithValues: folderGroups.map { ($0.key, $0) })
        let tagByKey = Dictionary(uniqueKeysWithValues: tagGroups.map { ($0.key, $0) })
        let allKeys = Set(folderByKey.keys).union(tagByKey.keys)

        var result: [ArtistIssue] = []
        for key in allKeys {
            let fg = folderByKey[key]
            let tg = tagByKey[key]
            // folder side only counts when the level allows folder merges
            let folderSources = (thoroughness.doesMerges ? fg?.sources : nil) ?? []
            let folderCounts  = (thoroughness.doesMerges ? fg?.fileCounts : nil) ?? []
            let tagVariants = tg?.variants ?? []
            let tagMembers = tg?.members ?? []

            let hasFolderSplit = folderSources.count > 1
            let hasTagSplit = tagVariants.count > 1
            guard hasFolderSplit || hasTagSplit else { continue }   // nothing to do

            // candidate names for the picker: union of folder names + tag spellings,
            // ranked by how many files back each name (tags + matching folder)
            var score: [String: Int] = [:]
            for (n, c) in tagVariants { score[n, default: 0] += c }
            for (n, c) in zip(folderSources, folderCounts) { score[n, default: 0] += c }
            let candidates = score.sorted { $0.value != $1.value ? $0.value > $1.value
                                                                 : $0.key.lowercased() < $1.key.lowercased() }.map { $0.key }

            // default kept name: prior choice if still valid, else the top candidate
            let canonical: String = {
                if let p = prior[key], candidates.contains(p.canonical) { return p.canonical }
                return candidates.first ?? (tagVariants.first?.name ?? folderSources.first ?? "")
            }()
            let accepted = prior[key]?.accepted ?? true

            result.append(ArtistIssue(key: key, canonical: canonical, accepted: accepted,
                                      candidates: candidates,
                                      folderSources: folderSources, folderFileCounts: folderCounts,
                                      tagVariants: tagVariants, tagMembers: tagMembers))
        }
        artists = result.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() }
    }

    /// Safe cosmetic tidy of a folder name — trailing underscores (stripped
    /// illegal chars), stray/doubled whitespace, trailing dots. Never invents.
    nonisolated static func cleanFolderName(_ name: String) -> String {
        var n = name
        while n.contains("  ") { n = n.replacingOccurrences(of: "  ", with: " ") }
        n = n.trimmingCharacters(in: .whitespaces)
        while n.hasSuffix("_") || n.hasSuffix(".") || n.hasSuffix(" ") { n = String(n.dropLast()) }
        return n.trimmingCharacters(in: .whitespaces)
    }

    /// Normalise an artist folder name to a collision key: drops a leading
    /// "The"/trailing ", The", unifies & and "and", strips punctuation/spaces.
    nonisolated static func artistKey(_ name: String) -> String {
        var s = name.lowercased()
        s = s.replacingOccurrences(of: " & ", with: " and ")
        if s.hasSuffix(", the") { s = "the " + s.dropLast(5) }
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        return s.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    func cancel() { cancelFlag.cancelled = true; cancelRequested = true }

    // MARK: Tag check (Phase 2 preview) — read artist tags, find split spellings

    func checkTags() {
        guard let root, !checkingTags else { return }
        checkingTags = true; tagProgress = "Reading tags…"
        let box = cancelFlag
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var counts: [String: Int] = [:]     // exact artist string → track count
            var filesByName: [String: [URL]] = [:]  // exact artist string → its files
            var seen = 0
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = en.nextObject() as? URL {
                    if box.cancelled { break }
                    guard Self.isAudio(u) else { continue }
                    seen += 1
                    if let artist = Self.readArtist(u), !artist.isEmpty {
                        counts[artist, default: 0] += 1
                        filesByName[artist, default: []].append(u)
                    }
                    if seen % 25 == 0 { await self.setTagProgress("Read \(seen) tracks…") }
                }
            }
            // group exact spellings by normalised key; keep only real splits
            var byKey: [String: [(String, Int)]] = [:]
            for (name, c) in counts { byKey[Self.artistKey(name), default: []].append((name, c)) }
            let groups = byKey.compactMap { (k, v) -> TagGroup? in
                guard v.count > 1 else { return nil }
                let variants = v.sorted { $0.1 > $1.1 }
                let members = variants.flatMap { (name, _) in
                    (filesByName[name] ?? []).map { TagMember(url: $0, relPath: Self.rel($0, root), oldName: name) }
                }
                return TagGroup(key: k, variants: variants, members: members)
            }
            await self.finishTagCheck(groups: groups, tracks: seen, cancelled: box.cancelled)
        }
    }

    private func setTagProgress(_ s: String) { tagProgress = s }

    private func finishTagCheck(groups: [TagGroup], tracks: Int, cancelled: Bool) {
        checkingTags = false; tagProgress = ""
        if !cancelled { tagGroups = groups; rebuildArtists() }
        if !cancelled {
            let splits = artists.filter { $0.hasTagSplit }.count
            status = splits == 0
                ? "Read \(tracks) tags — no split artist spellings found."
                : "Read \(tracks) tags — \(splits) artist(s) split across different spellings."
        }
    }

    /// Read the artist tag. Uses the same TagLib shim that writes it, so a
    /// recorded "old" value exactly matches what a rewrite would overwrite —
    /// undo is then exact.
    nonisolated static func readArtist(_ url: URL) -> String? { readField(url, "artist") }

    /// Read one tag field ("artist","album","albumartist","title","track").
    nonisolated static func readField(_ url: URL, _ field: String) -> String? {
        guard let c = md_get_field(url.path, field) else { return nil }
        defer { free(c) }
        let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Write one tag field surgically — only that frame changes; the ID3 version
    /// and every other frame (year, rating, cover art, …) are preserved.
    nonisolated static func writeField(_ url: URL, _ field: String, to value: String) throws {
        let rc = md_set_field(url.path, field, value)
        if rc != 0 { throw NSError(domain: "MDTagShim", code: Int(rc),
                                   userInfo: [NSLocalizedDescriptionKey: "tag write failed (\(rc))"]) }
    }

    /// Add a performer credit (name + instrument/role) to the musician-credits list.
    nonisolated static func addPerformer(_ url: URL, name: String, role: String) throws {
        let rc = md_add_performer(url.path, name, role)
        if rc != 0 { throw NSError(domain: "MDTagShim", code: Int(rc),
                                   userInfo: [NSLocalizedDescriptionKey: "credit write failed (\(rc))"]) }
    }

    /// Remove a performer credit (for undo).
    nonisolated static func removePerformer(_ url: URL, name: String, role: String) {
        _ = md_remove_performer(url.path, name, role)
    }

    // MARK: Commit — apply accepted removals + merges as a log of reversible moves

    var hasWork: Bool {
        !ArtworkChoices.shared.byKey.isEmpty          // covers picked in the Artwork step
            || (deduped && !dedupClusters.isEmpty)    // duplicates to remove on Apply
            || (organised && organisePlans.contains { $0.targetRel != nil && $0.targetRel != $0.rel })  // tree to rebuild
            || findings.contains { $0.accepted && $0.kind.safe }
            || renames.contains { $0.accepted && $0.newName != $0.oldName }
            || artists.contains { $0.accepted && artistHasApplicableWork($0) }
            || (tagWritingEnabled && proposals.contains { p in p.accepted && (
                    (applyNames && p.hasChange)
                    || (applyArtwork && p.canAddArt)
                    || (applyCredits && !(p.enrichment?.isEmpty ?? true))) })
    }

    // MARK: Identify — fingerprint each track and propose the correct names

    func identify() {
        guard let root, hasAcoustIDKey, !identifying else { return }
        identifying = true; proposals = []; identifyProgress = "Identifying…"
        recentFinds = []; identifyMatched = 0; identifyListened = 0; identifyListening = true
        didIdentify = false; enriched = false
        let box = cancelFlag; box.cancelled = false
        let id = Identifier(apiKey: Identifier.configuredKey)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // collect audio files
            var files: [URL] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = en.nextObject() as? URL { if Self.isAudio(u) { files.append(u) } }
            }
            let total = files.count

            // Phase 1 — LISTEN. Read tags and fingerprint files in parallel (pure
            // local work, no rate limit), so the CPU/disk cost happens up front
            // instead of stalling in front of every network call. Bounded so a
            // handful of tens-of-MB decodes run at once, not the whole library.
            var ready: [ReadyTrack] = []
            let cap = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            var listened = 0
            await withTaskGroup(of: ReadyTrack?.self) { group in
                var iter = files.makeIterator()
                func addNext() {
                    guard !box.cancelled, let u = iter.next() else { return }
                    group.addTask {
                        let rel = Self.rel(u, root)
                        let a = Self.readField(u, "artist") ?? ""
                        let t = Self.readField(u, "title") ?? ""
                        let al = Self.readField(u, "album") ?? ""
                        let c = Self.readField(u, "composer") ?? ""
                        let l = Self.readField(u, "label") ?? ""
                        let hasArt = md_has_artwork(u.path) == 1
                        guard let fp = id.fingerprint(u) else { return nil }
                        return ReadyTrack(url: u, rel: rel, artist: a, title: t, album: al,
                                          composer: c, label: l, hasArt: hasArt, fp: fp)
                    }
                }
                for _ in 0..<cap { addNext() }
                while let r = await group.next() {
                    listened += 1
                    if let r { ready.append(r) }
                    if listened % 2 == 0 || listened == total { await self.setListened(listened, total) }
                    addNext()
                }
            }
            await self.beginMatching()

            // Phase 2 — MATCH. AcoustID lookups, paced to its 3-requests/second
            // limit. The lookup latency counts toward the gap, so we only wait the
            // remainder — no dead 350ms tacked on after each request.
            var found: [TrackProposal] = []
            var done = 0
            for r in ready {
                if box.cancelled { break }
                let start = DispatchTime.now().uptimeNanoseconds
                if let p = try? await id.resolve(url: r.url, relPath: r.rel, fingerprint: r.fp,
                                                 curArtist: r.artist, curTitle: r.title, curAlbum: r.album,
                                                 curHasArt: r.hasArt, curComposer: r.composer, curLabel: r.label) {
                    await self.pushFind("\(p.newTitle) — \(p.newArtist)", changed: p.hasChange)
                    found.append(p)
                }
                done += 1
                if done % 3 == 0 { await self.setIdentifyProgress("Matched \(done)/\(ready.count)…") }
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let waitMs = 340.0 - elapsedMs
                if waitMs > 0 { try? await Task.sleep(nanoseconds: UInt64(waitMs * 1_000_000)) }
            }
            // Phase 3 — RECONCILE the tracks whose album is still unknown, rather
            // than giving up on them (they'd otherwise land in an "Unknown Album").
            let reconciled: [TrackProposal]
            if box.cancelled { reconciled = found }
            else {
                reconciled = await Self.reconcileAlbums(ready: ready, found: found, id: id, box: box) { msg in
                    await self.setIdentifyProgress(msg)
                }
            }
            await self.finishIdentify(proposals: reconciled, total: total, cancelled: box.cancelled)
        }
    }

    /// After the AcoustID pass, work out the album for tracks it couldn't place,
    /// instead of leaving them "Unknown":
    ///   (1) FOLDER CONSENSUS — a track inherits the album its identified
    ///       folder-mates agree on (auto-applied; folders are one album).
    ///   (2) TEXT SEARCH — no consensus? ask MusicBrainz by artist+title and send
    ///       the guess to Review (a song can be on several releases).
    /// Only what neither can resolve stays unknown (and Organise leaves it put).
    nonisolated private static func reconcileAlbums(
        ready: [ReadyTrack], found: [TrackProposal], id: Identifier,
        box: CancelBox, progress: @escaping @Sendable (String) async -> Void
    ) async -> [TrackProposal] {
        var byRel = Dictionary(found.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })

        func effectiveAlbum(_ r: ReadyTrack) -> String? {
            if let p = byRel[r.rel], !Organiser.isPlaceholderAlbum(p.chosenAlbum) { return p.chosenAlbum }
            return Organiser.isPlaceholderAlbum(r.album) ? nil : r.album
        }
        func effectiveArtist(_ r: ReadyTrack) -> String {
            if let p = byRel[r.rel], !p.newArtist.isEmpty { return p.newArtist }; return r.artist
        }
        func effectiveTitle(_ r: ReadyTrack) -> String {
            if let p = byRel[r.rel], !p.newTitle.isEmpty { return p.newTitle }; return r.title
        }
        func makeProposal(_ r: ReadyTrack, album: String, score: Double, accepted: Bool, reviewed: Bool) -> TrackProposal {
            TrackProposal(url: r.url, relPath: r.rel, score: score,
                curArtist: r.artist, curTitle: r.title, curAlbum: r.album,
                newArtist: "", newTitle: "", albumCandidates: [album], chosenAlbum: album,
                accepted: accepted, reviewed: reviewed, recordingID: nil, curHasArt: r.hasArt,
                curComposer: r.composer, curLabel: r.label, enrichment: nil)
        }

        // (1) folder consensus — a track with no album inherits the folder's dominant one
        let byFolder = Dictionary(grouping: ready) { ($0.rel as NSString).deletingLastPathComponent }
        var toSearch: [ReadyTrack] = []
        for (_, tracks) in byFolder {
            let resolved = tracks.compactMap { effectiveAlbum($0) }
            let consensus: String? = {
                guard !resolved.isEmpty else { return nil }
                let counts = Dictionary(grouping: resolved, by: { $0.lowercased() }).mapValues { $0.count }
                guard let top = counts.max(by: { $0.value < $1.value }),
                      Double(top.value) / Double(resolved.count) >= 0.6 else { return nil }   // clear majority only
                return resolved.first { $0.lowercased() == top.key }
            }()
            for r in tracks where effectiveAlbum(r) == nil {
                if let alb = consensus {   // auto-applied: same folder = same album
                    if var p = byRel[r.rel] { p.chosenAlbum = alb; p.reviewed = true; p.accepted = true; byRel[r.rel] = p }
                    else { byRel[r.rel] = makeProposal(r, album: alb, score: 1.0, accepted: true, reviewed: true) }
                } else {
                    toSearch.append(r)
                }
            }
        }

        // (2) text search the leftovers (paced to MusicBrainz's ~1 request/second)
        for (i, r) in toSearch.enumerated() {
            if box.cancelled { break }
            await progress("Looking up album \(i + 1)/\(toSearch.count)…")
            if let alb = await id.searchAlbum(artist: effectiveArtist(r), title: effectiveTitle(r)),
               !Organiser.isPlaceholderAlbum(alb) {
                // speculative — a song can be on several releases → send to Review,
                // not accepted until the user confirms it in the queue.
                if var p = byRel[r.rel] { p.chosenAlbum = alb; p.reviewed = false; p.accepted = false; byRel[r.rel] = p }
                else { byRel[r.rel] = makeProposal(r, album: alb, score: 0.5, accepted: false, reviewed: false) }
            }
            try? await Task.sleep(nanoseconds: 1_050_000_000)
        }

        return Array(byRel.values)
    }

    /// A file that's been listened to (tags read + fingerprinted) and is ready for
    /// the rate-limited AcoustID lookup.
    private struct ReadyTrack {
        let url: URL; let rel: String
        let artist: String; let title: String; let album: String
        let composer: String; let label: String
        let hasArt: Bool; let fp: AudioFingerprint
    }

    private func setIdentifyProgress(_ s: String) { identifyProgress = s }
    private func setListened(_ done: Int, _ total: Int) {
        identifyListened = done; identifyProgress = "Listening \(done)/\(total)…"
    }
    private func beginMatching() { identifyListening = false; identifyProgress = "Matching…" }

    private func pushFind(_ s: String, changed: Bool) {
        identifyMatched += 1
        recentFinds.insert((changed ? "✎ " : "✓ ") + s, at: 0)
        if recentFinds.count > 7 { recentFinds.removeLast() }
    }

    private func finishIdentify(proposals p: [TrackProposal], total: Int, cancelled: Bool) {
        identifying = false; identifyProgress = ""
        proposals = p.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        if !cancelled {
            didIdentify = true                       // Identify step complete → Next unlocks
            let act = p.filter { $0.isActionable }.count
            status = p.isEmpty
                ? "Identified \(total) tracks — nothing matched."
                : "Identified \(p.count) tracks — \(act) with changes so far · run Fill credits to check the rest."
            savePlan()   // preserve the network-heavy identify results
        }
    }

    // MARK: Enrich — second pass: MusicBrainz relationships (composer/label/credits)

    /// Looks up composer, lyricist, label and performer credits for the identified
    /// tracks. Slower than identify (MusicBrainz allows ~1 request/second), so it's
    /// its own pass and can be cancelled; results attach to each proposal.
    func enrich() {
        guard !proposals.isEmpty, !enriching else { return }
        enriching = true; enrichProgress = "Looking up credits…"
        recentFinds = []; enrichDone = 0
        let box = cancelFlag; box.cancelled = false
        let client = MusicBrainzClient()
        // Look up every identified track. We can't tell from the tag alone whether a
        // track is missing performers or a lyricist (those live in frames we don't
        // pre-read), so we check them all and let the gap-fill decide what to add —
        // nothing complete is ever overwritten.
        let targets = proposals.compactMap { p -> EnrichTarget? in
            guard let rid = p.recordingID else { return nil }
            return EnrichTarget(id: p.id, rid: rid,
                                title: p.newTitle.isEmpty ? p.curTitle : p.newTitle,
                                artist: p.newArtist.isEmpty ? p.curArtist : p.newArtist,
                                album: p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum)
        }
        // Group by album so ONE release lookup covers the whole album — including a
        // VARIOUS-ARTISTS compilation, whose tracks have different artists but share an
        // album. (Grouping by artist+album used to fragment a compilation into singles,
        // so it never batched and missed the album-wide credits per-album Perfect finds.)
        // The exception: a GENERIC title shared by ≥2 artists ("Greatest Hits", "Live")
        // is usually two different albums colliding, so those sub-split by artist to
        // avoid seeding one from the other's release. Tracks with no album tag stay
        // single. Order is preserved so the feed still moves top-to-bottom.
        var order: [String] = []
        var groups: [String: [EnrichTarget]] = [:]
        var albumOrder: [String] = []
        var byAlbum: [String: [EnrichTarget]] = [:]
        for (i, t) in targets.enumerated() {
            let key = t.album.isEmpty ? "single#\(i)" : "alb|" + Self.foldKey(t.album)
            if byAlbum[key] == nil { albumOrder.append(key) }
            byAlbum[key, default: []].append(t)
        }
        for key in albumOrder {
            let ts = byAlbum[key]!
            let distinctArtists = Set(ts.map { Self.foldKey($0.artist) }.filter { !$0.isEmpty })
            let albumFold = key.hasPrefix("alb|") ? String(key.dropFirst(4)) : ""
            if distinctArtists.count >= 2 && Self.genericAlbumTitles.contains(albumFold) {
                for t in ts {                                   // ambiguous generic title → keep artists apart
                    let sk = key + "|" + Self.foldKey(t.artist)
                    if groups[sk] == nil { order.append(sk) }
                    groups[sk, default: []].append(t)
                }
            } else {                                            // real album (incl. VA compilation) → one group
                order.append(key)
                groups[key] = ts
            }
        }
        let total = targets.count
        Self.creditsLog("=== Credits run: \(total) tracks in \(order.count) album-group(s) ===", reset: true)
        Task.detached(priority: .userInitiated) {
            var done = 0
            var batchCovered = 0, fellBack = 0, batchedGroups = 0
            for folder in order {
                if box.cancelled { break }
                let tracks = groups[folder] ?? []
                // A lone track isn't worth a batch (2 requests for 1); look it up
                // directly. Real albums (2+ tracks) go through one release lookup.
                let didBatch = tracks.count > 1
                let credits: MusicBrainzClient.AlbumCredits
                if let seed = tracks.first, didBatch {
                    credits = await client.albumCredits(seedRecordingID: seed.rid, albumTitle: seed.album, groupSize: tracks.count)
                    batchedGroups += 1
                } else {
                    credits = MusicBrainzClient.AlbumCredits()
                }
                var covered = 0, missed = 0
                for t in tracks {
                    if box.cancelled { break }
                    // matched by recording id, else by title, else a per-track lookup
                    var e: Enrichment
                    if let hit = credits.byRecording[t.rid] { e = hit; covered += 1 }
                    else if let hit = credits.byTitle[Self.foldKey(t.title)] { e = hit; covered += 1 }
                    else if didBatch {
                        // missed the album batch, but borrow the album's label/date/
                        // artwork and pay only a single recording lookup (not three)
                        e = await client.recordingOnly(recordingID: t.rid)
                        if e.label == nil { e.label = credits.label; e.catalogNumber = credits.catalog }
                        if e.date == nil { e.date = credits.date }
                        if e.releaseMBID == nil { e.releaseMBID = credits.releaseMBID }
                        missed += 1
                    } else {
                        e = await client.enrich(recordingID: t.rid); missed += 1
                    }
                    await self.attachEnrichment(t.id, e)
                    done += 1
                    await self.pushEnrich(t.id, e, done: done, total: total)
                }
                batchCovered += covered; fellBack += missed
                let batchInfo = didBatch ? "batch covered \(covered)/\(tracks.count), \(missed) fell back" : "single (per-track)"
                Self.creditsLog("group '\(folder)' size=\(tracks.count): \(batchInfo)")
            }
            let s = await client.stats()
            Self.creditsLog("--- TOTAL: \(order.count) groups, \(batchedGroups) batched · tracks \(done) (batch-covered \(batchCovered), per-track \(fellBack)) · MusicBrainz requests=\(s.mb), Discogs=\(s.discogs) ---")
            await self.finishEnrich(cancelled: box.cancelled)
        }
    }

    /// Append a line to ~/musicdeduper-credits.log (reset truncates it). Lets us
    /// see whether album-batching is actually engaging on a real library.
    nonisolated static func creditsLog(_ line: String, reset: Bool = false) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("musicdeduper-credits.log")
        if reset {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } else if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = (line + "\n").data(using: .utf8) { h.write(d) }
            try? h.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private struct EnrichTarget { let id: UUID; let rid: String; let title: String; let artist: String; let album: String }
    private nonisolated static func foldKey(_ s: String) -> String { TrackProposal.typoFold(s).lowercased() }

    private func setEnrichProgress(_ s: String) { enrichProgress = s }

    /// Advance the live credits counter/feed as each track is looked up.
    private func pushEnrich(_ id: UUID, _ e: Enrichment, done: Int, total: Int) {
        enrichDone = done
        enrichProgress = "Credits \(done)/\(total)…"
        // lead with artist · album · title so the log line says WHICH track it is
        let p = proposals.first(where: { $0.id == id })
        let artist = p.map { $0.newArtist.isEmpty ? $0.curArtist : $0.newArtist } ?? ""
        let album  = p.map { $0.chosenAlbum.isEmpty ? $0.curAlbum : $0.chosenAlbum } ?? ""
        let title  = p.map { $0.newTitle.isEmpty ? $0.curTitle : $0.newTitle } ?? "track"
        let head = [artist, album, title].filter { !$0.isEmpty }.joined(separator: " · ")
        var bits: [String] = []
        if e.composer != nil { bits.append("composer") }
        if e.lyricist != nil { bits.append("lyricist") }
        if e.label != nil { bits.append("label") }
        if !e.performers.isEmpty { bits.append("\(e.performers.count) performer\(e.performers.count == 1 ? "" : "s")") }
        if e.releaseMBID != nil { bits.append("cover source") }   // a release for the Artwork step to pull from — not fetched here
        let found = bits.isEmpty ? "nothing new" : "+ " + bits.joined(separator: ", ")
        recentFinds.insert((bits.isEmpty ? "✓ " : "✎ ") + "\(head) — \(found)", at: 0)
        if recentFinds.count > 7 { recentFinds.removeLast() }
    }

    private func attachEnrichment(_ id: UUID, _ e: Enrichment) {
        if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].enrichment = e }
    }

    private func finishEnrich(cancelled: Bool) {
        enriching = false; enrichProgress = ""; enriched = true
        let filled = proposals.filter { !($0.enrichment?.isEmpty ?? true) }.count
        if !cancelled { status = "Looked up credits — \(filled) track(s) enriched." }
        savePlan()   // preserve the credit lookups + stage progress
    }

    // MARK: Organise (rebuild the clean tree from tags)

    /// Build the placement plan — read each track's tags (overlaying any accepted
    /// identify/credits corrections that aren't written to disk yet) and ask
    /// Organiser where each file should live. Preview only; nothing moves.
    func organise() {
        guard let root else { return }
        organising = true; organiseProgress = "Reading tags…"; status = "Planning the clean tree…"
        // in-memory corrections not yet on disk, keyed by root-relative path
        let corrections: [String: (artist: String, album: String, title: String)] =
            Dictionary(proposals.filter { $0.accepted }.map { p in
                (p.relPath, (p.newArtist.isEmpty ? p.curArtist : p.newArtist,
                             p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum,
                             p.newTitle.isEmpty ? p.curTitle : p.newTitle))
            }, uniquingKeysWith: { a, _ in a })
        let composerFirst = composerFirstClassical
        let renumber = renumberTracks
        let comps = confirmedCompilations
        let declinedMerges = declinedAlbumMerges
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var inputs: [OrganiseInput] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in en {
                    guard Self.isAudio(url) else { continue }
                    let rel = Self.rel(url, root)
                    if rel.hasPrefix("Music Librarian Quarantine") { continue }
                    let c = corrections[rel]
                    var artist = c?.artist ?? (Self.readField(url, "artist") ?? "")
                    var album  = c?.album  ?? (Self.readField(url, "album")  ?? "")
                    let title  = c?.title  ?? (Self.readField(url, "title")  ?? "")
                    let aa     = Self.readField(url, "albumartist") ?? ""
                    let track  = Int((Self.readField(url, "track") ?? "").prefix(while: { $0.isNumber })) ?? 0
                    let disc   = Int((Self.readField(url, "disc")  ?? "").prefix(while: { $0.isNumber })) ?? 0
                    let composer = Self.readField(url, "composer") ?? ""
                    // tagless file (DRM etc.) → recover artist/album from the folder path
                    if (artist.isEmpty || album.isEmpty), let inf = Self.pathAlbumArtist(rel) {
                        if artist.isEmpty { artist = inf.artist }
                        if album.isEmpty { album = inf.album }
                    }
                    let comp = (Self.readField(url, "compilation") ?? "").hasPrefix("1")
                    inputs.append(OrganiseInput(rel: rel, ext: url.pathExtension.lowercased(),
                        artist: artist, albumArtist: aa, album: album, title: title,
                        trackNo: track, discNo: disc, isClassical: false, composer: composer,
                        isCompilation: comp))
                }
            }
            let mergeCands = Organiser.albumMergeCandidates(inputs)
            // default every detected edition-merge ON, minus the ones the user declined
            let merges = Set(mergeCands.map { $0.key }).subtracting(declinedMerges)
            let plans = Organiser.plan(inputs, composerFirstForClassical: composerFirst, renumber: renumber,
                                       compilations: comps, mergeAlbums: merges)
            let candidates = Self.compilationCandidates(from: inputs)
            await self.finishOrganise(plans, candidates: candidates, mergeCands: mergeCands)
        }
    }

    /// Last-resort artist/album from the folder path (…/Artist/Album/Track) for files
    /// with NO readable tags — e.g. DRM .m4p, whose tags TagLib can't read but which
    /// can still be MOVED. Returns nil for shallow paths or a known junk top folder.
    nonisolated static func pathAlbumArtist(_ rel: String) -> (artist: String, album: String)? {
        let comps = rel.split(separator: "/").map(String.init)
        guard comps.count >= 3 else { return nil }                 // need Artist/Album/File
        let album = comps[comps.count - 2], artist = comps[comps.count - 3]
        let junk: Set<String> = ["apple music", "downloads", "music", "itunes", "media"]
        if junk.contains(artist.lowercased()) || album.isEmpty || artist.isEmpty { return nil }
        return (artist, album)
    }

    /// Build organise inputs by reading the tags ON DISK (no in-memory overlay) —
    /// used by the final Apply, which re-plans the tree AFTER the tag/dedup writes
    /// so placement reflects the final state. Nonisolated → runs in the commit task.
    nonisolated static func organiseInputsFromDisk(root: URL, fm: FileManager) -> [OrganiseInput] {
        var inputs: [OrganiseInput] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return inputs }
        for case let url as URL in en {
            guard isAudio(url) else { continue }
            let rel = self.rel(url, root)
            if rel.hasPrefix("Music Librarian Quarantine") { continue }
            let track = Int((readField(url, "track") ?? "").prefix(while: { $0.isNumber })) ?? 0
            let disc  = Int((readField(url, "disc")  ?? "").prefix(while: { $0.isNumber })) ?? 0
            var artist = readField(url, "artist") ?? "", album = readField(url, "album") ?? ""
            // tagless file (DRM etc.) → recover artist/album from the folder structure
            if (artist.isEmpty || album.isEmpty), let inf = pathAlbumArtist(rel) {
                if artist.isEmpty { artist = inf.artist }
                if album.isEmpty { album = inf.album }
            }
            inputs.append(OrganiseInput(rel: rel, ext: url.pathExtension.lowercased(),
                artist: artist, albumArtist: readField(url, "albumartist") ?? "",
                album: album, title: readField(url, "title") ?? "",
                trackNo: track, discNo: disc, isClassical: false, composer: readField(url, "composer") ?? "",
                isCompilation: (readField(url, "compilation") ?? "").hasPrefix("1")))
        }
        return inputs
    }

    /// Rename a proposed folder (and cascade to everything under it). `oldPath` is the
    /// full proposed folder path; only the last component is replaced with `newName`.
    func renameOrganiseFolder(_ oldPath: String, to newName: String) {
        let clean = Organiser.safe(newName)
        guard !clean.isEmpty, clean != (oldPath as NSString).lastPathComponent else { return }
        let parent = (oldPath as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? clean : parent + "/" + clean
        for i in organisePlans.indices {
            guard let t = organisePlans[i].targetRel else { continue }
            if t == oldPath || t.hasPrefix(oldPath + "/") {
                organisePlans[i].targetRel = newPath + String(t.dropFirst(oldPath.count))
            }
        }
    }

    /// Rename a single proposed file (keeps its folder).
    func renameOrganiseFile(planID: String, to newName: String) {
        let clean = Organiser.safe(newName)
        guard !clean.isEmpty, let i = organisePlans.firstIndex(where: { $0.id == planID }),
              let t = organisePlans[i].targetRel else { return }
        let dir = (t as NSString).deletingLastPathComponent
        organisePlans[i].targetRel = dir.isEmpty ? clean : dir + "/" + clean
    }

    private func finishOrganise(_ plans: [OrganisePlan], candidates: [CompilationCandidate] = [],
                                mergeCands: [Organiser.MergeGroup] = []) {
        organising = false; organiseProgress = ""; organised = true; organisePlans = plans
        compilationCandidates = candidates
        albumMergeCandidates = mergeCands
        // auto-confirm flagged compilations so they're filed under Various Artists
        for c in candidates where c.flagged { confirmedCompilations.insert(c.id) }
        let moves = plans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }.count
        let flagged = plans.filter { $0.targetRel == nil }.count
        status = "Clean tree planned — \(moves) file(s) to reorganise, \(flagged) flagged."
        if pendingReorganiseApply {          // reorganiseStragglers(): re-planned, now apply the moves
            pendingReorganiseApply = false
            if moves > 0 { applyOrganise() } else { organiseStale = false }
        }
    }

    /// Apply the organise plan: write the guaranteed tags, then move each file to
    /// its clean path. Recorded to run.json (ops + tagEdits) so Undo reverses it.
    func applyOrganise() {
        guard let root else { return }
        let plans = organisePlans.filter { $0.targetRel != nil && $0.targetRel != $0.rel }
        guard !plans.isEmpty else { return }
        busy = true; committing = true; commitPhase = "Reorganising files…"; commitDone = 0
        commitTotal = plans.count; cancelRequested = false
        let box = cancelFlag; box.cancelled = false
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []
            var tagEdits: [(rel: String, field: String, old: String)] = []
            var log = "Music Librarian — organise \(Date())\nLibrary: \(root.path)\n\n"
            var done = 0
            for p in plans {
                if box.cancelled { break }
                guard let target = p.targetRel else { continue }
                let src = root.appendingPathComponent(p.rel)
                guard fm.fileExists(atPath: src.path) else { continue }
                // guaranteed tags (track#, album-artist) — write while at the source
                for (field, value) in p.tagWrites {
                    let old = Self.readField(src, field) ?? ""
                    if old == value { continue }
                    do { try Self.writeField(src, field, to: value)
                         tagEdits.append((p.rel, field, old))
                         log += "TAG: \(p.rel)  \(field) '\(old)' → '\(value)'\n"
                    } catch { log += "FAILED tag \(p.rel) \(field): \(error.localizedDescription)\n" }
                }
                // move to the clean path (never overwrite an existing target)
                let dst = root.appendingPathComponent(target)
                if fm.fileExists(atPath: dst.path) {
                    log += "SKIP (target exists): \(target)\n"
                } else {
                    do {
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: src, to: dst)
                        ops.append((p.rel, target))
                        log += "MOVED: \(p.rel) → \(target)\n"
                    } catch { log += "FAILED move \(p.rel): \(error.localizedDescription)\n" }
                }
                done += 1
                if done % 5 == 0 { await self.setCommitProgress("Reorganising files", done: done) }
            }
            // prune the source folders the moves emptied (e.g. the old "AC_DC" and its
            // "Unknown Album" once their tracks moved into "AC-DC/High Voltage"). Only
            // genuinely-empty dirs (ignoring .DS_Store) are removed; undo re-creates
            // them when it restores the files, so this stays reversible.
            var checkDirs = Set<String>()
            for op in ops {
                var cur = (op.from as NSString).deletingLastPathComponent
                while !cur.isEmpty && cur != "." {
                    checkDirs.insert(cur)
                    cur = (cur as NSString).deletingLastPathComponent
                }
            }
            for rel in checkDirs.sorted(by: { $0.count > $1.count }) {   // deepest first
                if rel.hasPrefix("Music Librarian Quarantine") { continue }
                let dir = root.appendingPathComponent(rel)
                guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                if contents.allSatisfy({ $0 == ".DS_Store" }) {
                    for junk in contents { try? fm.removeItem(at: dir.appendingPathComponent(junk)) }
                    if (try? fm.removeItem(at: dir)) != nil { log += "REMOVED empty folder: \(rel)\n" }
                }
            }
            let total = ops.count + tagEdits.count
            log += "\n\(total) change(s)\(box.cancelled ? " (stopped early)" : "").\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "Reorganised \(ops.count) file(s)",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
                "perfEdits": [], "artEdits": [], "artPromotions": [], "artReplacements": [],
            ]
            if total > 0, let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            } else { try? fm.removeItem(at: quarantine) }
            await self.finishOrganiseApply(quarantine: quarantine, moves: ops)
        }
    }

    private func finishOrganiseApply(quarantine: URL, moves: [(from: String, to: String)]) {
        busy = false; committing = false; cancelRequested = false
        commitPhase = ""; commitDone = 0; commitTotal = 0
        lastQuarantine = quarantine
        // the files moved — repoint the in-memory proposals to their new paths so the
        // grid regroups by the clean albums and the player keeps working.
        if let root, !moves.isEmpty {
            let map = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
            for i in proposals.indices {
                if let to = map[proposals[i].relPath] {
                    proposals[i].relPath = to
                    proposals[i].url = root.appendingPathComponent(to)
                }
            }
        }
        organisePlans.removeAll(); organised = false
        organiseStageDone = true; organiseStale = false
        lastRunSummary = "Reorganised \(moves.count) file(s)."
        status = lastRunSummary ?? status
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()   // paths changed → drop stale thumbnails
        loadRuns()
    }

    // MARK: Deduplicate (folded in from the old wizard, with merge-of-best)

    /// Scan the library, read tags, and cluster duplicates (best copy = keeper).
    func dedup() {
        guard let root else { return }
        deduping = true; status = "Finding duplicates…"; dedupClusters = []; dedupTracks = []
        let mode = MatchMode.balanced, tol = 2.0, cross = false
        Task.detached(priority: .userInitiated) {
            var mutable = await Self.buildTracksFromDisk(root: root, fm: FileManager.default)
            let cl = buildClusters(&mutable, mode: mode, tol: tol, crossAlbum: cross) { s in
                Task { await self.setDedupStatus(s) }
            }
            await self.finishDedup(tracks: mutable, clusters: cl)
        }
    }

    /// Read every audio file under `root` (skipping quarantine) into Track records with
    /// their current on-disk tags. Shared by the Duplicates preview and the Apply-time
    /// re-detection, so both see exactly the same data.
    nonisolated static func buildTracksFromDisk(root: URL, fm: FileManager) async -> [Track] {
        var urls: [URL] = []
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                  options: [.skipsHiddenFiles]) {
            while let obj = en.nextObject() {
                guard let u = obj as? URL, isAudio(u) else { continue }
                if rel(u, root).hasPrefix("Music Librarian Quarantine") { continue }
                urls.append(u)
            }
        }
        var built: [Track] = []
        for u in urls {
            let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let m = await readMetadata(url: u, size: size)
            let r = rel(u, root)
            built.append(Track(id: built.count, url: u, name: u.lastPathComponent,
                relDir: (r as NSString).deletingLastPathComponent, size: size, ext: m.ext,
                title: m.title, artist: m.artist, album: m.album, albumArtist: m.albumArtist,
                trackNo: m.trackNo, discNo: m.discNo, duration: m.duration,
                lossless: m.lossless, bitrate: m.bitrate, codec: m.codec))
        }
        return built
    }

    private func setDedupStatus(_ s: String) { status = s }

    private func finishDedup(tracks: [Track], clusters: [Cluster]) {
        deduping = false; deduped = true; dedupTracks = tracks; dedupClusters = clusters
        let dupes = clusters.reduce(0) { $0 + $1.memberIDs.count - 1 }
        status = "Found \(clusters.count) duplicate group(s) — \(dupes) file(s) can be removed."
    }

    func setDedupKeeper(clusterID: UUID, trackID: Int) {
        guard let i = dedupClusters.firstIndex(where: { $0.id == clusterID }) else { return }
        dedupClusters[i].keeperID = trackID
    }
    func dedupTrack(_ id: Int) -> Track? { dedupTracks.first { $0.id == id } }
    var dedupRemovableCount: Int { dedupClusters.reduce(0) { $0 + $1.memberIDs.count - 1 } }

    /// Apply dedup with MERGE-OF-BEST: the keeper (best-quality copy) inherits any
    /// blank tags and missing cover art from its duplicates, then the duplicates go
    /// to the shared quarantine. Recorded to run.json (ops + tagEdits + artEdits) so
    /// Undo puts the files back and reverses the backfill.
    func applyDedup() {
        guard let root, !dedupClusters.isEmpty else { return }
        busy = true; committing = true; commitPhase = "Merging & removing duplicates…"; commitDone = 0
        commitTotal = dedupClusters.reduce(0) { $0 + $1.memberIDs.count }
        cancelRequested = false; let box = cancelFlag; box.cancelled = false
        let byId = Dictionary(dedupTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        struct DJob { let keeper: URL; let keeperRel: String; let losers: [(url: URL, rel: String)] }
        var jobs: [DJob] = []
        for c in dedupClusters {
            guard let k = byId[c.keeperID] else { continue }
            let losers = c.memberIDs.filter { $0 != c.keeperID }.compactMap { byId[$0] }
                .map { (url: $0.url, rel: Self.rel($0.url, root)) }
            jobs.append(DJob(keeper: k.url, keeperRel: Self.rel(k.url, root), losers: losers))
        }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []
            var tagEdits: [(rel: String, field: String, old: String)] = []
            var artEdits: [String] = []
            var log = "Music Librarian — dedup \(Date())\nLibrary: \(root.path)\n\n"
            var done = 0
            let backfill = ["title", "artist", "album", "albumartist", "composer", "lyricist", "label", "conductor", "date", "track", "disc"]
            for job in jobs {
                if box.cancelled { break }
                // merge-of-best: fill each of the keeper's BLANK fields from a loser
                for field in backfill where (Self.readField(job.keeper, field) ?? "").isEmpty {
                    for l in job.losers {
                        let v = Self.readField(l.url, field) ?? ""
                        if !v.isEmpty {
                            do { try Self.writeField(job.keeper, field, to: v)
                                 tagEdits.append((job.keeperRel, field, ""))
                                 log += "MERGE: \(job.keeperRel)  + \(field) '\(v)' (from a duplicate)\n"
                            } catch {}
                            break
                        }
                    }
                }
                // art backfill: if the keeper has none, take a duplicate's cover
                if md_has_artwork(job.keeper.path) == 0 {
                    for l in job.losers {
                        var len: Int32 = 0, ty: Int32 = 0
                        if let b = md_copy_artwork(l.url.path, &len, &ty) {
                            let d = Data(bytes: b, count: Int(len)); free(b)
                            let mime = d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                            let rc = d.withUnsafeBytes { buf in
                                md_set_artwork(job.keeper.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(d.count), mime)
                            }
                            if rc == 0 { artEdits.append(job.keeperRel); log += "MERGE: \(job.keeperRel)  + cover (from a duplicate)\n" }
                            break
                        }
                    }
                }
                done += 1
                // move the duplicates to quarantine
                for l in job.losers {
                    if box.cancelled { break }
                    let src = root.appendingPathComponent(l.rel)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let toRel = qRel + "/" + l.rel
                    let dst = root.appendingPathComponent(toRel)
                    do {
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: src, to: dst)
                        ops.append((l.rel, toRel))
                        log += "DUPLICATE → quarantine: \(l.rel)\n"
                    } catch { log += "FAILED \(l.rel): \(error.localizedDescription)\n" }
                    done += 1
                    if done % 5 == 0 { await self.setCommitProgress("Merging & removing duplicates", done: done) }
                }
            }
            let total = ops.count + tagEdits.count + artEdits.count
            log += "\n\(total) change(s)\(box.cancelled ? " (stopped early)" : "").\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "Removed \(ops.count) duplicate(s)",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
                "perfEdits": [], "artEdits": artEdits, "artPromotions": [], "artReplacements": [],
            ]
            if total > 0, let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            } else { try? fm.removeItem(at: quarantine) }
            await self.finishDedupApply(quarantine: quarantine, removedRels: ops.map { $0.from })
        }
    }

    private func finishDedupApply(quarantine: URL, removedRels: [String]) {
        busy = false; committing = false; cancelRequested = false
        commitPhase = ""; commitDone = 0; commitTotal = 0
        lastQuarantine = quarantine
        // the removed duplicates are gone — drop their now-dangling proposals so the
        // grid and player don't point at quarantined files.
        let gone = Set(removedRels)
        proposals.removeAll { gone.contains($0.relPath) }
        dedupClusters.removeAll(); dedupTracks.removeAll(); deduped = false
        dedupStageDone = true
        lastRunSummary = "Removed \(removedRels.count) duplicate(s)."
        status = lastRunSummary ?? status
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()   // keeper art may have changed → drop stale thumbnails
        loadRuns()
    }

    func commit() {
        guard let root, hasWork else { return }
        busy = true; status = "Applying changes…"
        committing = true; commitPhase = "Preparing…"; commitDone = 0; cancelRequested = false
        let box = cancelFlag; box.cancelled = false
        let removals = findings.filter { $0.accepted && $0.kind.safe }.map { ($0.relPath, $0.kind.rawValue) }
        // folder merges from accepted artists that have a folder split
        let accMerges = artists.filter { $0.accepted && $0.folderMerges > 0 }
            .map { ($0.canonical, $0.folderSources) }
        let accRenames = renames.filter { $0.accepted && $0.newName != $0.oldName }
            .map { ($0.relPath, $0.newName) }
        // tag rewrites: (file, relPath, field, oldValue, newValue). Two sources —
        // the artist-split fixer (field "artist") and identify (artist/title/album).
        var accTagEdits: [(URL, String, String, String, String)] = tagWritingEnabled ? artists
            .filter { $0.accepted && $0.tagRewrites > 0 }
            .flatMap { a in a.tagMembers.filter { $0.oldName != a.canonical }
                .map { ($0.url, $0.relPath, "artist", $0.oldName, a.canonical) } } : []
        // identify proposals — each changed field becomes its own reversible edit
        if tagWritingEnabled && applyNames {
            for p in proposals where p.accepted && p.hasChange {
                if p.artistChanged && nameKindEnabled(p.artistChangeKind) { accTagEdits.append((p.url, p.relPath, "artist", p.curArtist, p.newArtist)) }
                if p.titleChanged  && nameKindEnabled(p.titleChangeKind)  { accTagEdits.append((p.url, p.relPath, "title",  p.curTitle,  p.newTitle)) }
                if p.albumChanged  && nameKindEnabled(p.albumChangeKind)  { accTagEdits.append((p.url, p.relPath, "album",  p.curAlbum,  p.chosenAlbum)) }
            }
        }
        // enrichment gap-fills (composer/label/date) — candidate values; only
        // written where the file's field is actually blank (checked at apply time)
        let accEnrich: [(URL, String, [(String, String)])] = (tagWritingEnabled && applyCredits) ? proposals
            .filter { $0.accepted }
            .compactMap { p in
                guard let e = p.enrichment, !e.isEmpty else { return nil }
                var fields: [(String, String)] = []
                if let c = e.composer { fields.append(("composer", c)) }
                if let ly = e.lyricist { fields.append(("lyricist", ly)) }
                if let l = e.label { fields.append(("label", l)) }
                if let d = e.date { fields.append(("date", d)) }
                return fields.isEmpty ? nil : (p.url, p.relPath, fields)
            } : []
        // performer credits from enrichment — added to the credits list, reversibly
        let accPerf: [(URL, String, [(String, String)])] = (tagWritingEnabled && applyCredits) ? proposals
            .filter { $0.accepted }
            .compactMap { p in
                guard let e = p.enrichment, !e.performers.isEmpty else { return nil }
                return (p.url, p.relPath, e.performers.map { ($0.name, $0.role) })
            } : []
        // cover art — grouped PER ALBUM so one image is resolved once and applied to
        // every track in it (kills the per-track patchwork and the duplicate fetches).
        // The album's release MBIDs are pooled for the lookup; empty-album tracks each
        // form their own group.
        var artJobs: [String: AlbumArtJob] = [:]
        if tagWritingEnabled && applyArtwork {
            for p in proposals where p.accepted {
                // group by the disc-stripped album so both discs of a set share one cover
                let album = Organiser.stripDiscSuffix(p.chosenAlbum.isEmpty ? p.curAlbum : p.chosenAlbum).clean
                // compilations collapse to Various Artists so one cover covers all tracks
                let artist = artArtistFor(album: album, artist: p.newArtist.isEmpty ? p.curArtist : p.newArtist)
                let key = Self.foldKey(artist) + "|" + (album.isEmpty ? "single:" + p.relPath : Self.foldKey(album))
                var job = artJobs[key] ?? AlbumArtJob(artist: artist, album: album, mbids: [], files: [])
                if let m = p.enrichment?.releaseMBID, !job.mbids.contains(m) { job.mbids.append(m) }
                job.files.append((p.url, p.relPath))
                artJobs[key] = job
            }
        }
        let albumArt = Array(artJobs.values)
        // cover choices from the Artwork step → apply each chosen image to its
        // album's files in THIS run (so all picked covers land in one apply, not
        // one run per Accept). Files come from the proposals sharing the album key.
        let artChoices = ArtworkChoices.shared.byKey
        let chosenKeys = Set(artChoices.keys)
        let artChoiceJobs: [(image: Data, files: [(URL, String)])] = artChoices.compactMap { (k, img) in
            let files = proposals.filter {
                self.artKey(artist: $0.newArtist.isEmpty ? $0.curArtist : $0.newArtist,
                            album: $0.chosenAlbum.isEmpty ? $0.curAlbum : $0.chosenAlbum) == k
            }.map { ($0.url, $0.relPath) }
            return files.isEmpty ? nil : (img, files)
        }
        // rough total for the progress bar (art files counted; merges/renames add a little)
        // DEFERRED duplicate plan — keeper + losers per cluster, applied in THIS run
        // (instead of a separate immediate apply). Files come from the dedup scan.
        struct DedupJob: Sendable { let keeper: URL; let keeperRel: String; let losers: [DLoser] }
        struct DLoser: Sendable { let url: URL; let rel: String }
        // Duplicates are RE-DETECTED at commit from the final on-disk tags (below),
        // not taken from the Duplicates-step snapshot — so album fixes made in Identify
        // or Review are in effect when we decide what's a duplicate. The snapshot count
        // is only used to size the progress bar.
        let doDedup = deduped
        let dedupEstimate = dedupClusters.reduce(0) { $0 + max($1.memberIDs.count - 1, 0) }
        // DEFERRED organise — rebuild the clean tree at the end of this run, on the
        // final tags (so late-accepted album fixes land in the right folder).
        let doOrganise = organised
        let composerFirstOrg = composerFirstClassical
        let renumberOrg = renumberTracks
        let compsOrg = confirmedCompilations
        let declinedMergesOrg = declinedAlbumMerges
        let checkMissing = checkMissingTracks
        commitTotal = accTagEdits.count
            + accEnrich.reduce(0) { $0 + $1.2.count }
            + accPerf.reduce(0) { $0 + $1.2.count }
            + albumArt.reduce(0) { $0 + $1.files.count }
            + removals.count + accRenames.count + accMerges.count
            + dedupEstimate
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var done = 0
            @Sendable func bump(_ phase: String) async {
                done += 1
                if done % 5 == 0 { await self.setCommitProgress(phase, done: done) }
            }
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var ops: [(from: String, to: String)] = []   // recorded moves (root-relative)
            var tagEdits: [(rel: String, field: String, old: String)] = []  // recorded tag rewrites
            var perfEdits: [(rel: String, name: String, role: String)] = []  // recorded performer credits
            var artEdits: [String] = []                                      // rels where art was added
            var artPromotions: [(rel: String, oldType: Int)] = []            // rels whose art was retagged to front
            var artReplacements: [(rel: String, backup: String, oldType: Int)] = []  // covers replaced by a user choice (old art backed up)
            var flaggedArt: [(artist: String, album: String, files: [String], mbids: [String])] = []  // mixed albums with no cover found
            var log = "Music Librarian — change log \(Date())\nLibrary: \(root.path)\n\n"

            func move(_ fromRel: String, _ toRel: String) -> Bool {
                let from = root.appendingPathComponent(fromRel), to = root.appendingPathComponent(toRel)
                guard fm.fileExists(atPath: from.path) else { return false }
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: from, to: to)
                    ops.append((fromRel, toRel))
                    return true
                } catch { log += "FAILED \(fromRel): \(error.localizedDescription)\n"; return false }
            }

            // 0) tag rewrites — done first, while the files are still at their
            //    original locations (before any merge/rename moves them). Record
            //    the original path + field + old value so undo is exact.
            for (url, rel, field, old, new) in accTagEdits {
                if box.cancelled { break }
                do {
                    try Self.writeField(url, field, to: new)
                    tagEdits.append((rel, field, old))
                    log += "TAG: \(rel)  \(field) '\(old)' → '\(new)'\n"
                } catch { log += "FAILED tag \(rel) \(field): \(error.localizedDescription)\n" }
                await bump("Writing names & tags")
            }

            // 0a2) STUFFED ARTIST TAGS → primary artist + performer credits (Roon shape),
            //      applied here BEFORE organise so each track files under its clean primary
            //      artist. Same detector per-album Perfect uses; only the CONFIDENT cases
            //      (machine-joined "A,B" or "A feat. B") auto-apply — ambiguous spaced lists
            //      that could be a band name are logged for review, not changed. Reversible
            //      (artist tagEdit + performer perfEdit). m4p can't be written, so skipped.
            if !box.cancelled, let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = en.nextObject() as? URL {
                    if box.cancelled { break }
                    guard Self.isAudio(u), u.pathExtension.lowercased() != "m4p",
                          !u.path.contains("Music Librarian Quarantine"),
                          let cur = Self.readField(u, "artist"),
                          let split = TrackProposal.splitArtistCredit(cur), split.primary != cur else { continue }
                    let rel = Self.rel(u, root)
                    guard split.confident else {
                        log += "ARTIST LIST (left for review — open in the Album Inspector): \(rel): \(cur)\n"; continue
                    }
                    do {
                        try Self.writeField(u, "artist", to: split.primary)
                        tagEdits.append((rel, "artist", cur))
                        log += "ARTIST SPLIT: \(rel): \(cur) → \(split.primary) + \(split.performers.joined(separator: ", "))\n"
                    } catch { log += "FAILED artist split \(rel): \(error.localizedDescription)\n"; continue }
                    for name in split.performers where md_has_performer(u.path, name, "performer") == 0 {
                        do { try Self.addPerformer(u, name: name, role: "performer"); perfEdits.append((rel, name, "performer")) }
                        catch {}
                    }
                    await bump("Tidying artist credits")
                }
            }

            // 0a3) DISC ORDER — a multi-disc set flattened into one folder with no disc
            //      tags interleaves track numbers (1,1,2,2,…). Assign disc numbers by
            //      occurrence (ordered by file name) BEFORE organise, so it files them as
            //      a proper multi-disc album. Same detector per-album Perfect uses.
            if !box.cancelled {
                func leadInt(_ s: String?) -> Int { Int((s ?? "").split(separator: "/").first.map(String.init) ?? "") ?? 0 }
                var byFolder: [String: [(url: URL, track: Int, disc: Int)]] = [:]
                if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    while let u = en.nextObject() as? URL {
                        if box.cancelled { break }
                        guard Self.isAudio(u), !u.path.contains("Music Librarian Quarantine") else { continue }
                        let tn = leadInt(Self.readField(u, "track"))
                        guard tn > 0 else { continue }
                        byFolder[u.deletingLastPathComponent().path, default: []].append((u, tn, leadInt(Self.readField(u, "disc"))))
                    }
                }
                for (_, items) in byFolder {
                    if box.cancelled { break }
                    let dup = Dictionary(grouping: items, by: { $0.disc * 1000 + $0.track }).contains { $0.value.count > 1 }
                    guard dup else { continue }
                    var seen: [Int: Int] = [:]
                    for it in items.sorted(by: { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }) {
                        let key = it.disc * 1000 + it.track
                        let newDisc = (seen[key] ?? 0) + 1
                        seen[key] = newDisc
                        guard it.disc != newDisc else { continue }
                        let rel = Self.rel(it.url, root)
                        do {
                            try Self.writeField(it.url, "disc", to: String(newDisc))
                            tagEdits.append((rel, "disc", it.disc == 0 ? "" : String(it.disc)))
                            log += "DISC: \(rel)  track \(it.track) → disc \(newDisc)\n"
                        } catch { log += "FAILED disc \(rel): \(error.localizedDescription)\n" }
                        await bump("Assigning disc numbers")
                    }
                }
            }

            // 0b) enrichment gap-fills — only fill a field that is actually BLANK,
            //     never overwrite. Record old = "" so undo clears it again.
            for (url, rel, fields) in accEnrich {
                if box.cancelled { break }
                for (field, value) in fields where (Self.readField(url, field) ?? "").isEmpty {
                    do {
                        try Self.writeField(url, field, to: value)
                        tagEdits.append((rel, field, ""))
                        log += "TAG: \(rel)  + \(field) '\(value)' (was blank)\n"
                    } catch { log += "FAILED enrich \(rel) \(field): \(error.localizedDescription)\n" }
                    await bump("Filling in credits")
                }
            }

            // 0c) performer credits — added to the musician-credits list, recorded
            //     so undo removes exactly what was added.
            for (url, rel, people) in accPerf {
                if box.cancelled { break }
                for (name, role) in people {
                    do {
                        try Self.addPerformer(url, name: name, role: role)
                        perfEdits.append((rel, name, role))
                        log += "CREDIT: \(rel)  + \(name) (\(role))\n"
                    } catch { log += "FAILED credit \(rel): \(error.localizedDescription)\n" }
                    await bump("Adding performer credits")
                }
            }

            // 0d) cover art — UNIFY WHEN MIXED. First promote any non-front art to a
            //     Front Cover (non-destructive retag). Then, per album: if the tracks
            //     already share one cover, leave it. If they're mixed or have gaps,
            //     put the album's real cover (iTunes / Cover Art Archive) on every
            //     track — backing up each replaced image so it's fully reversible. If
            //     no cover can be found for a mixed album, flag it for manual review.
            let artClient = CoverArtClient()
            // cheap image fingerprint: byte count + a checksum of the first 64 bytes
            func artFingerprint(_ url: URL) -> String? {
                var len: Int32 = 0, type: Int32 = 0
                guard let buf = md_copy_artwork(url.path, &len, &type) else { return nil }
                let d = Data(bytes: buf, count: Int(len)); free(buf)
                return "\(len):" + String(d.prefix(64).reduce(UInt64(0)) { $0 &+ UInt64($1) })
            }

            // (0) COVER CHOICES from the Artwork step — put each picked image on all
            //     its album's tracks, backing up any existing art so it's reversible.
            if !artChoiceJobs.isEmpty {
                let artBackupDir = quarantine.appendingPathComponent("artwork-backups", isDirectory: true)
                var bIdx = 0
                for cj in artChoiceJobs {
                    if box.cancelled { break }
                    let mime = cj.image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                    for (url, rel) in cj.files {
                        if box.cancelled { break }
                        await bump("Setting chosen cover art")
                        if md_has_artwork(url.path) == 1 {
                            var bl: Int32 = 0, bt: Int32 = 0
                            if let bbuf = md_copy_artwork(url.path, &bl, &bt) {
                                let bdata = Data(bytes: bbuf, count: Int(bl)); free(bbuf)
                                try? fm.createDirectory(at: artBackupDir, withIntermediateDirectories: true)
                                let name = "\(bIdx).img"; bIdx += 1
                                try? bdata.write(to: artBackupDir.appendingPathComponent(name))
                                artReplacements.append((rel, "artwork-backups/" + name, Int(bt)))
                            }
                        } else {
                            artEdits.append(rel)   // was blank → undo just strips it
                        }
                        let rc = cj.image.withUnsafeBytes { buf in
                            md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(cj.image.count), mime)
                        }
                        log += rc == 0 ? "ART: \(rel)  ← chosen cover (\(cj.image.count) bytes)\n" : "FAILED art \(rel): rc \(rc)\n"
                    }
                }
            }

            for job in albumArt {
                if box.cancelled { break }
                // an album the user picked a cover for is already done above — skip it
                if chosenKeys.contains(ArtworkChoices.key(artist: job.artist, album: job.album)) { continue }
                // (i) promote non-front art to front cover
                for (url, rel) in job.files {
                    if md_has_artwork(url.path) == 1 && md_has_front_cover(url.path) == 0 {
                        let oldType = Int(md_artwork_type(url.path))
                        if md_set_artwork_type(url.path, 3) == 0 {
                            artPromotions.append((rel, oldType))
                            log += "ART: \(rel)  promoted picture type \(oldType) → front cover\n"
                        }
                    }
                }
                // (ii) KEEP existing art. Only fill tracks that have NONE — and
                //      prefer the album's OWN cover (copied from a track that has
                //      one) over anything fetched, so the owner's real cover
                //      propagates to blank tracks (e.g. one disc has art, the other
                //      doesn't). Never replace art that's already there. If an album
                //      carries several DIFFERENT covers, don't guess — flag it for
                //      the Artwork review step to choose.
                await bump("Checking cover art")
                let prints = job.files.map { (f: $0, print: artFingerprint($0.url)) }
                let withArt = prints.filter { $0.print != nil }
                let blanks = prints.filter { $0.print == nil }
                let distinct = Set(withArt.compactMap { $0.print })
                if distinct.count > 1 {
                    flaggedArt.append((job.artist, job.album, job.files.map { $0.rel }, job.mbids))
                    log += "ART: album '\(job.artist) — \(job.album)' has \(distinct.count) different covers → flagged for review\n"
                    continue
                }
                if blanks.isEmpty { continue }   // every track already shares one cover — leave it untouched

                // pick the fill image: the album's own cover if any track has one, else fetched
                var fillData: Data? = nil
                var fillSource = "album's own cover"
                if let src = withArt.first?.f.url {
                    var l: Int32 = 0, t: Int32 = 0
                    if let b = md_copy_artwork(src.path, &l, &t) {
                        fillData = Data(bytes: b, count: Int(l)); free(b)
                    }
                } else {
                    await bump("Fetching cover art")
                    if let cover = await artClient.albumCover(releaseMBIDs: job.mbids, artist: job.artist, album: job.album) {
                        fillData = cover; fillSource = "fetched album cover"
                    }
                }
                guard let data = fillData else {
                    // gaps but nothing to fill with → manual review
                    flaggedArt.append((job.artist, job.album, blanks.map { $0.f.rel }, job.mbids))
                    log += "ART: album '\(job.artist) — \(job.album)' has \(blanks.count) blank track(s) and no cover found → flagged for review\n"
                    continue
                }
                let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                for (f, _) in blanks {
                    await bump("Adding cover art")
                    let rc = data.withUnsafeBytes { buf in
                        md_set_artwork(f.url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(data.count), mime)
                    }
                    if rc == 0 {
                        artEdits.append(f.rel)   // was empty → undo just strips it
                        log += "ART: \(f.rel)  ← \(fillSource) (\(data.count) bytes, gap filled)\n"
                    } else { log += "FAILED art \(f.rel): rc \(rc)\n" }
                }
            }

            // 0e) DUPLICATES — RE-DETECT from the final tags now that every Identify/Review
            //     album fix above is on disk, so cross-folder copies that only became
            //     duplicates after their album was corrected (an "Unknown Album" that's
            //     really "Check Your Head", a "[Sony]"/"[Castle]" edition) are caught.
            //     Highest-quality copy is kept; losers are quarantined. (User setting:
            //     auto within an album.)
            var dedupJobs: [DedupJob] = []
            if doDedup && !box.cancelled {
                await self.setCommitProgress("Finding duplicates", done: done)
                var tracks = await Self.buildTracksFromDisk(root: root, fm: fm)
                let clusters = buildClusters(&tracks, mode: .balanced, tol: 2.0, crossAlbum: false)
                let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for c in clusters {
                    guard let k = byId[c.keeperID] else { continue }
                    let losers = c.memberIDs.filter { $0 != c.keeperID }.compactMap { byId[$0] }
                        .map { DLoser(url: $0.url, rel: Self.rel($0.url, root)) }
                    if !losers.isEmpty {
                        dedupJobs.append(DedupJob(keeper: k.url, keeperRel: Self.rel(k.url, root), losers: losers))
                    }
                }
            }
            if !dedupJobs.isEmpty && !box.cancelled {
                await self.setCommitProgress("Merging & removing duplicates", done: done)
                let backfill = ["title", "artist", "album", "albumartist", "composer", "lyricist", "label", "conductor", "date", "track", "disc"]
                for job in dedupJobs {
                    if box.cancelled { break }
                    for field in backfill where (Self.readField(job.keeper, field) ?? "").isEmpty {
                        for l in job.losers {
                            let v = Self.readField(l.url, field) ?? ""
                            if !v.isEmpty {
                                do { try Self.writeField(job.keeper, field, to: v); tagEdits.append((job.keeperRel, field, "")); log += "MERGE: \(job.keeperRel)  + \(field)\n" } catch {}
                                break
                            }
                        }
                    }
                    if md_has_artwork(job.keeper.path) == 0 {
                        for l in job.losers {
                            var len: Int32 = 0, ty: Int32 = 0
                            if let b = md_copy_artwork(l.url.path, &len, &ty) {
                                let d = Data(bytes: b, count: Int(len)); free(b)
                                let mime = d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                                let rc = d.withUnsafeBytes { buf in md_set_artwork(job.keeper.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(d.count), mime) }
                                if rc == 0 { artEdits.append(job.keeperRel); log += "MERGE: \(job.keeperRel)  + cover\n" }
                                break
                            }
                        }
                    }
                    for l in job.losers {
                        if box.cancelled { break }
                        if move(l.rel, qRel + "/" + l.rel) { log += "DUPLICATE → quarantine: \(l.rel)\n" }
                        await bump("Merging & removing duplicates")
                    }
                }
            }

            // 1) folder merges + renames — ONLY when we're not rebuilding the whole
            //    tree below (Organise supersedes artist/album placement).
            if !doOrganise {
                if !accMerges.isEmpty || !accRenames.isEmpty {
                    await self.setCommitProgress("Reorganising folders", done: done)
                }
                for (canonical, sources) in accMerges {
                    if box.cancelled { break }
                    for src in sources where src != canonical {
                        let srcDir = root.appendingPathComponent(src)
                        let children = (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? []
                        for child in children {
                            let fromRel = src + "/" + child
                            let toRel = canonical + "/" + child
                            if fm.fileExists(atPath: root.appendingPathComponent(toRel).path) {
                                let sub = (try? fm.contentsOfDirectory(atPath: srcDir.appendingPathComponent(child).path)) ?? []
                                for f in sub {
                                    let fFrom = fromRel + "/" + f, fTo = toRel + "/" + f
                                    if !fm.fileExists(atPath: root.appendingPathComponent(fTo).path) {
                                        if move(fFrom, fTo) { log += "MERGED: \(fFrom) → \(fTo)\n" }
                                    } else { log += "SKIPPED (exists): \(fTo)\n" }
                                }
                            } else if move(fromRel, toRel) {
                                log += "MERGED: \(fromRel) → \(toRel)\n"
                            }
                        }
                        if move(src, qRel + "/" + src) { log += "QUARANTINED (emptied): \(src)\n" }
                    }
                }
                for (rel, newName) in accRenames.sorted(by: { $0.0.count > $1.0.count }) {
                    if box.cancelled { break }
                    let parent = (rel as NSString).deletingLastPathComponent
                    let toRel = parent.isEmpty ? newName : parent + "/" + newName
                    if move(rel, toRel) { log += "RENAMED: \(rel) → \(toRel)\n" }
                }
            }

            // 2) removals — junk + empty folders → quarantine (deepest first). Always.
            if !box.cancelled {
                for (rel, kind) in removals.sorted(by: { $0.0.count > $1.0.count }) {
                    if move(rel, qRel + "/" + rel) { log += "QUARANTINED (\(kind)): \(rel)\n" }
                }
            }

            // 3) ORGANISE — rebuild the clean Album Artist / Album / ## Title tree from
            //    the FINAL tags (after every write above), so late-accepted album fixes
            //    land in the right folder. Re-planned here, not from the step preview.
            if doOrganise && !box.cancelled {
                await self.setCommitProgress("Reorganising files", done: done)
                let orgInputs = Self.organiseInputsFromDisk(root: root, fm: fm)
                let mergesOrg = Set(Organiser.albumMergeCandidates(orgInputs).map { $0.key })
                    .subtracting(declinedMergesOrg)
                let plans = Organiser.plan(orgInputs,
                                           composerFirstForClassical: composerFirstOrg, renumber: renumberOrg,
                                           compilations: compsOrg, mergeAlbums: mergesOrg)
                for p in plans {
                    if box.cancelled { break }
                    guard let target = p.targetRel, target != p.rel else { continue }
                    let src = root.appendingPathComponent(p.rel)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    // Collision: the clean-tree destination is already occupied. If the
                    // sitting file is the SAME recording (matching size, or matching
                    // duration), this source is a leftover duplicate the dedup pass didn't
                    // fold in — quarantine it rather than stranding it in a stray folder.
                    let dst = root.appendingPathComponent(target)
                    if fm.fileExists(atPath: dst.path) {
                        let sSize = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
                        let dSize = (try? dst.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -2
                        var sameTrack = (sSize == dSize)
                        if !sameTrack {
                            let sd = await readMetadata(url: src, size: Int64(max(sSize, 0))).duration
                            let dd = await readMetadata(url: dst, size: Int64(max(dSize, 0))).duration
                            if sd > 0 && dd > 0 { sameTrack = abs(sd - dd) <= 3.0 }
                        }
                        if sameTrack {
                            if move(p.rel, qRel + "/" + p.rel) { log += "DUPLICATE (target exists) → quarantine: \(p.rel)\n" }
                        } else {
                            log += "SKIPPED (target exists, different track): \(p.rel) → \(target)\n"
                        }
                        await bump("Reorganising files")
                        continue
                    }
                    for (field, value) in p.tagWrites {
                        let old = Self.readField(src, field) ?? ""
                        if old == value { continue }
                        do { try Self.writeField(src, field, to: value); tagEdits.append((p.rel, field, old)) } catch {}
                    }
                    if move(p.rel, target) { log += "MOVED: \(p.rel) → \(target)\n" }
                    await bump("Reorganising files")
                }
            }

            // 4) prune folders emptied by any of the above moves (deepest first,
            //    genuinely-empty only; undo re-creates them when it restores files).
            if !box.cancelled {
                var checkDirs = Set<String>()
                for op in ops {
                    var cur = (op.from as NSString).deletingLastPathComponent
                    while !cur.isEmpty && cur != "." { checkDirs.insert(cur); cur = (cur as NSString).deletingLastPathComponent }
                }
                for rel in checkDirs.sorted(by: { $0.count > $1.count }) {
                    if rel.hasPrefix("Music Librarian Quarantine") { continue }
                    let dir = root.appendingPathComponent(rel)
                    guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                    if contents.allSatisfy({ $0 == ".DS_Store" }) {
                        for junk in contents { try? fm.removeItem(at: dir.appendingPathComponent(junk)) }
                        if (try? fm.removeItem(at: dir)) != nil { log += "REMOVED empty folder: \(rel)\n" }
                    }
                }
            }

            // 5) ALBUM ANALYSIS on the final tree — the same checks per-album "Perfect
            //    this album" runs, so the two flows surface the same things:
            //    (a) POSSIBLY-DAMAGED files (offline, always) — a track much shorter than
            //        its album's typical length, likely truncated. Info only, never removed.
            //    (b) MISSING-TRACK reconcile (network, gated by the toggle) — remembered per
            //        album folder so the Album Inspector greys the gaps out later.
            //    One disk pass (buildTracksFromDisk) gives tags + durations for both.
            var missingReports: [MissingAlbumReport] = []
            var damagedReports: [DamagedAlbumReport] = []
            if !box.cancelled {
                let diskTracks = await Self.buildTracksFromDisk(root: root, fm: fm)
                var byFolder: [String: [Track]] = [:]
                for t in diskTracks {
                    byFolder[t.url.deletingLastPathComponent().path, default: []].append(t)
                }
                // real albums only — skip loose/junk folders and one-offs the checks can't help
                let albums = byFolder.filter { $0.value.count >= 2 && !Organiser.albumOrEmpty($0.value.first?.album ?? "").isEmpty }
                    .sorted { $0.key < $1.key }
                let mb = MusicBrainzClient()
                var idx = 0
                for (folder, tracks) in albums {
                    if box.cancelled { break }
                    idx += 1
                    let album = Organiser.stripDiscSuffix(tracks.first?.album ?? "").clean
                    let comp = compsOrg.contains(Organiser.fold(album))
                    let aaTally = tracks.map { $0.displayArtist }.filter { !$0.isEmpty }
                    let artist = comp ? "Various Artists"
                        : (aaTally.sorted { a, b in aaTally.filter { $0 == a }.count > aaTally.filter { $0 == b }.count }.first ?? "")

                    // (a) possibly-damaged — same heuristic as per-album Perfect
                    let durs = tracks.map { $0.duration }.filter { $0 > 0 }.sorted()
                    let median = durs.isEmpty ? 0 : durs[durs.count / 2]
                    let shorties = tracks.filter { $0.duration > 0 && $0.duration <= 40 && median > 90 && $0.duration < median * 0.5 }
                    if !shorties.isEmpty {
                        let dlines = shorties.map { "“\($0.title.isEmpty ? $0.name : $0.title)” — \(fmtDur($0.duration)) (album typical \(fmtDur(median)))" }
                        damagedReports.append(DamagedAlbumReport(artist: artist, album: album.isEmpty ? (tracks.first?.album ?? "") : album, lines: dlines))
                        log += "\nPOSSIBLY DAMAGED in “\(album)” (unusually short, kept for review):\n"
                        for l in dlines { log += "  · \(l)\n" }
                    }

                    // (b) missing tracks — reconcile online, gated
                    guard checkMissing, tracks.count >= 4, !album.isEmpty else { continue }
                    await self.setCommitProgress("Checking for missing tracks (\(idx) of \(albums.count))", done: done)
                    let discCount = max(1, Set(tracks.map { $0.discNo == 0 ? 1 : $0.discNo }).count)
                    guard let match = await mb.bestRelease(artist: artist, album: album,
                                                           haveTitles: tracks.map { $0.title }, discCount: discCount)
                    else { continue }
                    let have = Set(tracks.map { TrackProposal.typoFold($0.title).lowercased() })
                    let missing = match.tracks
                        .filter { !have.contains(TrackProposal.typoFold($0.title).lowercased()) }
                        .sorted { ($0.disc, $0.track) < ($1.disc, $1.track) }
                    // always remember the matched tracklist so the inspector can show gaps
                    AlbumReconcileStore.save(folder, match)
                    guard !missing.isEmpty else { continue }
                    let lines = missing.map { "Disc \($0.disc) · \($0.track). \($0.title)" }
                    missingReports.append(MissingAlbumReport(artist: artist, album: match.title,
                                                             missing: missing.count, total: match.tracks.count,
                                                             missingTitles: lines))
                    log += "\nMISSING from “\(match.title)” (\(missing.count) of \(match.tracks.count)):\n"
                    for l in lines { log += "  · \(l)\n" }
                }
            }

            let total = ops.count + tagEdits.count + perfEdits.count + artEdits.count
                        + artPromotions.count + artReplacements.count
            let wasCancelled = box.cancelled
            log += "\n\(total) change(s)\(wasCancelled ? " (stopped early — you pressed Cancel)" : ""). Restore with 'Undo this run'.\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)

            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "\(total) change(s) applied\(wasCancelled ? " (cancelled)" : "")",
                "ops": ops.map { ["from": $0.from, "to": $0.to] },
                "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
                "perfEdits": perfEdits.map { ["rel": $0.rel, "name": $0.name, "role": $0.role] },
                "artEdits": artEdits,
                "artPromotions": artPromotions.map { ["rel": $0.rel, "oldType": String($0.oldType)] },
                "artReplacements": artReplacements.map { ["rel": $0.rel, "backup": $0.backup, "oldType": String($0.oldType)] },
            ]
            if total > 0, let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            } else if total == 0 {
                // nothing was applied (cancelled before any change) — leave no empty run
                try? fm.removeItem(at: quarantine)
            }
            await self.finishCommit(count: total, quarantine: quarantine, cancelled: wasCancelled,
                                    flagged: flaggedArt.map { ArtworkReviewItem(artist: $0.artist, album: $0.album, files: $0.files, mbids: $0.mbids) },
                                    missing: missingReports, damaged: damagedReports)
        }
    }

    private func finishCommit(count: Int, quarantine: URL, cancelled: Bool = false,
                              flagged: [ArtworkReviewItem] = [], missing: [MissingAlbumReport] = [],
                              damaged: [DamagedAlbumReport] = []) {
        busy = false
        missingTrackReports = missing.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
        damagedTrackReports = damaged.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
        // the summary dialog is set BEFORE committing flips false so the view's
        // onChange sees it and shows the "all done" sheet (not just a dismiss).
        showCompletionSummary = !cancelled && count > 0
        committing = false; cancelRequested = false
        artworkNeedsReview = flagged
        commitPhase = ""; commitDone = 0; commitTotal = 0
        lastQuarantine = quarantine
        lastRunSummary = cancelled ? "Stopped — applied \(count) change(s) before you cancelled."
                                   : "Applied \(count) change(s)."
        findings.removeAll { $0.accepted && $0.kind.safe }
        renames.removeAll { $0.accepted && $0.newName != $0.oldName }
        artists.removeAll { $0.accepted && artistHasApplicableWork($0) }
        proposals.removeAll { $0.accepted && $0.hasChange }
        status = lastRunSummary ?? status
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()   // art on disk changed → drop stale thumbnails
        if !cancelled {
            ArtworkChoices.shared.clearAll()                        // cover choices were embedded in this run
            // the dedup + organise plans were applied in this run → consume them
            deduped = false; dedupClusters = []; dedupTracks = []
            organised = false; organisePlans = []
            organiseStale = false
            compilationCandidates = []; confirmedCompilations = []
            albumMergeCandidates = []; declinedAlbumMerges = []
        }
        if !cancelled && count > 0 { clearPlan() }   // the plan has been applied → consumed
        loadRuns()
    }

    // MARK: Manual artwork review (albums flagged during commit)

    /// The distinct covers already embedded across a flagged album's tracks, so the
    /// picker can offer "use one of these" as thumbnails.
    func existingCovers(for item: ArtworkReviewItem) -> [Data] {
        guard let root else { return [] }
        var seen = Set<String>(); var out: [Data] = []
        for rel in item.files {
            let url = root.appendingPathComponent(rel)
            var len: Int32 = 0, type: Int32 = 0
            guard let buf = md_copy_artwork(url.path, &len, &type) else { continue }
            let d = Data(bytes: buf, count: Int(len)); free(buf)
            let key = "\(len):" + String(d.prefix(64).reduce(UInt64(0)) { $0 &+ UInt64($1) })
            if seen.insert(key).inserted { out.append(d) }
        }
        return out
    }

    /// Re-run the online search for a flagged album (editable artist/album).
    func researchCover(artist: String, album: String) async -> Data? {
        await CoverArtClient().itunesCover(artist: artist, album: album)
    }

    /// Candidate covers FROM THE SERVICES for an album under review — Cover Art
    /// Archive (by the album's release MBIDs) plus the top iTunes matches — so the
    /// Artwork step offers real cover choices, not just whatever's already embedded.
    func serviceCovers(for item: ArtworkReviewItem) async -> [Data] {
        await CoverArtClient().candidates(releaseMBIDs: item.mbids, artist: item.artist, album: item.album)
    }
    /// Re-search the services with edited artist/album terms.
    func serviceCovers(artist: String, album: String, mbids: [String] = []) async -> [Data] {
        await CoverArtClient().candidates(releaseMBIDs: mbids, artist: artist, album: album)
    }

    /// Stream service covers to `onEach` progressively, in order, deduped — so the
    /// Artwork picker fills in one cover at a time as each downloads.
    func streamServiceCovers(artist: String, album: String, mbids: [String],
                             onEach: @escaping @MainActor (Data) -> Void) async {
        var seen = Set<String>()
        await CoverArtClient().streamCandidates(releaseMBIDs: mbids, artist: artist, album: album) { d in
            let k = "\(d.count):" + String(d.prefix(48).reduce(UInt64(0)) { $0 &+ UInt64($1) })
            if seen.insert(k).inserted { await MainActor.run { onEach(d) } }
        }
    }
    func streamServiceCovers(for item: ArtworkReviewItem, onEach: @escaping @MainActor (Data) -> Void) async {
        await streamServiceCovers(artist: item.artist, album: item.album, mbids: item.mbids, onEach: onEach)
    }

    /// The release MBIDs the identify pass found for an album (for Cover Art Archive).
    private func mbids(forAlbum album: String, artist: String) -> [String] {
        let al = Organiser.stripDiscSuffix(album).clean.lowercased(), ar = artist.lowercased()
        let ids = proposals.filter {
            Organiser.stripDiscSuffix($0.chosenAlbum.isEmpty ? $0.curAlbum : $0.chosenAlbum).clean.lowercased() == al
            && ($0.newArtist.isEmpty ? $0.curArtist : $0.newArtist).lowercased() == ar
        }.compactMap { $0.enrichment?.releaseMBID }
        return Array(Set(ids))
    }

    /// Record a cover choice for an album (does NOT write to disk) — it's embedded
    /// with everything else in the final Apply, so all the covers you pick land in
    /// ONE run. Previews update immediately via ArtworkChoices + ArtRefresh.
    func chooseArtwork(item: ArtworkReviewItem, image: Data) {
        ArtworkChoices.shared.byKey[ArtworkChoices.key(artist: item.artist, album: item.album)] = image
        artworkNeedsReview.removeAll { $0.id == item.id }
        ArtRefresh.shared.bump()
        status = "Cover chosen for \(item.album) — applies with the rest on Apply."
        savePlan()
    }

    /// Apply a chosen cover to every track of a flagged album — backing up any
    /// existing art so it's reversible — and drop the album from the review list.
    func applyChosenArtwork(item: ArtworkReviewItem, image: Data) {
        guard let root else { return }
        busy = true; status = "Setting cover for \(item.album)…"
        let files = item.files
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let qRel = "Music Librarian Quarantine/\(stamp)"
            let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let backupDir = quarantine.appendingPathComponent("artwork-backups", isDirectory: true)
            let mime = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            var artEdits: [String] = []
            var artReplacements: [(rel: String, backup: String, oldType: Int)] = []
            var idx = 0
            var log = "Music Librarian — manual artwork \(Date())\nAlbum: \(item.artist) — \(item.album)\n\n"
            for rel in files {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                var l: Int32 = 0, t: Int32 = 0
                if let b = md_copy_artwork(url.path, &l, &t) {
                    let bd = Data(bytes: b, count: Int(l)); free(b)
                    try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    let name = "\(idx).img"; idx += 1
                    try? bd.write(to: backupDir.appendingPathComponent(name))
                    artReplacements.append((rel, "artwork-backups/" + name, Int(t)))
                } else { artEdits.append(rel) }
                let rc = image.withUnsafeBytes { buf in
                    md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(image.count), mime)
                }
                log += rc == 0 ? "ART: \(rel)  ← chosen cover\n" : "FAILED art \(rel): rc \(rc)\n"
            }
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "root": root.path,
                "summary": "Cover set for \(item.album) (\(files.count) track(s))",
                "ops": [], "tagEdits": [], "perfEdits": [],
                "artEdits": artEdits,
                "artPromotions": [],
                "artReplacements": artReplacements.map { ["rel": $0.rel, "backup": $0.backup, "oldType": String($0.oldType)] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) {
                try? data.write(to: quarantine.appendingPathComponent("run.json"))
            }
            await self.finishArtworkChoice(item: item, quarantine: quarantine)
        }
    }

    private func finishArtworkChoice(item: ArtworkReviewItem, quarantine: URL) {
        busy = false
        lastQuarantine = quarantine
        artworkNeedsReview.removeAll { $0.id == item.id }
        status = "Cover set for \(item.album)."
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()   // show the chosen cover immediately
        loadRuns()
    }

    /// Dismiss a flagged album without touching its art ("leave as-is").
    func skipArtworkReview(_ item: ArtworkReviewItem) {
        artworkNeedsReview.removeAll { $0.id == item.id }
    }

    // MARK: Run history + undo

    // Every library the app has opened, so Runs/Logs can list runs across all of
    // them without a library being selected.
    static let rootsKey = "perfectLibraryRoots"
    static func rememberRoot(_ url: URL) {
        var roots = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        if !roots.contains(url.path) { roots.append(url.path); UserDefaults.standard.set(roots, forKey: rootsKey) }
    }

    /// Apply inspector edits (tag rewrites, renames, deletes) as ONE reversible run,
    /// recorded in the same run.json the wizard writes — so it appears in Runs and
    /// undoes exactly. `moves` are (fromRel, toRel); an empty `to` sends the file or
    /// folder to quarantine (a delete). Tag writes happen first, while files are still
    /// at their original paths. `then` runs on the main actor when done.
    func applyLibraryRun(root: URL, summary: String,
                         tagWrites: [(rel: String, field: String, value: String)] = [],
                         moves: [(from: String, to: String)] = [],
                         artEmbeds: [(rel: String, image: Data, mime: String)] = [],
                         performerAdds: [(rel: String, name: String, role: String)] = [],
                         then: (@MainActor () -> Void)? = nil) {
        busy = true; status = "Applying…"
        Task {   // @MainActor-isolated (this method is on the store); disk work suspends off-main
            await Self.performLibraryOps(root: root, summary: summary,
                                         tagWrites: tagWrites, moves: moves, artEmbeds: artEmbeds,
                                         performerAdds: performerAdds)
            // Cover art / paths on disk just changed — drop the cached thumbnails so the
            // grid and album covers reload from the files (clear() bumps ArtRefresh).
            ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
            self.busy = false; self.status = ""; self.loadRuns(); then?()
        }
    }

    /// The disk side of a library edit — runs off the main actor. Writes tags, moves
    /// files (empty `to` = quarantine), and records a run.json + changelog so the whole
    /// thing is one undoable entry in Runs.
    nonisolated static func performLibraryOps(root: URL, summary: String,
                                              tagWrites: [(rel: String, field: String, value: String)],
                                              moves: [(from: String, to: String)],
                                              artEmbeds: [(rel: String, image: Data, mime: String)] = [],
                                              performerAdds: [(rel: String, name: String, role: String)] = []) async {
        let fm = FileManager.default
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
        let qRel = "Music Librarian Quarantine/\(stamp)"
        let quarantine = root.appendingPathComponent(qRel, isDirectory: true)
        try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        var ops: [(from: String, to: String)] = []
        var tagEdits: [(rel: String, field: String, old: String)] = []
        var perfEdits: [(rel: String, name: String, role: String)] = []   // credits added → undo removes them
        var artEdits: [String] = []                                   // art added where there was none → undo strips it
        var artReplacements: [(rel: String, backup: String, oldType: Int)] = []  // art replaced → undo restores backup
        var log = "Music Librarian — change log \(Date())\nLibrary: \(root.path)\n\n"

        for w in tagWrites {
            let url = root.appendingPathComponent(w.rel)
            let old = readField(url, w.field) ?? ""
            if old == w.value { continue }
            do { try writeField(url, w.field, to: w.value); tagEdits.append((w.rel, w.field, old))
                 log += "TAG: \(w.rel)  \(w.field) '\(old)' → '\(w.value)'\n" } catch {}
        }
        // performer credits — added to the musician-credits list, recorded so undo
        // removes exactly what was added. Skip any already present (idempotent).
        for p in performerAdds {
            let url = root.appendingPathComponent(p.rel)
            guard fm.fileExists(atPath: url.path), md_has_performer(url.path, p.name, p.role) == 0 else { continue }
            do { try addPerformer(url, name: p.name, role: p.role); perfEdits.append((p.rel, p.name, p.role))
                 log += "CREDIT: \(p.rel)  + \(p.name) (\(p.role))\n" } catch {}
        }
        // Embed artwork BEFORE any moves so the recorded rels are the files' original
        // paths (undo reverses moves first, then restores art by rel). Existing art is
        // backed up (artReplacements); a blank track's added art is recorded in artEdits.
        if !artEmbeds.isEmpty {
            let artBackupDir = quarantine.appendingPathComponent("artwork-backups", isDirectory: true)
            var bIdx = 0
            for e in artEmbeds {
                let url = root.appendingPathComponent(e.rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                if md_has_artwork(url.path) == 1 {
                    var bl: Int32 = 0, bt: Int32 = 0
                    if let bbuf = md_copy_artwork(url.path, &bl, &bt) {
                        let bdata = Data(bytes: bbuf, count: Int(bl)); free(bbuf)
                        try? fm.createDirectory(at: artBackupDir, withIntermediateDirectories: true)
                        let name = "\(bIdx).img"; bIdx += 1
                        try? bdata.write(to: artBackupDir.appendingPathComponent(name))
                        artReplacements.append((e.rel, "artwork-backups/" + name, Int(bt)))
                    }
                } else {
                    artEdits.append(e.rel)   // was blank → undo just strips it
                }
                let rc = e.image.withUnsafeBytes { buf in
                    md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(e.image.count), e.mime)
                }
                log += rc == 0 ? "ART: \(e.rel)  ← unified cover (\(e.image.count) bytes)\n" : "FAILED art \(e.rel): rc \(rc)\n"
            }
        }
        // longest source path first so a folder's files move before the folder
        for m in moves.sorted(by: { $0.from.count > $1.from.count }) {
            let toRel = m.to.isEmpty ? qRel + "/" + m.from : m.to
            let from = root.appendingPathComponent(m.from), to = root.appendingPathComponent(toRel)
            guard fm.fileExists(atPath: from.path) else { continue }
            // A case-only rename ("… On …" → "… on …") on a case-insensitive volume
            // makes `to` look like it already exists (it's the SAME file as `from`) —
            // that's not a collision, so allow it; only skip a genuinely different file.
            let caseOnly = from.path != to.path && from.path.lowercased() == to.path.lowercased()
            if !m.to.isEmpty && !caseOnly && fm.fileExists(atPath: to.path) {
                log += "SKIP (target exists): \(toRel)\n"; continue
            }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if caseOnly {
                    // go via a temp name so a case-insensitive filesystem actually applies it
                    let tmp = to.deletingLastPathComponent().appendingPathComponent(".mdtmp-\(to.lastPathComponent)")
                    try? fm.removeItem(at: tmp)
                    try fm.moveItem(at: from, to: tmp)
                    try fm.moveItem(at: tmp, to: to)
                } else {
                    try fm.moveItem(at: from, to: to)
                }
                ops.append((m.from, toRel))
                log += "\(m.to.isEmpty ? "DELETE → quarantine" : "MOVE"): \(m.from) → \(toRel)\n"
            } catch { log += "FAILED \(m.from): \(error.localizedDescription)\n" }
        }
        let total = ops.count + tagEdits.count + perfEdits.count + artEdits.count + artReplacements.count
        log += "\n\(total) change(s). Restore with 'Undo this run'.\n"
        try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)
        let record: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "root": root.path, "summary": summary,
            "ops": ops.map { ["from": $0.from, "to": $0.to] },
            "tagEdits": tagEdits.map { ["rel": $0.rel, "field": $0.field, "old": $0.old] },
            "perfEdits": perfEdits.map { ["rel": $0.rel, "name": $0.name, "role": $0.role] },
            "artEdits": artEdits, "artPromotions": [],
            "artReplacements": artReplacements.map { ["rel": $0.rel, "backup": $0.backup, "oldType": String($0.oldType)] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: quarantine.appendingPathComponent("run.json"))
        }
    }

    /// Load runs from EVERY remembered library (plus the current one), not just the
    /// selected one — so the Runs window works with no library open. Each run's
    /// library is derived from where its quarantine physically sits, so undo targets
    /// the right folder even if the library was copied elsewhere.
    func loadRuns() {
        var roots = Set(UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? [])
        if let r = root { roots.insert(r.path) }
        // Seed from the folders the user has opened elsewhere (Manage/Library browser,
        // last main-window library) so Runs is populated on first launch of a build
        // even before any root has been formally remembered.
        if let bp = UserDefaults.standard.string(forKey: "libraryBrowserRoot") { roots.insert(bp) }
        let fm = FileManager.default
        var found: [RunRecord] = []
        for rp in roots {
            let qroot = URL(fileURLWithPath: rp).appendingPathComponent("Music Librarian Quarantine", isDirectory: true)
            guard let subs = try? fm.contentsOfDirectory(at: qroot, includingPropertiesForKeys: nil) else { continue }
            for sub in subs { if let rec = Self.loadRunRecord(sub) { found.append(rec) } }
        }
        runs = found.sorted { $0.date > $1.date }
    }

    /// Parse one quarantine folder's run.json into a RunRecord, deriving the library
    /// root from the folder's own location (…/<root>/Music Librarian Quarantine/<ts>).
    static func loadRunRecord(_ folder: URL) -> RunRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("run.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        let date = ISO8601DateFormatter().date(from: obj["date"] as? String ?? "") ?? Date(timeIntervalSince1970: 0)
        let ops = (obj["ops"] as? [[String: String]] ?? []).compactMap { d -> (String, String)? in
            guard let f = d["from"], let t = d["to"] else { return nil }; return (f, t)
        }
        let tagEdits = (obj["tagEdits"] as? [[String: String]] ?? []).compactMap { d -> (String, String, String)? in
            guard let r = d["rel"], let o = d["old"] else { return nil }
            return (r, d["field"] ?? "artist", o)
        }
        let perfEdits = (obj["perfEdits"] as? [[String: String]] ?? []).compactMap { d -> (String, String, String)? in
            guard let r = d["rel"], let n = d["name"], let ro = d["role"] else { return nil }; return (r, n, ro)
        }
        let artEdits = obj["artEdits"] as? [String] ?? []
        let artPromotions = (obj["artPromotions"] as? [[String: String]] ?? []).compactMap { d -> (String, Int)? in
            guard let r = d["rel"] else { return nil }; return (r, Int(d["oldType"] ?? "0") ?? 0)
        }
        let artReplacements = (obj["artReplacements"] as? [[String: String]] ?? []).compactMap { d -> (String, String, Int)? in
            guard let r = d["rel"], let b = d["backup"] else { return nil }; return (r, b, Int(d["oldType"] ?? "0") ?? 0)
        }
        let n = ops.count + tagEdits.count + perfEdits.count + artEdits.count + artPromotions.count + artReplacements.count
        return RunRecord(id: folder.path, folder: folder, root: root, date: date,
                         ops: ops, tagEdits: tagEdits, perfEdits: perfEdits, artEdits: artEdits,
                         artPromotions: artPromotions, artReplacements: artReplacements,
                         summary: obj["summary"] as? String ?? "\(n) changes")
    }

    /// Reverse a run: move each recorded change back (to → from), newest moves
    /// first, then remove the emptied quarantine folder.
    func undo(_ run: RunRecord) {
        let root = run.root      // the library this run physically belongs to
        busy = true; status = "Undoing run in \(root.lastPathComponent)…"
        let folder = run.folder, ops = run.ops, tagEdits = run.tagEdits, perfEdits = run.perfEdits, artEdits = run.artEdits
        let artPromotions = run.artPromotions, artReplacements = run.artReplacements
        let isCurrentLibrary = (self.root?.path == root.path)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var restored = 0, failed = 0

            // merge-aware restore: never clobber an existing directory (the emptied
            // source folder of a merge is restored into one the file-restores have
            // already rebuilt) — merge its contents in instead.
            func restore(_ from: URL, _ to: URL) -> Bool {
                let fromIsDir = (try? from.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let toExists = fm.fileExists(atPath: to.path)
                if fromIsDir && toExists {
                    for child in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                        _ = restore(from.appendingPathComponent(child), to.appendingPathComponent(child))
                    }
                    try? fm.removeItem(at: from)   // now-empty source shell
                    return true
                }
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if toExists { try? fm.removeItem(at: to) }
                    try fm.moveItem(at: from, to: to)
                    return true
                } catch { return false }
            }

            // deepest `to` first so files come out before their quarantined parent
            for op in ops.reversed().sorted(by: { $0.to.count > $1.to.count }) {
                let from = root.appendingPathComponent(op.to)     // where it is now
                let to = root.appendingPathComponent(op.from)      // where it belongs
                guard fm.fileExists(atPath: from.path) else { continue }
                if restore(from, to) { restored += 1 } else { failed += 1 }
            }

            // restore tag rewrites — the files are back at their original paths now,
            // so write each old artist spelling back into place.
            for edit in tagEdits {
                let url = root.appendingPathComponent(edit.rel)
                guard fm.fileExists(atPath: url.path) else { failed += 1; continue }
                do { try Self.writeField(url, edit.field, to: edit.old); restored += 1 } catch { failed += 1 }
            }
            // remove any performer credits this run added
            for edit in perfEdits {
                let url = root.appendingPathComponent(edit.rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                Self.removePerformer(url, name: edit.name, role: edit.role); restored += 1
            }
            // strip any cover art this run added
            for rel in artEdits {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                _ = md_remove_artwork(url.path); restored += 1
            }
            // put any promoted picture back to its original type (non-destructive)
            for (rel, oldType) in artPromotions {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                _ = md_set_artwork_type(url.path, Int32(oldType)); restored += 1
            }
            // restore any replaced art from its backup (read BEFORE the quarantine
            // folder is removed below), then put the original picture type back
            for (rel, backup, oldType) in artReplacements {
                let url = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path),
                      let bdata = try? Data(contentsOf: folder.appendingPathComponent(backup)) else { continue }
                let mime = bdata.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                let rc = bdata.withUnsafeBytes { buf in
                    md_set_artwork(url.path, buf.bindMemory(to: CChar.self).baseAddress, Int32(bdata.count), mime)
                }
                if rc == 0 { _ = md_set_artwork_type(url.path, Int32(oldType)); restored += 1 }
            }

            try? fm.removeItem(at: folder)
            let qroot = root.appendingPathComponent("Music Librarian Quarantine")
            if let empty = try? fm.contentsOfDirectory(atPath: qroot.path), empty.isEmpty {
                try? fm.removeItem(at: qroot)
            }
            await self.finishUndo(restored: restored, failed: failed, current: isCurrentLibrary)
        }
    }

    private func finishUndo(restored: Int, failed: Int, current: Bool) {
        busy = false
        lastRunSummary = nil
        status = "Restored \(restored) change(s)" + (failed > 0 ? ", \(failed) failed." : ".")
        loadRuns()
        // only re-scan when the undone run belongs to the library that's open
        if current && diagnosed { diagnose() }
    }

    // MARK: Detection helpers

    nonisolated static func rel(_ u: URL, _ root: URL) -> String {
        let p = u.path, base = root.path
        if p.hasPrefix(base) {
            var r = String(p.dropFirst(base.count))
            if r.hasPrefix("/") { r.removeFirst() }
            return r
        }
        return u.lastPathComponent
    }

    nonisolated static func junkReason(_ u: URL) -> String? {
        let name = u.lastPathComponent
        if name == ".DS_Store" { return "macOS folder metadata" }
        if name.hasPrefix("._") { return "macOS AppleDouble metadata" }
        if name == "Thumbs.db" || name == "desktop.ini" { return "Windows metadata" }
        if name.hasSuffix(".crswap") { return "leftover temporary file" }
        if name.contains("smbdelete") { return "leftover server-delete marker" }
        return nil
    }

    nonisolated static let audioExts: Set<String> = ["mp3","m4a","m4p","aac","flac","wav","aiff","aif","alac","ogg","wma","opus"]
    nonisolated static func isAudio(_ u: URL) -> Bool { audioExts.contains(u.pathExtension.lowercased()) }

    /// FairPlay-protected content is reported by AVFoundation directly.
    nonisolated static func isDRM(_ u: URL) async -> Bool {
        let ext = u.pathExtension.lowercased()
        if ext == "m4p" { return true }   // fast path
        guard ext == "m4a" || ext == "mp4" || ext == "aac" else { return false }
        return (try? await AVURLAsset(url: u).load(.hasProtectedContent)) ?? false
    }
}
