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
  @ObservationIgnored private var connections: OpenConnections?
  @ObservationIgnored private var key: SharedKey?
  @ObservationIgnored private var requestedPort: UInt16?
  @ObservationIgnored private let queue = DispatchQueue(label: "today.mcp")

  @ObservationIgnored private let connectionTimeout: TimeInterval

  init(container: ModelContainer, effects: MCPEffects, connectionTimeout: TimeInterval = 10) {
    self.container = container
    self.effects = effects
    self.connectionTimeout = connectionTimeout
  }

  /// `port: 0` laisse le système choisir (tests) ; l'état donne alors le port réel.
  func start(port: UInt16, key: String) {
    // Même port, clé neuve (« Régénérer la clé ») : on garde l'écoute et on change la clé. Arrêter
    // puis relier le port échouait une fois sur trois — macOS ne l'a pas encore rendu, et le
    // relancement répondait « Port déjà utilisé ». Une connexion déjà ouverte est jugée sur la
    // NOUVELLE clé : la porte la lit au moment de trancher.
    if listener != nil, port != 0, requestedPort == port || state == .listening(port: port),
      let shared = self.key
    {
      shared.set(key)
      return
    }
    stop()
    let shared = SharedKey(key)
    let parameters = NWParameters.tcp
    // 127.0.0.1 et rien d'autre : rien n'atteint ce port depuis le réseau.
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
    parameters.allowLocalEndpointReuse = true
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      state = .failed(Self.describe(error, port: port))
      return
    }
    // Une requête déjà décodée quand l'écoute s'arrête (bascule décochée, clé régénérée) ne
    // s'exécute pas : elle a été admise par un serveur qui n'existe plus.
    let route: @Sendable (JSONValue) async -> JSONValue? = { [weak self, weak listener] request in
      await self?.route(request, admittedBy: listener)
    }
    let queue = queue
    let timeout = connectionTimeout
    let pool = OpenConnections()
    listener.newConnectionHandler = { connection in
      guard pool.admit(connection) else {
        connection.start(queue: queue)
        return Self.respond(connection, status: 503)
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .cancelled, .failed: pool.forget(connection)
        default: break
        }
      }
      connection.start(queue: queue)
      // Une connexion qui n'envoie jamais la fin de sa requête ne garde pas un descripteur à vie :
      // l'app les partage avec SQLite.
      queue.asyncAfter(deadline: .now() + timeout) { connection.cancel() }
      Self.receive(on: connection, buffer: Data(), key: shared, route: route)
    }
    listener.stateUpdateHandler = { [weak self, weak listener] update in
      // Le port réel n'est connu qu'une fois lié (`port: 0`) ; en échec, `listener.port` vaut 0.
      let bound = listener?.port?.rawValue ?? 0
      Task { @MainActor in self?.apply(update, port: bound == 0 ? port : bound, from: listener) }
    }
    self.listener = listener
    self.connections = pool
    self.key = shared
    self.requestedPort = port
    listener.start(queue: queue)
  }

  /// Coupe l'écoute ET les connexions ouvertes : une connexion admise avant l'arrêt enverrait
  /// sinon sa requête plus tard, avec l'ancienne clé.
  func stop() {
    listener?.stateUpdateHandler = nil
    listener?.cancel()
    listener = nil
    if let pool = connections { queue.async { pool.cancelAll() } }
    connections = nil
    key = nil
    requestedPort = nil
    state = .off
  }

  /// `from` : l'écouteur qui parle. Un `.failed` de l'ANCIEN, mis en file juste avant un
  /// redémarrage (« Régénérer la clé »), coupait sinon le nouveau.
  private func apply(_ update: NWListener.State, port: UInt16, from origin: NWListener?) {
    guard let listener, origin === listener else { return }
    switch update {
    case .ready: state = .listening(port: port)
    case .failed(let error):
      state = .failed(Self.describe(error, port: port))
      listener.cancel()
      self.listener = nil
    default: break
    }
  }

  /// Le cas courant dit en clair ; le reste garde le message système, qui est ce qu'on a de mieux.
  private static func describe(_ error: Error, port: UInt16) -> String {
    if case NWError.posix(.EADDRINUSE) = error {
      return "Port \(port) déjà utilisé par un autre programme."
    }
    return "Port \(port) indisponible : \(error.localizedDescription)"
  }

  private func route(_ request: JSONValue, admittedBy origin: NWListener?) -> JSONValue? {
    guard let listener, origin === listener else {
      return .object([
        "jsonrpc": .string("2.0"), "id": request["id"] ?? .null,
        "error": .object([
          "code": .number(-32000), "message": .string("Today a coupé l'accès de Claude Code."),
        ]),
      ])
    }
    return MCPRouter(context: container.mainContext, effects: effects).handle(request)
  }

  // MARK: - Connexions (hors fil principal)

  private nonisolated static func receive(
    on connection: NWConnection, buffer: Data, key: SharedKey,
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
        if let refusal = MCPGate.status(for: request, key: key.value) {
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
      503: "Service Unavailable",
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

/// Les connexions ouvertes d'UN écouteur. Touché seulement sur la file du serveur.
/// ponytail: `@unchecked Sendable` + verrou plutôt qu'un acteur — les rappels de `Network` sont
/// synchrones, un acteur forcerait un saut asynchrone à chaque admission.
private final class OpenConnections: @unchecked Sendable {
  /// Au-delà, 503 : Claude Code n'ouvre qu'une poignée de connexions à la fois.
  static let limit = 16
  private let lock = NSLock()
  private var open: [ObjectIdentifier: NWConnection] = [:]

  func admit(_ connection: NWConnection) -> Bool {
    lock.withLock {
      guard open.count < Self.limit else { return false }
      open[ObjectIdentifier(connection)] = connection
      return true
    }
  }

  func forget(_ connection: NWConnection) {
    lock.withLock { _ = open.removeValue(forKey: ObjectIdentifier(connection)) }
  }

  func cancelAll() {
    let all = lock.withLock {
      let all = Array(open.values)
      open.removeAll()
      return all
    }
    all.forEach { $0.cancel() }
  }
}

/// La clé en vigueur, lue par la porte au moment de trancher : la changer n'exige pas de relier
/// le port. Touchée depuis le fil principal (écriture) et la file du serveur (lecture).
private final class SharedKey: @unchecked Sendable {
  private let lock = NSLock()
  private var current: String
  init(_ key: String) { current = key }
  var value: String { lock.withLock { current } }
  func set(_ key: String) { lock.withLock { current = key } }
}
