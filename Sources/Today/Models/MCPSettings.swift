import Foundation
import Security

/// Les réglages du serveur MCP : bascule, clé, port, et la commande qui branche Claude Code.
///
/// Bascule ÉTEINTE par défaut : un port qui écoute est un choix, pas un cadeau.
enum MCPSettings {
  static let enabledKey = "mcpEnabled"
  static let secretKey = "mcpKey"

  /// Un port par instance : `TodayDev` (lancé par `run-dev.sh`, qui pose `TODAY_APP_SUPPORT_DIR`)
  /// tourne à côté de l'app du quotidien, et deux listeners ne partagent pas un port.
  static func port(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
    environment["TODAY_APP_SUPPORT_DIR"] == nil ? 48631 : 48632
  }

  /// Le nom sous lequel Claude Code connaît le serveur : distinct pour l'instance de dev, sinon
  /// brancher l'une débrancherait l'autre.
  static func serverName(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    environment["TODAY_APP_SUPPORT_DIR"] == nil ? "today" : "today-dev"
  }

  /// La clé, générée au premier besoin. Dans les défauts du bundle (`TodayDev` a les siens).
  /// ponytail: pas le Trousseau — un process qui tourne sous le même utilisateur lit de toute façon
  /// la base SQLite directement ; le Trousseau ne protégerait rien de plus.
  static func key(in defaults: UserDefaults = .standard) -> String {
    if let existing = defaults.string(forKey: secretKey), existing.count == 64 { return existing }
    return regenerateKey(in: defaults)
  }

  @discardableResult
  static func regenerateKey(in defaults: UserDefaults = .standard) -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes : \(status)")
    let key = bytes.map { String(format: "%02x", $0) }.joined()
    defaults.set(key, forKey: secretKey)
    return key
  }

  static func command(name: String, port: UInt16, key: String) -> String {
    "claude mcp add --transport http --scope user \(name) http://127.0.0.1:\(port)/mcp "
      + "--header \"Authorization: Bearer \(key)\""
  }
}
