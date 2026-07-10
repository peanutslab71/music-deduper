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
/// mp3 only for now. Returns 0 on success, negative on error.
int md_add_performer(const char *path, const char *name, const char *role);

/// Remove a performer credit (for undo). Returns 0 on success, negative on error.
int md_remove_performer(const char *path, const char *name, const char *role);

/* Back-compat convenience wrappers for the artist field. */
char *md_get_artist(const char *path);
int md_set_artist(const char *path, const char *artist);

#ifdef __cplusplus
}
#endif

#endif /* MD_TAG_SHIM_H */
