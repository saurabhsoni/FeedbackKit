import Testing
@testable import FeedbackKit

@Test func categoriesMatchDatabaseConstraint() {
    #expect(Set(FeedbackCategory.allCases.map(\.rawValue)) == ["bug", "idea", "general"])
}
