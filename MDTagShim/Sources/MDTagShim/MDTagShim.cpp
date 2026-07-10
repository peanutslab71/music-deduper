#include "MDTagShim.h"

#include <cstdlib>
#include <cstring>
#include <cctype>
#include <string>

#include <taglib/fileref.h>
#include <taglib/tstring.h>
#include <taglib/tag.h>
#include <taglib/mpegfile.h>
#include <taglib/id3v2tag.h>
#include <taglib/id3v2header.h>
#include <taglib/textidentificationframe.h>
#include <taglib/attachedpictureframe.h>
#include <taglib/tpropertymap.h>

static bool hasSuffixCI(const char *p, const char *ext) {
    size_t lp = std::strlen(p), le = std::strlen(ext);
    if (lp < le) return false;
    for (size_t i = 0; i < le; i++)
        if (std::tolower((unsigned char)p[lp - le + i]) != (unsigned char)ext[i]) return false;
    return true;
}

static char *dupString(const TagLib::String &s) {
    std::string u = s.to8Bit(true);  // UTF-8
    char *out = (char *)std::malloc(u.size() + 1);
    if (out) std::memcpy(out, u.c_str(), u.size() + 1);
    return out;
}

// Map a field name to its ID3v2 text-frame ID. Returns nullptr if unknown.
static const char *frameIdFor(const char *field) {
    if (std::strcmp(field, "artist") == 0)      return "TPE1";
    if (std::strcmp(field, "album") == 0)       return "TALB";
    if (std::strcmp(field, "albumartist") == 0) return "TPE2";
    if (std::strcmp(field, "title") == 0)       return "TIT2";
    if (std::strcmp(field, "track") == 0)       return "TRCK";
    if (std::strcmp(field, "composer") == 0)    return "TCOM";
    if (std::strcmp(field, "lyricist") == 0)    return "TEXT";
    if (std::strcmp(field, "label") == 0)       return "TPUB";
    if (std::strcmp(field, "conductor") == 0)   return "TPE3";
    if (std::strcmp(field, "date") == 0)        return "TDRC";
    return nullptr;
}

// Read a field from the generic tag (works for any format via FileRef).
static TagLib::String genericGet(const TagLib::Tag *t, const char *field) {
    if (std::strcmp(field, "artist") == 0)      return t->artist();
    if (std::strcmp(field, "album") == 0)       return t->album();
    if (std::strcmp(field, "title") == 0)       return t->title();
    if (std::strcmp(field, "track") == 0)       return t->track() ? TagLib::String(std::to_string(t->track())) : TagLib::String();
    // albumartist has no generic accessor
    return TagLib::String();
}

static void genericSet(TagLib::Tag *t, const char *field, const TagLib::String &v) {
    if (std::strcmp(field, "artist") == 0)      t->setArtist(v);
    else if (std::strcmp(field, "album") == 0)  t->setAlbum(v);
    else if (std::strcmp(field, "title") == 0)  t->setTitle(v);
    else if (std::strcmp(field, "track") == 0)  t->setTrack((unsigned int)std::atoi(v.toCString(true)));
}

extern "C" char *md_get_field(const char *path, const char *field) {
    if (path == nullptr || field == nullptr) return nullptr;
    const char *frameId = frameIdFor(field);
    // MP3: read the exact ID3v2 frame so it matches what we write
    if (hasSuffixCI(path, ".mp3") && frameId) {
        TagLib::MPEG::File f(path);
        if (f.isValid() && f.ID3v2Tag()) {
            const auto &frames = f.ID3v2Tag()->frameList(frameId);
            if (!frames.isEmpty()) {
                TagLib::String s = frames.front()->toString();
                if (!s.isEmpty()) return dupString(s);
            }
        }
        return nullptr;
    }
    TagLib::FileRef f(path);
    if (!f.isNull() && f.tag()) {
        TagLib::String s = genericGet(f.tag(), field);
        if (!s.isEmpty()) return dupString(s);
    }
    return nullptr;
}

extern "C" int md_set_field(const char *path, const char *field, const char *value) {
    if (path == nullptr || field == nullptr || value == nullptr) return -3;
    const char *frameId = frameIdFor(field);
    if (frameId == nullptr && !hasSuffixCI(path, ".mp3")) {
        // fall through to generic for non-mp3 known fields
    }
    TagLib::String v(value, TagLib::String::UTF8);

    // MP3: replace only the one text frame, keep the ID3v2 version, disturb nothing else.
    if (hasSuffixCI(path, ".mp3")) {
        if (frameId == nullptr) return -4;  // unsupported field for mp3
        TagLib::MPEG::File f(path);
        if (!f.isValid()) return -1;
        TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
        unsigned int mv = tag->header()->majorVersion();
        TagLib::ID3v2::Version ver = (mv >= 4) ? TagLib::ID3v2::v4 : TagLib::ID3v2::v3;
        tag->removeFrames(frameId);
        // an empty value clears the field (removes the frame) — so undoing a
        // gap-fill that started blank leaves no empty frame behind
        if (!v.isEmpty()) {
            auto *frame = new TagLib::ID3v2::TextIdentificationFrame(frameId, TagLib::String::UTF16);
            frame->setText(v);
            tag->addFrame(frame);  // tag takes ownership
        }
        bool ok = f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, ver, TagLib::File::DoNotDuplicate);
        return ok ? 0 : -2;
    }

    // Other formats: generic setter changes only that field; TagLib preserves the rest.
    TagLib::FileRef f(path);
    if (f.isNull() || !f.tag()) return -1;
    genericSet(f.tag(), field, v);
    return f.save() ? 0 : -2;
}

// Add a performer credit (name + instrument/role). Uses TagLib's property map,
// which routes "PERFORMER:role" to the TMCL musician-credits frame. Merges into
// the existing properties so nothing else is disturbed.
extern "C" int md_add_performer(const char *path, const char *name, const char *role) {
    if (path == nullptr || name == nullptr || role == nullptr) return -3;
    if (!hasSuffixCI(path, ".mp3")) return -4;   // mp3 for now
    TagLib::MPEG::File f(path);
    if (!f.isValid()) return -1;
    TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
    unsigned int mv = tag->header()->majorVersion();
    TagLib::ID3v2::Version ver = (mv >= 4) ? TagLib::ID3v2::v4 : TagLib::ID3v2::v3;
    TagLib::PropertyMap props = tag->properties();
    TagLib::String key = TagLib::String("PERFORMER:") + TagLib::String(role, TagLib::String::UTF8);
    props.insert(key, TagLib::StringList(TagLib::String(name, TagLib::String::UTF8)));
    tag->setProperties(props);
    bool ok = f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, ver, TagLib::File::DoNotDuplicate);
    return ok ? 0 : -2;
}

// Remove a performer credit added earlier (for undo). Erases the PERFORMER:role
// entry (TagLib upper-cases the role in the property key).
extern "C" int md_remove_performer(const char *path, const char *name, const char *role) {
    if (path == nullptr || name == nullptr || role == nullptr) return -3;
    if (!hasSuffixCI(path, ".mp3")) return -4;
    TagLib::MPEG::File f(path);
    if (!f.isValid()) return -1;
    TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
    unsigned int mv = tag->header()->majorVersion();
    TagLib::ID3v2::Version ver = (mv >= 4) ? TagLib::ID3v2::v4 : TagLib::ID3v2::v3;
    TagLib::PropertyMap props = tag->properties();
    TagLib::String key = (TagLib::String("PERFORMER:") + TagLib::String(role, TagLib::String::UTF8)).upper();
    props.erase(key);
    tag->setProperties(props);
    bool ok = f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, ver, TagLib::File::DoNotDuplicate);
    return ok ? 0 : -2;
}

// Does the file already have embedded cover art? 1 = yes, 0 = no.
extern "C" int md_has_artwork(const char *path) {
    if (path == nullptr) return -3;
    if (hasSuffixCI(path, ".mp3")) {
        TagLib::MPEG::File f(path);
        if (!f.isValid() || !f.ID3v2Tag()) return 0;
        return f.ID3v2Tag()->frameList("APIC").isEmpty() ? 0 : 1;
    }
    return 0;   // other formats: treated as "unknown / no" for now (mp3 gap-fill)
}

// Embed a front cover, replacing any existing one. Keeps the ID3 version.
extern "C" int md_set_artwork(const char *path, const char *data, int len, const char *mime) {
    if (path == nullptr || data == nullptr || len <= 0) return -3;
    if (!hasSuffixCI(path, ".mp3")) return -4;
    TagLib::MPEG::File f(path);
    if (!f.isValid()) return -1;
    TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
    unsigned int mv = tag->header()->majorVersion();
    TagLib::ID3v2::Version ver = (mv >= 4) ? TagLib::ID3v2::v4 : TagLib::ID3v2::v3;
    tag->removeFrames("APIC");
    auto *pic = new TagLib::ID3v2::AttachedPictureFrame();
    pic->setMimeType(TagLib::String(mime != nullptr ? mime : "image/jpeg"));
    pic->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
    pic->setPicture(TagLib::ByteVector(data, (unsigned int)len));
    tag->addFrame(pic);   // tag takes ownership
    bool ok = f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, ver, TagLib::File::DoNotDuplicate);
    return ok ? 0 : -2;
}

// Remove embedded cover art (for undo of an added cover).
extern "C" int md_remove_artwork(const char *path) {
    if (path == nullptr) return -3;
    if (!hasSuffixCI(path, ".mp3")) return -4;
    TagLib::MPEG::File f(path);
    if (!f.isValid()) return -1;
    TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
    unsigned int mv = tag->header()->majorVersion();
    TagLib::ID3v2::Version ver = (mv >= 4) ? TagLib::ID3v2::v4 : TagLib::ID3v2::v3;
    tag->removeFrames("APIC");
    bool ok = f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, ver, TagLib::File::DoNotDuplicate);
    return ok ? 0 : -2;
}

extern "C" char *md_get_artist(const char *path) { return md_get_field(path, "artist"); }
extern "C" int md_set_artist(const char *path, const char *artist) { return md_set_field(path, "artist", artist); }
