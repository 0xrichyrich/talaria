#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class RosterDeleteCandidateTests: XCTestCase {
    func testCandidateCapturesMatchingNonDefaultBotAndTargetAtomically() {
        let bot = makeBot("lab::worker")
        let target = ProfileLifecycleTarget(
            rosterID: bot.id,
            route: GatewayBotRoute(gatewayID: "lab", profile: "worker"))

        let candidate = RosterDeleteCandidate.resolve(bot: bot, target: target)

        XCTAssertEqual(candidate?.bot, bot)
        XCTAssertEqual(candidate?.target, target)
    }

    func testCandidateRejectsMissingMismatchedAndDefaultTargets() {
        let worker = makeBot("lab::worker")
        XCTAssertNil(RosterDeleteCandidate.resolve(bot: worker, target: nil))
        XCTAssertNil(RosterDeleteCandidate.resolve(
            bot: worker,
            target: ProfileLifecycleTarget(
                rosterID: "lab::other",
                route: GatewayBotRoute(gatewayID: "lab", profile: "worker"))))

        let localDefault = makeBot("default")
        XCTAssertNil(RosterDeleteCandidate.resolve(
            bot: localDefault,
            target: ProfileLifecycleTarget(
                rosterID: localDefault.id,
                route: GatewayBotRoute(gatewayID: "primary", profile: "default"))))

        let remoteDefault = makeBot("lab::default")
        XCTAssertNil(RosterDeleteCandidate.resolve(
            bot: remoteDefault,
            target: ProfileLifecycleTarget(
                rosterID: remoteDefault.id,
                route: GatewayBotRoute(gatewayID: "lab", profile: "default"))))
    }

    private func makeBot(_ id: String) -> Bot {
        Bot(id: id, job: "", shape: .circle, hue: .violet)
    }
}
#endif
