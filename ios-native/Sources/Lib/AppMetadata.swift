import Foundation

/// Tiny grab-bag of utilities that were duplicated across 3+ call
/// sites and earned a single home. Keep this file small — items here
/// should be genuinely cross-cutting (no domain ownership) and have
/// no good single-feature home.
enum AppMetadata {
    /// `CFBundleShortVersionString` (e.g. "1.0.0"). Used as the
    /// `appVersion` field stamped into outgoing share envelopes so a
    /// recipient receiving a stale-schema recipe knows which sender
    /// build to nudge. Falls back to "0.0.0" if the Info.plist key is
    /// missing — shouldn't happen in shipping builds, but a missing
    /// key shouldn't crash the share path.
    ///
    /// Previously duplicated as a private static helper in
    /// `LibraryMirrorService` and a private instance method in
    /// `RecipeDetailView`; consolidated here so a future build-number
    /// scheme change lands in one place.
    static var currentAppVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// CloudKit / NSError messages tend to carry the human-readable
    /// reason in `userInfo["ServerErrorDescription"]` rather than
    /// `localizedDescription` (which is often the generic
    /// "CKErrorDomain error N"). Falls back to `localizedDescription`
    /// when the server description isn't present.
    ///
    /// Previously duplicated across `FriendsStore`,
    /// `FriendLibraryView`, `LibraryMirrorService`, and
    /// `UserProfileMirror`.
    static func describeServerError(_ error: Error) -> String {
        let serverMessage = (error as NSError).userInfo["ServerErrorDescription"] as? String
        return serverMessage ?? error.localizedDescription
    }
}
