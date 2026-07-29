import Foundation

/// Durées d'estimation d'une tâche, en minutes (0 = non estimée).
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

/// Ce que la journée peut encore absorber, confronté à ce qui y est planifié.
///
/// C'est la seule vue de l'app qui dise non : une liste « Aujourd'hui » ordinaire accepte
/// n'importe quel volume sans broncher, et c'est ce silence qui rend les journées fictives.
///
/// ponytail: la capacité restante n'est qu'un compte à rebours jusqu'à l'heure de fin de journée
/// — un après-midi plein de réunions est compté comme libre. Brancher EventKit (créneaux
/// réellement libres du calendrier) quand la barre aura prouvé qu'elle sert.
struct DayCapacity {
  let plannedMinutes: Int
  let availableMinutes: Int
  let unestimatedCount: Int

  /// Prend des minutes brutes, pas des `TaskItem` : le calcul reste testable sans ModelContainer.
  init(estimates: [Int], now: Date = Date(), endOfDayHour: Int, calendar: Calendar = .current) {
    plannedMinutes = estimates.reduce(0) { $0 + max(0, $1) }
    unestimatedCount = estimates.filter { $0 <= 0 }.count
    let end = calendar.date(bySettingHour: endOfDayHour, minute: 0, second: 0, of: now) ?? now
    availableMinutes = max(0, Int(end.timeIntervalSince(now) / 60))
  }

  var overflowMinutes: Int { max(0, plannedMinutes - availableMinutes) }
  var isOverbooked: Bool { overflowMinutes > 0 }

  /// Part de la journée disponible déjà réservée, bornée à 1 : le dépassement se dit en toutes
  /// lettres, une barre qui déborde de son cadre ne dirait rien de plus.
  var fill: Double {
    guard availableMinutes > 0 else { return plannedMinutes > 0 ? 1 : 0 }
    return min(1, Double(plannedMinutes) / Double(availableMinutes))
  }

  static let endOfDayHourKey = "dayEndHour"
  static let defaultEndOfDayHour = 18
}
