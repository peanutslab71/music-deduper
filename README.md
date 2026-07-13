# Music Librarian

A native Mac app for cleaning up a local music library: identify and tag tracks,
fix cover art, remove duplicates, organise everything into a clean folder tree,
browse and play it, and copy it out to a server or NAS. It works on your files in
place, shows you every change before it's made, and keeps a full undo history — so
nothing it does is permanent until you say so.

I wrote it because my own library had years of accumulated mess in it — the same album
ripped twice, MP3s sitting next to the FLAC versions that replaced them, "Track 01 (1).flac"
copies from old backups, half-tagged rips, missing cover art, compilations scattered across
a dozen artist folders. Cleaning that up by hand across thousands of files isn't realistic,
and I didn't trust anything else to make the right calls. This does the tedious part and
lets you review everything before a single file is touched.

## What it does

The app is organised into a few tabs across the top; you can use any of them on their own.

### Perfect — revive a library in place

The main event. Point **Perfect** at a folder and it works through the library step by
step, showing what it proposes at each stage; nothing is written until a single final
**Apply**, and the whole run can be undone afterwards.

- **Identify** unknown or mistagged tracks by sound (AcoustID fingerprint → MusicBrainz),
  and fill in missing tags, credits and details from free public databases.
- **Duplicates** — remove copies, keeping the best one (lossless over lossy, then higher
  bitrate, then more complete tags). As well as identical files and same-title/length
  matches, it catches two files that share an album and track number even when a title has
  a typo, and truncated/partial copies of a track you already have in full — while leaving
  genuinely short tracks (interludes, intros) alone.
- **Organise** into a clean `Album Artist / Album / ## Title` tree. Various-artists
  compilations are filed under **Various Artists** rather than split across each guest
  artist; differently-named editions of one album (a `[Sony]` or `[Castle]` reissue, a
  `(Remastered)` version, multi-disc parts) can be merged into one; and a track whose
  album-artist tag disagrees with the rest of its album (a guest credit, say) is filed
  with the album instead of on its own. The compilations and merges it isn't certain
  about are listed for you to confirm first.
- **Artwork** — find and fill missing covers, from the file's own art or the cover
  services.
- An interrupted session is remembered: quit or cancel mid-run and it reopens the same
  library at the same step next launch.

### Library — browse, play and edit

The **Library** tab shows any folder as an album grid (covers come from the files' own
tags). Click an album to open the **Album Inspector**:

- **Play** a whole album or a single track. Playback runs in a **player bar** at the
  bottom of the window — shuffle, previous, play/pause, next, repeat, a scrubber, volume,
  and a real-time **frequency spectrum** of what's playing (28 bands, ~30 Hz–16 kHz).
  Playback continues when you close the album; the bar stays.
- **Edit tags** in a side panel: title, artist, album, album artist, track, disc, year,
  genre and composer.
- **Rename** an album (retags its tracks and renames the folder) or **delete** a track or
  a whole album. As everywhere else, deletes go to the app's quarantine folder, not the
  Trash, and every edit is recorded so it can be undone.
- Protected iTunes files (`.m4p`, FairPlay DRM) show a lock — their tags read fine and
  they organise normally, but macOS can't decode the audio, so they can't be played.

### Find duplicates and copy to a server

A four-step wizard — **Source → Review → Clean up → Copy** — for the specific job of
de-duplicating a library and copying the keepers out to a server or NAS.

- **Scan** every track (proper tags and durations via AVFoundation, plus content
  fingerprints — not filename guessing).
- **Review** the duplicate groups, or an album-artwork grid of the whole library if there
  are none. The best copy in each group is marked **KEEP**; click any row to override.
- **Clean up** sends the duplicates to the Trash, or deletes permanently if you ask twice.
  Keepers are never touched.
- **Copy** rebuilds a clean Artist/Album tree at a destination, as an explicit sequence:
  locate the share → pick the folder → copy. Files that already exist **ask first**
  (Overwrite / Skip, each or All — nothing silent). The copy is built for flaky network
  shares: **three to four files in parallel** (self-tuning — per-file round trips dominate
  on the old SMB dialects small servers speak), existence checks batched per album folder,
  macOS told not to throttle the app or sleep mid-run, the share nudged every 30 seconds so
  it can't idle out, every copied file verified against the source, and a file that fails
  retried up to 5 times (re-mounting the share directly, never through Finder, if it
  dropped) before being set aside, with a **Retry failed** button at the end. If the server
  disappears entirely, the run **pauses itself** and offers Resume rather than grinding
  through timeouts.
- **ROCK-aware copying**: if the destination is a Roon ROCK with Roon Server running, the
  copy is blocked — copying under a live server can hang it. The app offers to stop Roon
  Server, runs the copy, then offers to start it again so it imports in one clean pass.
  Migrating over several runs? Leave Roon Server stopped **between** runs too — a NUC busy
  importing thousands of fresh tracks can drop off the network and look like a hardware
  fault ([HELP.md](HELP.md) has the full story).

### File Commander

The **Browse** tab is a two-pane file manager that talks to your server directly through
the built-in engine — browse, rename, make folders, move and copy between your Mac and the
server (or around the server itself), delete, and export a folder as a zip. Faster and
steadier than Finder against an old Roon ROCK, and mounts nothing.

### Built-in network engine

Underneath the copy and File Commander tabs, the app has its own SMB networking: it
discovers servers, lists shares, browses folders and transfers files by talking to the
server **directly**, without macOS's network mount in the path (the thing that beachballs
Finder when a NAS hiccups). Old, fussy servers — Roon ROCK's ten-year-old Samba included —
get patient timeouts, instant reconnects and honest errors macOS won't give them. The
classic mount-based engine is one toggle away.

### Everything is reversible

Nothing the app writes goes straight to the Trash or is overwritten in place. Duplicate
removals, organise moves, tag edits, renames and deletes all go to a dated **quarantine**
folder inside the library, with a change log. The **Runs** window (Library ▸ Runs) lists
every run across every library you've opened and reverts any of them — files come back out
of quarantine and tags are written back. **Logs** (Library ▸ Logs) shows each run's change
log. A change is only permanent once you empty the quarantine folder yourself.

There's a full walkthrough in [USAGE.md](USAGE.md), and [HELP.md](HELP.md)
covers performance tuning (including a fix for macOS's slow SMB defaults),
troubleshooting, and uninstalling.

## Setting up identification (API keys)

To identify tracks and fill in tags, credits and cover art, Music Librarian
looks your music up against free public databases. Most need no account, but:

- **AcoustID** (track identification by sound) needs a **free key you provide**.
- **Discogs** (extra credits) works better with a **free token** — optional.

Open **Music Librarian ▸ Settings** (⌘,), paste your keys, and you're set — each
row links straight to where you get it and explains the free-tier limits. Keys
are stored in your Mac's Keychain, never in the app. Without an AcoustID key the
app still cleans, de-duplicates and organises; it just skips identification.

Full details, links and rate limits: **[docs/API-KEYS.md](docs/API-KEYS.md)**.

## Download

A signed and notarized build is available from
[my profile page on AllSports.World](https://allsports.world/profiles/neilcotty/) —
open the DMG, drag the app to Applications. Needs macOS 13 (Ventura) or later.

## Problems or ideas?

Report bugs and requests on the
[GitHub issues page](https://github.com/peanutslab71/music-librarian/issues) —
include your macOS version and, for copy problems, what the destination is
(local folder, NAS, Roon ROCK).

## Building from source

You'll need Xcode (free on the Mac App Store).

1. Open `MusicLibrarian.xcodeproj`.
2. Check the scheme says **MusicLibrarian** and the destination is **My Mac**.
3. Press ⌘R. If Xcode asks about signing, set the target's Team to your own Apple ID
   under Signing & Capabilities — a free personal team is fine for running locally.

To produce a standalone `.app`, use Product → Archive. `make_dmg.sh` turns an exported
app into a drag-to-Applications DMG, and `DISTRIBUTION.md` covers the Developer ID
signing and notarization steps if you want a build other Macs will open without warnings.

## Use at your own risk

This app moves, retags and deletes files — that's its job. It's provided free, **as is,
with no warranty of any kind, express or implied**, and no liability is accepted for any
loss of data or other damage arising from its use. It is careful — the duplicate wizard's
deletes default to the Trash and are confirmed twice, and everything Perfect and the
Library tab do is reversible from the Runs window — but you should **back up your library
before letting this (or any) tool loose on it**. See [LICENSE](LICENSE) for the full terms
(MIT).

The app's own code is MIT; the built-in network engine uses the LGPL-licensed
AMSMB2/libsmb2 libraries — see [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## Notes

- Scanning and previewing never modify your library. The duplicate wizard writes nothing
  until you run a delete or copy (deletes confirmed twice); Perfect writes nothing until
  the final Apply; and Library edits are applied when you make them but recorded for undo.
- The app is not sandboxed, so it can read the folder you pick and delete files.
  macOS may prompt once for access to certain folders — click Allow.
- If your source lives in iCloud with "Optimize Storage" on, download the files first
  (Finder → right-click the folder → Download Now), or some tracks may read as unreadable.
- Duplicate matching runs at three strictness levels (Strict / Balanced / Aggressive) —
  see [USAGE.md](USAGE.md) for what each level actually compares.
- If the Xcode project file itself ever refuses to open, there's a rebuild recipe in
  [docs/xcode-recovery.md](docs/xcode-recovery.md).
