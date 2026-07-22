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

  /// Texte brut, pour l'aperçu tronqué (une ligne, sans mise en forme) sous une tâche au repos.
  /// Retours à la ligne et espaces multiples repliés en un seul espace : l'aperçu reste une ligne
  /// continue que la vue tronque à sa largeur, au lieu de s'arrêter au premier `\n` d'une note
  /// multi-lignes (ex. une consigne suivie de ses détails).
  static func plainText(_ data: Data) -> String {
    decode(data).string
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }
}
