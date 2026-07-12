# API keys & the services Music Librarian uses

Music Librarian identifies your music and fills in tags, credits and cover art
by looking it up against free public music databases. Most of these need no
account. **One of them — AcoustID — needs a free key that you provide**, and one
more (Discogs) works better if you add a free token.

You enter these in **Music Librarian ▸ Settings** (⌘,). They're stored in your
Mac's **Keychain** — never in the app itself — and are only ever sent to the
service they belong to.

Without an AcoustID key the app still works: it cleans tags, removes duplicates
and organises your library. It just can't *identify* unknown tracks, fill
missing credits, or fetch missing artwork until you add one.

---

## AcoustID — track identification (free key required)

**What it does.** AcoustID recognises a track from a short acoustic
"fingerprint" of the audio, so it can identify a song even when the tags are
wrong, missing, or just say "Track 03". Music Librarian computes the fingerprint
on your Mac (using Chromaprint) and sends **only the fingerprint** — never your
audio files.

**Why you need it.** It's the foundation of the Identify step. Credit-filling
and missing-artwork lookup build on the identity it returns.

**Free-tier limits.** Free. Look-ups are limited to about **3 per second**. A
large library is processed steadily within that limit — there's no daily cap.

**Get a key:** register an application at
<https://acoustid.org/new-application> (name it anything, e.g. "Music
Librarian"), then copy the **API key** it shows you into Settings.

---

## Discogs — extra release credits (free token, optional)

**What it does.** Discogs adds detailed release credits — performers,
producers, engineers — plus catalogue numbers and label info that MusicBrainz
sometimes doesn't have.

**Why it's optional.** MusicBrainz already supplies the core credits without it.
Adding a Discogs token makes the Credits step richer and faster.

**Free-tier limits.** **25 requests/minute** unauthenticated, or **60/minute**
with a free personal token (which also authenticates your requests).

**Get a token:** sign in at Discogs and generate a **personal access token** at
<https://www.discogs.com/settings/developers>, then paste it into Settings.

---

## MusicBrainz & the Cover Art Archive — core data + covers (no key)

**What they do.** MusicBrainz is the main identity/metadata database; the Cover
Art Archive supplies album covers linked to MusicBrainz releases. Both are free
and need no account.

**Contact (optional).** MusicBrainz asks every app to include a **contact** — an
email address or a URL — in each request, so they can reach you if one of your
queries misbehaves. It's not a login and grants no extra access. Set yours in
Settings, or leave it blank to use the app's default.

**Free-tier limits.** About **1 request/second**. Music Librarian paces itself
to stay under this automatically.

---

## Apple iTunes Search — fallback cover art (no key)

Used only to find a cover when the Cover Art Archive doesn't have one. It's a
public endpoint with no key; the app matches on title so it never attaches the
wrong cover.

---

## Where your keys are stored

In the macOS **Keychain**, under the service `com.local.musiclibrarian.apikeys`.
They are not written into the app bundle, the app's preferences, or any log.
Clearing a field in Settings deletes it from the Keychain.

Developers building from source can instead put keys in `Secrets.xcconfig` (see
`Secrets.xcconfig.example`); those are used only as a fallback when the Keychain
is empty, and **must be left blank in any build you distribute**.
