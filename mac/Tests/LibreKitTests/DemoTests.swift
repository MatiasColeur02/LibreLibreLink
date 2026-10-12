import Foundation
import Testing
@testable import LibreKit

// El servidor de demo pasa por el cliente real: login con redirección, pacientes y gráfico.
// `.serialized` porque el escenario es global.
@Suite(.serialized) struct DemoTests {
    private func load(_ scenario: DemoScenario) async throws -> (GraphResult, [GlucoseCondition]) {
        DemoServer.scenario = scenario
        let client = DemoServer.makeClient()
        let patients = try await client.patients()
        #expect(await client.region.code == "la")
        let graph = try await client.graph(patientID: try #require(patients.first).id)
        let conditions = GlucoseStatus.conditions(
            current: graph.current, sensor: graph.sensor, settings: AlarmSettings(),
            fetched: true, connectionError: nil, needsAttention: nil, now: Date()
        )
        return (graph, conditions)
    }

    @Test func normalDayHasTwelveHoursOfHistory() async throws {
        let (graph, conditions) = try await load(.normal)
        #expect(graph.history.count >= 140)
        #expect(graph.current?.trend != nil)
        #expect(graph.sensor?.serial.hasPrefix("3MH0") == true)
        #expect(!conditions.contains(.signalLoss))
        #expect(!conditions.contains(.stale))
    }

    @Test(arguments: [
        (DemoScenario.high, GlucoseCondition.high),
        (.low, .low),
        (.urgentLow, .urgentLow),
        (.belowRange, .urgentLow),
        (.stale, .stale),
        (.signalLoss, .signalLoss),
    ])
    func scenarioProducesCondition(scenario: DemoScenario, expected: GlucoseCondition) async throws {
        let (_, conditions) = try await load(scenario)
        #expect(conditions.contains(expected))
    }

    @Test func outOfScaleValues() async throws {
        #expect(GlucoseStatus.displayValue(try #require(try await load(.belowRange).0.current).mgdL) == "LO")
        #expect(GlucoseStatus.displayValue(try #require(try await load(.aboveRange).0.current).mgdL) == "HI")
    }

    @Test func sensorEnding() async throws {
        let (_, conditions) = try await load(.sensorEnding)
        #expect(conditions.contains { if case .sensorExpiringSoon = $0 { true } else { false } })
    }

    @Test func accountProblems() async throws {
        DemoServer.scenario = .mustAcceptTerms
        await #expect(throws: LibreLinkUpError.mustAcceptTerms) { try await DemoServer.makeClient().patients() }
        DemoServer.scenario = .connectionError
        await #expect(throws: LibreLinkUpError.http(503)) { try await DemoServer.makeClient().patients() }
        DemoServer.scenario = .noPatients
        #expect(try await DemoServer.makeClient().patients().isEmpty)
        DemoServer.scenario = .tour
    }

    @Test func tourCyclesThroughSteps() {
        let start = Date(timeIntervalSince1970: 0)
        let steps = (0..<DemoScenario.tourSteps.count).map {
            DemoScenario.tour.resolved(at: start.addingTimeInterval(Double($0) * DemoScenario.tourStep))
        }
        #expect(steps == DemoScenario.tourSteps)
        #expect(DemoScenario.high.resolved(at: start) == .high)
    }
}
