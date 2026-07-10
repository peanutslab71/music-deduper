# Metadata field mapping — how Perfect must route data into tags

This is the reference for the identify / gap-fill features. It maps each piece of
data we can get from the APIs to the correct tag field in each file format, and to
what Roon (and other servers) actually read. The goal is simple: **put every value
in the field it belongs in, and never conflate two different concepts.**

Sources: MusicBrainz Picard tag-mapping; Roon "File Tag Best Practice" and
"Metadata Model" knowledge-base; MusicBrainz API; AcoustID web service; Cover Art
Archive.

## The golden rules

1. **Artist ≠ performer ≠ composer.** They are three different things and live in
   three different fields. The single most common way tools corrupt a library is
   dumping performers or composers into the artist field.
   - **Artist** = who the track is *billed to* (the headline act).
   - **Performer** = a musician who played on it (a sideman), with an instrument.
   - **Composer** = who wrote it.
2. **Never join names with a comma.** Real names contain commas ("Earth, Wind &
   Fire", "Crosby, Stills & Nash", "Emerson, Lake & Palmer"). Roon explicitly warns
   that a comma delimiter breaks artist/composer/label parsing. Multiple values must
   be **separate tag values** (multiple ID3 frames / null-separated in ID3v2.4, or
   repeated Vorbis fields), never one comma-joined string.
3. **Don't invert names.** "Wolfgang Amadeus Mozart", not "Mozart, Wolfgang
   Amadeus" — Roon matches the natural form.
4. **A sideman is a credit, not a co-artist.** Adding "Lester Young (tenor sax)" to
   a Billie Holiday track means adding a *performer credit*, not changing the artist
   to "Billie Holiday, Lester Young".
5. **Filling a blank is safe; changing an existing value needs review.**

## Field → tag mapping

| Concept | ID3v2.4 (mp3) | Vorbis (flac/ogg) | MP4 (m4a) | Roon reads |
|---|---|---|---|---|
| Artist (billing) | TPE1 | ARTIST | ©ART | ARTIST / TPE1 |
| Album artist | TPE2 | ALBUMARTIST | aART | ALBUMARTIST / TPE2 |
| Composer | TCOM | COMPOSER | ©wrt | COMPOSER / TCOM |
| Lyricist / writer | TEXT | LYRICIST | ----:…:LYRICIST | (writer credits) |
| Conductor | TPE3 | CONDUCTOR | ----:…:CONDUCTOR | CONDUCTOR / TPE3 |
| Ensemble (classical) | — | ENSEMBLE | ----:…:ENSEMBLE | ENSEMBLE |
| Soloist (classical) | — | SOLOIST(S) | ----:…:SOLOIST | SOLOIST / SOLOISTS |
| Performer + instrument | **TMCL** (role→name pairs) | PERFORMER="Name (role)" or PERSONNEL="Name - role" | ----:…:PERFORMER | PERSONNEL, TMCL, TIPL, IPLS, INVOLVEDPEOPLE |
| Producer / engineer / mixer | **TIPL** (function→name pairs) | PRODUCER / ENGINEER / MIXER | ----:…:PRODUCER etc. | TIPL, IPLS, INVOLVEDPEOPLE, PERSONNEL |
| Remixer | TPE4 | REMIXER | ----:…:REMIXER | — |
| Record label | TPUB | LABEL | ----:…:LABEL | LABEL |
| Catalog number | TXXX:CATALOGNUMBER | CATALOGNUMBER | ----:…:CATALOGNUMBER | CATALOGNUMBER |
| ISRC | TSRC | ISRC | ----:…:ISRC | — |
| Barcode / UPC | TXXX:BARCODE | BARCODE | ----:…:BARCODE | UPC |
| Release date | TDRC | DATE | ©day | YEAR / date |
| Original release date | TDOR | ORIGINALDATE | ----:…:ORIGINALDATE | ORIGINALRELEASEDATE |
| Track number | TRCK ("n/total") | TRACKNUMBER (+TRACKTOTAL) | trkn | TRACKNUM |
| Disc number | TPOS | DISCNUMBER (+DISCTOTAL) | disk | — |
| Genre | TCON | GENRE | ©gen | GENRE |
| Grouping | GRP1 | GROUPING | ©grp | — |
| Work (classical) | TXXX:WORK / TIT1 | WORK | ----:…:WORK | WORK |
| Movement name | MVNM | MOVEMENTNAME | ©mvn | PART |
| Movement number | MVIN | MOVEMENT | ©mvi | — |
| MusicBrainz Recording ID | UFID:http://musicbrainz.org | MUSICBRAINZ_TRACKID / …RECORDINGID | ----:…:MusicBrainz Recording Id | (matching) |
| MusicBrainz Release ID | TXXX:MusicBrainz Album Id | MUSICBRAINZ_ALBUMID | ----:…:MusicBrainz Album Id | (matching) |
| MusicBrainz Artist ID | TXXX:MusicBrainz Artist Id | MUSICBRAINZ_ARTISTID | ----:…:MusicBrainz Artist Id | (matching) |
| AcoustID | TXXX:Acoustid Id | ACOUSTID_ID | ----:…:Acoustid Id | — |

Notes:
- **TMCL** (Musician Credits List, v2.4) stores pairs of *(instrument, name)* — the
  correct home for "Lester Young / tenor saxophone". **TIPL** (Involved People List)
  stores *(function, name)* for producer/engineer/etc. **IPLS** is the v2.3 combined
  equivalent. TagLib supports these.
- MP4 has no standard atom for performer-with-instrument; taggers (and Roon) use
  freeform `----:com.apple.iTunes:PERFORMER` style atoms.
- Roon's **PERSONNEL** format is `Name - Role`, and the role must be one Roon
  recognises (Flute, Violin, Producer, Recording, Liner Notes, …).
- **Classical**: Roon says to prefer ENSEMBLE / SOLOIST / PERSONNEL over ARTIST, and
  to use WORK / PART for multi-movement grouping — the area Roon+MusicBrainz handle
  worst, so it needs deliberate care.

## Where each value comes from

- **AcoustID** (`/v2/lookup`, meta=recordings+releasegroups): the fingerprint →
  recording match, with the recording's **artist credit** (the billing) and
  candidate release-groups (albums). This is the artist/title/album layer. It does
  **not** return performers, composers, labels, or per-release track numbers.
- **MusicBrainz** (`/ws/2`), looked up by the recording MBID AcoustID returns:
  - `inc=artist-credits` → the billed artist(s) — for the **artist** field.
  - `inc=artist-rels` on the recording → **performers** (instrument/vocal roles),
    producer/engineer → PERFORMER / TMCL / TIPL.
  - `inc=work-rels` → the linked **work**; then a work lookup `inc=artist-rels`
    gives **composer** and **lyricist**.
  - `inc=releases` / release lookup `inc=labels` → **label** + **catalog number** +
    the **track number** on the chosen release.
- **Cover Art Archive** (`coverartarchive.org/release/<mbid>` or
  `/release-group/<mbid>`): the **artwork**.

## Perfect's write plan (per field)

- **Artist**: write only the **billed artist credit** from MusicBrainz. If the
  credit is genuinely multiple artists, write them as **multiple tag values**, never
  comma-joined. Changing an existing artist goes through the review queue.
- **Performers**: fetched from recording relationships, written to TMCL / PERSONNEL
  as *(role, name)* — a green "+" gap-fill. **Sidemen never touch the artist field.**
- **Composer / lyricist**: from work relationships → TCOM / TEXT. Gap-fill when
  blank; review when overwriting.
- **Label / catalog number**: from the chosen release → TPUB / CATALOGNUMBER.
- **Track number**: from the chosen release, not guessed by position.
- **Title / album**: canonical form from MusicBrainz (including proper typography).
- **Artwork**: Cover Art Archive → embedded image frame (APIC / covr), reversible.

## Second enrichment source: Discogs

MusicBrainz is the canonical identity (CC0, fingerprint-linked) but is often thin
on **credits** — for many recordings its performer list is empty. **Discogs**
fills that gap: it's strong on personnel, production credits, labels/pressings,
and genres/styles, and — critically — **its data is released CC0 (public domain)**,
so we can embed it into files, exactly like MusicBrainz and unlike Gracenote
(whose licence forbids persisting its metadata into user files).

**Why not Gracenote:** excellent data, but its licence only permits using the API
*inside* a licensed app, not extracting and writing its metadata permanently into
the user's files — which is Perfect's whole job. It's also a closed SDK and can't
ship in a public open-source repo. CC0 sources (MusicBrainz, Discogs, Cover Art
Archive) are the only ones we can legally bake into tags.

**Matching (no fuzzy search):** the MusicBrainz release we already look up carries
a curated URL relationship to its Discogs release (`inc=url-rels`, relation type
`discogs`). We take that Discogs release ID directly — an exact, human-verified
link — and read the Discogs release. This avoids Discogs text-search ambiguity
entirely. Fallback (only if no MB link): Discogs search, which needs a token.

**What Discogs supplies** (`GET api.discogs.com/releases/{id}`):
- `extraartists` — credits with free-text roles. Route by role:
  - instrument/vocal roles (e.g. "Tenor Saxophone", "Guitar", "Vocals") → **performer** (TMCL)
  - "Producer", "Engineer", "Mixed By", "Mastered By" → **production credits** (TIPL)
  - "Written-By", "Composed By" → **composer**; "Lyrics By" → **lyricist**
- `labels` → label + catalog number (backup to MusicBrainz)
- `genres` / `styles` → genre
- `year` → date (backup)

**Precedence:** MusicBrainz first for canonical identity and any field it has;
Discogs tops up **blank** fields and adds the production/performer credits MB
lacks. Never overwrite an existing value (same gap-fill rule as everything else).

**Access:** reads are unauthenticated at 25 requests/min; a free personal token
raises this to 60/min and enables search. A `User-Agent` header is required. If
used, the token lives in the gitignored `Secrets.xcconfig` like the AcoustID key.
Per-release caching keeps it to one Discogs read per album.

## Known bug to fix (current code)

`Identify.swift` builds the artist as
`(rec.artists ?? []).compactMap { $0.name }.joined(separator: ", ")` — this
comma-joins multiple credited names into one string, exactly the anti-pattern Roon
warns against (and it mis-models sidemen as co-artists). Fix: take the **primary**
billed artist for the artist field, keep multiples as separate values, and route
any additional performers to the performer/credits field via the MusicBrainz
relationship lookup.
