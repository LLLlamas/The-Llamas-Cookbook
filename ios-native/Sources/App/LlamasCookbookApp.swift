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
                // The cream + terracotta palette has no dark-mode variant
                // (AppColor values are hard sRGB, not asset-catalog system
                // colors). Locking to light keeps SwiftUI's default fills
                // and sheet backgrounds rendering consistently — without
                // this, a tester whose phone is in dark mode sees the
                // Library scroll area fall through to system black.
                .preferredColorScheme(.light)
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self])
    }
}
