@testable import FeedbackKit
import Testing

@Test func categoriesMatchDatabaseConstraint() {
    #expect(Set(FeedbackCategory.allCases.map(\.rawValue)) == ["bug", "idea", "general"])
}
