import EventKit
import SwiftData
import SwiftUI

/// Page « À venir » : vue calendrier des tâches datées, rappels et événements Apple, groupés par
/// jour. Les 7 prochains jours s'affichent un par un (même vides) ; au-delà, un bandeau par mois
/// (plage fixe du mois) ne laisse apparaître que les jours qui contiennent réellement quelque
/// chose.
///
/// ponytail: page en lecture + coche seulement, pas de création ni de glisser-déposer — c'est un
/// aperçu groupé par date, pas une liste à ordre manuel (cf. `ListPageView` pour ça).
struct UpcomingPageView: View {
  @Binding var searchPresented: Bool

  @Environment(RemindersService.self) private var remindersService
  @Query private var allTasks: [TaskItem]
  @State private var events: [EKEvent] = []
  @State private var reminders: [EKReminder] = []

  /// Horizon de chargement EventKit — au-delà, on arrête d'interroger Calendrier/Rappels.
  /// ponytail: plafond simple ; à agrandir/paginer si quelqu'un plie réellement 6 mois à l'avance.
  private static let horizonDays = 180
  /// Largeur de la fenêtre « un jour par ligne, même vide » avant de passer aux bandeaux de mois.
  private static let nearWindowDays = 7

  private var linkedReminderIdentifiers: Set<String> {
    Set(allTasks.compactMap(\.reminderIdentifier))
  }

  private var unlinkedReminders: [EKReminder] {
    reminders.filter { !linkedReminderIdentifiers.contains($0.calendarItemIdentifier) }
  }

  private var tomorrow: Date {
    let calendar = Calendar.current
    return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
  }

  var body: some View {
    let agenda = agenda
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        ForEach(agenda.nearDays) { group in
          DaySection(group: group, onToggleTask: toggle, onToggleReminder: completeReminder)
        }
        ForEach(agenda.monthBands) { band in
          MonthBandHeader(name: band.name, rangeLabel: band.rangeLabel)
          ForEach(band.days) { group in
            DaySection(group: group, onToggleTask: toggle, onToggleReminder: completeReminder)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
    .task { await refreshAppleItems() }
    // Même double déclencheur que « Aujourd'hui » : un rappel/événement peut changer côté Apple
    // pendant que la page est ouverte ou en arrière-plan.
    .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
      Task { await refreshAppleItems() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await refreshAppleItems() }
    }
  }

  private var header: some View {
    HStack(spacing: rowInset) {
      PageHeaderIcon(systemImage: SmartList.upcoming.systemImage, tint: SmartList.upcoming.color)
      Text(SmartList.upcoming.label)
        .font(.title.bold())
      Spacer(minLength: 0)
    }
    .padding(.bottom, 14)
  }

  private func refreshAppleItems() async {
    let start = tomorrow
    let end = Calendar.current.date(byAdding: .day, value: Self.horizonDays, to: start) ?? start
    reminders = await remindersService.reminders(dueFrom: start, to: end)
    if await remindersService.requestEventAccess() {
      events = remindersService.events(from: start, to: end)
    }
  }

  private func toggle(_ task: TaskItem) {
    withAnimation(taskInsert) {
      task.toggleCompletion()
      if task.isCompleted { task.list?.moveToEndOfSection(task) }
    }
    Task { await remindersService.pushCompletion(for: task) }
  }

  /// Même principe que sur « Aujourd'hui » (`TodayPageView.completeReminder`) : coche le VRAI
  /// rappel Apple, retrait optimiste immédiat — trop petit pour valoir une extraction partagée.
  private func completeReminder(_ reminder: EKReminder) {
    let id = reminder.calendarItemIdentifier
    withAnimation(taskInsert) { reminders.removeAll { $0.calendarItemIdentifier == id } }
    Task { try? await remindersService.setCompleted(true, identifier: id) }
  }

  // MARK: Regroupement par jour / mois

  private func buildDayGroups() -> [Date: DayGroup] {
    let calendar = Calendar.current
    var byDay: [Date: DayGroup] = [:]
    func key(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    for task in SmartList.upcoming.filter(allTasks) {
      guard let when = task.when else { continue }
      let day = key(when)
      byDay[day, default: DayGroup(date: day)].items.append(.task(task))
    }
    for event in events {
      let day = key(event.startDate)
      byDay[day, default: DayGroup(date: day)].items.append(.event(event))
    }
    for reminder in unlinkedReminders {
      guard let components = reminder.dueDateComponents, let due = calendar.date(from: components)
      else { continue }
      let day = key(due)
      byDay[day, default: DayGroup(date: day)].items.append(.reminder(reminder))
    }
    for dayKey in byDay.keys {
      byDay[dayKey]?.items.sort(by: AgendaItem.precedes)
    }
    return byDay
  }

  private var agenda: Agenda {
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: Date())
    let groups = buildDayGroups()

    let near = (1...Self.nearWindowDays).map { offset -> DayGroup in
      let date = calendar.date(byAdding: .day, value: offset, to: todayStart)!
      return groups[date] ?? DayGroup(date: date)
    }
    guard let nearEnd = near.last?.date else { return Agenda(nearDays: near, monthBands: []) }
    let horizonEnd = calendar.date(byAdding: .day, value: Self.horizonDays, to: todayStart) ?? nearEnd

    // Au-delà de la fenêtre proche, seuls les jours qui contiennent réellement quelque chose
    // deviennent une ligne — pas de `DayHeader` vide comme dans la fenêtre proche.
    let distantDates = groups.keys.filter { $0 > nearEnd && $0 <= horizonEnd }.sorted()

    var bands: [MonthBand] = []
    var currentMonthStart: Date?
    var currentDays: [DayGroup] = []
    func flush() {
      guard let start = currentMonthStart, !currentDays.isEmpty else { return }
      bands.append(
        MonthBand(
          id: start, name: monthName(start), rangeLabel: rangeLabel(for: start, nearEnd: nearEnd),
          days: currentDays))
      currentDays = []
    }
    for date in distantDates {
      let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
      if monthStart != currentMonthStart {
        flush()
        currentMonthStart = monthStart
      }
      currentDays.append(groups[date]!)
    }
    flush()
    return Agenda(nearDays: near, monthBands: bands)
  }

  /// « Août » dans l'année courante, « Août 2027 » sinon — même règle que `ArchiveMonth.label`.
  private func monthName(_ monthStart: Date) -> String {
    let calendar = Calendar.current
    let sameYear = calendar.component(.year, from: monthStart) == calendar.component(.year, from: Date())
    let style: Date.FormatStyle = sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year()
    return monthStart.formatted(style).capitalized
  }

  /// Plage FIXE du mois (pas ajustée au contenu) : le premier mois distant démarre juste après la
  /// fenêtre proche (ex. J+7 = 6 août → bandeau « 7-31 ») ; les mois suivants couvrent 1 à leur
  /// dernier jour.
  private func rangeLabel(for monthStart: Date, nearEnd: Date) -> String {
    let calendar = Calendar.current
    let isPartial = calendar.isDate(monthStart, equalTo: nearEnd, toGranularity: .month)
    let startDay = isPartial ? calendar.component(.day, from: nearEnd) + 1 : 1
    let lastDay = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? startDay
    return "\(startDay)-\(lastDay)"
  }
}

// MARK: - Regroupement

private struct Agenda {
  let nearDays: [DayGroup]
  let monthBands: [MonthBand]
}

private struct MonthBand: Identifiable {
  let id: Date
  let name: String
  let rangeLabel: String
  let days: [DayGroup]
}

private struct DayGroup: Identifiable {
  let date: Date
  var items: [AgendaItem] = []
  var id: Date { date }
}

/// Une entrée de la vue calendrier — tâche de l'app, événement ou rappel Apple. Un seul type pour
/// que les trois se trient et s'affichent dans le MÊME flux chronologique (contrairement à
/// « Aujourd'hui », qui les sépare en sections).
private enum AgendaItem: Identifiable {
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

  /// Minutes depuis minuit si l'entrée porte une heure, `nil` sinon (tâche non datée à l'heure
  /// près, événement toute la journée, rappel sans heure d'échéance) — ce `nil` la place dans le
  /// groupe « sans heure », toujours en tête.
  private var minutesOfDay: Int? {
    let calendar = Calendar.current
    switch self {
    case .task(let task):
      guard task.hasTime, let when = task.when else { return nil }
      let c = calendar.dateComponents([.hour, .minute], from: when)
      return (c.hour ?? 0) * 60 + (c.minute ?? 0)
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
    case let (x?, y?): return x < y
    }
  }
}

// MARK: - Rendu

/// En-tête de jour (numéro + nom) suivi de ses entrées — absentes si le jour est vide (fenêtre
/// proche uniquement, cf. `UpcomingPageView.agenda`).
private struct DaySection: View {
  let group: DayGroup
  var onToggleTask: (TaskItem) -> Void
  var onToggleReminder: (EKReminder) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DayHeader(date: group.date)
      ForEach(group.items) { item in
        row(for: item)
      }
    }
  }

  @ViewBuilder private func row(for item: AgendaItem) -> some View {
    switch item {
    case .task(let task):
      UpcomingTaskRow(task: task, onToggle: { onToggleTask(task) })
    case .event(let event):
      EventRow(event: event)
    case .reminder(let reminder):
      ReminderRow(reminder: reminder, onToggle: { onToggleReminder(reminder) })
    }
  }
}

private struct DayHeader: View {
  let date: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(dayNumber)
          .font(.title.bold())
        Text(weekdayLabel)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Divider()
    }
    .padding(.top, 18)
    .padding(.bottom, 8)
  }

  private var dayNumber: String { "\(Calendar.current.component(.day, from: date))" }

  private var weekdayLabel: String {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
    if calendar.isDate(date, inSameDayAs: tomorrow) { return "Demain" }
    return date.formatted(.dateTime.weekday(.wide)).capitalized
  }
}

/// Bandeau de mois — nom en gras, plage de jours en gris (même distinction visuelle que la
/// capture d'écran de référence).
private struct MonthBandHeader: View {
  let name: String
  let rangeLabel: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(name).font(.title2.bold())
        Text(rangeLabel).font(.title2.bold()).foregroundStyle(.secondary)
      }
      Divider()
    }
    .padding(.top, 22)
    .padding(.bottom, 8)
  }
}

/// Ligne de tâche pour « À venir » — case, titre, rattachement, heure SI la tâche en porte une.
/// Pas de contrôle de durée (contrairement à `TodayRow`) : hors sujet pour un calendrier.
private struct UpcomingTaskRow: View {
  @Bindable var task: TaskItem
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: rowInset) {
      TaskCheckbox(isCompleted: task.isCompleted, onToggle: onToggle)

      VStack(alignment: .leading, spacing: 1) {
        Text(task.title.isEmpty ? "Sans titre" : task.title)
        if let parent {
          Text(parent)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if task.hasTime, let when = task.when {
        Text(when.formatted(date: .omitted, time: .shortened))
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var parent: String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
  }
}
