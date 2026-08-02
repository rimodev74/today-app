import Foundation

/// Durées d'estimation d'une tâche, en minutes (0 = non estimée). Lu par le menu « Durée… » d'une
/// tâche et par la pastille qu'une ligne au repos affiche quand elle en porte une.
enum Estimate {
  /// Les seuls choix offerts. Une liste courte force la décision ; un champ libre invite à
  /// peaufiner une estimation qui sera fausse de toute façon.
  static let presets = [15, 30, 60, 120, 240]

  /// « 45 min », « 2 h », « 1 h 30 ». `nil` quand rien n'est estimé — l'appelant décide alors
  /// quoi afficher (le vide ne se formate pas).
  static func label(_ minutes: Int) -> String? {
    guard minutes > 0 else { return nil }
    let (hours, rest) = (minutes / 60, minutes % 60)
    switch (hours, rest) {
    case (0, _): return "\(rest) min"
    case (_, 0): return "\(hours) h"
    default: return "\(hours) h \(rest)"
    }
  }
}
