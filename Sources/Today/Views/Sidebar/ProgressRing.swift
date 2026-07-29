import SwiftUI

/// Anneau de progression. Taille libre : 12pt devant une to-do list dans la sidebar,
/// 28pt à côté du titre dans l'en-tête de la vue détail.
struct ProgressRing: View {
  let progress: Double
  var size: CGFloat = 12
  var lineWidth: CGFloat = 2
  /// Remplit l'intérieur de l'anneau d'une part de camembert (le rendu Things de l'en-tête).
  /// Désactivé par défaut : les petits anneaux de la sidebar gardent leur trait seul.
  var showsFill: Bool = false

  var body: some View {
    ZStack {
      if showsFill {
        // Rendu Things de l'en-tête : contour TOUJOURS plein bleu, seule la part de
        // camembert intérieure suit la progression.
        Circle().stroke(Color.accentColor, lineWidth: lineWidth)
        if progress > 0 && progress < 1 {
          PieWedge(progress: progress)
            .fill(Color.accentColor)
            .rotationEffect(.degrees(-90))
            .padding(lineWidth + 1)
        }
      } else {
        // Petits anneaux (sidebar) : trait gris + arc accent qui se remplit.
        Circle().stroke(.tertiary, lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      // Anneau plein = terminé : on remplit le disque pour que ça se lise d'un coup d'œil.
      if progress >= 1 {
        Circle()
          .fill(Color.accentColor)
          .padding(lineWidth + 1)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .frame(width: size, height: size)
    .animation(.easeInOut(duration: 0.25), value: progress)
  }
}

/// Part de camembert de 0 à `progress` (0…1), partant de 3 h ; l'appelant tourne de -90° pour
/// démarrer en haut. `animatableData` la fait grandir en fondu, comme le trait de l'anneau.
private struct PieWedge: Shape {
  var progress: Double

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    p.move(to: center)
    p.addArc(
      center: center,
      radius: rect.width / 2,
      startAngle: .degrees(0),
      endAngle: .degrees(360 * progress),
      clockwise: false
    )
    p.closeSubpath()
    return p
  }
}
