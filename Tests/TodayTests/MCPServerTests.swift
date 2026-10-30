import Foundation
import Network
import SwiftData
import XCTest

@testable import Today

final class MCPServerTests: XCTestCase {
  private func raw(_ text: String) -> Data {
    Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
  }

  private func request(
    method: String = "POST", path: String = "/mcp", headers: [String: String]
  ) -> HTTPRequest {
    HTTPRequest(method: method, path: path, headers: headers, body: Data("{}".utf8))
  }

  // MARK: - Analyse

  func testParseCompleteRequest() {
    let result = HTTPRequest.parse(
      raw("POST /mcp HTTP/1.1\nHost: x\nContent-Length: 2\nAuthorization: Bearer k\n\n")
        + Data("{}".utf8))
    guard case .complete(let request) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/mcp")
    XCTAssertEqual(request.headers["authorization"], "Bearer k")
    XCTAssertEqual(request.body, Data("{}".utf8))
  }

  func testParseIncompleteUntilBodyArrives() {
    let head = raw("POST /mcp HTTP/1.1\nContent-Length: 10\n\n")
    XCTAssertEqual(HTTPRequest.parse(head), .incomplete)
    XCTAssertEqual(HTTPRequest.parse(raw("POST /mcp HTTP/1.1\nContent-Le")), .incomplete)
    guard case .complete(let request) = HTTPRequest.parse(head + Data("0123456789".utf8)) else {
      return XCTFail()
    }
    XCTAssertEqual(request.body.count, 10)
  }

  func testParseMissingContentLengthOnPostIsMalformed() {
    XCTAssertEqual(HTTPRequest.parse(raw("POST /mcp HTTP/1.1\nHost: x\n\n")), .malformed)
    XCTAssertEqual(HTTPRequest.parse(raw("garbage\n\n")), .malformed)
  }

  func testParseTooLarge() {
    XCTAssertEqual(
      HTTPRequest.parse(raw("POST /mcp HTTP/1.1\nContent-Length: 2000000\n\n")), .tooLarge)
  }

  // MARK: - Porte

  func testGateRejectsOrigin() {
    let r = request(headers: ["authorization": "Bearer k", "origin": "http://evil.example"])
    XCTAssertEqual(MCPGate.status(for: r, key: "k"), 403)
  }

  func testGateRejectsBadKey() {
    XCTAssertEqual(
      MCPGate.status(for: request(headers: ["authorization": "Bearer x"]), key: "k"), 401)
    XCTAssertEqual(MCPGate.status(for: request(headers: [:]), key: "k"), 401)
    XCTAssertEqual(
      MCPGate.status(for: request(headers: ["authorization": "Bearer "]), key: ""), 401)
  }

  func testGateRejectsGet() {
    let r = request(method: "GET", headers: ["authorization": "Bearer k"])
    XCTAssertEqual(MCPGate.status(for: r, key: "k"), 405)
    let other = request(path: "/x", headers: ["authorization": "Bearer k"])
    XCTAssertEqual(MCPGate.status(for: other, key: "k"), 404)
  }

  func testGateAcceptsBearer() {
    XCTAssertNil(MCPGate.status(for: request(headers: ["authorization": "Bearer k"]), key: "k"))
  }

  // MARK: - De bout en bout

  @MainActor
  func testServerAnswersInitializeOverLoopback() async throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let container = try ModelContainer(
      for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    let server = MCPServer(
      container: container, effects: MCPEffects(forgetAppleItems: { _ in }, removeCover: { _ in }))
    server.start(port: 0, key: "secret")
    defer { server.stop() }
    var port: UInt16 = 0
    for _ in 0..<100 {
      if case .listening(let p) = server.state {
        port = p
        break
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertNotEqual(port, 0, "état : \(server.state)")

    func post(_ headers: [String: String]) async throws -> (Int, JSONValue?) {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
      request.httpMethod = "POST"
      request.httpBody = Data(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
          .utf8)
      for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
      let (data, response) = try await URLSession.shared.data(for: request)
      return (
        (response as! HTTPURLResponse).statusCode,
        try? JSONDecoder().decode(JSONValue.self, from: data)
      )
    }

    let (ok, body) = try await post(["Authorization": "Bearer secret"])
    XCTAssertEqual(ok, 200)
    XCTAssertEqual(body?["result"]?["serverInfo"]?["name"]?.stringValue, "Today")
    let (forbidden, _) = try await post(["Authorization": "Bearer secret", "Origin": "http://evil"])
    XCTAssertEqual(forbidden, 403)
    let (unauthorized, _) = try await post([:])
    XCTAssertEqual(unauthorized, 401)
  }

  @MainActor
  func testBusyPortReportsTheRequestedPort() async throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let container = try ModelContainer(
      for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    let effects = MCPEffects(forgetAppleItems: { _ in }, removeCover: { _ in })
    let first = MCPServer(container: container, effects: effects)
    first.start(port: 0, key: "k")
    defer { first.stop() }
    var port: UInt16 = 0
    for _ in 0..<100 {
      if case .listening(let p) = first.state {
        port = p
        break
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let second = MCPServer(container: container, effects: effects)
    second.start(port: port, key: "k")
    defer { second.stop() }
    for _ in 0..<100 {
      if case .failed = second.state { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(second.state, .failed("Port \(port) déjà utilisé par un autre programme."))
  }

  @MainActor
  private func listeningServer(timeout: TimeInterval = 10) async throws -> (MCPServer, UInt16) {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let container = try ModelContainer(
      for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    let server = MCPServer(
      container: container, effects: MCPEffects(forgetAppleItems: { _ in }, removeCover: { _ in }),
      connectionTimeout: timeout)
    server.start(port: 0, key: "k")
    for _ in 0..<100 {
      if case .listening(let p) = server.state { return (server, p) }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("pas d'écoute : \(server.state)")
    return (server, 0)
  }

  /// Ouvre une connexion, envoie une requête INCOMPLÈTE, et rend vrai si le serveur la ferme
  /// avant `deadline` secondes.
  private func closesHalfOpenConnection(
    port: UInt16, within deadline: TimeInterval, after: @escaping () -> Void = {}
  ) async -> Bool {
    let connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "test")
    connection.start(queue: queue)
    connection.send(
      content: Data("POST /mcp HTTP/1.1\r\nContent-Length: 50\r\n\r\n{".utf8),
      completion: .idempotent)
    after()
    return await withCheckedContinuation { continuation in
      let once = OnceFlag()
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
        _, _, isComplete, error in
        if once.take() { continuation.resume(returning: isComplete || error != nil) }
      }
      queue.asyncAfter(deadline: .now() + deadline) {
        if once.take() { continuation.resume(returning: false) }
        connection.cancel()
      }
    }
  }

  @MainActor
  func testIdleConnectionIsCutAfterTimeout() async throws {
    let (server, port) = try await listeningServer(timeout: 0.2)
    defer { server.stop() }
    let closed = await closesHalfOpenConnection(port: port, within: 2)
    XCTAssertTrue(closed)
  }

  @MainActor
  func testStopCutsOpenConnections() async throws {
    let (server, port) = try await listeningServer()
    let closed = await closesHalfOpenConnection(port: port, within: 2) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { server.stop() }
    }
    XCTAssertTrue(closed)
  }

  @MainActor
  func testRestartingKeepsTheNewListener() async throws {
    let (server, port) = try await listeningServer()
    defer { server.stop() }
    server.start(port: port, key: "k2")
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(server.state, .listening(port: port))

    func status(_ key: String) async throws -> Int {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
      request.httpMethod = "POST"
      request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as! HTTPURLResponse).statusCode
    }
    let fresh = try await status("k2")
    let stale = try await status("k")
    XCTAssertEqual(fresh, 200)
    XCTAssertEqual(stale, 401)
  }
}

/// Garantit qu'une continuation ne reprend qu'une fois.
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}

final class MCPSettingsTests: XCTestCase {
  private let defaults = UserDefaults(suiteName: "MCPSettingsTests")!

  override func setUp() { defaults.removePersistentDomain(forName: "MCPSettingsTests") }

  func testKeyIsGeneratedOnceThenStable() {
    let key = MCPSettings.key(in: defaults)
    XCTAssertEqual(key.count, 64)
    XCTAssertTrue(key.allSatisfy(\.isHexDigit))
    XCTAssertEqual(MCPSettings.key(in: defaults), key)
    XCTAssertNotEqual(MCPSettings.regenerateKey(in: defaults), key)
  }

  func testPortSeparatesDevInstance() {
    XCTAssertEqual(MCPSettings.port(environment: [:]), 48631)
    XCTAssertEqual(MCPSettings.port(environment: ["TODAY_APP_SUPPORT_DIR": "TodayDev"]), 48632)
  }

  func testCommand() {
    XCTAssertEqual(
      MCPSettings.command(name: "today", port: 48631, key: "abc"),
      #"claude mcp add --transport http --scope user today http://127.0.0.1:48631/mcp --header "Authorization: Bearer abc""#
    )
  }
}
