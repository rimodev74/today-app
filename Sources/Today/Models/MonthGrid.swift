import Foundation

/// Les jours qu'affiche une grille de mois : six semaines PLEINES, toujours 42 cases.
///
/// **Six et pas « le nombre qu'il faut ».** Un mois tombe sur cinq ou six semaines selon le jour où
/// il commence ; une grille à hauteur variable ferait sauter le panneau qui la contient d'un mois à
/// l'autre — et ce panneau est un popover, donc une fenêtre qui se redimensionne sous le curseur. On
/// paie une rangée inutile certains mois, on ne paie jamais un panneau qui se déforme en naviguant.
///
/// Type de valeur, sans SwiftUI, et testé : c'est de l'arithmétique de calendrier, avec tout ce
/// qu'elle a d'à côté de l'intuition — le premier jour de semaine varie selon la région (lundi en
/// France, dimanche aux États-Unis), un mois déborde sur ses voisins, et `byAdding: .day` est le
/// seul saut qui reste juste la nuit d'un changement d'heure.
struct MonthGrid: Equatable {
  /// Le premier jour du mois présenté, au début de sa journée.
  let month: Date
  /// Les 42 jours affichés, dans l'ordre de lecture, chacun au début de sa journée. Les premiers et
  /// les derniers appartiennent aux mois voisins (`isInMonth` les distingue).
  let days: [Date]

  static let rows = 6
  static let columns = 7

  init(containing date: Date, calendar: Calendar = .current) {
    let start =
      calendar.date(from: calendar.dateComponents([.year, .month], from: date))
      ?? calendar.startOfDay(for: date)
    self.month = start
    // Reculer jusqu'au premier jour de la SEMAINE DE L'UTILISATEUR — `firstWeekday`, jamais une
    // constante : la même grille commence lundi ici et dimanche ailleurs.
    let weekday = calendar.component(.weekday, from: start)
    let lead = (weekday - calendar.firstWeekday + Self.columns) % Self.columns
    let first = calendar.date(byAdding: .day, value: -lead, to: start) ?? start
    self.days = (0..<(Self.rows * Self.columns)).map {
      calendar.date(byAdding: .day, value: $0, to: first) ?? first
    }
  }

  /// Ce jour appartient-il au mois présenté, ou déborde-t-il d'un voisin ?
  func isInMonth(_ day: Date, calendar: Calendar = .current) -> Bool {
    calendar.isDate(day, equalTo: month, toGranularity: .month)
  }

  func advanced(byMonths delta: Int, calendar: Calendar = .current) -> MonthGrid {
    guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return self }
    return MonthGrid(containing: next, calendar: calendar)
  }

  /// Les en-têtes de colonnes, dans l'ordre du calendrier de l'utilisateur. `shortWeekdaySymbols`
  /// est indexé à partir de DIMANCHE quel que soit `firstWeekday` — d'où la rotation.
  static func weekdaySymbols(_ calendar: Calendar = .current) -> [String] {
    let symbols = calendar.shortWeekdaySymbols
    guard symbols.count == columns else { return symbols }
    return (0..<columns).map { symbols[($0 + calendar.firstWeekday - 1) % columns] }
  }
}
