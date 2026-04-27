# Llamas Cookbook — Share Extension Plan

> **Goal:** make Llamas Cookbook appear as a destination in iOS share
> sheets across all apps. User in Safari, Reddit, Files, Mail, etc. →
> hit Share → see "Llamas Cookbook" in the apps row → tap → recipe
> lands in Import Preview ready to save.
>
> **Companion to:** [Recipe-Sharing.md](./Recipe-Sharing.md),
> [CLAUDE.md](./CLAUDE.md), [PROJECT.md](./PROJECT.md).
>
> **Audience:** Claude Code session, picking up to implement.

---

## 0. The 60-second summary

A Share Extension is a separate iOS app extension target — own
bundle id (`com.llamascookbook.app.shareext`), own provisioning
profile, runs in a different process when invoked from another app's
share sheet. Different mechanism from the URL scheme we already use:

| Mechanism | Direction | Triggers when |
|---|---|---|
| **URL scheme** (`llamascookbook://...`) | OUT → IN | Recipient taps a `llamascookbook://recipe/...` link in any app |
| **Document type** (`.llamarecipe`) | OUT → IN | Recipient taps a `.llamarecipe` file in Files / Mail attachment / AirDrop accept |
| **Share Extension** (this plan) | OTHER APPS → IN | Sender (in any app) hits Share, picks Llamas Cookbook as destination |

The extension is a **transparent passthrough**: it reads the shared
input (URL or `.llamarecipe` file), writes a handoff to the main app,
and dismisses. The main app does the actual import via the existing
flow. No SwiftData in the extension, no duplicated parsers, no UI
beyond a brief loading-spinner moment.

Two handoff paths:

- **URLs** → encode as `llamascookbook://share-url/<base64url>`
  deep link, open the main app via `extensionContext.open(_:)`. Main
  app's `onOpenURL` decodes and routes to the existing
  `RecipeURLImporter` flow.
- **`.llamarecipe` files** → write bytes to an **App Group shared
  container** (`group.com.llamascookbook.app`), open the main app
  with `llamascookbook://share-incoming/<uuid>`. Main app reads from
  the shared container, runs `RecipeShare.decode + materialize`,
  presents Import Preview, deletes the shared file on success.

**Effort:** ~1 dev-day for the extension target + handoff code, ~½
day for Apple Developer Portal + GitHub Actions wiring, ~½ day for
tests + polish. Three CI cycles minimum (the provisioning dance is
finicky and often needs two retries to settle).

---

## 1. What "share extension" means in practice

After this lands, the user can:

1. Find a recipe in **Safari** → Share button → "Llamas Cookbook" appears in the destinations row → tap → app opens to the URL Import flow with the URL pre-filled. Tap Save → recipe imported via the existing `RecipeURLImporter` + AI parser path.
2. Receive a **`.llamarecipe` file** in Files or Mail (saved earlier from a chat) → long-press → Share → "Llamas Cookbook" → app opens to Import Preview. Tap Save → recipe lands in Library.
3. Same for **third-party recipe-blog reader apps** that surface URLs through the share sheet. Reddit shares the post URL; Apollo shares the comment URL; etc.

Out of scope (see §17): plain text snippets, image-as-recipe (food
photo OCR), multi-recipe batch imports, share extension UI beyond a
brief loading flash.

---

## 2. Architecture — transparent passthrough

```
┌──────────────────────┐
│ Source app (Safari, │
│ Files, Mail, etc.)   │
└──────────┬───────────┘
           │ user picks "Llamas Cookbook" from share sheet
           ▼
┌──────────────────────┐
│ ShareViewController  │  separate process, no SwiftData,
│ (extension target)   │  no main-app code paths
└──────────┬───────────┘
           │ reads NSItemProvider; URL or .llamarecipe?
           │
   ┌───────┴───────┐
   ▼               ▼
URL form       File form
   │               │
   │               │ writes bytes to App Group shared container
   │               │ at share-inbox/<uuid>.llamarecipe
   │               │
   │ encodes URL   │
   │ as base64url  │
   │ in deep link  │
   ▼               ▼
llamascookbook://    llamascookbook://
share-url/<b64url>   share-incoming/<uuid>
   │               │
   └───────┬───────┘
           │ extensionContext.open(deepLink)
           │ + extensionContext.completeRequest(...)
           ▼
┌──────────────────────┐
│ Main app's RootView  │
│   .onOpenURL { ... } │
└──────────┬───────────┘
           │ routes by host:
           │   share-url       → ImportRecipeView prefilled with URL
           │   share-incoming  → read shared container → RecipeShare
           │                     → RecipeImportPreviewView
           ▼
┌──────────────────────┐
│ Import Preview sheet │  same UI as PR 3's AirDrop / chat-link path
│  Save / Cancel       │
└──────────────────────┘
```

Why transparent passthrough rather than full processing in the
extension:

1. **No duplicated logic.** The main app already has
   `RecipeShare.decode`, `RecipeShare.materialize`, the Import
   Preview UI, the `RecipeURLImporter` + AI parser pipeline.
   Reimplementing any of those in the extension would drift over time.
2. **No SwiftData in the extension.** SwiftData with App Groups is
   doable but complex (shared `ModelContainer` lifecycle,
   cross-process write coordination). We don't want to ship the
   first PR of the extension already requiring the data layer to
   move.
3. **Smaller binary, faster boot.** Share extensions have tight
   memory budgets (~120MB before iOS terminates them) and need to
   launch fast. A minimal extension stays well clear of those limits.
4. **Easier testing.** Extension is a pure I/O bridge — read input,
   encode handoff, dismiss. Main app's import flow is unchanged from
   PR 3.

---

## 3. New target — `LlamasCookbookShareExtension`

| Setting | Value |
|---|---|
| Bundle id | `com.llamascookbook.app.shareext` |
| Display name | `Save to Llamas Cookbook` (shows as the label in share sheets) |
| Target type | `app-extension` |
| Min iOS | 18.0 (matches main app) |
| Code signing | Manual, separate provisioning profile |
| Entitlements | App Groups (`group.com.llamascookbook.app`) |
| Sources | `ShareExtension/` + `Sources/Shared/SharedContainer.swift` |

Two new entitlements files (one per target — same content, different
file because Xcode signs each target separately):

```
ios-native/Resources/LlamasCookbook.entitlements             ← main app
ios-native/ShareExtension/LlamasCookbookShareExtension.entitlements  ← extension
```

Both files declare the same App Group:

```xml
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.llamascookbook.app</string>
    </array>
</dict>
```

The App Group is the shared container — both processes can read and
write files under
`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.llamascookbook.app")`.

---

## 4. Activation rule — when does the extension appear?

iOS only shows the extension in share sheets when its activation
rule matches the shared content. We declare two accepted types:
`public.url` (web URLs, file URLs to text files Safari might share)
and `com.llamascookbook.recipe` (our own UTType from PR 1).

`ShareExtension/Info.plist`:

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>NSExtensionActivationRule</key>
        <string>SUBQUERY (
            extensionItems,
            $extensionItem,
            SUBQUERY (
                $extensionItem.attachments,
                $attachment,
                ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url"
                || ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.llamascookbook.recipe"
            ).@count > 0
        ).@count > 0</string>
    </dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
</dict>
```

The predicate form (raw `SUBQUERY (...)`) is more reliable than the
dictionary form (`NSExtensionActivationSupportsWebURLWithMaxCount`)
because the dictionary form has known issues with custom UTIs — it
silently ignores `com.llamascookbook.recipe` and only triggers on
the web-URL fallback.

---

## 5. `ShareViewController` — entry point

`ShareExtension/ShareViewController.swift`. Subclasses
`UIViewController` (not `SLComposeServiceViewController` — the SLC
template ships a pre-built UI we don't want).

```swift
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let llamaRecipeUTI = "com.llamascookbook.recipe"

    override func viewDidLoad() {
        super.viewDidLoad()
        // Cream background matches the main app's chrome so the brief
        // flash before we hand off doesn't read as broken.
        view.backgroundColor = UIColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await processInput() }
    }

    private func processInput() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first
        else {
            await complete(success: false)
            return
        }

        // Custom UTI is more specific — check first so a `.llamarecipe`
        // never falls through to the URL branch.
        if attachment.hasItemConformingToTypeIdentifier(Self.llamaRecipeUTI) {
            await handleLlamaRecipeFile(attachment)
        } else if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            await handleURL(attachment)
        } else {
            await complete(success: false)
        }
    }

    private func handleURL(_ attachment: NSItemProvider) async {
        do {
            let raw = try await attachment.loadItem(forTypeIdentifier: UTType.url.identifier)
            guard let url = raw as? URL else {
                await complete(success: false); return
            }
            let encoded = Data(url.absoluteString.utf8).base64URLEncodedString()
            guard let deepLink = URL(string: "llamascookbook://share-url/\(encoded)")
            else { await complete(success: false); return }
            await openMainApp(with: deepLink)
        } catch {
            await complete(success: false)
        }
    }

    private func handleLlamaRecipeFile(_ attachment: NSItemProvider) async {
        do {
            let raw = try await attachment.loadItem(forTypeIdentifier: Self.llamaRecipeUTI)
            let data: Data
            if let url = raw as? URL {
                data = try Data(contentsOf: url)
            } else if let direct = raw as? Data {
                data = direct
            } else {
                await complete(success: false); return
            }

            let id = UUID().uuidString
            let inbox = SharedContainer.shareInboxURL()
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let fileURL = inbox.appendingPathComponent("\(id).llamarecipe")
            try data.write(to: fileURL)

            guard let deepLink = URL(string: "llamascookbook://share-incoming/\(id)")
            else { await complete(success: false); return }
            await openMainApp(with: deepLink)
        } catch {
            await complete(success: false)
        }
    }

    @MainActor
    private func openMainApp(with url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            extensionContext?.open(url) { _ in
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                cont.resume()
            }
        }
    }

    @MainActor
    private func complete(success: Bool) async {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
```

**No UI beyond the cream-colored backdrop.** The user picks Llamas
Cookbook from the share sheet → sees a brief cream flash (~250–400
ms while NSItemProvider resolves) → main app launches with the
import flow. Apple's HIG approves this passthrough pattern for share
extensions whose entire job is "send to main app."

---

## 6. URL handoff — `llamascookbook://share-url/<base64url>`

The URL form encodes the original web URL as base64url and tucks it
into a deep link the main app already knows how to receive (via
`onOpenURL`).

Sender side — `ShareViewController.handleURL(_:)` (§5).

Receiver side — `RootView.onOpenURL` adds a new branch:

```swift
} else if url.scheme == "llamascookbook", url.host == "share-url" {
    let parts = url.pathComponents.filter { $0 != "/" }
    guard let encoded = parts.first,
          let data = Data(base64URLEncoded: encoded),
          let urlString = String(data: data, encoding: .utf8),
          let webURL = URL(string: urlString)
    else { return }
    pendingShareURLImport = webURL  // drives the URL-import sheet
}
```

The `RecipeURLImporter` + AI parser flow then runs as if the user
had pasted the URL into the existing Library FAB → "Import from
text" sheet.

---

## 7. File handoff — App Group shared container

The URL transport doesn't fit `.llamarecipe` payloads with photos
(megabytes of base64 would blow past every URL transport's practical
limit). Instead the extension writes the bytes to an App Groups
shared directory and hands the main app a UUID via deep link.

```
group.com.llamascookbook.app/
    share-inbox/
        <uuid-1>.llamarecipe        ← written by extension, deleted by main app on import
        <uuid-2>.llamarecipe
        ...
```

Sender side — `ShareViewController.handleLlamaRecipeFile(_:)` (§5).

Receiver side — `RootView.onOpenURL` adds a second branch:

```swift
} else if url.scheme == "llamascookbook", url.host == "share-incoming" {
    let parts = url.pathComponents.filter { $0 != "/" }
    guard let id = parts.first else { return }
    let fileURL = SharedContainer.shareInboxURL().appendingPathComponent("\(id).llamarecipe")
    do {
        let data = try Data(contentsOf: fileURL)
        let envelope = try RecipeShare.decode(fileData: data)
        pendingShareImport = envelope     // drives Import Preview sheet
        // Clean up the shared-container file once we've decoded —
        // even if the user cancels the preview, we've already got
        // the envelope in memory.
        try? FileManager.default.removeItem(at: fileURL)
    } catch {
        shareImportError = error.localizedDescription
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

### 7.1 Shared-container lifecycle

The shared container can accumulate stale files if:
- User invokes the extension but never opens the main app
- User backgrounds the main app before the import handler fires
- Extension crashes mid-write

The main app sweeps `share-inbox/` on launch, deleting any
`.llamarecipe` entries older than 24 hours. Mirrors how iOS itself
manages temp directories — best-effort cleanup, never load-bearing.

```swift
// In LlamasCookbookApp.init or RootView's first .task:
SharedContainer.sweepShareInbox(olderThan: 24 * 60 * 60)
```

---

## 8. Apple Developer Portal setup

This is the **only step that requires going outside the codebase**.
~5–15 minutes in your browser. Follow in order — each step depends
on the previous.

### 8.1 Create the App Group identifier

1. Open <https://developer.apple.com/account/resources/identifiers/list>.
2. Switch the dropdown in the top right from **App IDs** to
   **App Groups**.
3. Click the **+** button to register a new identifier.
4. Choose **App Groups** → Continue.
5. Description: `Llamas Cookbook shared container`.
6. Identifier: `group.com.llamascookbook.app`.
7. Continue → Register.

### 8.2 Add the App Group to the existing main app App ID

1. Switch the dropdown back to **App IDs**.
2. Click `com.llamascookbook.app` (the main app).
3. Scroll to **App Groups** in the capabilities list. Check the
   checkbox if it isn't already, then click **Configure** to its
   right.
4. Tick `group.com.llamascookbook.app`. Continue → Save.
5. **You'll see a yellow banner**: "Modifying the App ID will require
   you to re-create or modify your provisioning profiles." That's
   expected — we'll regenerate the main profile in §8.5.

### 8.3 Create the Share Extension App ID

1. Still on the App IDs page, click **+** to register a new App ID.
2. Choose **App** → Continue.
3. Description: `Llamas Cookbook Share Extension`.
4. Bundle ID: **Explicit** → `com.llamascookbook.app.shareext`.
5. Capabilities: scroll to **App Groups** and check it. Click
   **Configure** and tick `group.com.llamascookbook.app`.
6. Continue → Register.

### 8.4 Create the Share Extension provisioning profile

1. Open <https://developer.apple.com/account/resources/profiles/list>.
2. Click **+** to create a new profile.
3. Type: **App Store** (under Distribution). Continue.
4. App ID: `com.llamascookbook.app.shareext` (the one you just
   created). Continue.
5. Certificate: pick the same iOS Distribution certificate the main
   app uses. Continue.
6. Profile Name: `Llamas Cookbook Share Extension`.
7. Generate → Download.

### 8.5 Regenerate the main app provisioning profile

The main App ID changed in §8.2 (App Group added), so the existing
profile is stale.

1. Still on the Profiles page, find the existing main-app distribution
   profile (its name should match what's stored in the
   `MAIN_PROFILE_NAME` env var in the CI workflow — typically
   something like `Llamas Cookbook Distribution`).
2. Click it → **Edit** → click **Save** without changing anything.
   This re-issues the profile with the updated entitlements.
3. Download the regenerated profile.

### 8.6 Encode both profiles as base64

You'll be on Windows, so PowerShell is the easiest path:

```powershell
# Main app — overwrites the value of the existing IOS_PROVISIONING_PROFILE_BASE64 secret
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\Llamas_Cookbook_Distribution.mobileprovision")) | Set-Clipboard
# Paste the clipboard into the GitHub secret immediately so you don't lose it.

# Share extension — new secret IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\Llamas_Cookbook_Share_Extension.mobileprovision")) | Set-Clipboard
```

### 8.7 Update GitHub Actions secrets

Open <https://github.com/SeptemberFinesse/The-Llamas-Cookbook/settings/secrets/actions>.

| Secret | Action | Value |
|---|---|---|
| `IOS_PROVISIONING_PROFILE_BASE64` | **Update** | base64 from §8.6 (regenerated main profile) |
| `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64` | **Add new** | base64 from §8.6 (extension profile) |

The widget profile (`IOS_WIDGET_PROVISIONING_PROFILE_BASE64`) is
unchanged.

### 8.8 Verify before pushing

The next CI run is the moment of truth. The signing dance often
needs one retry to settle. If the build fails at the archive step,
check the failure log for:

- `errSecInternalComponent` → certificate not in keychain. Should
  not happen unless the cert was rotated.
- `Provisioning profile 'X' has app ID 'Y' which does not match`
  → the App ID and profile were created but the main App ID's App
  Group entitlement didn't propagate. Re-edit-and-save the main
  profile (§8.5) and re-encode.
- `Provisioning profile doesn't include the app-groups entitlement`
  → §8.2's App Group config didn't save. Repeat §8.2 and §8.5.

---

## 9. `project.yml` additions

### 9.1 Main app target

Add to `targets.LlamasCookbookNative.settings.base`:

```yaml
        CODE_SIGN_ENTITLEMENTS: Resources/LlamasCookbook.entitlements
```

Add to `targets.LlamasCookbookNative.dependencies`:

```yaml
      - target: LlamasCookbookShareExtension
        embed: true
        codeSign: true
```

### 9.2 Share Extension target (new)

```yaml
  LlamasCookbookShareExtension:
    type: app-extension
    platform: iOS
    sources:
      - path: ShareExtension
      # SharedContainer is needed by both targets; live in Sources/Shared
      # alongside TimerAttributes (the existing cross-target file).
      - path: Sources/Shared/SharedContainer.swift
      # base64URL extension is on Data — extension shares with the main
      # app via this file.
      - path: Sources/Shared/Base64URL.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.llamascookbook.app.shareext
        PRODUCT_NAME: LlamasCookbookShareExtension
        TARGETED_DEVICE_FAMILY: "1"
        INFOPLIST_FILE: ShareExtension/Info.plist
        SKIP_INSTALL: YES
        ENABLE_USER_SCRIPT_SANDBOXING: YES
        SWIFT_STRICT_CONCURRENCY: minimal
        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_ENTITLEMENTS: ShareExtension/LlamasCookbookShareExtension.entitlements
        PROVISIONING_PROFILE_SPECIFIER: "$(SHARE_EXT_PROFILE_NAME)"
```

`Sources/Shared/Base64URL.swift` is extracted from the bottom of
`Lib/RecipeShare.swift` so the extension can share the encode/decode
helpers without dragging in SwiftData / `Recipe` types.

---

## 10. CI workflow updates

`.github/workflows/ios-native-ci.yml` already handles two
provisioning profiles (main + widget). Adding the share extension
follows the same pattern.

Three additions:

1. **New profile install step**, mirroring the existing widget
   profile install:

   ```yaml
   - name: Install share-extension provisioning profile
     env:
       PROFILE_BASE64: ${{ secrets.IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64 }}
     run: |
       echo "$PROFILE_BASE64" | base64 --decode > "$RUNNER_TEMP/shareext.mobileprovision"
       PROFILE_UUID=$(security cms -D -i "$RUNNER_TEMP/shareext.mobileprovision" \
         | plutil -extract UUID raw -)
       PROFILE_NAME=$(security cms -D -i "$RUNNER_TEMP/shareext.mobileprovision" \
         | plutil -extract Name raw -)
       mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
       cp "$RUNNER_TEMP/shareext.mobileprovision" \
         "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
       echo "SHARE_EXT_PROFILE_NAME=$PROFILE_NAME" >> "$GITHUB_ENV"
   ```

2. **Pass `SHARE_EXT_PROFILE_NAME` to xcodebuild archive** as a
   top-level build setting, matching how `MAIN_PROFILE_NAME` and
   `WIDGET_PROFILE_NAME` are already passed.

3. **No App Group setup in CI itself** — the entitlement is purely
   a build-time signing artifact. Apple Developer Portal handles the
   group registration; CI just needs the regenerated profiles.

---

## 11. Main-app receiving end

Two new branches in `RootView.onOpenURL`:

```swift
.onOpenURL { url in
    // ... existing cook deep-link branch (PR pre-this-plan) ...
    // ... existing recipe deep-link / file branches (PR 3) ...

    if url.scheme == "llamascookbook", url.host == "share-url" {
        handleShareURL(url)
    } else if url.scheme == "llamascookbook", url.host == "share-incoming" {
        handleShareIncoming(url)
    }
}

private func handleShareURL(_ url: URL) {
    let parts = url.pathComponents.filter { $0 != "/" }
    guard let encoded = parts.first,
          let data = Data(base64URLEncoded: encoded),
          let urlString = String(data: data, encoding: .utf8),
          let webURL = URL(string: urlString)
    else { return }
    // Reuses the existing import-from-URL flow that the FAB
    // already presents. We hand it a pre-filled URL and let it run.
    editor.importFromText(prefilledURL: webURL)
}

private func handleShareIncoming(_ url: URL) {
    let parts = url.pathComponents.filter { $0 != "/" }
    guard let id = parts.first else { return }
    let fileURL = SharedContainer.shareInboxURL().appendingPathComponent("\(id).llamarecipe")
    do {
        let data = try Data(contentsOf: fileURL)
        let envelope = try RecipeShare.decode(fileData: data)
        // Reuses PR 3's Import Preview presentation.
        pendingShareImport = envelope
        try? FileManager.default.removeItem(at: fileURL)
    } catch {
        shareImportError = error.localizedDescription
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

`editor.importFromText(prefilledURL:)` is a small new API on
`EditorCoordinator` — surfaces the existing import sheet with the
URL field pre-populated. The sheet's existing AI / regex flow runs
unchanged from there.

---

## 12. File inventory

### New files (5)

```
ios-native/ShareExtension/Info.plist                                    ← §4
ios-native/ShareExtension/ShareViewController.swift                     ← §5
ios-native/ShareExtension/LlamasCookbookShareExtension.entitlements     ← §3
ios-native/Resources/LlamasCookbook.entitlements                        ← §3 (main app)
ios-native/Sources/Shared/SharedContainer.swift                         ← §7
ios-native/Sources/Shared/Base64URL.swift                               ← extracted from Lib/RecipeShare.swift
```

### Modified files (4)

```
ios-native/project.yml                                          ← §9 — new target + entitlements paths
ios-native/Sources/App/RootView.swift                           ← §11 — new onOpenURL branches
ios-native/Sources/App/EditorCoordinator.swift                  ← §11 — importFromText(prefilledURL:) overload
ios-native/Sources/Lib/RecipeShare.swift                        ← drop the base64url Data extension (now in Sources/Shared/Base64URL.swift)
.github/workflows/ios-native-ci.yml                             ← §10 — new profile install + xcodebuild arg
```

### Untouched (verify, don't edit)

- `Sources/Models/*` — extension doesn't see SwiftData.
- `Sources/Lib/RecipeShare.swift` — schema/encode/decode body
  unchanged; only the base64url extension moves out.
- `Sources/Lib/RecipeURLImporter.swift` /
  `RecipeImporter.swift` / `RecipeAIParser.swift` — main app's
  existing import pipeline is reused as-is.
- `Sources/Views/Library/RecipeImportPreviewView.swift` (PR 3) —
  same UI handles the Share Extension's `.llamarecipe` payload.

---

## 13. DRY checklist — what's shared, where

| Concern | Single source of truth | Used by |
|---|---|---|
| App Group identifier | `SharedContainer.appGroupID` | Extension write path, main app read path, entitlements files (string-duplicated — must stay in sync) |
| Shared inbox path | `SharedContainer.shareInboxURL()` | Extension write, main app read, main app launch sweep |
| base64url Data encoding | `Data.base64URLEncodedString()` / `Data(base64URLEncoded:)` in `Sources/Shared/Base64URL.swift` | Main app `RecipeShare.encodeURL/decode(url:)`, extension `ShareViewController.handleURL` |
| Recipe envelope decode | `RecipeShare.decode(fileData:)` | Extension does NOT decode (just hands off bytes); main app decodes after reading from shared inbox |
| Recipe materialize | `RecipeShare.materialize(_:into:)` | Main app only — extension never touches SwiftData |
| URL importer flow | `EditorCoordinator.importFromText(prefilledURL:)` + `RecipeURLImporter` | Library FAB (existing) + main app's `share-url` handler (new) |
| Import Preview UI | `RecipeImportPreviewView` (PR 3) | AirDrop / chat-link path (PR 3) + Share Extension's `share-incoming` path (this PR) |

Three things deliberately **not** unified:

1. **Extension and main app are separate processes.** They don't
   share runtime state — only the App Group container. Concurrent
   reads/writes to the inbox are file-level (we use UUID-prefixed
   filenames so the extension and main app never write to the same
   file).
2. **Extension has no SwiftData.** Even though `RecipeShare.decode`
   doesn't strictly need SwiftData, the extension defers all decode
   work to the main app to keep the extension binary small and the
   memory footprint low. The extension is a transport, not a parser.
3. **`SharedContainer.appGroupID` and the entitlements files are
   string-duplicated.** Three strings of `group.com.llamascookbook.app`
   live in three places (Swift constant + main entitlements + extension
   entitlements). Apple's signing layer requires it; we just have to
   keep them in sync.

---

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Extension's App Group entitlement doesn't match main app's** at signing time | High — share extension installs but `containerURL(...)` returns nil at runtime, every share fails silently | §8.5 main-profile regeneration after adding the App Group; verify both profiles list the App Group entitlement before pushing |
| `extensionContext.open(_:)` returns `false` on iOS 18 | Medium — share completes but main app doesn't launch | The "responder chain" workaround (`UIResponder` walk + `perform(#selector(openURL:)`) is a well-documented fallback. Build it in from day one as a backup path. |
| Stale files accumulate in shared inbox | Low — disk usage creep | §7.1 main-app launch sweep deletes entries > 24h old |
| User picks Llamas Cookbook from share sheet but doesn't have the main app open / installed | iOS handles this — extension only appears if main app is installed | Per Apple's signing rules, an extension can't ship without its containing app. Not a real risk. |
| Extension's 120MB memory ceiling exceeded by a giant `.llamarecipe` (e.g., 50MB photos) | High — extension killed mid-write | We just write the bytes through; we don't decode them. 50MB streamed write to disk is comfortably under the limit. |
| Provisioning profile mismatch on first CI run after §8 | Medium — CI fails | §8.8 walks through the common error patterns; expect 1 retry to settle |
| Activation rule predicate has typo | Medium — extension never appears in share sheets | Test on real device with both URL and `.llamarecipe` content; §15 test #1 + #4 |
| Extension's `viewDidAppear` task runs after `extensionContext` becomes nil | Low (timing-dependent) | Capture `extensionContext` early; the framework holds it for the extension lifecycle |
| iOS UTI cache fails to recognize `com.llamascookbook.recipe` after install | Low — same UTI cache issue from PR 1 | Reinstall workaround. Document. |
| Share Extension UI looks broken because we ship an empty cream view | Cosmetic | Acceptable — the brief flash before main-app launch is < 500ms and the cream matches the main app |

---

## 15. Test plan — must-pass before merge

Real-device walkthrough after CI install:

1. **🚨 Extension appears for URL share.** In Safari, navigate to a
   recipe blog. Hit Share → "Llamas Cookbook" appears in the apps
   row. Tap → main app opens to the URL Import sheet with the URL
   pre-filled.
2. **URL import completes the round trip.** From #1, tap the Import
   Save action → recipe lands in Library, parsed via the existing
   `RecipeURLImporter` + AI flow. Source URL stamped on the recipe.
3. **Extension does NOT appear for unsupported types.** In Photos,
   pick an image, hit Share. Llamas Cookbook does not appear (image
   types don't match the activation predicate).
4. **🚨 Extension appears for `.llamarecipe` share.** From a chat
   message, save a `.llamarecipe` to Files. Long-press the file →
   Share → "Llamas Cookbook" appears. Tap → main app opens to the
   Import Preview (PR 3 UI) with the recipe's title, photos, etc.
5. **`.llamarecipe` import round trip via shared container.** From
   #4, tap Save to Library. Recipe lands with full fidelity (photos
   intact, provenance line shows). Open Files → Llamas Cookbook
   shared container → `share-inbox/` → file deleted (cleanup ran).
6. **🚨 Stale shared-container file is swept on launch.** Manually
   write a stale file to the inbox, set its mtime > 24h ago, force-
   kill the app, relaunch. File is gone after first runloop tick.
7. **Sender side from PR 2 still works.** Open a recipe in Detail,
   hit Share → menu shows file/link/text → AirDrop a `.llamarecipe`
   to a backup device → the Extension on the receiver picks it up
   from Files → import works.
8. **Provisioning regression check.** Existing TestFlight build
   continues to install over older builds without needing a clean
   wipe. (App Group addition triggers a re-issued main profile;
   should be transparent to upgrades.)
9. **Extension memory check.** Share a `.llamarecipe` with 5 large
   gallery photos (~25MB total). Extension completes in < 1s, no
   "extension terminated" toast.
10. **Cancel from share sheet preserves no state.** Pick Llamas
    Cookbook from a Safari share, then immediately swipe to dismiss
    the share sheet before the main app launches. No recipe drafted,
    no shared-inbox files left behind.
11. **Main app cold launch via Share Extension.** Force-kill the
    main app. From Safari, share a URL via Llamas Cookbook. App
    cold-launches into the URL Import flow (not Library, not Detail
    — the deep link routes correctly even from cold).
12. **Concurrent shares.** Send two `.llamarecipe` shares back-to-
    back from Files. Both inbox files written with distinct UUIDs;
    main app handles them serially as the user opens each.

Hold the bar at **#1, #4, #5, #6, #11**. If #9 or #12 wobble, log
and ship.

---

## 16. Sequencing — single PR, manageable scope

**One push.** Mixing this with PR 3 (the import side) doubles the
CI surface during the trickiest part of the rollout (Apple Portal
+ provisioning).

**PR 4 — `feat(share): share extension target`**

- §3 + §9 — new target in `project.yml`, entitlements files for both
  main and extension.
- §4 — `ShareExtension/Info.plist` activation rule.
- §5 — `ShareViewController`.
- §6 + §7 — `SharedContainer` + `Base64URL` in `Sources/Shared/`,
  base64URL extension extracted from `Lib/RecipeShare.swift`.
- §10 — CI workflow updates.
- §11 — main-app `onOpenURL` branches +
  `EditorCoordinator.importFromText(prefilledURL:)`.
- Test plan §15.

Plan **two CI cycles** for this PR — the provisioning profile dance
nearly always wants a retry on first install, even when the §8
checklist is followed cleanly.

---

## 17. Out of scope (deliberately deferred)

- **Plain text snippets in the share extension** — paste-into-Import
  already works. Adding text would expand the activation rule to
  `public.text` and require a third handoff path.
- **Image-as-recipe** (food-photo OCR / VLM extraction) — interesting
  future work but a different feature entirely; not a transport
  question.
- **Multi-recipe batch share** — ties into the `.llamacookbook` zip
  format, which is itself out of scope for the v1 share work.
- **Custom share extension UI** beyond the cream backdrop — Apple
  HIG approves passthrough, and adding compose-style UI conflicts
  with the "main app does the import" pattern.
- **Share Extension as a target for `.llamacookbook` (future)** — when
  multi-recipe bundles ship, add a new UTType + activation rule. Same
  shape, different file extension.
- **Cloud routing from the extension** — when cloud sync ships, the
  extension can post directly to the cloud API rather than handing
  off to the main app. Not v1.

---

## 18. Update these docs after merge

- **CLAUDE.md "Source of truth — read in this order":** add this
  doc to the feature plan list.
- **CLAUDE.md "Capability map":** add a "Share Extension" row
  pointing to `ShareExtension/ShareViewController.swift`.
- **CLAUDE.md "Source layout":** add `ShareExtension/` to the file-
  layout listing alongside `WidgetExtension/`. Add `SharedContainer`
  + `Base64URL` to the `Sources/Shared/` description.
- **CLAUDE.md "Tech stack":** add a row for App Groups
  (`group.com.llamascookbook.app`) under Persistence or a new "IPC"
  row.
- **CLAUDE.md "Signing & CI gotchas":** add the share-extension
  provisioning story (separate App ID, App Group requires both
  profiles to carry the entitlement, recovery from "doesn't include
  app-groups" failures).
- **Recipe-Sharing.md §10:** update the import-state-plumbing section
  to note the additional `share-url` and `share-incoming` URL-scheme
  branches.
- **PROJECT.md / ROADMAP.md:** if "Share Extension" was on the
  roadmap, drop it; if not, no change.
