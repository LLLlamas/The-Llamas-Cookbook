import SwiftUI
import SwiftData
import UIKit

@main
struct LlamasCookbookApp: App {
    init() {
        // Propagate accent to UIKit surfaces (keyboard Return key, text cursors,
        // selection handles) that read UIView.tintColor before SwiftUI's .tint()
        // reaches them.
        UIView.appearance().tintColor = UIColor(AppColor.accent)

        // Ask for notification permission up front so the first cooking
        // timer can schedule its background alert without an extra round-trip.
        TimerNotifications.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self])
    }
}
