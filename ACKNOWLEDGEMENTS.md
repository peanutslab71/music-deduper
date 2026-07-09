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

No changes have been made to either library; the app uses AMSMB2 as
published, fetched by version via Swift Package Manager
(see `MusicDeduper.xcodeproj` package references for the exact version).
