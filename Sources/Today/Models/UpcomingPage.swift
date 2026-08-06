import EventKit
import Foundation

/// Ce que la page « À venir » présente, à partir de ce qu'on lui donne : les tâches datées de
/// l'app, plus les événements et rappels Apple, groupés par jour.
///
/// Sorti de la vue pour la même raison que `TodayPage` et `AllTasksPage` : c'était un regroupement
/// par date, une fenêtre glissante et une boucle à état écrits DANS un `body`, donc invérifiables
/// autrement qu'en cliquant — et à trois `!` près d'un plantage. `now` et `calendar` sont des
/// paramètres : sans ça, « les 7 prochains jours » ne se testait qu'à la date du jour où l'on
/// lançait les tests.
///
/// La forme suit ce que la page dessine :
/// - `nearDays` — les 7 jours suivants, un par un, **même vides** (on veut voir le trou) ;
/// - `monthBands` — au-delà, un bandeau par mois, où seuls les jours qui portent quelque chose
///   deviennent une ligne.
struct UpcomingPage {
  let nearDays: [DayGroup]
  let monthBands: [MonthBand]

  /// Largeur de la fenêtre « un jour par ligne, même vide » avant de passer aux bandeaux de mois.
  static let nearWindowDays = 7
  /// Horizon de chargement EventKit — au-delà, on arrête d'interroger Calendrier/Rappels.
  /// ponytail: plafond simple ; à agrandir/paginer si quelqu'un plie réellement 6 mois à l'avance.
  static let horizonDays = 180

  init(
    tasks: [TaskItem],
    events: [EKEvent] = [],
    reminders: [EKReminder] = [],
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    let todayStart = calendar.startOfDay(for: now)
    let groups = Self.groupByDay(
      tasks: tasks, events: events, reminders: reminders, now: now, calendar: calendar)

    // Repli plutôt que `!` : `date(byAdding:)` ne rend nil pour aucune date représentable, mais la
    // fenêtre proche n'a pas besoin d'un force-unwrap pour être juste.
    let near = (1...Self.nearWindowDays).map { offset -> DayGroup in
      let date =
        calendar.date(byAdding: .day, value: offset, to: todayStart)
        ?? todayStart.addingTimeInterval(Double(offset) * 86_400)
      return groups[date] ?? DayGroup(date: date)
    }
    nearDays = near

    guard let nearEnd = near.last?.date else {
      monthBands = []
      return
    }
    let horizonEnd =
      calendar.date(byAdding: .day, value: Self.horizonDays, to: todayStart) ?? nearEnd

    // Au-delà de la fenêtre proche, seuls les jours qui contiennent réellement quelque chose
    // deviennent une ligne — pas de jour vide comme dans la fenêtre proche.
    let distant = groups.keys.filter { $0 > nearEnd && $0 <= horizonEnd }.sorted()

    monthBands = Self.bands(
      for: distant, groups: groups, nearEnd: nearEnd, now: now, calendar: calendar)
  }

  /// Ce que la page affiche, pan par pan, dans l'ordre du rendu : les jours proches puis ceux des
  /// bandeaux de mois. Seules les TÂCHES y entrent — un événement ou un rappel Apple n'est pas à
  /// nous, la sélection ne le désigne pas et ⌫ n'aurait rien à en faire.
  var taskBlocks: [TaskPageBlock] {
    (nearDays + monthBands.flatMap(\.days)).map { .visible($0.tasks) }
  }

  // MARK: Construction

  private static func groupByDay(
    tasks: [TaskItem], events: [EKEvent], reminders: [EKReminder], now: Date, calendar: Calendar
  ) -> [Date: DayGroup] {
    var byDay: [Date: DayGroup] = [:]
    func key(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    for task in SmartList.upcoming.filter(tasks, DayBounds(now: now, calendar: calendar)) {
      guard let when = task.when else { continue }
      byDay[key(when), default: DayGroup(date: key(when))].items.append(.task(task))
    }
    for event in events {
      let day = key(event.startDate)
      byDay[day, default: DayGroup(date: day)].items.append(.event(event))
    }
    for reminder in reminders {
      guard let components = reminder.dueDateComponents, let due = calendar.date(from: components)
      else { continue }
      byDay[key(due), default: DayGroup(date: key(due))].items.append(.reminder(reminder))
    }
    for dayKey in byDay.keys {
      byDay[dayKey]?.items.sort(by: AgendaItem.precedes)
    }
    return byDay
  }

  /// Découpe les jours distants en bandeaux mensuels. Boucle à état volontairement gardée telle
  /// quelle (un `Dictionary(grouping:)` perdrait l'ordre, qu'il faudrait retrier derrière).
  private static func bands(
    for dates: [Date], groups: [Date: DayGroup], nearEnd: Date, now: Date, calendar: Calendar
  ) -> [MonthBand] {
    var bands: [MonthBand] = []
    var currentMonthStart: Date?
    var currentDays: [DayGroup] = []

    func flush() {
      guard let start = currentMonthStart, !currentDays.isEmpty else { return }
      bands.append(
        MonthBand(
          id: start,
          name: monthName(start, now: now, calendar: calendar),
          rangeLabel: rangeLabel(for: start, nearEnd: nearEnd, calendar: calendar),
          days: currentDays))
      currentDays = []
    }

    for date in dates {
      let components = calendar.dateComponents([.year, .month], from: date)
      // Repli sur le jour lui-même : un mois qu'on ne sait pas nommer vaut mieux qu'un plantage.
      let monthStart = calendar.date(from: components) ?? date
      if monthStart != currentMonthStart {
        flush()
        currentMonthStart = monthStart
      }
      if let group = groups[date] { currentDays.append(group) }
    }
    flush()
    return bands
  }

  /// « Août » dans l'année courante, « Août 2027 » sinon — même règle que `ArchiveMonth.label`.
  static func monthName(_ monthStart: Date, now: Date = Date(), calendar: Calendar = .current)
    -> String
  {
    let sameYear =
      calendar.component(.year, from: monthStart) == calendar.component(.year, from: now)
    let style: Date.FormatStyle = sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year()
    return monthStart.formatted(style).capitalized
  }

  /// Plage FIXE du mois (pas ajustée au contenu) : le premier mois distant démarre juste après la
  /// fenêtre proche (ex. J+7 = 6 août → bandeau « 7-31 ») ; les mois suivants couvrent 1 à leur
  /// dernier jour.
  static func rangeLabel(for monthStart: Date, nearEnd: Date, calendar: Calendar = .current)
    -> String
  {
    let isPartial = calendar.isDate(monthStart, equalTo: nearEnd, toGranularity: .month)
    let startDay = isPartial ? calendar.component(.day, from: nearEnd) + 1 : 1
    let lastDay = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? startDay
    return "\(startDay)-\(lastDay)"
  }
}

// MARK: - Les pans

struct MonthBand: Identifiable {
  let id: Date
  let name: String
  let rangeLabel: String
  let days: [DayGroup]
}

struct DayGroup: Identifiable {
  let date: Date
  var items: [AgendaItem] = []
  var id: Date { date }

  /// Les seules entrées qui nous appartiennent — cf. `UpcomingPage.taskBlocks`.
  var tasks: [TaskItem] {
    items.compactMap {
      if case .task(let task) = $0 { return task }
      return nil
    }
  }
}

/// Une entrée de la vue calendrier — tâche de l'app, événement ou rappel Apple. Un seul type pour
/// que les trois se trient et s'affichent dans le MÊME flux chronologique (contrairement à
/// « Aujourd'hui », qui les sépare en sections).
enum AgendaItem: Identifiable {
  case task(TaskItem)
  case event(EKEvent)
  case reminder(EKReminder)

  var id: String {
    switch self {
    case .task(let task): return "task-\(task.persistentModelID)"
    case .event(let event): return "event-\(event.eventIdentifier ?? "")"
    case .reminder(let reminder): return "reminder-\(reminder.calendarItemIdentifier)"
    }
  }

  /// Minutes depuis minuit si l'entrée porte une heure, `nil` sinon (événement toute la journée,
  /// rappel sans heure d'échéance) — ce `nil` la place dans le groupe « sans heure », en tête.
  ///
  /// Une tâche en porte une depuis le schéma 5.0.0 (`whenMinutes`), et se range alors dans l'ordre
  /// chronologique du jour, entre les événements — c'est tout l'intérêt de lui avoir donné une
  /// heure. Sans heure, elle reste en tête avec les événements « toute la journée ».
  var minutesOfDay: Int? {
    let calendar = Calendar.current
    switch self {
    case .task(let task):
      return task.whenMinutes
    case .event(let event):
      guard !event.isAllDay else { return nil }
      let c = calendar.dateComponents([.hour, .minute], from: event.startDate)
      return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    case .reminder(let reminder):
      guard let c = reminder.dueDateComponents, let hour = c.hour else { return nil }
      return hour * 60 + (c.minute ?? 0)
    }
  }

  /// Sans heure d'abord (ordre d'insertion — tâches déjà en tête), puis chronologique.
  static func precedes(_ a: Self, _ b: Self) -> Bool {
    switch (a.minutesOfDay, b.minutesOfDay) {
    case (nil, nil): return false
    case (nil, _): return true
    case (_, nil): return false
    case (let x?, let y?): return x < y
    }
  }
}
