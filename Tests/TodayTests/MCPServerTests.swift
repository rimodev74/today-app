import Foundation
import SwiftData
import XCTest

@testable import Today

final class MCPServerTests: XCTestCase {
  private func raw(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

  private func request(
    method: String = "POST", path: String = "/mcp", headers: [String: String]
  ) -> HTTPRequest {
    HTTPRequest(method: method, path: path, headers: headers, body: Data("{}".utf8))
  }

  // MARK: - Analyse

  func testParseCompleteRequest() {
    let result = HTTPRequest.parse(
      raw("POST /mcp HTTP/1.1\nHost: x\nContent-Length: 2\nAuthorization: Bearer k\n\n") + Data("{}".utf8))
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
    XCTAssertEqual(MCPGate.status(for: request(headers: ["authorization": "Bearer x"]), key: "k"), 401)
    XCTAssertEqual(MCPGate.status(for: request(headers: [:]), key: "k"), 401)
    XCTAssertEqual(MCPGate.status(for: request(headers: ["authorization": "Bearer "]), key: ""), 401)
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
      if case .listening(let p) = server.state { port = p; break }
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
        (response as! HTTPURLResponse).statusCode, try? JSONDecoder().decode(JSONValue.self, from: data)
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
}
