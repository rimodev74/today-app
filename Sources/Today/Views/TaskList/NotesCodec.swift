import AppKit

/// Sérialise les notes riches (gras, italique, liens) en RTF pour le stockage `Data` des modèles
/// (`TaskItem.notes`, `TodoList.notes`, `Project.notes`). Seul point de conversion : les modèles
/// eux-mêmes restent ignorants du RTF, ils stockent du `Data` opaque.
enum NotesCodec {
  static func decode(_ data: Data) -> NSAttributedString {
    guard !data.isEmpty,
      let attributed = NSAttributedString(rtf: data, documentAttributes: nil)
    else { return NSAttributedString() }
    return attributed
  }

  /// Une note vide encode TOUJOURS en `Data()` exactement (jamais un en-tête RTF vide) : les
  /// `.isEmpty` sur `notes: Data` dans les vues restent fiables sans repasser par ce module.
  /// Le RTF sérialise le RGB résolu, pas une `NSColor` dynamique : un texte coloré via
  /// `.labelColor`/`.secondaryLabelColor` au moment de l'encodage garde cette couleur figée après
  /// rechargement, même si l'apparence système change entre-temps.
  static func encode(_ attributedString: NSAttributedString) -> Data {
    guard !attributedString.string.isEmpty else { return Data() }
    let range = NSRange(location: 0, length: attributedString.length)
    return attributedString.rtf(from: range, documentAttributes: [:]) ?? Data()
  }

  /// Aperçus déjà calculés, par contenu RTF. Le décodage RTF et l'expression régulière coûtent bien
  /// plus qu'une comparaison d'octets, et une rangée rejoue son corps à chaque survol : sans cache,
  /// chaque survol d'une tâche à notes redécodait le RTF. Clé = les octets eux-mêmes (`NSData`
  /// compare le contenu, pas l'identité) : une note modifiée change de clé toute seule, il n'y a
  /// rien à invalider. Borné en nombre ET en poids, `NSCache` vidant de lui-même sous pression.
  ///
  /// `nonisolated(unsafe)` : `NSCache` n'est pas `Sendable` pour le compilateur, mais Apple la
  /// documente sûre depuis plusieurs fils — et c'est la seule chose partagée ici.
  nonisolated(unsafe) private static let previews: NSCache<NSData, NSString> = {
    let cache = NSCache<NSData, NSString>()
    cache.countLimit = 512
    cache.totalCostLimit = 4 * 1024 * 1024
    return cache
  }()

  /// Texte brut, pour l'aperçu tronqué (une ligne, sans mise en forme) sous une tâche au repos.
  /// Retours à la ligne et espaces multiples repliés en un seul espace : l'aperçu reste une ligne
  /// continue que la vue tronque à sa largeur, au lieu de s'arrêter au premier `\n` d'une note
  /// multi-lignes (ex. une consigne suivie de ses détails). Mémoïsé (cf. `previews`).
  static func plainText(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }
    let key = data as NSData
    if let cached = previews.object(forKey: key) { return cached as String }
    let text = decode(data).string
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    previews.setObject(text as NSString, forKey: key, cost: data.count + text.utf8.count)
    return text
  }

  /// Vrai si l'aperçu de ces octets est déjà en cache — pour le test qui vérifie que le second
  /// appel ne recalcule pas.
  static func hasCachedPreview(for data: Data) -> Bool {
    previews.object(forKey: data as NSData) != nil
  }
}
