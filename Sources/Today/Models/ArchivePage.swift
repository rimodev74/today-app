import Foundation

/// Ce que la page « Archives » présente : les tâches cochées de TOUTES les listes, groupées par
/// mois de complétion, du plus récent au plus ancien.
///
/// Sorti de la vue pour la même raison que `TodayPage`, `AllTasksPage` et `UpcomingPage` : le
/// filtrage, le tri et le regroupement se refaisaient à CHAQUE lecture d'une propriété calculée,
/// plusieurs fois par rendu, et ne se vérifiaient qu'en cliquant. `now` est un paramètre : sans
/// lui, la règle « l'année n'apparaît que si elle diffère » se testerait autrement selon l'année
/// en cours.
struct ArchivePage {
  /// Toutes les archives, dans l'ordre d'affichage (la plus récemment cochée en tête). C'est aussi
  /// ce que « Vider les archives » supprime, et ce que le compteur de l'alerte annonce.
  let tasks: [TaskItem]
  let months: [ArchiveMonth]

  init(tasks all: [TaskItem], now: Date = Date(), calendar: Calendar = .current) {
    // La MÊME règle que la sidebar : filtre et tri viennent de `SmartList.archive`, ils ne sont
    // pas réécrits ici.
    let archived = SmartList.archive.sort(SmartList.archive.filter(all))
    tasks = archived
    months = ArchiveMonth.group(archived, now: now, calendar: calendar)
  }

  var isEmpty: Bool { tasks.isEmpty }

  /// Un pan par mois, dans l'ordre affiché — ce que ↑/↓ et ⌫ parcourent. Aucun n'est repliable.
  var blocks: [TaskPageBlock] { months.map { .visible($0.tasks) } }
}

/// Un mois d'archives. `id` = le premier jour du mois, qui sert aussi de clé de tri.
struct ArchiveMonth: Identifiable {
  let id: Date
  let tasks: [TaskItem]
  /// « Juillet » dans l'année courante, « Juillet 2025 » sinon — l'année n'apparaît que quand elle
  /// apporte quelque chose. Calculé À LA CONSTRUCTION : formater une date est cher, et cette
  /// étiquette était refaite à chaque rendu de l'en-tête de mois.
  let label: String

  init(id: Date, tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) {
    self.id = id
    self.tasks = tasks
    let sameYear = calendar.component(.year, from: id) == calendar.component(.year, from: now)
    let style = sameYear ? Date.FormatStyle.dateTime.month(.wide) : .dateTime.month(.wide).year()
    label = id.formatted(style).capitalized
  }

  /// Regroupe par mois de complétion, du plus récent au plus ancien. L'ordre À L'INTÉRIEUR d'un
  /// mois est celui reçu — l'appelant a déjà trié.
  ///
  /// Prend des tâches DÉJÀ sélectionnées, et pas toute la base : les deux appelants ne visent pas
  /// le même périmètre. La page « Archives » prend celles de l'app entière (`ArchivePage`) ; le
  /// dépliant d'une page de liste prend celles de CETTE liste, choisies par une autre règle
  /// (`isArchived`, qui dépend de l'ouverture de la page). Le regroupement, lui, est le même — et
  /// il n'est écrit qu'ici.
  static func group(_ tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current)
    -> [ArchiveMonth]
  {
    let grouped = Dictionary(grouping: tasks) { task -> Date in
      let components = calendar.dateComponents(
        [.year, .month], from: task.completedAt ?? .distantPast)
      return calendar.date(from: components) ?? .distantPast
    }
    return grouped.keys.sorted(by: >).map {
      ArchiveMonth(id: $0, tasks: grouped[$0] ?? [], now: now, calendar: calendar)
    }
  }
}
