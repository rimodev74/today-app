// La case à cocher d'une tâche, son tracé et le style de bouton qui lui donne son rebond.
// Sortie de `TaskListView.swift` — cf. l'en-tête de `TaskRow.swift`.
//
// Volontairement PAS un `Toggle` natif : cf. le commentaire de `TaskCheckbox` lui-même.

import AppKit
import SwiftData
import SwiftUI

/// Case à cocher façon Things : un carré à coin arrondi, vide et cerné d'un filet gris ;
/// rempli en accent avec une coche blanche une fois complété.
///
/// Custom et pas `.toggleStyle(.checkbox)` : la case native de macOS 26 est un carré **plein**,
/// impossible d'en tirer ce rendu par un simple restylage.
struct TaskCheckbox: View {
  let isCompleted: Bool
  /// Sous-tâche = cercle ; tâche = rectangle arrondi (défaut). Même case, seule la forme change :
  /// on ne duplique pas le tracé du check animé, le bounce ni le curseur main.
  var circular: Bool = false
  var onToggle: () -> Void

  private static let size: CGFloat = 16

  var body: some View {
    Button(action: onToggle) {
      // Forme branchée UNE fois en gardant un type `InsettableShape` concret (Circle /
      // RoundedRectangle) : `.strokeBorder` (trait posé À L'INTÉRIEUR du contour, cf. le rendu
      // Things d'origine) n'existe que sur `InsettableShape`, pas sur un `AnyShape` type-effacé.
      Group {
        if circular {
          fillAndBorder(Circle())
        } else {
          fillAndBorder(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
      }
      .overlay {
        // `.trim` = strokeEnd de Core Animation exposé en SwiftUI : le trait se *trace*
        // (0→1) au lieu d'apparaître. lineCap/Join .round pour la même douceur que Things.
        Checkmark()
          .trim(from: 0, to: isCompleted ? 1 : 0)
          .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
          .frame(width: Self.size * 0.55, height: Self.size * 0.55)
      }
      .frame(width: Self.size, height: Self.size)
      .contentShape(Rectangle())
    }
    // Bounce au press/release via un ButtonStyle dédié ; le tracé + le fond restent animés par le
    // withAnimation de la page.
    .buttonStyle(PressBounceButtonStyle())
    .animation(.bouncy(duration: 0.3, extraBounce: 0.15), value: isCompleted)
    // PAS `.onHover` + `NSCursor.set()` : cette case vit DANS une ligne qui a déjà son propre
    // `.onHover` ; les cursor rects AppKit sont résolus par la fenêtre à partir de la géométrie.
    .overlay { PointingHandCursorArea().allowsHitTesting(false) }
  }

  /// Fond + bordure d'une case, génériques sur la forme concrète (donc `.strokeBorder` disponible).
  /// Bordure et fond coexistent en permanence (opacité pilotée par isCompleted) : pas de `if` qui
  /// insère/retire une vue, sinon l'anim n'aurait rien à interpoler.
  private func fillAndBorder<S: InsettableShape>(_ shape: S) -> some View {
    shape
      .fill(isCompleted ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
      .overlay {
        shape
          .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
          .opacity(isCompleted ? 0 : 1)
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
