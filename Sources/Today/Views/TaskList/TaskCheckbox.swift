// La case à cocher d'une tâche, son tracé et le style de bouton qui lui donne son rebond.
// Sortie de `TaskListView.swift` — cf. l'en-tête de `TaskRow.swift`.
//
// Volontairement PAS un `Toggle` natif : cf. le commentaire de `TaskCheckbox` lui-même.

import AppKit
import SwiftData
import SwiftUI

/// Un carré à coin arrondi À LA COULEUR DE LA PAGE : cerné de cette couleur tant que la tâche
/// reste à faire, rempli de la même avec une coche blanche une fois faite.
///
/// La FORME est celle d'origine et elle le reste — le cercle essayé à la refonte v2 a été repris.
/// Ce qui change par rapport à l'avant, et ce qui suffit, c'est la COULEUR : le contour était gris
/// système, il est maintenant celui de la destination (`pageTint`). Une page se lit donc à sa
/// colonne de gauche avant même son titre, sans toucher au repère que la main connaît déjà.
///
/// Custom et pas `.toggleStyle(.checkbox)` : la case native de macOS 26 est un carré **plein**,
/// impossible d'en tirer ce rendu par un simple restylage.
struct TaskCheckbox: View {
  let isCompleted: Bool
  /// Case d'une SOUS-ligne : même case, plus petite. C'est la taille qui hiérarchise, pas la
  /// forme — deux formes différentes se lisaient comme deux natures de case, alors que c'est le
  /// même geste.
  var compact: Bool = false
  var onToggle: () -> Void

  /// Lue ici plutôt que passée : cette case est enfouie sous quatre niveaux de vues
  /// (cf. `EnvironmentValues.pageTint`).
  @Environment(\.pageTint) private var tint

  private var size: CGFloat { compact ? 14 : 17 }
  /// Le rayon suit la taille : 4,5 pt sur une case de 16 était la valeur de la maquette d'origine,
  /// soit un peu plus du quart du côté. Figé, il aurait rendu la case réduite presque circulaire.
  private var radius: CGFloat { size * 0.28 }

  var body: some View {
    Button(action: onToggle) {
      box
        .overlay {
          // `.trim` = strokeEnd de Core Animation exposé en SwiftUI : le trait se *trace*
          // (0→1) au lieu d'apparaître. lineCap/Join .round pour la même douceur que Things.
          Checkmark()
            .trim(from: 0, to: isCompleted ? 1 : 0)
            .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: size * 0.52, height: size * 0.52)
            // L'opacité EN PLUS du tracé, et c'est le correctif du 17 septembre 2026. `taskInsert`
            // est un ressort critiquement amorti : il approche sa cible sans jamais l'atteindre
            // franchement — ~2 % de trajet restant 0,3 s après le décochage. Sur un fond
            // (`opacity`) 2 % ne se voit pas ; sur une GÉOMÉTRIE si : 2 % du chemin avec un bout
            // rond de 1,7 pt, c'est un point blanc en pleine opacité sur la ligne sélectionnée,
            // qui traîne puis saute. La coche se retire donc comme le fond, à la même courbe.
            .opacity(isCompleted ? 1 : 0)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
    // Bounce au press/release via un ButtonStyle dédié ; le tracé + le fond restent animés par le
    // withAnimation de la page.
    .buttonStyle(PressBounceButtonStyle())
    // PAS de `.animation(value: isCompleted)`, et c'est le correctif du 10 août 2026. Il y en avait
    // une, en `.bouncy(extraBounce: 0.15)` — soit un ressort à 45 % de rebond posé sur la case, à
    // l'instant même où la page déplace la rangée en `taskInsert` (critiquement amorti). La case
    // gardait donc sa propre courbe pendant que la ligne descendait à sa nouvelle place : la rangée
    // arrivait, et quelque chose rebondissait dessus. C'est exactement le piège décrit dans
    // `CLAUDE.md` § Animations — une transition d'état appartient à la PAGE, en `withAnimation`.
    // Les cinq sites qui cochent (`TaskRow`, `UpcomingPageView`, `ArchivePageView`, les deux
    // restaurations) enveloppent tous `toggleCompletion()` : il n'y a rien à rattraper ici.
    // PAS `.onHover` + `NSCursor.set()` : cette case vit DANS une ligne qui a déjà son propre
    // `.onHover` ; les cursor rects AppKit sont résolus par la fenêtre à partir de la géométrie.
    .overlay { PointingHandCursorArea().allowsHitTesting(false) }
  }

  /// Contour + fond, tous deux montés en permanence (opacité pilotée par `isCompleted`) : pas de
  /// `if` qui insère/retire une vue, sinon l'anim n'aurait rien à interpoler.
  ///
  /// La case vide est TRANSPARENTE et non `.controlBackgroundColor` : sur le verre, un fond opaque
  /// se lit comme un trou percé dans la fenêtre. C'est le trait seul qui la dessine.
  ///
  /// `.strokeBorder` (trait posé À L'INTÉRIEUR du contour) n'existe que sur `InsettableShape` —
  /// d'où la forme concrète gardée ici, sans `AnyShape` type-effacé.
  private var box: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return
      shape
      .fill(tint)
      .opacity(isCompleted ? 1 : 0)
      .overlay {
        shape
          .strokeBorder(tint, lineWidth: 1.6)
          .opacity(isCompleted ? 0 : 0.85)
      }
  }
}

/// Le chemin du check, en proportions de son cadre (dessiné du bras court vers le bras long, sens
/// dans lequel `.trim` le trace). Aucun SF Symbol ne sait se *tracer* — d'où le Path maison.
private struct Checkmark: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.52))
    p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.74))
    p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.80, y: rect.minY + rect.height * 0.28))
    return p
  }
}

/// Rétrécit tant que le bouton est maintenu, puis rebondit au relâchement (spring peu amorti →
/// léger dépassement). C'est le « bounce au clic » de Things, sans dépendre de la pression réelle.
private struct PressBounceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.8 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.45), value: configuration.isPressed)
  }
}
