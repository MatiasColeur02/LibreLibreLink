import Foundation
import Testing
@testable import LibreKit

// Fixtures anonimizadas con la forma de las respuestas de LibreLinkUp
// (según los modelos de pylibrelinkup 0.11.1).

@Test func regionRejectsArbitraryHosts() {
    #expect(Region(code: "LA")?.baseURL.absoluteString == "https://api-la.libreview.io")
    #expect(Region(code: "us")?.baseURL.absoluteString == "https://api.libreview.io")
    #expect(Region(code: "ru")?.baseURL.absoluteString == "https://api.libreview.ru")
    #expect(Region(code: "evil.com/") == nil)
    #expect(Region(code: "") == nil)
}

@Test func loginRedirect() throws {
    let json = #"{"status":0,"data":{"redirect":true,"region":"la"}}"#
    guard case .redirect(let region) = try LibreLinkUpClient.interpretLogin(Data(json.utf8)) else {
        Issue.record("esperaba redirect"); return
    }
    #expect(region.code == "la")
}

@Test func loginSuccess() throws {
    let json = #"""
    {"status":0,"data":{"user":{"id":"user-123","firstName":"A"},
     "authTicket":{"token":"tok","expires":1900000000,"duration":15552000000}}}
    """#
    guard case .success(let ticket, let userID) = try LibreLinkUpClient.interpretLogin(Data(json.utf8)) else {
        Issue.record("esperaba success"); return
    }
    #expect(ticket.token == "tok")
    #expect(userID == "user-123")
}

@Test func loginSteps() {
    let tou = #"{"status":4,"data":{"step":{"type":"tou"}}}"#
    #expect(throws: LibreLinkUpError.mustAcceptTerms) { try LibreLinkUpClient.interpretLogin(Data(tou.utf8)) }
    let bad = #"{"status":2,"error":{"message":"notAuthenticated"}}"#
    #expect(throws: LibreLinkUpError.invalidCredentials("notAuthenticated")) {
        try LibreLinkUpClient.interpretLogin(Data(bad.utf8))
    }
}

@Test func accountIDHashIsSHA256Hex() {
    #expect(LibreLinkUpClient.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func patients() throws {
    let json = #"{"status":0,"data":[{"id":"c1","patientId":"p-1","firstName":"Ana","lastName":"Pérez"}]}"#
    let list = try LibreLinkUpClient.decodePatients(Data(json.utf8))
    #expect(list == [Patient(id: "p-1", firstName: "Ana", lastName: "Pérez")])
}

@Test func graphParsesCurrentAndSortedHistory() throws {
    let json = #"""
    {"status":0,"data":{
      "connection":{"glucoseMeasurement":{"FactoryTimestamp":"10/12/2026 3:04:05 PM","Timestamp":"10/12/2026 12:04:05 PM",
        "ValueInMgPerDl":123,"TrendArrow":4,"isHigh":false,"isLow":false}},
      "graphData":[
        {"FactoryTimestamp":"10/12/2026 2:59:05 PM","ValueInMgPerDl":118,"isHigh":false,"isLow":false},
        {"FactoryTimestamp":"10/12/2026 2:54:05 PM","ValueInMgPerDl":60,"isHigh":false,"isLow":true}
      ]}}
    """#
    let graph = try LibreLinkUpClient.decodeGraph(Data(json.utf8))
    let current = try #require(graph.current)
    #expect(current.mgdL == 123)
    #expect(current.trend == .rising)
    // 15:04:05 UTC
    #expect(current.date == Date(timeIntervalSince1970: 1_791_817_445))
    #expect(graph.history.map(\.mgdL) == [60, 118])
    #expect(graph.history.first?.isLow == true)
}
