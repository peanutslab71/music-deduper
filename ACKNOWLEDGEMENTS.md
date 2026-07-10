# Acknowledgements

Music Deduper's own source code is MIT licensed (see [LICENSE](LICENSE)).

From v1.3 the app includes a built-in SMB network engine built on two
open-source libraries, both licensed under the **GNU Lesser General Public
License v2.1**:

- **[AMSMB2](https://github.com/amosavian/AMSMB2)** — Swift SMB2/3 client
  framework, © Amir Abbas Mousavian and contributors.
- **[libsmb2](https://github.com/sahlberg/libsmb2)** — SMB2/3 userspace
  client library, © Ronnie Sahlberg and contributors (bundled inside
  AMSMB2).

The full LGPL 2.1 text is available at
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>.

Because these libraries are LGPL, the **combined application binary** is
distributed under terms that satisfy the LGPL — the library is linked as a
separate framework inside the app bundle, and this complete source
repository (including the build configuration that produces the app) is
public, so anyone can rebuild the app with a modified version of the
library. The app's *own* code remains MIT.

## Tag reading and writing (Perfect)

The **Perfect** feature reads and writes the artist tags stored inside music
files. This is done directly with **[TagLib](https://taglib.org/)**, the
open-source tag reader/writer, dual-licensed under **LGPL 2.1 / MPL 1.1**:

- TagLib is bundled as source via
  **[CXXTagLib](https://github.com/sbooth/CXXTagLib)** (© Stephen F. Booth).
- A small in-repo shim, `MDTagShim`, wraps TagLib to change only the one tag
  field (the artist) while preserving the tag version and every other frame —
  a surgical, lossless edit.
- **[SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)** (© Stephen F.
  Booth, **MIT**) is also linked; it bundles TagLib and some audio codec
  libraries, some of which (e.g. LAME, mpg123) are **LGPL 2.1**.

As with the SMB engine above, the combined binary satisfies these licenses:
this complete source repository and its build configuration are public, so
anyone can rebuild the app against a modified version of any bundled library.
The app's own code remains MIT.

## SMB network engine

The app uses a lightly patched fork of AMSMB2, published at
<https://github.com/peanutslab71/AMSMB2> (branch `guest-anonymous-session`).
The single change: an empty password now produces an anonymous/guest SMB
session instead of an NTLM exchange with an empty-password hash, matching
the macOS client's guest behaviour — some embedded NAS/streamer firmware
rejects the latter. The change has been offered upstream. libsmb2 is
unmodified.
