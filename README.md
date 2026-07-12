# Music Librarian

A small native Mac app that finds and removes duplicate tracks in a music library.

I wrote it because my own library had years of accumulated mess in it — the same album
ripped twice, MP3s sitting next to the FLAC versions that replaced them, "Track 01 (1).flac"
copies from old backups. Cleaning that up by hand across thousands of files isn't realistic,
and I didn't trust anything else to make the right call about which copy to keep. This does
the tedious part: it scans the library, groups the copies together, picks the best one of
each, and lets you review everything before a single file is touched.

## What it does

A four-step wizard: **Source → Review → Clean up → Copy.**

- Drop your music folder in and it scans every track — proper tags and durations
  read via AVFoundation, not filename guessing.
- Review lands where it should: duplicates grouped for review if there are any,
  otherwise an **album-artwork grid** of your whole library. The best copy in each
  group is marked **KEEP** — lossless beats lossy, then higher bitrate, then better
  tags. Click any row if you disagree.
- **Clean up** sends the duplicates to the Trash (or deletes permanently, if you
  ask twice). Keepers are never touched.
- **Copy** rebuilds a clean Artist/Album tree on a server or NAS share, as an
  explicit sequence: locate the share → pick the folder → copy. Files that already
  exist **ask first** (Overwrite / Skip, each or All — nothing silent). The copy is
  built for flaky network shares: **three to four files copy in parallel**
  (self-tuning — per-file round trips dominate on the old SMB dialects small
  servers speak), existence checks are batched per album folder, macOS is told not
  to throttle the app or sleep mid-run, the share is nudged every 30 seconds so
  the connection can't idle out, every copied file is verified against the source,
  and a file that fails is retried up to 5 times (re-mounting the share directly —
  never through Finder — if it dropped) before being set aside, with a **Retry
  failed** button at the end. If the server disappears entirely, the run **pauses
  itself** and offers Resume rather than grinding through timeouts.
- **Built-in network engine** (v1.3): the app finds servers on your network,
  lists their shares, browses folders and copies files by talking SMB
  **directly to the server** — macOS's own network mount (the thing that
  beachballs Finder when a NAS hiccups) is not involved at any point, and
  can even be ejected during copies. Old, fussy servers (Roon ROCK's
  ten-year-old Samba very much included) get the patient timeouts,
  instant reconnects and honest errors macOS refuses to give them. The
  classic mount-based engine remains one toggle away.
- **ROCK-aware copying** (v1.1): if the destination is a Roon ROCK server with Roon
  Server running, the copy is blocked — copying under a live server can hang it. The
  app offers to stop Roon Server for you, runs the copy, then offers to start it
  again so it imports everything in one clean pass. Migrating a big library over
  several runs? Leave Roon Server stopped **between** runs too — a NUC busy
  importing thousands of fresh tracks can drop off the network entirely and
  look like a hardware fault ([HELP.md](HELP.md) has the full story).

There's also a **File Commander** (the Browse tab): a two-pane file manager
that talks to your server directly through the built-in engine — browse,
rename, make folders, move and copy between your Mac and the server (or
around the server itself), delete, and export a folder as a zip. It's
faster and steadier than Finder against an old Roon ROCK, and mounts
nothing.

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

This app deletes files — that's its job. It's provided free, **as is, with no
warranty of any kind, express or implied**, and no liability is accepted for any
loss of data or other damage arising from its use. Deletes default to the Trash
and are confirmed twice, but you should **back up your library before letting
this (or any) tool loose on it**. See [LICENSE](LICENSE) for the full terms (MIT).

The app's own code is MIT; the built-in network engine uses the LGPL-licensed
AMSMB2/libsmb2 libraries — see [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## Notes

- The scanner never modifies your library. Nothing is written or deleted until you
  explicitly run a delete or copy, and deletes are confirmed twice.
- The app is not sandboxed, so it can read the folder you pick and delete files.
  macOS may prompt once for access to certain folders — click Allow.
- If your source lives in iCloud with "Optimize Storage" on, download the files first
  (Finder → right-click the folder → Download Now), or some tracks may read as unreadable.
- Duplicate matching runs at three strictness levels (Strict / Balanced / Aggressive) —
  see [USAGE.md](USAGE.md) for what each level actually compares.
- If the Xcode project file itself ever refuses to open, there's a rebuild recipe in
  [docs/xcode-recovery.md](docs/xcode-recovery.md).
