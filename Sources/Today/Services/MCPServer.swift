import Foundation
import Network
import Observation
import SwiftData

/// Le serveur MCP de Today : HTTP sur 127.0.0.1, un `POST /mcp` par requête JSON-RPC.
///
/// Le fil principal ne voit que l'appel d'outil (`MCPRouter`, écritures SwiftData sur le contexte
/// de l'interface). Réception, analyse, décodage et encodage JSON se font sur `queue`.
@MainActor
@Observable
final class MCPServer {
  enum State: Equatable {
    case off
    case listening(port: UInt16)
    case failed(String)
  }

  private(set) var state: State = .off

  @ObservationIgnored private let container: ModelContainer
  @ObservationIgnored private let effects: MCPEffects
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private let queue = DispatchQueue(label: "today.mcp")

  init(container: ModelContainer, effects: MCPEffects) {
    self.container = container
    self.effects = effects
  }

  /// `port: 0` laisse le système choisir (tests) ; l'état donne alors le port réel.
  func start(port: UInt16, key: String) {
    stop()
    let parameters = NWParameters.tcp
    // 127.0.0.1 et rien d'autre : rien n'atteint ce port depuis le réseau.
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
    parameters.allowLocalEndpointReuse = true
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      state = .failed("Port \(port) indisponible (\(error.localizedDescription)).")
      return
    }
    let route: @Sendable (JSONValue) async -> JSONValue? = { [weak self] request in
      await self?.route(request)
    }
    let queue = queue
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      Self.receive(on: connection, buffer: Data(), key: key, route: route)
    }
    listener.stateUpdateHandler = { [weak self, weak listener] update in
      let bound = listener?.port?.rawValue ?? port
      Task { @MainActor in self?.apply(update, port: bound) }
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  /// ponytail: n'annule que l'écoute. Chaque connexion se ferme d'elle-même après SA réponse
  /// (`Connection: close`) ; une requête en vol au moment de l'arrêt finit son tour.
  func stop() {
    listener?.stateUpdateHandler = nil
    listener?.cancel()
    listener = nil
    state = .off
  }

  private func apply(_ update: NWListener.State, port: UInt16) {
    guard listener != nil else { return }
    switch update {
    case .ready: state = .listening(port: port)
    case .failed(let error):
      state = .failed("Port \(port) indisponible (\(error.localizedDescription)).")
      listener?.cancel()
      listener = nil
    default: break
    }
  }

  private func route(_ request: JSONValue) -> JSONValue? {
    MCPRouter(context: container.mainContext, effects: effects).handle(request)
  }

  // MARK: - Connexions (hors fil principal)

  private nonisolated static func receive(
    on connection: NWConnection, buffer: Data, key: String,
    route: @escaping @Sendable (JSONValue) async -> JSONValue?
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      switch HTTPRequest.parse(buffer) {
      case .incomplete:
        // Le client a raccroché avant la fin : rien ne s'exécute sur un corps tronqué.
        if isComplete || error != nil {
          connection.cancel()
        } else {
          receive(on: connection, buffer: buffer, key: key, route: route)
        }
      case .malformed: respond(connection, status: 400)
      case .tooLarge: respond(connection, status: 413)
      case .complete(let request):
        if let refusal = MCPGate.status(for: request, key: key) {
          return respond(connection, status: refusal)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
          return respond(connection, status: 400)
        }
        Task {
          if let reply = await route(json), let body = try? JSONEncoder().encode(reply) {
            respond(connection, status: 200, body: body)
          } else {
            respond(connection, status: 202)  // notification : rien à répondre
          }
        }
      }
    }
  }

  private nonisolated static func respond(
    _ connection: NWConnection, status: Int, body: Data? = nil
  ) {
    let reasons = [
      200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
    ]
    var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
    head += "Connection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
    if body != nil { head += "Content-Type: application/json\r\n" }
    if status == 405 { head += "Allow: POST\r\n" }
    head += "\r\n"
    connection.send(
      content: Data(head.utf8) + (body ?? Data()),
      completion: .contentProcessed { _ in connection.cancel() })
  }
}
