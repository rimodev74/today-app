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
        // Montée EN PERMANENCE — y compris à 0 (l'arc est alors dégénéré, elle ne dessine rien) et
        // à 1 (elle remplit le disque). C'est LA condition pour que l'anneau s'anime vraiment.
        //
        // Bornée par `if progress > 0 && progress < 1`, la part entrait et sortait de l'arbre à
        // chaque extrémité : SwiftUI jouait alors une TRANSITION (un fondu) au lieu d'interpoler
        // `animatableData`. D'où un simple fondu au changement de liste, là où cocher une tâche —
        // qui ne fait que bouger la valeur, sans monter ni démonter — faisait vraiment grandir la
        // part. Toujours montée, les deux cas empruntent le même chemin.
        PieWedge(progress: progress)
          .fill(Color.accentColor)
          .rotationEffect(.degrees(-90))
          .padding(lineWidth + 1)
      } else {
        // Petits anneaux (sidebar) : trait gris + arc accent qui se remplit.
        Circle().stroke(.tertiary, lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
        // Anneau plein = terminé : on remplit le disque pour que ça se lise d'un coup d'œil.
        // Réservé au PETIT anneau : dans la variante `showsFill`, la part de camembert ci-dessus
        // couvre déjà tout le disque à 1 — l'ajouter y aurait superposé un fondu à une
        // interpolation qui arrive déjà à bon port.
        if progress >= 1 {
          Circle()
            .fill(Color.accentColor)
            .padding(lineWidth + 1)
            .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .frame(width: size, height: size)
    // L'anneau de l'en-tête est la MÊME vue d'une liste à l'autre (la page n'a pas de `.id`, cf.
    // `TaskListView`) — c'est ce qui lui permet de parcourir sa valeur au lieu de réapparaître.
    .animation(Self.ringFlow, value: progress)
  }

  /// Ressort de la MÊME famille que `taskInsert` (cocher une tâche), mais plus lent et
  /// CRITIQUEMENT amorti.
  ///
  /// Amortissement à 1 et non 0,62 : un ressort qui rebondit fait dépasser `progress` hors de
  /// 0…1 à chaque extrémité. `PieWedge` borne désormais son tracé, donc le rebond ne peut plus
  /// rien casser — mais sur une jauge, le dépassement se lit quand même comme un mensonge
  /// (l'anneau annonce « terminé » avant de l'être). Une jauge se pose, elle ne rebondit pas.
  private static let ringFlow = Animation.spring(response: 0.5, dampingFraction: 1)
}

/// Part de camembert de 0 à `progress` (0…1), partant de 3 h ; l'appelant tourne de -90° pour
/// démarrer en haut. `animatableData` la fait grandir, comme le trait de l'anneau.
///
/// Interne (et non `private`) uniquement pour que `ProgressRingTests` puisse vérifier qu'à 0 elle
/// ne peint RIEN : c'est ce que suppose `ProgressRing`, qui la monte désormais en permanence.
struct PieWedge: Shape {
  var progress: Double

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    // BORNÉ à 0…1 avant tout tracé. `progress` est ici une valeur ANIMÉE, pas une donnée : rien ne
    // garantit qu'elle reste dans ses bornes en chemin. Un ressort peu amorti (`taskInsert`,
    // amortissement 0,62) dépasse volontairement sa cible — au-delà de 1 l'arc repart au-delà du
    // tour complet, et sous 0 il s'ouvre à l'envers, où le remplissage par indice non nul peint le
    // COMPLÉMENT de la part. Passer d'une liste avancée à une liste vide faisait donc osciller le
    // disque entre plein et vide au rythme du ressort, très vite : c'est ce clignotement.
    //
    // Le bornage est ici et pas chez l'appelant : c'est le tracé qui doit tenir face à n'importe
    // quelle valeur intermédiaire, quelle que soit la courbe d'animation choisie plus tard.
    let ratio = min(max(progress, 0), 1)
    var p = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    p.move(to: center)
    p.addArc(
      center: center,
      radius: rect.width / 2,
      startAngle: .degrees(0),
      endAngle: .degrees(360 * ratio),
      clockwise: false
    )
    p.closeSubpath()
    return p
  }
}
