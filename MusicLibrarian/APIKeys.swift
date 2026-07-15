//
//  APIKeys.swift
//  MusicLibrarian
//
//  User-supplied API credentials: a small Keychain wrapper, a nonisolated
//  accessor the identify code reads off the main thread, an ObservableObject
//  store the Settings window binds to, and the Settings UI itself.
//
//  Why this exists: Music Librarian identifies tracks against free public
//  services (AcoustID, MusicBrainz, Discogs). AcoustID needs a free key and
//  Discogs an optional token. A downloaded copy ships with NO keys, so each
//  user supplies their own here — stored in the macOS Keychain, never in the
//  app bundle. (A developer build may still bake keys via Secrets.xcconfig;
//  those act only as a fallback when the Keychain is empty.)
//

import SwiftUI
import Security

// MARK: - Keychain (tiny generic-password wrapper)

enum Keychain {
    private static let service = "com.local.musiclibrarian.apikeys"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func set(_ value: String, _ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { SecItemDelete(base as CFDictionary); return }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base; add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Effective keys (nonisolated — safe to read from the identify actor)

/// The values the networking code actually uses. Each is the user's Keychain
/// entry if set, otherwise the value baked into the build via Secrets.xcconfig
/// (empty in a public release). Reads touch only Keychain + the app bundle, so
/// they're safe off the main thread.
enum APIKeys {
    static let acoustAccount = "acoustid_api_key"
    static let discogsAccount = "discogs_token"
    static let contactAccount = "musicbrainz_contact"

    /// A valid MusicBrainz contact when the user hasn't set one — the project
    /// page, which their guidelines accept in place of an email.
    static let defaultContact = "https://github.com/peanutslab71/music-librarian"

    static var acoustID: String { effective(Keychain.get(acoustAccount), bundle: "ACOUSTID_API_KEY") }
    static var discogs: String { effective(Keychain.get(discogsAccount), bundle: "DISCOGS_TOKEN") }
    static var contact: String {
        let v = (Keychain.get(contactAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? defaultContact : v
    }

    private static func effective(_ stored: String?, bundle: String) -> String {
        let s = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return (Bundle.main.object(forInfoDictionaryKey: bundle) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Store the Settings window binds to

@MainActor
final class APICredentials: ObservableObject {
    static let shared = APICredentials()

    @Published var acoustIDKey: String { didSet { Keychain.set(acoustIDKey, APIKeys.acoustAccount) } }
    @Published var discogsToken: String { didSet { Keychain.set(discogsToken, APIKeys.discogsAccount) } }
    @Published var contact: String { didSet { Keychain.set(contact, APIKeys.contactAccount) } }

    private init() {
        acoustIDKey = Keychain.get(APIKeys.acoustAccount) ?? ""
        discogsToken = Keychain.get(APIKeys.discogsAccount) ?? ""
        contact = Keychain.get(APIKeys.contactAccount) ?? ""
    }

    // "Set" means the networking code has a usable value (Keychain OR a
    // fallback baked into this build), not just that the field is non-empty.
    var acoustIDIsSet: Bool { !APIKeys.acoustID.isEmpty }
    var discogsIsSet: Bool { !APIKeys.discogs.isEmpty }
}

// MARK: - Open the standard Settings window from anywhere (macOS 13+)

/// SwiftUI's `openSettings` environment action is macOS 14+, so drive the
/// standard menu action by selector — its name changed in Ventura, so try the
/// new one first and fall back to the old.
@MainActor func openAppSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @EnvironmentObject private var creds: APICredentials

    var body: some View {
        Form {
            Section {
                KeyField(
                    title: "AcoustID API key", required: true,
                    text: $creds.acoustIDKey, isSet: creds.acoustIDIsSet,
                    help: "AcoustID identifies a track from a short acoustic fingerprint of the audio, even when the tags are wrong or missing. Fingerprints are computed on your Mac — only the fingerprint is sent, never your music. It's free.\n\nRate limit: about 3 look-ups per second. A large library is processed steadily within that limit.",
                    url: "https://acoustid.org/new-application", getLabel: "Register a free application → get a key")
            } header: {
                Text("Identification")
            } footer: {
                Text("Required to identify unknown tracks, fill credits and fetch missing cover art. Without it, the library is still cleaned, de-duplicated and organised — identification is skipped.")
            }

            Section {
                KeyField(
                    title: "Discogs personal token", required: false,
                    text: $creds.discogsToken, isSet: creds.discogsIsSet,
                    help: "Discogs adds detailed release credits (performers, producers, engineers) and catalogue/label info that MusicBrainz sometimes lacks. Optional — MusicBrainz still supplies core credits without it.\n\nRate limit: 25 requests/minute unauthenticated, or 60/minute with a free personal token.",
                    url: "https://www.discogs.com/settings/developers", getLabel: "Generate a personal token")
            } header: {
                Text("Extra credits — optional")
            } footer: {
                Text("A token raises the rate limit and authenticates requests, so credit-filling is faster and more complete.")
            }

            Section {
                TextField("you@example.com — or leave blank", text: $creds.contact)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("MusicBrainz contact — optional")
            } footer: {
                Text("MusicBrainz and the Cover Art Archive are free and need no key, but ask every app to include a contact (an email or URL) so they can reach you if a query misbehaves. Not a login. Leave blank to use the app default. Limited to about 1 request/second.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("MusicBrainz & the Cover Art Archive — track data, credits and cover art", systemImage: "checkmark.circle")
                    Label("Deezer — extra cover art and full tracklists for finding missing tracks", systemImage: "checkmark.circle")
                    Label("iTunes Search — extra cover art", systemImage: "checkmark.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Also used — no key needed")
            } footer: {
                Text("These free services need no sign-up. AcoustID above is the only key you have to register for; a Discogs token is optional.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 660)
    }
}

/// One credential row: label + required/optional tag + "?" explainer + status
/// pill, a paste field with a reveal toggle, and a link to where to get it.
private struct KeyField: View {
    let title: String
    let required: Bool
    @Binding var text: String
    let isSet: Bool
    let help: String
    let url: String
    let getLabel: String

    @State private var reveal = false
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.medium)
                Text(required ? "required" : "optional")
                    .font(.caption2).foregroundStyle(required ? .orange : .secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((required ? Color.orange : Color.gray).opacity(0.15)))
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showHelp) {
                        Text(help).font(.callout).padding(14).frame(width: 320)
                    }
                Spacer()
                statusPill
            }
            HStack(spacing: 6) {
                Group {
                    if reveal { TextField("Paste your key", text: $text) }
                    else { SecureField("Paste your key", text: $text) }
                }
                .textFieldStyle(.roundedBorder)
                Toggle(isOn: $reveal) {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
                .toggleStyle(.button).help(reveal ? "Hide" : "Reveal")
            }
            Link(destination: URL(string: url)!) {
                Label(getLabel, systemImage: "arrow.up.right.square")
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Image(systemName: isSet ? "checkmark.circle.fill" : "exclamationmark.circle")
            Text(isSet ? "Set" : "Not set")
        }
        .font(.caption2)
        .foregroundStyle(isSet ? .green : .orange)
    }
}
