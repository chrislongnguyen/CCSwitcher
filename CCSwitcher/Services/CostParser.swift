import Foundation

/// Provides cost summaries from Claude Code session JSONL files.
/// All actual parsing is done by `SessionParseCache`; this is a thin facade.
final class CostParser: Sendable {
    static let shared = CostParser()
    private init() {}

    /// Compute cost summary from the in-memory parse cache.
    /// Caller must ensure `SessionParseCache.shared.refreshFromFilesystem()`
    /// has been awaited at least once this cycle.
    func getCostSummary() async -> CostSummary {
        return await SessionParseCache.shared.costSummary()
    }

    // MARK: - Helpers

    /// "claude-opus-4-6" → "Opus"
    static func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
