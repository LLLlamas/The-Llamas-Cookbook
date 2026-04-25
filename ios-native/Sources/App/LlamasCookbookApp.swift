import SwiftUI
import SwiftData
import UIKit

@main
struct LlamasCookbookApp: App {
    @State private var appearance = AppearanceSettings()

    init() {
        // Propagate accent to UIKit surfaces (keyboard Return key, text cursors,
        // selection handles) that read UIView.tintColor before SwiftUI's .tint()
        // reaches them. Stays at the default terracotta — keyboard tint follows
        // the design baseline rather than the user's pick to avoid an extra
        // UIKit refresh dance on every color change.
        UIView.appearance().tintColor = UIColor(AppColor.accent)

        // Ask for notification permission up front so the first cooking
        // timer can schedule its background alert without an extra round-trip.
        TimerNotifications.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appearance)
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self])
    }
}
