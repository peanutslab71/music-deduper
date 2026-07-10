#ifndef MD_TAG_SHIM_H
#define MD_TAG_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Read the artist tag. Returns a malloc'd UTF-8 string the caller must free(),
/// or NULL if there is no artist / the file can't be read.
char *md_get_artist(const char *path);

/// Set the artist tag, preserving the ID3 version and every other frame
/// (surgical, lossless single-field edit). Returns 0 on success, negative on error.
int md_set_artist(const char *path, const char *artist);

#ifdef __cplusplus
}
#endif

#endif /* MD_TAG_SHIM_H */
