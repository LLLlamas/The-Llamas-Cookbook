import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(UserAccount.self) private var userAccount
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.modelContext) private var modelContext
    @State private var session = CookingSession()
    @State private var editor = EditorCoordinator()
    @State private var navContext = NavigationContext()
    /// Programmatic-path binding for the library NavigationStack. Lets
    /// `LibraryView`'s existing `NavigationLink(value: recipe)` taps
    /// keep working while also giving us a hook to push Detail
    /// programmatically — used after a share import is Saved so the
    /// recipient lands directly on the new recipe's Detail view rather
    /// than back on the library list.
    @State private var libraryPath = NavigationPath()

    /// Decoded incoming share envelope. Non-nil → present
    /// `RecipeImportPreviewView` as a sheet so the user can review +
    /// Save / Cancel. Set by the `share-url` and `.llamarecipe` file
    /// branches in `.onOpenURL` below; cleared on dismiss.
    @State private var pendingShareImport: LCRecipeShareV1?
    /// User-facing error string for a malformed / unsupported share.
    /// Drives the share-import alert. Set when `RecipeShare.decode`
    /// throws — `unsupportedSchemaVersion` (sender on a newer build),
    /// `decodeFailure` (corrupt bytes), `malformedShareURL` (URL
    /// shape doesn't match the expected pattern).
    @State private var shareImportError: String?

    var body: some View {
        NavigationStack(path: $libraryPath) {
            LibraryView()
        }
        .tint(appearance.accentColor)
        .environment(session)
        .environment(editor)
        .environment(navContext)
        .overlay(alignment: .bottom) {
            // Floats above Library / Detail / any pushed nav screens
            // while a cook session is minimized. Plural-aware:
            //   • 1 cook, no Detail-eligible add → single full pill
            //   • 1 cook + Detail of a different recipe → small green
            //     "Add to Cook Mode" button on the left + pill on the
            //     right (~1/4 + 3/4 split)
            //   • 2+ cooks → equally-sized pills, each tappable to
            //     foreground that cook
            if !session.activeCooks.isEmpty && !session.isCookModeVisible {
                CookingPillsBar(
                    session: session,
                    navContext: navContext,
                    accent: appearance.accentColor,
                    lookupRecipe: lookupRecipe
                )
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.isCookModeVisible)
        .task {
            // Cold launch (or relaunch after iOS killed us) — pull any
            // saved cook session back into memory before the first frame
            // settles so the user lands directly in Cook Mode if they
            // were mid-cooking when the app went away.
            session.restore(using: lookupRecipe)
            // Best-effort cleanup of stale share-inbox entries from the
            // share extension. Runs once per cold launch; never
            // load-bearing — the route handler also deletes after a
            // successful read, this catches the cases where the user
            // invoked the extension but never opened the main app.
            SharedContainer.sweepShareInbox()
            // Apple-ID revocation check. If the user opened iOS
            // Settings → Apple ID → Sign in with Apple → "Stop Using
            // Apple ID" for our app while we were backgrounded, this
            // call drops them back to signed-out so the next Profile
            // open prompts a fresh sign-in. No-op when signed out.
            await userAccount.refreshCredentialState()
            // Drain any pending CloudKit deletions left over from a
            // previous Delete-Account whose cascade hit a network
            // failure. Idempotent + early-return when the queue is
            // empty (the common case), so this doesn't add latency
            // to launches that don't need it. Apple App Review
            // tests Delete Account, and we can't have records
            // stranded in CloudKit just because the cascade hit a
            // blip — `CloudKitService.drainPendingDeletes` keeps
            // retrying until the cloud confirms gone.
            await CloudKitService.retryPendingDeletes()
            // Slice 6 — register CKQuerySubscriptions for friend
            // events + recipe-import events. Idempotent + locally
            // gated by a UserDefaults flag so this is a fast
            // no-op when nothing's changed; re-runs when the user
            // signs into a different Apple ID. Skips silently
            // when iCloud isn't bound (signed-out state); that
            // path lights up after `UserAccount.completeSignIn`
            // runs the same call.
            await CloudKitSubscriptions.registerIfNeeded()
            // Slice 6 — bind the FriendsStore to friendship-event
            // pushes so the friends list / requests section
            // refresh as soon as a push lands rather than waiting
            // for the next ProfileView open. Idempotent on
            // re-call (NotificationCenter dedupes by
            // observer-block identity, but `task` only fires once
            // per scene lifetime so re-call doesn't happen in
            // practice).
            friendsStore.observeRemotePushes()
        }
        .onOpenURL { url in
            // Six URL shapes land here:
            //   1. llamascookbook://cook/<recipeID>          ← cook deep link
            //      (Live Activity tap, notification tap)
            //   2. llamascookbook://recipe/v<N>/<base64url>  ← URL-form share
            //      (recipient tapped a chat-app link from before cloud
            //      hosting; also the iCloud-unavailable fallback path)
            //   3. llamascookbook://share/<recordName>       ← cloud-permalink
            //      share — recipient tapped a `share/<6char-id>` link, we
            //      fetch the RecipeShare record from CloudKit public DB.
            //      Legacy form, kept for back-compat with any test links
            //      sitting in chat history pre-2026-04-29; new links go
            //      through the HTTPS Universal Link form below.
            //   4. file://...something.llamarecipe           ← document open
            //      (AirDrop accept, Files / Mail attachment tap)
            //   5. llamascookbook://share-url/<base64url>    ← Share Extension
            //      handoff for a URL the user shared from another app
            //      (Safari, Reddit, etc.)
            //   6. llamascookbook://share-incoming/<uuid>    ← Share Extension
            //      handoff for a `.llamarecipe` file the user shared
            //      from Files / Mail; bytes wait in the App Group inbox
            //   7. https://<shareLinkHost>/r/<recordName>   ← Universal
            //      Link (the same recipe-share permalink as #3 but
            //      delivered as an HTTPS URL because the rich-preview
            //      bubble in Messages requires HTTPS). iOS sometimes
            //      delivers Universal Links here AND sometimes via
            //      `.onContinueUserActivity` below — handling both
            //      keeps the import flow reliable across cold-launch
            //      vs warm-foreground deliveries on iOS 18.
            //
            // Order: cook first (most frequent), then the three share
            // forms, then file open, then the two share-extension
            // handoffs, then the HTTPS Universal Link. All disjoint
            // by scheme/host/file-extension so order is strict only
            // within each predicate match.

            if let recipeID = parseCookDeepLink(url) {
                routeCookDeepLink(recipeID)
            } else if url.scheme == "llamascookbook", url.host == "recipe" {
                routeShareURL(url)
            } else if url.scheme == "llamascookbook", url.host == "share" {
                routeCloudShareLink(url)
            } else if url.isFileURL, url.pathExtension.lowercased() == "llamarecipe" {
                routeShareFile(url)
            } else if url.scheme == "llamascookbook", url.host == "share-url" {
                routeShareExtensionURL(url)
            } else if url.scheme == "llamascookbook", url.host == "share-incoming" {
                routeShareExtensionFile(url)
            } else if url.scheme == "https",
                      url.host == CloudKitService.shareLinkHost {
                routeUniversalLink(url)
            }
        }
        // Universal Links — `https://llamascookbook.pages.dev/r/<recordName>`
        // arriving from a tap on the rich-preview bubble in Messages /
        // Mail / etc. iOS validates the AASA file on first launch; once
        // validated, the OS routes matching URLs into the app.
        //
        // **Why both handlers exist**: iOS 18 SwiftUI delivers Universal
        // Links *either* through `.onOpenURL` (with the full https URL,
        // typical for cold-launch + scene reactivation) *or* through
        // `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`
        // (typical for warm-foreground deliveries via NSUserActivity).
        // Apple's docs imply only the latter is canonical, but in
        // practice both fire depending on launch state. Routing through
        // both into the same `routeUniversalLink` keeps the import flow
        // reliable regardless of how iOS chose to deliver the URL —
        // duplicate calls would no-op since `pendingShareImport`
        // becomes the same UUID either way.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            routeUniversalLink(url)
        }
        .onChange(of: navContext.pendingImportedRecipeID) { _, newID in
            // Slice 5 — friend-import navigation. When
            // `FriendRecipeDetailView.performImport` signals
            // completion, look up the freshly-materialized recipe
            // and run the same post-save choreography the file/
            // link share path uses (sheet dismiss → library
            // highlight → Detail push). LibraryView's mirror
            // observer dismisses the Profile sheet that hosts the
            // friend nav stack.
            //
            // The signal is consumed at the end of the highlight
            // sequence (inside `runPostSaveHighlight`) so a
            // subsequent import fires a fresh nil → id transition.
            guard let newID,
                  let recipe = lookupRecipe(newID)
            else { return }
            runPostSaveHighlight(for: recipe)
            // Clear immediately — runPostSaveHighlight has already
            // captured the recipe by reference and started its
            // Task, so clearing the signal field doesn't interfere
            // with the highlight sequence. Clearing now (rather
            // than at the end of the sequence) ensures a rapid
            // re-import of the same recipe (importing an updated
            // copy after the chain root edited it) fires onChange
            // again.
            navContext.pendingImportedRecipeID = nil
        }
        .sheet(item: $pendingShareImport) { envelope in
            RecipeImportPreviewView(envelope: envelope) { savedRecipe in
                // Defer the nav push until the sheet has had time to
                // dismiss; pushing immediately leaves the user staring
                // at a half-dismissed sheet and SwiftUI sometimes drops
                // the push entirely if it lands mid-animation. The
                // intermediate beat also gives `runPostSaveHighlight`
                // a window to scroll the library + flash the magnify
                // badge on the new recipe's letter before Detail
                // pulls focus.
                runPostSaveHighlight(for: savedRecipe)
            }
            // @Observable values can drop out across sheet
            // boundaries — re-injecting is cheap insurance, same
            // pattern as the Cook Mode cover above.
            .environment(appearance)
        }
        .alert(
            "Couldn't import recipe",
            isPresented: shareImportErrorPresented,
            presenting: shareImportError
        ) { _ in
            Button("OK") { shareImportError = nil }
        } message: { message in
            Text(message)
        }
        .fullScreenCover(isPresented: cookingSheetPresented) {
            if let recipe = session.foregroundedRecipe,
               let cookID = session.foregroundedCookID {
                CookModeView(
                    recipe: recipe,
                    cookID: cookID,
                    restoration: session.pendingRestoration
                ) {
                    // Multi-cook close: drop *just this cook* from the
                    // session. `remove` minimizes the cover — if other
                    // cooks remain they keep running silently and surface
                    // as resume pills, the user lands back on whatever
                    // screen sat behind Cook Mode rather than being
                    // yanked into a different recipe.
                    session.remove(cookID: cookID)
                }
                // .id(cookID) forces SwiftUI to tear down + recreate
                // CookModeView when the foregrounded cook changes,
                // so each cook's @State (strikes, timer, phase) seeds
                // fresh from its own pendingRestoration instead of
                // bleeding the previous cook's values.
                .id(cookID)
                // Cook Mode owns the entire screen — no sheet chrome,
                // no swipe-to-dismiss, no rounded corners. Exit goes
                // through the in-view close (X) or Mark-as-cooked.
                // Explicit environment re-injection: @Observable values
                // don't always propagate through covers reliably, and the
                // children of cook mode may read them. Cheap to be safe.
                .environment(appearance)
                .environment(session)
                .environment(editor)
            }
        }
        .sheet(item: editorBinding) { sheet in
            EditorSheetHost(
                sheet: sheet,
                onClose: { editor.end() },
                onSaved: { savedRecipe in
                    // Same pattern as the share-recipient hand-off:
                    // close the editor sheet, then push Detail after
                    // the dismiss animation has had time to clear so
                    // SwiftUI doesn't drop the push mid-animation.
                    // Used by every save path that creates a new
                    // recipe — Write Down Your Recipe, all three
                    // import flows, and the photo "Edit then Save"
                    // hand-off — so users always land on the recipe
                    // they just made. The interstitial beat also
                    // doubles as the post-save highlight window
                    // (library scrolls + A–Z magnify flashes).
                    editor.end()
                    runPostSaveHighlight(for: savedRecipe)
                }
            )
            .environment(appearance)
            .environment(editor)
            .environment(session)
        }
        .alert(
            "Discard changes?",
            isPresented: discardAlertPresented,
            presenting: editor.pendingSwitch
        ) { _ in
            Button("Keep editing", role: .cancel) { editor.cancelDiscard() }
            Button("Discard", role: .destructive) { editor.confirmDiscard() }
        } message: { _ in
            Text("You have unsaved changes. Leaving will lose them.")
        }
    }

    private var cookingSheetPresented: Binding<Bool> {
        // The cover follows `isCookModeVisible` rather than just "do we
        // have any active cooks?" — minimize hides the cover without
        // tearing down the session, and the resume pill / Live Activity
        // tap can flip it back on. SwiftUI may write `false` here when
        // the user dismisses (which we have disabled for cook mode), so
        // we route through `minimize()` to keep the session alive.
        Binding(
            get: { session.isCookModeVisible && !session.activeCooks.isEmpty },
            set: { newValue in
                if !newValue { session.minimize() }
            }
        )
    }

    /// The editor sheet's binding only writes on dismiss — and because
    /// `.interactiveDismissDisabled()` is applied inside the sheet host,
    /// the user can't accidentally drag it away; only Save / Cancel paths
    /// call `editor.end()` explicitly.
    private var editorBinding: Binding<EditorCoordinator.ActiveSheet?> {
        Binding(
            get: { editor.active },
            set: { newValue in
                if newValue == nil { editor.end() }
            }
        )
    }

    private var discardAlertPresented: Binding<Bool> {
        Binding(
            get: { editor.pendingSwitch != nil },
            set: { if !$0 { editor.cancelDiscard() } }
        )
    }

    private var shareImportErrorPresented: Binding<Bool> {
        Binding(
            get: { shareImportError != nil },
            set: { if !$0 { shareImportError = nil } }
        )
    }

    // MARK: post-save highlight

    /// Brief library highlight choreography that runs between sheet
    /// dismiss and Detail push for every new-recipe save path
    /// (scratch entry, all three import flows, share-recipient
    /// import). Sequence:
    ///
    ///   1. Wait ~150ms — sheet dismiss is in flight; library is
    ///      uncovering. Setting the highlight now means LibraryView's
    ///      onChange has the signal by the time the user can see the
    ///      list, so the scroll + badge land smoothly instead of
    ///      flickering on after a beat of empty stillness.
    ///   2. Set `pendingHighlightRecipeID`. LibraryView reacts:
    ///      ScrollViewReader scrolls to the row, LetterIndex flashes
    ///      the magnify badge on the recipe's letter (under A–Z
    ///      sort).
    ///   3. Linger ~750ms so the scroll + badge are clearly visible
    ///      before Detail pulls focus.
    ///   4. Push Detail.
    ///   5. Wait ~400ms for the push transition to complete, then
    ///      clear the highlight so the badge disappears off-screen
    ///      and not mid-animation.
    ///
    /// Total visible window: ~900ms — short enough to feel like a
    /// transition, long enough for the eye to follow.
    private func runPostSaveHighlight(for savedRecipe: Recipe) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            navContext.pendingHighlightRecipeID = savedRecipe.id
            try? await Task.sleep(for: .milliseconds(750))
            libraryPath.append(savedRecipe)
            try? await Task.sleep(for: .milliseconds(400))
            navContext.pendingHighlightRecipeID = nil
        }
    }

    // MARK: deep-link routing

    /// `llamascookbook://cook/<recipeID>` — Live Activity tap or
    /// notification tap. Multi-cook aware: matches by recipeID and
    /// foregrounds that specific cook (so cook B's lock-screen
    /// activity lands the user in cook B's view, not whichever cook
    /// happened to be foregrounded last).
    private func routeCookDeepLink(_ recipeID: UUID) {
        // Cold launch with persisted cooks → restore first, then route
        // by recipeID so a tap on a Live Activity from cold doesn't
        // skip the rehydration step.
        if session.activeCooks.isEmpty {
            session.restore(using: lookupRecipe)
        }
        if let cook = session.activeCooks.first(where: { $0.recipe.id == recipeID }) {
            session.foreground(cookID: cook.id)
        } else if session.activeCooks.isEmpty, let recipe = lookupRecipe(recipeID) {
            // No persisted session and no live cook for that recipe —
            // start a fresh cook. Live Activity outlived the session.
            session.start(recipe)
        } else {
            // Active cooks exist but none matches this recipeID —
            // edge case (stale Live Activity from a deleted recipe).
            // Surface whatever's already in the session rather than
            // no-oping.
            session.resume()
        }
    }

    /// `llamascookbook://recipe/v1/<base64url>` — recipient tapped a
    /// chat-app share link. Decodes inline (URL form has no photos)
    /// and queues the import preview.
    private func routeShareURL(_ url: URL) {
        do {
            if let envelope = try RecipeShare.decode(url: url) {
                pendingShareImport = envelope
            }
        } catch let error as RecipeShare.Error {
            shareImportError = error.errorDescription
        } catch {
            shareImportError = error.localizedDescription
        }
    }

    /// `llamascookbook://share/<recordName>` — recipient tapped a
    /// cloud-permalink share link. Fetches the `RecipeShare` record
    /// from CloudKit's public DB; on success, presents the same import
    /// preview the file / URL paths use (single sheet binding, single
    /// materialize path). Errors surface via `shareImportError`. The
    /// fetch happens off the main actor; UI mutations stay on it.
    private func routeCloudShareLink(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let recordName = parts.first, !recordName.isEmpty else {
            shareImportError = "Malformed share link."
            return
        }
        fetchCloudShareRecord(recordName: recordName)
    }

    /// `https://<shareLinkHost>/<shareLinkPathPrefix>/<recordName>` —
    /// recipient tapped the rich-preview bubble in Messages / Mail
    /// / etc. iOS hands us the URL via `NSUserActivityTypeBrowsingWeb`
    /// after validating the AASA file. We extract the record name
    /// from the path (defensive about path shape, since iOS guarantees
    /// host match but the path could in theory carry trailing
    /// segments) and route through the same CloudKit fetch as the
    /// legacy custom-scheme share path. Anything that doesn't match
    /// the expected `/r/<name>` shape no-ops — we don't surface an
    /// error alert because Universal Links can be handed to us for
    /// any matching host (e.g. a future marketing page at
    /// `/about` would land here too if iOS ever delivered it
    /// erroneously).
    private func routeUniversalLink(_ url: URL) {
        guard url.scheme == "https",
              url.host == CloudKitService.shareLinkHost
        else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2,
              parts[0] == CloudKitService.shareLinkPathPrefix,
              !parts[1].isEmpty
        else { return }
        let recordName = parts[1]
        fetchCloudShareRecord(recordName: recordName)
    }

    /// Shared CloudKit fetch path for the two share routes (legacy
    /// `llamascookbook://share/<id>` custom-scheme + new
    /// `https://...pages.dev/r/<id>` Universal Link). Both call this
    /// with the extracted record name; both surface errors through
    /// the same `shareImportError` alert.
    private func fetchCloudShareRecord(recordName: String) {
        Task { @MainActor in
            do {
                let envelope = try await CloudKitService.fetchShare(recordName: recordName)
                pendingShareImport = envelope
            } catch let recipeError as RecipeShare.Error {
                shareImportError = recipeError.errorDescription
            } catch let cloudError as CloudKitServiceError {
                shareImportError = cloudError.errorDescription
            } catch {
                // CKError, network, unknown record — surface the system
                // message. iCloud-not-signed-in lands here as
                // CKError.notAuthenticated; phrasing is close enough.
                shareImportError = error.localizedDescription
            }
        }
    }

    /// `file:///private/var/.../something.llamarecipe` — recipient
    /// opened a `.llamarecipe` attachment from AirDrop / Files / Mail.
    /// `LSSupportsOpeningDocumentsInPlace = NO` means iOS hands us a
    /// copy in our Inbox (`tmp/.../Inbox/...`); we read it once and
    /// move on. iOS handles the inbox cleanup eventually.
    /// `decode(fileURL:)` stat-checks size before reading so a 500 MB
    /// payload doesn't even touch memory.
    private func routeShareFile(_ url: URL) {
        do {
            let envelope = try RecipeShare.decode(fileURL: url)
            pendingShareImport = envelope
        } catch let error as RecipeShare.Error {
            shareImportError = error.errorDescription
        } catch {
            shareImportError = error.localizedDescription
        }
    }

    /// `llamascookbook://share-url/<base64url>` — user invoked the
    /// Llamas Cookbook share extension on a URL (Safari, Reddit,
    /// recipe-blog reader). Decode the base64url back to the original
    /// URL and route through the existing import-from-text sheet
    /// with the URL pre-filled. The sheet's URL fetch + AI parser run
    /// the same code path as a manual paste.
    private func routeShareExtensionURL(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let encoded = parts.first,
              let data = Data(base64URLEncoded: encoded),
              let urlString = String(data: data, encoding: .utf8),
              !urlString.isEmpty
        else {
            shareImportError = "Couldn't read the shared link."
            return
        }
        editor.startImportFromLink(url: urlString)
    }

    /// `llamascookbook://share-incoming/<uuid>` — user invoked the
    /// share extension on a `.llamarecipe` file (Files / Mail). The
    /// extension wrote the bytes to `share-inbox/<uuid>.llamarecipe`
    /// in the App Group container; we read + decode + present the
    /// Import Preview, then delete the inbox copy. Cleanup is
    /// idempotent — sweeping on launch (§ `task` below) catches any
    /// orphans from extension runs that didn't reach this handler.
    private func routeShareExtensionFile(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        // UUID validation on the handoff id — explicitly documents the
        // "this is an opaque random key, not a path component" intent
        // and hardens against any future URL-parsing-quirk that might
        // sneak `..` past the pathComponents normalizer.
        guard let id = parts.first, !id.isEmpty, UUID(uuidString: id) != nil else {
            shareImportError = "Malformed share handoff."
            return
        }
        let fileURL = SharedContainer.shareInboxURL().appendingPathComponent("\(id).llamarecipe")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            let envelope = try RecipeShare.decode(fileURL: fileURL)
            pendingShareImport = envelope
        } catch let error as RecipeShare.Error {
            shareImportError = error.errorDescription
        } catch {
            shareImportError = error.localizedDescription
        }
    }

    private func lookupRecipe(_ id: UUID) -> Recipe? {
        let descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    /// Parses `llamascookbook://cook/<uuid>` and returns the UUID, or
    /// nil if the URL doesn't match (other scheme, missing host, malformed
    /// path). Defensive — anything unparseable just no-ops the deep link
    /// rather than crashing, since this runs from `onOpenURL` which iOS
    /// can deliver at any moment with arbitrary input.
    private func parseCookDeepLink(_ url: URL) -> UUID? {
        guard url.scheme == "llamascookbook", url.host == "cook" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first else { return nil }
        return UUID(uuidString: first)
    }
}

/// Wraps the editor/import/new-recipe flow in its own detent-managed
/// sheet content. Owns a local `@State` for the selected detent so each
/// fresh presentation starts at `.large` — and stays at whatever detent
/// the user drags it to during a single session.
private struct EditorSheetHost: View {
    let sheet: EditorCoordinator.ActiveSheet
    let onClose: () -> Void
    /// Called with the freshly persisted Recipe whenever the editor
    /// finishes via Save — covers every save path: "Write Down Your
    /// Recipe", text/link/photo imports, and the photo "Edit then
    /// Save" hand-off. RootView dismisses the editor sheet and pushes
    /// Detail so users always land on their newly saved recipe rather
    /// than back on the Library list. The `.edit(Recipe)` case still
    /// uses `onClose` — those users are already viewing the recipe
    /// they edited, so a redundant Detail push would just stack a
    /// duplicate page on the navigation stack.
    let onSaved: (Recipe) -> Void

    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            switch sheet {
            case .new(let seed):
                // Every new-recipe save (with or without an import
                // seed) routes through `onSaved` so the user lands on
                // Detail. The seed parameter still matters as the
                // editor's pre-fill (photo-import "Edit then Save"
                // hand-off), just no longer affects the post-save
                // navigation decision.
                RecipeEditorView(recipe: nil, initialDraft: seed) { savedRecipe in
                    onSaved(savedRecipe)
                }
            case .edit(let recipe):
                // Editing an existing recipe — user is typically
                // already viewing it on Detail. Close-only (no extra
                // navigation) avoids stacking a duplicate Detail on
                // the navigation path.
                RecipeEditorView(recipe: recipe) { _ in onClose() }
            case .importFromText(let seedText):
                ImportFromTextView(seedText: seedText, onSaved: onSaved)
            case .importFromLink(let prefilledURL):
                ImportFromLinkView(prefilledURL: prefilledURL, onSaved: onSaved)
            case .importFromPhoto:
                ImportFromPhotoView(onSaved: onSaved)
            }
        }
        .presentationDetents([.large, .height(80)], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(80)))
        .presentationDragIndicator(.visible)
        // Full swipe-down is blocked — the only way to fully close the
        // editor is Save, Cancel (with the existing discard alert), or
        // confirming the switch-discard alert at RootView.
        .interactiveDismissDisabled()
    }
}

/// Floating pills bar shown when Cook Mode is minimized. Renders one
/// pill per active cook; when the user is viewing the Detail page of a
/// recipe that *isn't* in the session yet (and there's room under the
/// 4-cook cap), prepends a small green "Add to Cook Mode" button so
/// they can spawn a parallel cook without re-entering Cook Mode.
///
/// Layout transitions:
///   • 1 cook, no Detail-eligible add → 1 full-width accent pill
///   • 1 cook + green add button → ~1/4 green + ~3/4 accent pill
///   • 2+ cooks → equally-sized accent pills, no add button if at cap
///
/// Spring-animated on `activeCooks.count` and on `canShowAdd` so the
/// transitions feel cohesive when the user adds a parallel cook.
private struct CookingPillsBar: View {
    let session: CookingSession
    let navContext: NavigationContext
    let accent: Color
    let lookupRecipe: (UUID) -> Recipe?

    private var detailRecipe: Recipe? {
        guard let id = navContext.detailedRecipeID else { return nil }
        return lookupRecipe(id)
    }

    /// True when the green add button should appear: there's a Detail
    /// recipe in scope and we're under the concurrency cap. The recipe
    /// being already cooking is *fine* — the user can run the same
    /// recipe twice in parallel (two batches, different scales, etc.),
    /// each cook gets its own `ActiveCook.id`.
    private var canShowAdd: Bool {
        guard navContext.detailedRecipeID != nil else { return false }
        return session.canAddCook
    }

    /// Total tiles competing for horizontal space — pills plus the
    /// optional Add button. At 3+ the pill drops its timer-countdown
    /// line + chevron and tightens padding so 4 tiles still fit
    /// without pinching titles to unreadable widths on narrow phones.
    /// 4 is the hard cap (`maxConcurrentCooks`); when at cap the Add
    /// button is hidden so we never go past 4 tiles.
    private var slotCount: Int {
        session.activeCooks.count + (canShowAdd ? 1 : 0)
    }

    private var compactPills: Bool { slotCount >= 3 }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if canShowAdd, let recipe = detailRecipe {
                AddToCookButton {
                    Haptics.impact(.light)
                    session.addParallel(recipe)
                }
                // Shrinks at 3-slot density so the trailing pills get
                // back the width the Add button would otherwise hog.
                .frame(maxWidth: compactPills ? 56 : 92)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ForEach(session.activeCooks) { cook in
                CookPill(
                    cook: cook,
                    accent: accent,
                    duplicateIndex: session.duplicateIndex(for: cook.id),
                    compact: compactPills
                ) {
                    Haptics.selection()
                    session.foreground(cookID: cook.id)
                }
                .frame(maxWidth: .infinity)
                .transition(
                    .scale(scale: 0.85).combined(with: .opacity)
                )
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85),
                   value: session.activeCooks.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.85),
                   value: canShowAdd)
    }
}

/// One cook's resume pill. Same accent-on-cream visual language as the
/// pre-multi `CookingResumePill`, but compacted for the 2-up case
/// where two pills share the bottom row. The "COOKING" eyebrow drops
/// when the pill goes plural — the title + chevron alone read clearly
/// at half-width.
private struct CookPill: View {
    let cook: ActiveCook
    let accent: Color
    /// 1-based suffix for same-recipe duplicates; nil when the recipe
    /// is only running once. When non-nil, renders as " (N)" after the
    /// title so the user can tell two pills of the same recipe apart.
    let duplicateIndex: Int?
    /// True when 3+ tiles share the bottom row. Drops the timer
    /// countdown line + chevron and tightens padding so titles still
    /// have width to render on narrow phones at the 4-cook cap. The
    /// per-cook timer is still visible via the lock-screen Live
    /// Activity / Dynamic Island and inside the cook's own view.
    let compact: Bool
    let onTap: () -> Void

    private var displayTitle: String {
        let base = StringCase.titleCase(cook.recipe.title)
        guard let n = duplicateIndex else { return base }
        return "\(base) (\(n))"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: compact ? AppSpacing.xs : AppSpacing.sm) {
                Image(systemName: "fork.knife")
                    .font(.system(size: compact ? 13 : 15, weight: .bold))
                if compact {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayTitle)
                            .font(.system(size: 13, weight: .semibold, design: .serif))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        // Always reserve space for the timer line so
                        // pills stay the same height whether or not a
                        // timer is running. The "0:00" placeholder
                        // matches the live countdown's metrics so a pill
                        // with a timer and a pill without sit on the
                        // same baseline when side-by-side.
                        Group {
                            if let endsAt = cook.timerEndsAt, endsAt > Date() {
                                Text(timerInterval: Date()...endsAt, countsDown: true)
                                    .opacity(0.92)
                            } else {
                                Text("0:00")
                                    .opacity(0)
                            }
                        }
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, compact ? AppSpacing.sm : AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .shadow(color: AppColor.shadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume cooking \(displayTitle)")
    }
}

/// Small green "Add to Cook Mode" button. Same `fork.knife` glyph as
/// the cooking pill — same affordance language — but tinted with the
/// success green so it visually reads as "spawn another cook" rather
/// than "resume what's already running."
private struct AddToCookButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 15, weight: .bold))
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(AppColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(AppColor.success)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .shadow(color: AppColor.shadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add this recipe to Cook Mode")
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self, RecipePhoto.self, RecipeStepPhoto.self], inMemory: true)
        .environment(AppearanceSettings())
        .environment(OwnerProfile())
        .environment(UserAccount())
}
