import AlarmKit
import Foundation

/// Cook-context payload AlarmKit hands to the widget extension when it
/// renders the alarm's countdown / alert presentation. AlarmKit's
/// `AlarmAttributes<Metadata>` carries this through the same
/// `ActivityConfiguration` plumbing ActivityKit uses, so the widget
/// extension can read it on the lock screen + Dynamic Island.
///
/// Shared between the main app (which builds an `AlarmAttributes` with
/// this metadata when scheduling each timer) and the widget extension
/// (which reads `context.attributes.metadata.*` to render). Conforms to
/// `AlarmMetadata` (which itself refines `Codable` + `Hashable` +
/// `Sendable`) — no extra protocol work needed.
struct TimerAlarmMetadata: AlarmMetadata {
    /// Recipe title displayed inside the alarm's lock-screen + Dynamic
    /// Island presentations.
    var recipeTitle: String

    /// Recipe id — kept here so a future "tap the alarm to open Cook Mode
    /// for this recipe" `AppIntent` has the routing key it needs without
    /// re-querying.
    var recipeID: UUID

    /// Distinct cook identity per active session. The same recipe can be
    /// cooked twice in parallel (e.g. two batches with different scales);
    /// each cook owns its own alarm + presentation.
    var cookID: UUID

    /// Human label for the timer ("Bake", "Pot", "Cook").
    var label: String

    /// 1-based index of the step that owns this timer, so the widget can
    /// say "Step 3" without needing the full recipe object.
    var stepNumber: Int

    /// Scheduled alarm fire date, stored here so the widget's countdown
    /// text doesn't depend on `AlarmPresentationState` property names
    /// that change across AlarmKit betas.
    var endDate: Date
}
