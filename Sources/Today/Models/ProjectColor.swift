import AppKit
import SwiftUI

/// La teinte d'un projet : une des couleurs de la palette, ou une couleur LIBRE choisie au sélecteur
/// de macOS.
///
/// Stockée dans `Project.colorRaw`, la même colonne qu'avant : `"blue"` pour la palette (le
/// `rawValue` de `PaletteColor`, inchangé), `"#3A7BD5"` pour une couleur libre. Aucune montée de
/// schéma — la colonne était déjà une chaîne, et une base d'avant se relit telle quelle.
///
/// Les en-têtes de section gardent la palette seule (`TaskItem.headerColor`) : seul le projet a
/// demandé la couleur libre.
enum ProjectColor: Equatable {
  case palette(PaletteColor)
  /// `0xRRGGBB`, en sRGB.
  case custom(UInt32)

  init?(raw: String) {
    if let palette = PaletteColor(rawValue: raw) {
      self = .palette(palette)
    } else if let hex = Self.parseHex(raw) {
      self = .custom(hex)
    } else {
      return nil
    }
  }

  var raw: String {
    switch self {
    case .palette(let palette): return palette.rawValue
    case .custom(let hex): return String(format: "#%06X", hex)
    }
  }

  var palette: PaletteColor? {
    if case .palette(let palette) = self { return palette }
    return nil
  }

  /// `"#3A7BD5"` (dièse obligatoire, six chiffres) → `0x3A7BD5`. Le dièse distingue sans ambiguïté
  /// une couleur libre d'un nom de la palette, aujourd'hui comme le jour où elle en gagnera un.
  static func parseHex(_ raw: String) -> UInt32? {
    guard raw.count == 7, raw.first == "#" else { return nil }
    return UInt32(raw.dropFirst(), radix: 16)
  }

  /// La variante SOMBRE d'une couleur libre. Les couleurs de la palette sont des couleurs système,
  /// qui s'ajustent seules entre les deux thèmes ; une couleur libre est figée, et un bleu nuit
  /// choisi en clair disparaîtrait sur le fond sombre. Même geste qu'Apple sur ses couleurs
  /// système : plus lumineuse, un peu moins saturée.
  ///
  /// ponytail: une règle fixe (+0,15 de luminosité, ×0,9 de saturation, plancher à 0,55). Si une
  /// couleur précise le demande un jour, laisser choisir sa variante sombre à la main.
  static func darkVariant(of hex: UInt32) -> UInt32 {
    let color = NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    let dark = NSColor(
      hue: hue, saturation: saturation * 0.9, brightness: max(0.55, min(1, brightness + 0.15)),
      alpha: 1
    ).usingColorSpace(.sRGB)!
    return hexValue(of: dark)
  }

  /// `NSColor` (n'importe quel espace) → `0xRRGGBB` sRGB. `nil` pour une couleur sans équivalent
  /// sRGB (un motif, une couleur nommée de catalogue sans composantes).
  static func hex(of color: NSColor) -> UInt32? {
    color.usingColorSpace(.sRGB).map(hexValue(of:))
  }

  private static func hexValue(of srgb: NSColor) -> UInt32 {
    func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
    return byte(srgb.redComponent) << 16 | byte(srgb.greenComponent) << 8 | byte(srgb.blueComponent)
  }

  /// Ce que peignent l'icône, les anneaux, la barre et le bandeau du projet. Une couleur libre passe
  /// par `dualColor`, la seule façon de doubler une couleur figée dans cette app (cf. `Theme.swift`).
  var color: Color {
    switch self {
    case .palette(let palette): return palette.color
    case .custom(let hex): return dualColor(light: hex, dark: Self.darkVariant(of: hex))
    }
  }
}
