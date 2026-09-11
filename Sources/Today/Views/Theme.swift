import AppKit
import SwiftUI

// L'identité visuelle de l'app, en un seul endroit : le verre de la fenêtre, la couleur de chaque
// page, et les voiles qui rendent l'un lisible malgré l'autre.
//
// POURQUOI un fichier : ces valeurs ne veulent rien dire séparément. Le voile de page n'a de sens
// qu'en face du matériau qu'il couvre, et la teinte d'une page se retrouve à quatre endroits (le
// badge du bandeau, la case à cocher, la pilule d'heure, le lavis du fond). Éparpillées, elles
// dérivaient — c'est exactement ce qui s'est passé avec les trois `NSColor(name:)` écrits à la main
// dans `ContentView` et `SidebarView`, qui passent tous par `dualColor` désormais.

// MARK: - Couleurs doublées

private func srgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha)
}

/// Une couleur figée qui existe en DEUX versions, résolue par l'apparence de la vue qui la rend.
///
/// C'est la règle du projet mise en fonction : une `Color(red:…)` nue est un bug de mode sombre en
/// attente. Un `NSColor` à provider plutôt qu'un `@Environment(\.colorScheme)` — une seule
/// définition, lisible depuis n'importe où, y compris les calques AppKit qui n'ont pas
/// d'environnement SwiftUI.
func dualColor(
  light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
) -> Color {
  Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? srgb(dark, darkAlpha) : srgb(light, lightAlpha)
    })
}

// MARK: - La couleur d'une page

/// La teinte d'une destination. C'est le pivot de la refonte : chaque page porte SA couleur, et
/// cette couleur se retrouve partout où la page se signale — l'icône de sa ligne de sidebar, le
/// badge de son bandeau, le cercle de ses cases à cocher, ses pilules d'heure, le lavis de son fond.
///
/// Les valeurs sont plus sourdes en clair et plus claires en sombre : une même teinte posée sur du
/// verre blanc et sur du verre noir n'a pas le même contraste, et c'est le texte qui en paie le prix.
enum PageTint {
  // Ardoise BLEUTÉE et non grise : « Tâches » est la page la plus fournie, et un gris pur y
  // éteignait toute la colonne d'anneaux. Assez sourde pour rester un bac de réception.
  static let inbox = dualColor(light: 0x5F_6B85, dark: 0x99_A6C4)
  static let today = dualColor(light: 0xD9_8A1F, dark: 0xF2_A93C)
  static let upcoming = dualColor(light: 0x78_57E0, dark: 0xA3_8CF5)
  static let archive = dualColor(light: 0x2E_9E60, dark: 0x4F_C383)
  static let pomodoro = dualColor(light: 0xD8_503C, dark: 0xF0_705C)
}

private struct PageTintKey: EnvironmentKey {
  static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
  /// Posée UNE fois par la fenêtre à partir de la destination courante, lue par les rangées.
  ///
  /// Par l'environnement et non par un paramètre : la case à cocher est enfouie sous une `TaskRow`,
  /// elle-même sous une page, elle-même sous `TaskListView` — la faire descendre à la main
  /// demanderait un paramètre de plus à chacun des cinq chemins, et une page oubliée serait une
  /// page qui reste sur l'accent système sans que rien ne le dise. Une lecture d'environnement ne
  /// traverse pas SwiftData : c'est le contraire d'une propriété calculée de `@Model` lue par
  /// rangée (cf. CLAUDE.md § Ce qui se rend à chaque image).
  var pageTint: Color {
    get { self[PageTintKey.self] }
    set { self[PageTintKey.self] = newValue }
  }
}

// MARK: - Le verre

/// Le matériau de la fenêtre, en `behindWindow` : c'est le bureau qui est flouté, pas le contenu de
/// l'app.
///
/// `behindWindow` EXIGE une fenêtre non opaque à fond transparent (cf. `WindowConfigurator`) —
/// sinon AppKit n'a rien à prélever et le matériau retombe sur un gris plat. Les coins arrondis et
/// l'ombre restent natifs : c'est la vue de cadre de la fenêtre qui masque, pas nous.
///
/// `state` laissé au défaut (`.followsWindowActiveState`) : une fenêtre au second plan se
/// désature, comme le Finder et Mail. C'est le comportement système, on ne le contredit pas.
struct WindowGlass: NSViewRepresentable {
  let material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .behindWindow
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
  }
}

/// Ce qui se pose SUR le verre pour que le texte reste lisible.
///
/// Sans voile, un fond d'écran chargé traverse et le contraste s'effondre — c'est le défaut de
/// toutes les fenêtres « full glass » faites à la main. Les deux colonnes n'ont pas le même : la
/// page est celle qu'on lit, elle est plus couverte ; la sidebar reste plus vitrée, ce qui suffit à
/// les distinguer sans inventer de teinte (le problème des fonds opaques natifs, identiques en
/// sombre pour les deux colonnes).
///
/// ponytail: deux constantes à régler à l'œil, pas une formule de contraste. Plafond : sur un fond
/// d'écran très clair ET très contrasté, monter `page` de quelques centièmes.
enum Scrim {
  /// Les alphas sont ceux de la maquette (`--window-bg` / `--sidebar-bg`) : la page tire vraiment
  /// vers le BLANC, elle n'est pas un gris translucide. Un voile trop mince laissait le verre
  /// prendre la couleur du bureau jusque sous le texte — c'était gris quoi qu'on fasse.
  ///
  /// La sidebar reste plus grise ET moins couverte : elle prélève donc davantage sur le bureau.
  /// C'est ce double écart, pas une teinte inventée, qui sépare les deux colonnes.
  static let page = dualColor(light: 0xFF_FFFF, dark: 0x1E_1E22, lightAlpha: 0.68, darkAlpha: 0.52)
  static let sidebar = dualColor(
    light: 0xF2_F2F5, dark: 0x0E_0E12, lightAlpha: 0.52, darkAlpha: 0.60)
}

/// Le lavis de teinte en tête de la page : la couleur de la destination qui déteint sur le haut du
/// contenu, puis se dissout.
///
/// C'est ce qui donne à chaque page son ambiance sans rien colorer de lisible — l'orange
/// d'« Aujourd'hui » ou le violet d'« À venir » se sentent avant qu'on ait lu le titre.
///
/// Posé en `.background` de la colonne, JAMAIS en frère dans un `ZStack` : un `VStack` distribue sa
/// hauteur restante à ses enfants flexibles, et un dégradé posé en frère avale la page
/// (cf. CLAUDE.md § Layout).
struct PageTintWash: View {
  let tint: Color

  var body: some View {
    LinearGradient(
      colors: [tint.opacity(0.13), tint.opacity(0)],
      startPoint: .top, endPoint: .bottom
    )
    .frame(height: 280)
    .frame(maxHeight: .infinity, alignment: .top)
    .allowsHitTesting(false)
  }
}

// MARK: - Le badge d'un bandeau de page

/// Le carré arrondi teinté qui coiffe le titre d'une page.
///
/// Il remplace le glyphe nu : une icône posée à côté d'un titre se lit comme une décoration, la
/// même icône dans un cartouche de sa couleur se lit comme l'identité de la page. C'est le repère
/// que la sidebar et le bandeau partagent — même symbole, même teinte, des deux côtés.
///
/// Largeur de layout FIXE (le cartouche entier) : sans elle, chaque page décalerait son titre d'une
/// valeur différente selon la largeur de son symbole.
struct PageBadge: View {
  let systemImage: String
  let tint: Color

  static let side: CGFloat = 30

  var body: some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
      .fill(tint.opacity(0.16))
      .frame(width: Self.side, height: Self.side)
      .overlay {
        Image(systemName: systemImage)
          .font(.app(15, weight: .semibold))
          .foregroundStyle(tint)
      }
  }
}

// MARK: - Les surfaces d'une ligne

/// Une ligne SÉLECTIONNÉE, et une ligne SURVOLÉE. Partagées par la sidebar, les pages de tâches,
/// les en-têtes de section et la grille du calendrier — c'est la même notion, elle ne peut pas se
/// présenter autrement d'un endroit à l'autre.
///
/// NEUTRES, et c'est le cœur de la refonte. La sélection était le lavande de Things (#D1DFFC, soit
/// l'accent système translucide) : le repère le plus reconnaissable de l'app dont on voulait se
/// détacher, et une couleur qui se battait avec la teinte de la page. Un noir/blanc à faible alpha
/// se pose sur le verre sans le salir — il ASSOMBRIT ce qu'il y a derrière au lieu d'y peindre une
/// teinte, donc il marche sur n'importe quel fond d'écran. La couleur, elle, est passée là où elle
/// informe : la case à cocher, la pilule d'heure, le badge du bandeau.
let rowSelectionFill = dualColor(
  light: 0x00_0000, dark: 0xFF_FFFF, lightAlpha: 0.070, darkAlpha: 0.115)
let rowHoverFill = dualColor(
  light: 0x00_0000, dark: 0xFF_FFFF, lightAlpha: 0.042, darkAlpha: 0.060)

/// Le rayon d'une pilule de ligne. Une seule valeur : sidebar, tâches et en-têtes se répondent.
let rowRadius: CGFloat = 8
