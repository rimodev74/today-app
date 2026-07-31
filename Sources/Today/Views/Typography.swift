import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// Échelle typographique globale de l'app.
///
/// macOS n'expose pas de Dynamic Type : les `Font.TextStyle` natifs sont figés (body = 13 pt) et
/// `.dynamicTypeSize()` ne touche pas les `.system(size:)` en dur. Pour que TOUT grossisse dans les
/// mêmes proportions — sémantique, tailles fixes et éditeurs AppKit — tout passe par ici.
enum Typo {
  /// 1.0 = tailles système natives.
  static let scale: CGFloat = 1.05

  static func size(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }

  /// Tailles natives macOS des styles sémantiques, que SwiftUI ne laisse pas lire.
  static func size(_ style: Font.TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: size(26)
    case .title: size(22)
    case .title2: size(17)
    case .title3: size(15)
    case .headline, .body: size(13)
    case .callout: size(12)
    case .subheadline: size(11)
    case .footnote, .caption, .caption2: size(10)
    @unknown default: size(13)
    }
  }
}

extension Font {
  static func app(
    _ points: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
  ) -> Font {
    .system(size: Typo.size(points), weight: weight, design: design)
  }

  /// Équivalent mis à l'échelle d'un style natif : `.font(.app(.callout))` remplace `.font(.callout)`.
  static func app(_ style: Font.TextStyle) -> Font {
    .system(size: Typo.size(style), weight: style == .headline ? .semibold : .regular)
  }
}

#if canImport(AppKit)
  extension NSFont {
    /// Pour les `NSTextView` (titres de tâche, notes) qui ne passent pas par `Font`.
    static func app(_ points: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular)
      -> NSFont
    {
      .systemFont(ofSize: Typo.size(points), weight: weight)
    }
  }
#endif
