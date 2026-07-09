# Music Deduper — Help

Practical answers for using the app, getting the best copy performance, and
fixing the problems people actually hit. The step-by-step walkthrough of the
wizard lives in [USAGE.md](USAGE.md); this file is for when something is slow,
stuck, or you just want to know what's going on.

---

## The basics

Music Deduper does three jobs, in order, and never touches a file without
asking:

1. **Scan** a music folder and group duplicate tracks together, marking the
   best copy of each as **KEEP** (lossless beats lossy, then higher bitrate,
   then better tags).
2. **Clean up** — send the duplicates to the Trash (keepers are never touched).
3. **Copy** the keepers to a server or NAS as a clean Artist/Album tree.

You can stop after any step. Plenty of people only ever use it to find and
remove duplicates and never copy anything anywhere.

## Copying to a server — how the app protects itself

Network shares — especially over Wi-Fi, especially on small NAS boxes and
Roon ROCK — drop out. The copy step assumes they will:

- **Three files copy at once — four when the link is clean.** On the old SMB
  dialects small servers speak, the per-file back-and-forth costs more than
  the data itself; parallel streams keep the link busy. The count self-tunes:
  after 20 files in a row with no retries it steps up to 4, and drops back
  to 3 the moment anything struggles.
- **Existence checks are per album, not per file.** Before copying, the app
  lists each destination album folder once and remembers the answer, instead
  of asking the server about every file — thousands of round trips saved on
  a big run, and brand-new albums cost nothing to check.
- Every copied file's size is **verified against the source**; a file that
  arrives incomplete is deleted and re-copied.
- A failing file is retried up to **5 times** with increasing waits, and the
  share is **re-mounted automatically** if it has dropped — directly through
  the system mounter, never via Finder, and at most once per 30 seconds, so
  a dead server doesn't get hammered (and Finder doesn't get dragged in).
- If several files in a row fail, the run **pauses itself** — "the server has
  stopped responding" with a **Resume** button — instead of timing out on
  every remaining file. Fix the network (or the server), press Resume, and
  it picks up where it stopped.
- Re-mounts use the server's **IP address**, not its name. When you locate the
  share the app converts the name (e.g. `rock`) to its IP and says so on the
  Copy page — a network that's already misbehaving often can't answer name
  lookups either, so the app doesn't ask it to.
- The share is **nudged every 30 seconds** during a copy so the connection is
  never idle long enough to be dropped.
- A file that fails all its retries is set aside and the copy **moves on**.
  When the run reaches the end, a **sweep pass** automatically retries the
  set-aside files once more (the share has usually recovered by then); any
  that still fail are listed behind the **Retry failed** button.
- **You choose what ships.** On the Review step's Library tab, every album
  has a badge (top-left of the artwork): tick = whole album selected,
  minus = some tracks, empty circle = none. Click the badge to toggle an
  album, open an album for per-track checkboxes, or use All/None in the
  header. Everything is selected by default; the Copy button copies exactly
  the selected count it shows. (Selection affects copying only — Clean up
  always works on the whole library.)
- While a copy or delete runs, the app tells macOS not to throttle it and not
  to put the machine to sleep.

If you see `⟳ Retrying…` lines in the copy log now and then, that's the app
absorbing a network wobble — not a problem. If you see them constantly, read
the performance section below.

## Getting the best copy speed

- **Keep the app's window visible while it copies.** macOS has a feature
  called App Nap that deliberately throttles an app's disk and network
  activity when its window is completely covered or minimised — being merely
  "not in front" is fine, but bury the window and macOS starts slowing the
  app down. Music Deduper opts out of App Nap and additionally declares the
  copy as user-initiated work, but keeping the window at least partly on
  screen is a free extra guarantee. The copy will *survive* being buried —
  retries and reconnects take care of that — it's just slower.
- **Leave "Keep the display awake while copying" ticked if you're on Wi-Fi.**
  When the display sleeps, many Macs also drop the Wi-Fi radio into a
  low-power mode — which is exactly what a long network copy can't afford.
  The checkbox (on the Copy page) keeps the screen on only while a copy is
  actually running.
- **Wired beats Wi-Fi, every time.** A Mac on Wi-Fi talking to a wired server
  will hit a ceiling of a few MB/s on the kind of old SMB dialect small
  servers speak, and Wi-Fi blips are where most mid-copy retries come from.
  For a big first copy (thousands of files), plugging the Mac into ethernet
  for an hour is worth more than every other tweak combined.
- **Don't browse the share in Finder while copying.** Finder generates
  previews and thumbnails, which means opening lots of files — competition
  the little server doesn't need.
- **Roon ROCK users:** the app stops Roon Server before copying (and offers to
  restart it after). That's not just to protect the copy — when Roon Server
  comes back it imports and audio-analyses everything new, which pegs the NUC
  for a while. If the share feels slow *after* a copy, that's Roon working,
  not a fault.

## Making macOS's SMB client behave (the big one)

A few of macOS's SMB client defaults hurt small servers:

- it **cryptographically signs every packet** when the negotiation lands
  that way — pure overhead on a guest share on your own network, and it
  hits small files hardest;
- it tries **multichannel** (parallel connections), which simple servers
  often mishandle, causing stalls and session drops;
- it subscribes to **change notifications** from the server — constant
  chatter that basic servers handle badly.

All three are fixed with one small system config file. The repo includes
[`tune-smb.sh`](tune-smb.sh), which does it with a backup and an undo note,
or do it by hand — open Terminal and paste:

```
printf '[default]\nsigning_required=no\nmc_on=no\nnotify_off=yes\n' | sudo tee /etc/nsmb.conf
```

(One tempting setting to avoid: `max_resp_timeout`. Raising it sounds like
resilience, but it means a hung request blocks whatever issued it — Finder
included — for that long. Leave it at its 30-second default; the app's own
retries handle stalls.)

Then **eject the share in Finder and reconnect** — the setting only applies
to new mounts. Reconnect by IP if you can: Finder → Go → Connect to Server →
`smb://192.168.x.x/YourShare`.

To check what your connection is actually doing, before or after:

```
smbutil statshares -a
```

To undo it all: `sudo rm /etc/nsmb.conf` and remount. The setting affects
every SMB share this Mac mounts, and is safe for home/small-office use; on a
corporate network your IT department may require signing.

Real-world result on the network this was written against (Roon ROCK on a
NUC, Mac on Wi-Fi): folder listings went from many seconds to instant, and a
recursive walk of 2,500 files took 1.8 seconds.

## "Server connections interrupted"

That macOS dialog means the SMB session dropped — the network went away long
enough that the Mac gave up. Click **Ignore**: the app re-mounts the share
itself and carries on, and macOS usually restores the session too. Only use
Disconnect All if you're actually done with the share.

If you see it often, it's almost always the Wi-Fi leg. The SMB config above
reduces how *painful* each drop is; ethernet is what makes them stop.

Technical background: macOS declares an SMB session interrupted after only
10–12 seconds without a server response. So the dialog doesn't mean the
network *died* — any 10-second stall triggers it, and Wi-Fi has several
built-in sources of exactly that kind of stall (next section).

## Wi-Fi stalls: AirDrop, Handoff and friends

A Mac's Wi-Fi card periodically leaves your network's channel to service
other Apple features, and every hop is a brief stall on anything mid-transfer:

- **AirDrop / AirPlay / Handoff** make the Wi-Fi radio hop to their own
  channels every 5–12 seconds while active. During a big copy, turning
  **AirDrop off** (Control Centre) and, if you don't use it, **Handoff off**
  (System Settings → General → AirDrop & Handoff) removes the single biggest
  source of periodic stalls.
- **Location Services** trigger a full Wi-Fi channel scan roughly once a
  minute for apps that use your location — each scan pauses the connection
  briefly. Trimming the list (System Settings → Privacy & Security →
  Location Services) helps.
- **"Private Wi-Fi Address"** (macOS 15 and later): on your *home* network,
  set it to **Fixed** or Off (System Settings → Wi-Fi → Details) — the
  rotating variety can force a mid-transfer network renegotiation.
- Finder writing its folder-view files (`.DS_Store`) onto network shares is
  more chatter a small server doesn't need; Apple's documented switch:
  ```
  defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
  ```

Or skip the whole subject: plug the Mac into ethernet for big copies.

## Common questions

**Does the scan change my library?** No. Nothing is written or deleted until
you explicitly run Clean up or Copy, and deletes are confirmed twice (and go
to the Trash by default).

**Why does it want to stop my Roon Server before copying?** Copying under a
running Roon Server can hang it. The app checks the destination, blocks the
copy while the server runs, offers to stop it for you, and offers to restart
it afterwards so everything imports in one clean pass.

**A file shows "failed after 5 tries" — is it lost?** No — nothing happened
to the source file. The copy just couldn't land it on the server. Press
**Retry failed** when the run finishes; if it keeps failing, check the file
opens on your Mac and the server has disk space.

**Files read as unreadable during scan?** If your library lives in iCloud
with "Optimize Mac Storage" on, download the folder first (right-click →
Download Now).

**macOS asked about the local network / folder access.** Both are one-time
permission prompts: local network access is how the app checks a Roon ROCK's
status, and folder access is how it reads your library. Click Allow.

## Uninstalling

The app is a single self-contained bundle:

1. Quit Music Deduper.
2. Drag **Music Deduper** from Applications to the Trash.
3. Optionally remove its settings (window positions, recent folders, saved
   share address) — open Terminal and run:
   ```
   defaults delete com.local.musicdeduper
   ```
4. If you ran `tune-smb.sh` and want that undone too:
   `sudo rm /etc/nsmb.conf` (your previous config, if any, is at
   `/etc/nsmb.conf.backup`).

That's everything — the app installs no helpers, launch agents, or kernel
anything.

## Still stuck?

Open an issue on the
[GitHub issues page](https://github.com/peanutslab71/music-deduper/issues)
with your macOS version, what the destination is (local folder, NAS, Roon
ROCK), and — for copy problems — a screenshot of the copy log.
