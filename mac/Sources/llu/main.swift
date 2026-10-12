import Foundation
import LibreKit

// Uso: LLU_EMAIL=... LLU_PASSWORD=... swift run llu
//      swift run llu --demo [escenario]   (servidor falso, sin cuenta)
// Prueba login, lista pacientes y muestra la última lectura de cada uno.

let env = ProcessInfo.processInfo.environment
let arguments = CommandLine.arguments.dropFirst()
let client: LibreLinkUpClient
if arguments.first == "--demo" {
    if let name = arguments.dropFirst().first {
        guard let scenario = DemoScenario(rawValue: name) else {
            let names = DemoScenario.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("Escenario desconocido. Opciones: \(names)\n".utf8))
            exit(2)
        }
        DemoServer.scenario = scenario
    } else {
        DemoServer.scenario = .normal
    }
    client = DemoServer.makeClient()
} else {
    guard let email = env["LLU_EMAIL"], let password = env["LLU_PASSWORD"] else {
        FileHandle.standardError.write(Data("Definí LLU_EMAIL y LLU_PASSWORD (cuenta de LibreLinkUp), o usá --demo.\n".utf8))
        exit(2)
    }
    client = LibreLinkUpClient(email: email, password: password, region: env["LLU_REGION"].flatMap(Region.init(code:)) ?? .global)
}

do {
    let patients = try await client.patients()
    print("Región: \(await client.region) — \(patients.count) paciente(s)")
    let time = DateFormatter()
    time.dateStyle = .short
    time.timeStyle = .medium
    for patient in patients {
        let graph = try await client.graph(patientID: patient.id)
        if let current = graph.current {
            let age = Int(Date().timeIntervalSince(current.date) / 60)
            print("\(patient.displayName): \(Int(current.mgdL)) mg/dL \(current.trend?.arrow ?? "") (\(time.string(from: current.date)), hace \(age) min)")
        } else {
            print("\(patient.displayName): sin lectura actual")
        }
        print("  historial: \(graph.history.count) puntos")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
