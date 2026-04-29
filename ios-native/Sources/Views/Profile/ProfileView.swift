import SwiftUI
import AuthenticationServices

/// Profile sheet — entry point for Sign in with Apple, in-app
/// identity, and Delete Account. Reached from `LibraryView`'s
/// person-circle toolbar button. Sheet-presented (parallel to the
/// `AccentColorPicker` pattern) so dismiss is a swipe-down or the
/// Done button.
///
/// PR 1 scope: signed-out toggle (SignInWithAppleButton), signed-in
/// shell (editable display name, Sign Out, Delete Account, friend-
/// code placeholder, "Coming soon" friends row). PR 2+ fills in the
/// friend code and adds the share/copy affordances; PR 4 adds the
/// friends list. The signed-out copy intentionally avoids over-
/// promising — until PR 2 lands, signing in lights up no in-app
/// feature, so the explainer below frames it as preparation rather
/// than the deliverable.
struct ProfileView: View {
    @Environment(UserAccount.self) private var userAccount
    @Environment(OwnerProfile.self) private var ownerProfile
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft: String = ""
    @State private var isEditingName: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xl) {
                    header

                    switch userAccount.status {
                    case .signedOut, .signingIn:
                        // `.signingIn` shares the visual treatment with
                        // signed-out — Apple's SignInWithAppleButton
                        // surfaces its own modal sheet that gates user
                        // input, so we don't need to gray our button on
                        // top of that. (We learned the hard way: in iOS
                        // 18 the button's onCompletion sometimes never
                        // delivers when the user dismisses the Apple
                        // sheet via swipe-down, leaving status stuck at
                        // .signingIn forever and the button visibly
                        // disabled. Treating the two states identically
                        // here means the user can always re-tap.)
                        signedOutBody
                    case .signedIn(let identity):
                        signedInBody(identity: identity)
                    case .signInFailed(let message):
                        // VStack so the switch arm produces a single
                        // View — ViewBuilder switch cases require it.
                        VStack(spacing: AppSpacing.md) {
                            signedOutBody
                            errorBanner(message: message)
                        }
                    }

                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(AppSpacing.lg)
            }
            .background(AppColor.background)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appearance.accentColor)
                }
            }
            .alert(
                "Delete account?",
                isPresented: $showingDeleteConfirm
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    userAccount.deleteAccount()
                }
            } message: {
                Text("This signs you out and forgets your in-app identity. Recipes saved on this device will not be removed.")
            }
            .onAppear {
                // Recover from a stranded `.signingIn` from a previous
                // attempt (see comment in the switch above). Idempotent
                // — no-op when status isn't `.signingIn`.
                userAccount.cancelInFlightSignIn()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: AppSpacing.sm) {
            LlamaLogo(size: 96, shadowColor: appearance.accentColor)
            Text("Llamas Cookbook")
                .font(AppFont.recipeTitle)
                .foregroundStyle(appearance.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.md)
    }

    private var signedOutBody: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Sign in to send recipes to friends")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)

            Text("Optional — only needed to send recipes directly to friends in the app. The file and link share options keep working without an account.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.md)

            SignInWithAppleButton(.signIn) { request in
                // Don't pre-flip status to `.signingIn`; Apple's modal
                // sheet is the natural input lock and onCompletion
                // doesn't always fire on swipe-down dismiss in iOS 18,
                // which would strand the UI in `.signingIn` (button
                // grayed forever). Status only moves on a real
                // outcome — success, hard error, or cancel.
                SignInWithAppleService.configure(request)
            } onCompletion: { result in
                do {
                    let credential = try SignInWithAppleService.processCompletion(result)
                    userAccount.completeSignIn(with: credential, ownerProfile: ownerProfile)
                    Haptics.success()
                } catch {
                    userAccount.failSignIn(with: error)
                }
            }
            // The standard size; the system button enforces its own
            // dimensions per Apple's HIG so we don't try to retint
            // or restyle. Black on cream reads cleanly against the
            // cream background.
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.vertical, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    @ViewBuilder
    private func signedInBody(identity: UserAccount.UserIdentity) -> some View {
        VStack(spacing: AppSpacing.lg) {
            displayNameRow(identity: identity)
            friendCodeRow(identity: identity)
            friendsRow
        }

        VStack(spacing: AppSpacing.sm) {
            Button {
                Haptics.selection()
                userAccount.signOut()
            } label: {
                Text("Sign out")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                Haptics.warning()
                showingDeleteConfirm = true
            } label: {
                Text("Delete account")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.destructive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.destructive.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, AppSpacing.md)
    }

    private func displayNameRow(identity: UserAccount.UserIdentity) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("DISPLAY NAME")
                .eyebrowStyle(AppColor.textTertiary)
            HStack(spacing: AppSpacing.sm) {
                if isEditingName {
                    TextField("Your name", text: $nameDraft)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFieldFocused)
                        .font(AppFont.sectionHeading)
                        .foregroundStyle(AppColor.textPrimary)
                        .onSubmit { commitNameEdit() }
                    Button {
                        commitNameEdit()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(identity.displayName)
                        .font(AppFont.sectionHeading)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer(minLength: 0)
                    Button {
                        nameDraft = identity.displayName
                        isEditingName = true
                        // Defer focus until after the field is in the view
                        // hierarchy — focusing inline races against SwiftUI's
                        // state propagation and the keyboard never appears.
                        DispatchQueue.main.async { nameFieldFocused = true }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .frame(width: 32, height: 32)
                            .background(AppColor.surfaceSunken)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit display name")
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Friend-code row. PR 1 ships a "Coming soon" placeholder — the
    /// code itself is generated when CloudKit lands in PR 2. The row
    /// stays visible in PR 1 so the layout doesn't reflow when PR 2
    /// fills it in; the disabled visual treatment communicates "not
    /// yet" without hiding the affordance.
    private func friendCodeRow(identity: UserAccount.UserIdentity) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("FRIEND CODE")
                .eyebrowStyle(AppColor.textTertiary)
            if let code = identity.friendCode {
                Text(code)
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .foregroundStyle(appearance.accentColor)
                    .tracking(4)
            } else {
                Text("Coming soon")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textTertiary)
                    .italic()
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var friendsRow: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Friends")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Coming soon")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
            Spacer()
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.destructive)
            Text(message)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(AppColor.destructive.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.destructive.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: Edit helpers

    private func commitNameEdit() {
        userAccount.updateDisplayName(nameDraft)
        // Keep `OwnerProfile` (the file/link share flow's name source)
        // in lock-step so the user only has to edit their name in one
        // place. PR 2 will route the share flow through `UserAccount`
        // directly and this sync line goes away.
        if let identity = userAccount.status.identity {
            ownerProfile.userName = identity.displayName
        }
        isEditingName = false
        nameFieldFocused = false
        Haptics.success()
    }
}
