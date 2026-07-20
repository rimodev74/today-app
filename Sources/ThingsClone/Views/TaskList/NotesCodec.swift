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
  static func encode(_ attributedString: NSAttributedString) -> Data {
    guard !attributedString.string.isEmpty else { return Data() }
    let range = NSRange(location: 0, length: attributedString.length)
    return attributedString.rtf(from: range, documentAttributes: [:]) ?? Data()
  }

  /// Texte brut, pour l'aperçu tronqué (une ligne, sans mise en forme) sous une tâche au repos.
  static func plainText(_ data: Data) -> String {
    decode(data).string
  }
}
