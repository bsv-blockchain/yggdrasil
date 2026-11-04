import XCTest
@testable import Yggdrasil

/// Turning off a tab's amber until something actually changes.
///
/// Not a timer and not "snooze for 2 hours" — those guess. The dismissal
/// records a fingerprint of *why* the tab was demanding attention, and holds
/// only while that fingerprint is unchanged. A new commit, a new thread, a new
/// review request or a new agent record all change it, and the amber comes
/// back on its own.
final class AttentionDismissalTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "attention-dismissal-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        // Otherwise every run leaves a plist behind, here and on CI.
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func row(
        headSHA: String? = "abc123",
        threads: Int = 0,
        activityTotal: Int = 0,
        requestedAt: Date? = nil,
        requested: Bool = false,
        reviewState: String? = nil,
        ciState: String? = nil
    ) -> GitHubStatus {
        var row = GitHubStatus(
            taskID: 1, ciState: ciState, ciURL: nil, mergeable: nil, mergeableState: nil,
            reviewState: reviewState, unreadCommentsCount: 0, lastSeenCommentID: nil,
            fetchedAt: Date(timeIntervalSince1970: 0),
            commentsReviewsTotal: activityTotal, commitsTotal: 0, headSHA: headSHA,
            seenCommentsReviewsTotal: nil, seenCommitsTotal: nil, seenHeadSHA: nil,
            viewerLatestReviewState: nil, viewerReviewedHeadSHA: nil,
            unresolvedThreadsAwaitingViewer: threads,
            viewerLastEngagementAt: nil, headCommittedAt: nil,
            viewerReviewRequested: requested,
            viewerDidAuthorPR: false
        )
        row.viewerReviewRequestedAt = requestedAt
        return row
    }

    private func signature(
        _ row: GitHubStatus? = nil, session: AgentActivitySample? = nil
    ) -> String {
        AttentionSignature.make(row: row ?? self.row(), session: session)
    }

    // MARK: - What counts as "something changed"

    func testSameInputsGiveTheSameSignature() {
        XCTAssertEqual(signature(), signature())
    }

    func testANewCommitChangesIt() {
        XCTAssertNotEqual(signature(row(headSHA: "abc")), signature(row(headSHA: "def")))
    }

    func testANewUnresolvedThreadChangesIt() {
        XCTAssertNotEqual(signature(row(threads: 1)), signature(row(threads: 2)))
    }

    /// A count alone isn't enough: resolving one thread and opening another
    /// between two syncs returns the count to its muted value. The
    /// monotonically-growing activity total is what catches that.
    func testSwappingOneThreadForAnotherStillChangesIt() {
        XCTAssertNotEqual(
            signature(row(threads: 1, activityTotal: 10)),
            signature(row(threads: 1, activityTotal: 11))
        )
    }

    func testAFreshReviewRequestChangesIt() {
        XCTAssertNotEqual(
            signature(row(requestedAt: Date(timeIntervalSince1970: 100))),
            signature(row(requestedAt: Date(timeIntervalSince1970: 200)))
        )
    }

    /// A request with no recorded timestamp still has to register.
    func testTheRequestFlagAloneChangesIt() {
        XCTAssertNotEqual(signature(row(requested: false)), signature(row(requested: true)))
    }

    func testAChangedReviewDecisionChangesIt() {
        XCTAssertNotEqual(
            signature(row(reviewState: "APPROVED")),
            signature(row(reviewState: "CHANGES_REQUESTED"))
        )
    }

    /// Red CI on your own PR is a reason `needsAttention` fires, so a mute that
    /// ignored it would let a tab go red and stay silent.
    func testCIGoingRedChangesIt() {
        XCTAssertNotEqual(
            signature(row(ciState: "SUCCESS")),
            signature(row(ciState: "FAILURE"))
        )
    }

    func testAPendingQuestionChangesIt() {
        let asking = AgentActivitySample(
            activity: .awaitingAnswer, timestamp: Date(timeIntervalSince1970: 10)
        )
        XCTAssertNotEqual(signature(session: nil), signature(session: asking))
    }

    func testASecondQuestionChangesIt() {
        let first = AgentActivitySample(
            activity: .awaitingAnswer, timestamp: Date(timeIntervalSince1970: 10)
        )
        let second = AgentActivitySample(
            activity: .awaitingAnswer, timestamp: Date(timeIntervalSince1970: 20)
        )
        XCTAssertNotEqual(signature(session: first), signature(session: second))
    }

    /// The agent's own chatter is not an event. Fingerprinting every record it
    /// writes made muting useless precisely where it is wanted: mute a tab to
    /// deal with its thread later, keep working in it, and the mute would lapse
    /// within one 5s tick.
    func testOrdinaryAgentWorkDoesNotChangeIt() {
        let early = AgentActivitySample(
            activity: .working, timestamp: Date(timeIntervalSince1970: 10)
        )
        let later = AgentActivitySample(
            activity: .working, timestamp: Date(timeIntervalSince1970: 9999)
        )
        XCTAssertEqual(signature(session: early), signature(session: later))
    }

    func testAFinishedTurnDoesNotChangeIt() {
        let working = AgentActivitySample(
            activity: .working, timestamp: Date(timeIntervalSince1970: 10)
        )
        let ended = AgentActivitySample(
            activity: .turnEnded, timestamp: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(signature(session: working), signature(session: ended))
    }

    func testNilAndEmptyAreDistinguishable() {
        XCTAssertNotEqual(signature(row(headSHA: nil)), signature(row(headSHA: "")))
    }

    // MARK: - Whether the dismissal still holds

    func testAmberIsSuppressedWhileNothingHasChanged() {
        XCTAssertTrue(AttentionSignature.isDismissed(current: "sig-a", dismissed: "sig-a"))
    }

    func testAmberReturnsOnceSomethingChanges() {
        XCTAssertFalse(AttentionSignature.isDismissed(current: "sig-b", dismissed: "sig-a"))
    }

    func testNothingDismissedMeansNotSuppressed() {
        XCTAssertFalse(AttentionSignature.isDismissed(current: "sig-a", dismissed: nil))
    }

    /// A tab with no status yet has an empty signature; it must never count as
    /// muted, or every tab would read muted before the first poll tick.
    func testAnEmptySignatureIsNeverDismissed() {
        XCTAssertFalse(AttentionSignature.isDismissed(current: "", dismissed: ""))
    }

    // MARK: - Reaching the filter

    /// The user-visible claim: a muted tab drops out of "Needs me".
    func testMutedTabDropsOutOfNeedsMe() {
        let status = TabStatus.aggregate(
            claude: .idle,
            git: GitState(dirty: false, remote: .noRemote),
            github: .init(ciState: nil, unread: 0, hasActivity: true),
            attentionSignature: "sig-a"
        )
        XCTAssertTrue(
            TabRowViewModel.needsAttention(branchName: "review-pr-7", status: status),
            "unmuted, this tab needs attention"
        )
        XCTAssertFalse(
            TabRowViewModel.needsAttention(
                branchName: "review-pr-7", status: status, dismissedSignature: "sig-a"
            ),
            "muted, it must drop out"
        )
    }

    func testMutedTabReturnsToNeedsMeOnceTheSignatureMoves() {
        let status = TabStatus.aggregate(
            claude: .idle,
            git: GitState(dirty: false, remote: .noRemote),
            github: .init(ciState: nil, unread: 0, hasActivity: true),
            attentionSignature: "sig-b"
        )
        XCTAssertTrue(
            TabRowViewModel.needsAttention(
                branchName: "review-pr-7", status: status, dismissedSignature: "sig-a"
            )
        )
    }

    // MARK: - Storage

    func testRoundTripsThroughStorage() {
        AttentionDismissal.dismiss(tabID: 7, signature: "sig-a", defaults: defaults)
        XCTAssertEqual(AttentionDismissal.dismissedSignature(tabID: 7, defaults: defaults), "sig-a")
    }

    func testRestoringClearsIt() {
        AttentionDismissal.dismiss(tabID: 7, signature: "sig-a", defaults: defaults)
        AttentionDismissal.restore(tabID: 7, defaults: defaults)
        XCTAssertNil(AttentionDismissal.dismissedSignature(tabID: 7, defaults: defaults))
    }

    func testTabsAreIndependent() {
        AttentionDismissal.dismiss(tabID: 1, signature: "sig-a", defaults: defaults)
        XCTAssertNil(AttentionDismissal.dismissedSignature(tabID: 2, defaults: defaults))
    }
}
