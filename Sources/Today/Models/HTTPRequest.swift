import Foundation

/// Une requête HTTP/1.1 réduite à ce qu'un client MCP envoie : une ligne, des en-têtes, un corps à
/// `Content-Length`. Pas de `chunked`, pas de keep-alive (on répond `Connection: close`).
///
/// ponytail: HTTP fait main plutôt qu'un serveur embarqué — `Network.framework` ne fournit que le
/// TCP, et une dépendance pour UN chemin POST serait plus lourde que ces quarante lignes. Le jour
/// où il faut du flux (SSE) ou du `chunked`, c'est ici qu'il manquera.
struct HTTPRequest: Sendable, Equatable {
  let method: String
  let path: String
  /// Clés en minuscules : HTTP ne distingue pas la casse des noms d'en-têtes.
  let headers: [String: String]
  let body: Data

  static let maxBodyBytes = 1_048_576

  enum ParseResult: Equatable {
    case incomplete
    case malformed
    case tooLarge
    case complete(HTTPRequest)
  }

  /// Analyse ce qui est arrivé jusqu'ici. `.incomplete` tant que les en-têtes ou le corps annoncé ne
  /// sont pas entiers : TCP livre en paquets, un corps tronqué ne s'exécute JAMAIS.
  static func parse(_ buffer: Data) -> ParseResult {
    guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      // En-têtes plus gros que le plafond : personne ne les finira.
      return buffer.count > maxBodyBytes ? .tooLarge : .incomplete
    }
    guard let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else {
      return .malformed
    }
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .malformed }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { return .malformed }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let method = String(parts[0])
    let length: Int
    if let declared = headers["content-length"] {
      guard let value = Int(declared), value >= 0 else { return .malformed }
      length = value
    } else if method == "POST" {
      return .malformed
    } else {
      length = 0
    }
    guard length <= maxBodyBytes else { return .tooLarge }
    let bodyStart = split.upperBound
    guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
    let body = Data(buffer[bodyStart..<(bodyStart + length)])
    return .complete(
      HTTPRequest(method: method, path: String(parts[1]), headers: headers, body: body))
  }
}

/// Qui a le droit d'entrer. `nil` = autorisé, sinon le statut HTTP du refus.
///
/// L'ordre compte : `Origin` d'abord, parce qu'un navigateur en envoie TOUJOURS un et que Claude
/// Code n'en envoie pas. C'est ce qui ferme la porte au DNS rebinding : une page web qui ferait
/// pointer un domaine vers 127.0.0.1 atteindrait le port, jamais la base.
enum MCPGate {
  static func status(for request: HTTPRequest, key: String) -> Int? {
    if request.headers["origin"] != nil { return 403 }
    guard !key.isEmpty, let auth = request.headers["authorization"], auth.hasPrefix("Bearer "),
      constantTimeEqual(String(auth.dropFirst("Bearer ".count)), key)
    else { return 401 }
    guard request.path == "/mcp" else { return 404 }
    guard request.method == "POST" else { return 405 }
    return nil
  }

  /// Comparaison qui ne s'arrête pas au premier octet différent : le temps de réponse ne dit rien
  /// de la longueur du préfixe juste.
  static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8)
    let rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
    return diff == 0
  }
}
