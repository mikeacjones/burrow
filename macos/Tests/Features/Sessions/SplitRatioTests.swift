import Testing
@testable import Ghostty

/// `newViewRatio` gives the new pane its share wherever it lands
/// (`default-h-split-ratio` / `default-v-split-ratio`).
struct SplitRatioTests {
    private func split(_ direction: SplitTree<MockView>.NewDirection, ratio: Double) throws
        -> (split: SplitTree<MockView>.Node.Split, existing: MockView, new: MockView) {
        let existing = MockView(), new = MockView()
        let tree = try SplitTree<MockView>(view: existing)
            .inserting(view: new, at: existing, direction: direction, newViewRatio: ratio)
        guard case .split(let split) = tree.root else {
            Issue.record("expected a split")
            throw SplitTree<MockView>.SplitError.viewNotFound
        }
        return (split, existing, new)
    }

    @Test(arguments: [SplitTree<MockView>.NewDirection.right, .down])
    func newPaneAfterExisting(direction: SplitTree<MockView>.NewDirection) throws {
        // The new pane is the right/bottom child, so the left/top keeps 75%.
        let (split, existing, new) = try split(direction, ratio: 0.25)
        #expect(split.ratio == 0.75)
        #expect(split.left == .leaf(view: existing))
        #expect(split.right == .leaf(view: new))
    }

    @Test(arguments: [SplitTree<MockView>.NewDirection.left, .up])
    func newPaneBeforeExisting(direction: SplitTree<MockView>.NewDirection) throws {
        // The new pane is the left/top child and gets 25%.
        let (split, existing, new) = try split(direction, ratio: 0.25)
        #expect(split.ratio == 0.25)
        #expect(split.left == .leaf(view: new))
        #expect(split.right == .leaf(view: existing))
    }

    @Test func defaultsToEvenSplit() throws {
        let existing = MockView(), new = MockView()
        let tree = try SplitTree<MockView>(view: existing).inserting(view: new, at: existing, direction: .right)
        guard case .split(let split) = tree.root else { Issue.record("expected a split"); return }
        #expect(split.ratio == 0.5)
    }
}
