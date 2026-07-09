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

- Every copied file's size is **verified against the source**; a file that
  arrives incomplete is deleted and re-copied.
- A failing file is retried up to **5 times** with increasing waits, and the
  share is **re-mounted automatically** if it has dropped.
- Re-mounts use the server's **IP address**, not its name. When you locate the
  share the app converts the name (e.g. `rock`) to its IP and says so on the
  Copy page — a network that's already misbehaving often can't answer name
  lookups either, so the app doesn't ask it to.
- The share is **nudged every 30 seconds** during a copy so the connection is
  never idle long enough to be dropped.
- A file that fails all its retries is set aside and the copy **moves on** —
  a **Retry failed** button at the end re-runs just those files.
- While a copy or delete runs, the app tells macOS not to throttle it and not
  to put the machine to sleep.

If you see `⟳ Retrying…` lines in the copy log now and then, that's the app
absorbing a network wobble — not a problem. If you see them constantly, read
the performance section below.

## Getting the best copy speed

- **Keep the app in front while it copies.** macOS quietly deprioritises
  background apps in several ways the app can only partly opt out of. The
  copy will *survive* being backgrounded — retries and reconnects take care
  of that — but it runs fastest as the frontmost app with the Mac awake.
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

macOS ships with two SMB client behaviours that hurt small servers:

- it **cryptographically signs every packet** when the server allows it —
  pure overhead on a guest share on your own network, and it hits small
  files hardest;
- it tries **multichannel** (parallel connections), which simple servers
  often mishandle, causing stalls and session drops.

Both are fixed with a two-line system config file. The repo includes
[`tune-smb.sh`](tune-smb.sh), which does it with a backup and an undo note,
or do it by hand — open Terminal and paste:

```
printf '[default]\nsigning_required=no\nmc_on=no\n' | sudo tee /etc/nsmb.conf
```

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
