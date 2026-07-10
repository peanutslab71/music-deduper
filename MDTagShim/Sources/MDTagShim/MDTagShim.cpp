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

extern "C" char *md_get_artist(const char *path) {
    if (path == nullptr) return nullptr;
    // MP3: read straight from the ID3v2 tag so it matches what we write
    if (hasSuffixCI(path, ".mp3")) {
        TagLib::MPEG::File f(path);
        if (f.isValid() && f.ID3v2Tag() && !f.ID3v2Tag()->artist().isEmpty())
            return dupString(f.ID3v2Tag()->artist());
    }
    TagLib::FileRef f(path);
    if (!f.isNull() && f.tag() && !f.tag()->artist().isEmpty())
        return dupString(f.tag()->artist());
    return nullptr;
}

extern "C" int md_set_artist(const char *path, const char *artist) {
    if (path == nullptr || artist == nullptr) return -3;
    TagLib::String value(artist, TagLib::String::UTF8);

    // MP3: touch only the TPE1 frame and keep the existing ID3v2 version, so no
    // other frame (year, rating, cover art, custom tags) is disturbed.
    if (hasSuffixCI(path, ".mp3")) {
        TagLib::MPEG::File f(path);
        if (!f.isValid()) return -1;
        TagLib::ID3v2::Tag *tag = f.ID3v2Tag(true);
        unsigned int mv = tag->header()->majorVersion();
        TagLib::ID3v2::Version v = (mv == 3) ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;
        tag->removeFrames("TPE1");
        auto *frame = new TagLib::ID3v2::TextIdentificationFrame("TPE1", TagLib::String::UTF16);
        frame->setText(value);
        tag->addFrame(frame);  // tag takes ownership
        bool ok = f.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, v, TagLib::File::DoNotDuplicate);
        return ok ? 0 : -2;
    }

    // Other formats (M4A, FLAC, …): the generic tag interface changes only the
    // artist field and TagLib preserves everything else on save.
    TagLib::FileRef f(path);
    if (f.isNull() || !f.tag()) return -1;
    f.tag()->setArtist(value);
    return f.save() ? 0 : -2;
}
