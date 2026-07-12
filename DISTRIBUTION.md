# Distributing Music Librarian (public, no Gatekeeper warnings)

Goal: a `.dmg` anyone can download and open with **no "unidentified developer" warning**.
That requires a paid Apple Developer account, signing with your **Developer ID**, and
**notarizing** the app (Apple's automated malware scan). Xcode automates most of it.

The project is already set up for this (Hardened Runtime is enabled, which notarization requires).

---

## 1. One-time setup

1. **Enrol in the Apple Developer Program** — https://developer.apple.com/programs/ (US$99/year).
   Approval usually takes minutes to a day.
2. In Xcode: **Settings → Accounts → +** and sign in with that Apple ID.
3. Open the project → select the **MusicLibrarian** target → **Signing & Capabilities**:
   - Tick **Automatically manage signing**.
   - Set **Team** to your developer team.
   (Xcode will create the Developer ID certificate for you the first time you distribute.)

## 2. Archive + notarize (Xcode does the heavy lifting)

1. Set the run destination to **Any Mac** (top toolbar), scheme **MusicLibrarian**, Release.
2. **Product → Archive.** When it finishes, the **Organizer** opens.
3. Click **Distribute App → Direct Distribution** (this is the Developer ID + notarization path;
   older Xcode calls it **Developer ID → Upload**).
4. Xcode signs it, uploads it to Apple for notarization, and (after a few minutes) marks it
   **Ready to distribute**. Click **Export** and save `MusicLibrarian.app` to a folder.
   - Xcode already **stapled** the notarization ticket to the app during export.

## 3. Make the DMG

From this folder, run the script against the exported app:

```bash
chmod +x make_dmg.sh
./make_dmg.sh "/path/to/exported/MusicLibrarian.app"
```

You'll get **`Music Librarian.dmg`** with a drag-to-Applications layout.

## 4. Notarize + staple the DMG itself (recommended)

Stapling the DMG means it passes Gatekeeper even before the app is copied out.

First, store credentials once (use an **app-specific password** from
https://account.apple.com → Sign-In & Security → App-Specific Passwords):

```bash
xcrun notarytool store-credentials "MD_NOTARY" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "abcd-efgh-ijkl-mnop"
```

Then for each release:

```bash
xcrun notarytool submit "Music Librarian.dmg" --keychain-profile "MD_NOTARY" --wait
xcrun stapler staple "Music Librarian.dmg"
```

`--wait` blocks until Apple finishes (usually a few minutes) and prints **Accepted**.

## 5. Verify before you ship

```bash
spctl -a -vvv -t open --context context:primary-signature "Music Librarian.dmg"   # should say: accepted, source=Notarized Developer ID
xcrun stapler validate "Music Librarian.dmg"                                        # should say: The validate action worked
```

Now anyone can download `Music Librarian.dmg`, open it, drag the app to Applications,
and launch it with **no warning**.

---

### Notes
- Your Team ID is on https://developer.apple.com/account under Membership.
- Re-notarize every time you change and re-release the app.
- The app is **not** sandboxed (it needs to read arbitrary folders and delete files).
  That's fine for Developer-ID distribution; only the Mac **App Store** would require sandboxing.
- If notarization is ever rejected, run
  `xcrun notarytool log <submission-id> --keychain-profile "MD_NOTARY"` to see why
  (usually a signing/hardened-runtime detail) and send me the output.
