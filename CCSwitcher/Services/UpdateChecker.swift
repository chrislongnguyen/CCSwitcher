import Foundation
import AppKit
import Sparkle
import SwiftUI

/// Thin ObservableObject wrapper around Sparkle's `SPUStandardUpdaterController`.
/// Keeps the existing call-site API (`checkForUpdates(manual:)`,
/// `@Published var isChecking`) so `CCSwitcherApp.swift` and `SettingsView.swift`
/// don't need to change. Sparkle owns its own progress UI (download sheet,
/// release-notes window, restart prompt), so `isChecking` is kept for source
/// compatibility but is never flipped — clicking the button always shows
/// Sparkle's UI immediately, which provides its own feedback.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Source-compat shim. Sparkle's UI is responsible for visible progress.
    @Published var isChecking = false

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` enables Sparkle's automatic background
        // checks at the interval configured by Sparkle (default: 1 day).
        // No delegates needed: standard UI behavior is what we want.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Manual = user-initiated; shows Sparkle's full UI including
    /// "you're up to date" feedback when no update is available.
    /// Background = silent unless an update is found.
    func checkForUpdates(manual: Bool = false) {
        if manual {
            controller.checkForUpdates(nil)
        } else {
            controller.updater.checkForUpdatesInBackground()
        }
    }
}
