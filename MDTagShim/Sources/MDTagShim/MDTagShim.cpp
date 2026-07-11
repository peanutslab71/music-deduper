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
#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4coverart.h>
#include <taglib/mp4item.h>
#include <taglib/flacfile.h>
#include <taglib/flacpicture.h>
#include <taglib/xiphcomment.h>

static bool hasSuffixCI(const char *p, const char *ext) {
    size_t lp = std::strlen(p), le = std::strlen(ext);
    if (lp < le) return false;
    for (size_t i = 0; i < le; i++)
        if (std::tolower((unsigned char)p[lp - le + i]) != (unsigned char)ext[i]) return false;
    return true;
}

// Which tag container this file uses, chosen by extension.
enum MDKind { MD_MP3, MD_MP4, MD_FLAC, MD_OTHER };
static MDKind kindOf(const char *p) {
    if (hasSuffixCI(p, ".mp3")) return MD_MP3;
    if (hasSuffixCI(p, ".m4a") || hasSuffixCI(p, ".m4p") ||
        hasSuffixCI(p, ".m4b") || hasSuffixCI(p, ".mp4")) return MD_MP4;
    if (hasSuffixCI(p, ".flac")) return MD_FLAC;
    return MD_OTHER;
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

// Save an MPEG file keeping its ID3 version, disturbing nothing else.
static bool saveMpeg(TagLib::MPEG::File &f, TagLib::ID3v2::Tag *tag) {
    unsigned int mv = tag->header()->majorVersion();
    TagLib::ID3v2::Version ver = (mv >= 4) ? TagLib::ID3v2::v4 : TagLib::ID3v2::v3;
    return f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, ver, TagLib::File::DoNotDuplicate);
}

// Add/remove a performer credit, using each format's own convention:
//   • mp3  — ID3 TMCL musician-credits pair (instrument, name), native, via the
//            "PERFORMER:role" property key.
//   • flac — a Vorbis PERFORMER comment valued "name (role)" (the Xiph standard).
//   • mp4  — a freeform PERFORMER atom valued "name (role)" (MP4 has no native
//            per-instrument credit; the ":role" property key is an invalid atom).
// add=true inserts, false erases exactly what was added.
static int performerEdit(const char *path, const char *name, const char *role, bool add) {
    if (path == nullptr || name == nullptr || role == nullptr) return -3;
    TagLib::String nm(name, TagLib::String::UTF8);
    TagLib::String rl(role, TagLib::String::UTF8);
    TagLib::String combined = nm + " (" + rl + ")";   // for flac/mp4
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid()) return -1;
        TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
        TagLib::PropertyMap props = tag->properties();
        TagLib::String key = TagLib::String("PERFORMER:") + rl;
        if (add) props.insert(key, TagLib::StringList(nm));
        else     props.erase(key.upper());   // TagLib upper-cases keys on the way out
        tag->setProperties(props);
        return saveMpeg(f, tag) ? 0 : -2;
    }
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid()) return -1;
        TagLib::Ogg::XiphComment *xiph = f.xiphComment(true);
        if (add) xiph->addField("PERFORMER", combined, false);   // false = append, keep others
        else     xiph->removeFields("PERFORMER", combined);
        return f.save() ? 0 : -2;
    }
    case MD_MP4: {
        TagLib::MP4::File f(path);
        if (!f.isValid() || !f.tag()) return -1;
        auto *tag = f.tag();
        const char *ck = "----:com.apple.iTunes:PERFORMER";
        TagLib::StringList vals;
        if (tag->contains(ck)) vals = tag->item(ck).toStringList();
        if (add) {
            vals.append(combined);
        } else {
            TagLib::StringList kept;
            for (const auto &v : vals) if (v != combined) kept.append(v);
            vals = kept;
        }
        if (vals.isEmpty()) tag->removeItem(ck);
        else tag->setItem(ck, TagLib::MP4::Item(vals));
        return f.save() ? 0 : -2;
    }
    default: return -4;
    }
}

extern "C" int md_add_performer(const char *path, const char *name, const char *role) {
    return performerEdit(path, name, role, true);
}
extern "C" int md_remove_performer(const char *path, const char *name, const char *role) {
    return performerEdit(path, name, role, false);
}

// Does the file already have embedded cover art (any picture)? 1 = yes, 0 = no.
extern "C" int md_has_artwork(const char *path) {
    if (path == nullptr) return -3;
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid() || !f.ID3v2Tag()) return 0;
        return f.ID3v2Tag()->frameList("APIC").isEmpty() ? 0 : 1;
    }
    case MD_MP4: {
        TagLib::MP4::File f(path);
        if (!f.isValid() || !f.tag()) return 0;
        return (f.tag()->contains("covr") && !f.tag()->item("covr").toCoverArtList().isEmpty()) ? 1 : 0;
    }
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid()) return 0;
        return f.pictureList().isEmpty() ? 0 : 1;
    }
    default: return 0;
    }
}

// Is a picture specifically typed Front Cover? 1 = yes, 0 = no.
extern "C" int md_has_front_cover(const char *path) {
    if (path == nullptr) return -3;
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid() || !f.ID3v2Tag()) return 0;
        const auto &frames = f.ID3v2Tag()->frameList("APIC");
        for (auto *fr : frames) {
            auto *pic = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(fr);
            if (pic && pic->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) return 1;
        }
        return 0;
    }
    case MD_MP4:  return md_has_artwork(path);   // MP4 covr has no type; treat as front
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid()) return 0;
        for (auto *pic : f.pictureList())
            if (pic->type() == TagLib::FLAC::Picture::FrontCover) return 1;
        return 0;
    }
    default: return 0;
    }
}

// The primary picture's type int (ID3/FLAC: 3=front, 0=other, …), or -1 if none.
extern "C" int md_artwork_type(const char *path) {
    if (path == nullptr) return -3;
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid() || !f.ID3v2Tag()) return -1;
        const auto &frames = f.ID3v2Tag()->frameList("APIC");
        if (frames.isEmpty()) return -1;
        auto *pic = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frames.front());
        return pic ? (int)pic->type() : -1;
    }
    case MD_MP4:  return md_has_artwork(path) == 1 ? 3 : -1;
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid() || f.pictureList().isEmpty()) return -1;
        return (int)f.pictureList().front()->type();
    }
    default: return -1;
    }
}

// Retag the primary picture's type WITHOUT touching its bytes. Non-destructive,
// so promoting an "Other" picture to Front Cover is fully reversible.
extern "C" int md_set_artwork_type(const char *path, int type) {
    if (path == nullptr) return -3;
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid() || !f.ID3v2Tag()) return -1;
        const auto &frames = f.ID3v2Tag()->frameList("APIC");
        if (frames.isEmpty()) return -1;
        auto *pic = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frames.front());
        if (!pic) return -1;
        pic->setType((TagLib::ID3v2::AttachedPictureFrame::Type)type);
        return saveMpeg(f, f.ID3v2Tag()) ? 0 : -2;
    }
    case MD_MP4:  return 0;   // no type field — already effectively front
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid() || f.pictureList().isEmpty()) return -1;
        f.pictureList().front()->setType((TagLib::FLAC::Picture::Type)type);
        return f.save() ? 0 : -2;
    }
    default: return -4;
    }
}

// Copy the primary picture's bytes (malloc'd; caller frees). Sets *outLen and
// *outType. Returns NULL if there's no art.
static char *copyBytes(const TagLib::ByteVector &bv) {
    char *out = (char *)std::malloc(bv.size());
    if (out) std::memcpy(out, bv.data(), bv.size());
    return out;
}
extern "C" char *md_copy_artwork(const char *path, int *outLen, int *outType) {
    if (outLen) *outLen = 0;
    if (outType) *outType = -1;
    if (path == nullptr) return nullptr;
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid() || !f.ID3v2Tag()) return nullptr;
        const auto &frames = f.ID3v2Tag()->frameList("APIC");
        if (frames.isEmpty()) return nullptr;
        auto *pic = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frames.front());
        if (!pic) return nullptr;
        TagLib::ByteVector bv = pic->picture();
        if (outLen) *outLen = (int)bv.size();
        if (outType) *outType = (int)pic->type();
        return copyBytes(bv);
    }
    case MD_MP4: {
        TagLib::MP4::File f(path);
        if (!f.isValid() || !f.tag() || !f.tag()->contains("covr")) return nullptr;
        auto list = f.tag()->item("covr").toCoverArtList();
        if (list.isEmpty()) return nullptr;
        TagLib::ByteVector bv = list.front().data();
        if (outLen) *outLen = (int)bv.size();
        if (outType) *outType = 3;
        return copyBytes(bv);
    }
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid() || f.pictureList().isEmpty()) return nullptr;
        auto *pic = f.pictureList().front();
        TagLib::ByteVector bv = pic->data();
        if (outLen) *outLen = (int)bv.size();
        if (outType) *outType = (int)pic->type();
        return copyBytes(bv);
    }
    default: return nullptr;
    }
}

// Embed a FRONT cover, replacing any existing art.
extern "C" int md_set_artwork(const char *path, const char *data, int len, const char *mime) {
    if (path == nullptr || data == nullptr || len <= 0) return -3;
    const char *m = (mime != nullptr) ? mime : "image/jpeg";
    TagLib::ByteVector bytes(data, (unsigned int)len);
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid()) return -1;
        TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
        tag->removeFrames("APIC");
        auto *pic = new TagLib::ID3v2::AttachedPictureFrame();
        pic->setMimeType(TagLib::String(m));
        pic->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
        pic->setPicture(bytes);
        tag->addFrame(pic);   // tag takes ownership
        return saveMpeg(f, tag) ? 0 : -2;
    }
    case MD_MP4: {
        TagLib::MP4::File f(path);
        if (!f.isValid() || !f.tag()) return -1;
        bool png = (std::strstr(m, "png") != nullptr) || (std::strstr(m, "PNG") != nullptr);
        TagLib::MP4::CoverArt::Format fmt = png ? TagLib::MP4::CoverArt::PNG : TagLib::MP4::CoverArt::JPEG;
        TagLib::MP4::CoverArtList list;
        list.append(TagLib::MP4::CoverArt(fmt, bytes));
        f.tag()->setItem("covr", TagLib::MP4::Item(list));
        return f.save() ? 0 : -2;
    }
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid()) return -1;
        f.removePictures();
        auto *pic = new TagLib::FLAC::Picture();
        pic->setType(TagLib::FLAC::Picture::FrontCover);
        pic->setMimeType(TagLib::String(m));
        pic->setData(bytes);
        f.addPicture(pic);   // file takes ownership
        return f.save() ? 0 : -2;
    }
    default: return -4;
    }
}

// Remove embedded cover art (for undo of an added cover).
extern "C" int md_remove_artwork(const char *path) {
    if (path == nullptr) return -3;
    switch (kindOf(path)) {
    case MD_MP3: {
        TagLib::MPEG::File f(path);
        if (!f.isValid()) return -1;
        TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
        tag->removeFrames("APIC");
        return saveMpeg(f, tag) ? 0 : -2;
    }
    case MD_MP4: {
        TagLib::MP4::File f(path);
        if (!f.isValid() || !f.tag()) return -1;
        f.tag()->removeItem("covr");
        return f.save() ? 0 : -2;
    }
    case MD_FLAC: {
        TagLib::FLAC::File f(path);
        if (!f.isValid()) return -1;
        f.removePictures();
        return f.save() ? 0 : -2;
    }
    default: return -4;
    }
}

extern "C" char *md_get_artist(const char *path) { return md_get_field(path, "artist"); }
extern "C" int md_set_artist(const char *path, const char *artist) { return md_set_field(path, "artist", artist); }
