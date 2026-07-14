#ifndef MD_TAG_SHIM_H
#define MD_TAG_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Supported field names (case-sensitive):
     "artist", "album", "albumartist", "title", "track",
     "composer", "label", "conductor", "date"
   All edits are surgical: only the named field's frame changes; the ID3 version
   and every other frame (year, rating, cover art, custom tags) are preserved. */

/// Read a field. Returns a malloc'd UTF-8 string the caller must free(), or NULL.
char *md_get_field(const char *path, const char *field);

/// Set a field, losslessly. Returns 0 on success, negative on error.
int md_set_field(const char *path, const char *field, const char *value);

/// Add a performer credit (name + instrument/role) to the musician-credits list.
/// mp3 (ID3 TMCL), m4a/aac (MP4), flac/ogg (Vorbis PERFORMER). 0 = ok, neg = error.
int md_add_performer(const char *path, const char *name, const char *role);

/// Remove a performer credit (for undo). Returns 0 on success, negative on error.
int md_remove_performer(const char *path, const char *name, const char *role);

/// Whether a performer credit (exact name + role) is already present. 1 = yes, 0 = no.
/// Lets a gap-fill avoid adding a duplicate credit when run more than once.
int md_has_performer(const char *path, const char *name, const char *role);

/// Embedded cover art. has: 1=any picture present, 0=none. set: embed a FRONT
/// cover (jpeg/png bytes), replacing existing art. remove: strip cover art (undo).
/// Works for mp3 (ID3 APIC), m4a/aac/mp4 (covr atom), flac (picture block).
/// 0 = ok, negative = error.
int md_has_artwork(const char *path);
int md_set_artwork(const char *path, const char *data, int len, const char *mime);
int md_remove_artwork(const char *path);

/// Front-cover awareness (for the "art is present but typed 'Other', so players
/// hide it" case). has_front: 1 if a picture is specifically type Front Cover.
/// artwork_type: the primary picture's ID3/FLAC picture-type int (3 = front,
/// 0 = other, …), or -1 if none. set_artwork_type: retag the primary picture's
/// type WITHOUT touching its bytes (non-destructive, so promotion is reversible).
int md_has_front_cover(const char *path);
int md_artwork_type(const char *path);
int md_set_artwork_type(const char *path, int type);

/// Copy the primary embedded picture's bytes so a cover we're about to replace can
/// be backed up (making the replace reversible). Returns a malloc'd buffer the
/// caller must free(), sets *outLen to its size and *outType to the picture-type
/// int, or returns NULL if the file has no art.
char *md_copy_artwork(const char *path, int *outLen, int *outType);

/* Back-compat convenience wrappers for the artist field. */
char *md_get_artist(const char *path);
int md_set_artist(const char *path, const char *artist);

#ifdef __cplusplus
}
#endif

#endif /* MD_TAG_SHIM_H */
