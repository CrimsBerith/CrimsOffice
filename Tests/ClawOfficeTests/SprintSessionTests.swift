import XCTest
@testable import ClawOffice

/// Deterministic coverage for AutonomousSprintSession persistence model.
/// No network, no sleep, no real disk I/O — pure Codable roundtrip.
final class SprintSessionTests: XCTestCase {

    func testAutonomousSprintSessionCodableRoundtrip() throws {
        let agentId = UUID()
        let sessionId = UUID()
        let original = AutonomousSprintSession(
            id: sessionId,
            agentId: agentId,
            goal: "Uzun sprint hedefi",
            currentIteration: 7,
            maxIterations: 50,
            status: .paused,
            lastUpdate: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotContext: "snapshot-payload"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutonomousSprintSession.self, from: data)

        XCTAssertEqual(decoded.id, sessionId)
        XCTAssertEqual(decoded.agentId, agentId)
        XCTAssertEqual(decoded.goal, "Uzun sprint hedefi")
        XCTAssertEqual(decoded.currentIteration, 7)
        XCTAssertEqual(decoded.maxIterations, 50)
        XCTAssertEqual(decoded.status, .paused)
        XCTAssertEqual(decoded.snapshotContext, "snapshot-payload")
        XCTAssertEqual(decoded.lastUpdate.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testSessionStatusAllCasesCodable() throws {
        let cases: [AutonomousSprintSession.SessionStatus] = [.running, .paused, .completed, .failed]
        for status in cases {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(AutonomousSprintSession.SessionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testSessionDefaultsAreRunningAndZeroIteration() {
        let s = AutonomousSprintSession(agentId: UUID(), goal: "g", maxIterations: 10)
        XCTAssertEqual(s.currentIteration, 0)
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.snapshotContext, "")
    }
}