import EventKit
import SwiftData
import SwiftUI

/// Page « À venir » : vue calendrier des tâches datées, rappels et événements Apple, groupés par
/// jour. Les 7 prochains jours s'affichent un par un (même vides) ; au-delà, un bandeau par mois
/// (plage fixe du mois) ne laisse apparaître que les jours qui contiennent réellement quelque
/// chose.
///
/// Elle a le socle commun des pages de tâches — sélection, ⌫, ↑/↓, clic dans le vide — sur ses
/// seules tâches : un événement ou un rappel Apple ne nous appartient pas, il ne se sélectionne
/// donc pas.
///
/// ponytail: ni création ni ordre manuel — c'est un aperçu groupé par date, pas une liste
/// (cf. `ListPageView` pour ça).
struct UpcomingPageView: View {
  @Binding var searchPresented: Bool

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  @Query private var allTasks: [TaskItem]
  /// La sélection, comme sur toute autre page de tâches (cf. `TaskFocus`). Pas d'édition ici : la
  /// page est un aperçu par date, on y coche et on y supprime — renommer se fait dans la liste.
  @State private var focus = TaskFocus()

  private var linkedReminderIdentifiers: Set<String> {
    Set(allTasks.compactMap(\.reminderIdentifier))
  }

  /// Rappels/événements Apple — mis en cache dans `remindersService` (même raison que
  /// `TodayPageView`) : cette page est recréée à chaque réouverture de l'onglet, une `@State`
  /// locale rechargeait donc visiblement tout à chaque fois.
  private var events: [EKEvent] { remindersService.upcomingEvents }
  private var reminders: [EKReminder] { remindersService.upcomingReminders }

  private var unlinkedReminders: [EKReminder] {
    reminders.filter { !linkedReminderIdentifiers.contains($0.calendarItemIdentifier) }
  }

  private var tomorrow: Date { DayBounds().startOfTomorrow }

  var body: some View {
    // Construit UNE fois par rendu, puis distribué — le calcul lui-même vit dans `UpcomingPage`,
    // avec ses tests (cf. la règle « une vue orchestre et anime ; elle ne calcule pas »).
    let agenda = UpcomingPage(
      tasks: allTasks, events: events, reminders: unlinkedReminders)
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        Group {
          ForEach(agenda.nearDays) { group in
            DaySection(
              group: group, focus: $focus, onToggleTask: toggle,
              onToggleReminder: completeReminder)
          }
          ForEach(agenda.monthBands) { band in
            MonthBandHeader(name: band.name, rangeLabel: band.rangeLabel)
            ForEach(band.days) { group in
              DaySection(
                group: group, focus: $focus, onToggleTask: toggle,
                onToggleReminder: completeReminder)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    // Le socle commun : ⌫, ↑/↓, clic dans le vide. Un pan par jour, dans l'ordre affiché — les
    // rappels et événements Apple n'en font pas partie, ils ne se sélectionnent pas (ils ne nous
    // appartiennent pas : ⌫ ne peut rien en faire).
    .taskPageBase(focus: $focus, blocks: { agenda.taskBlocks }, delete: delete, reorder: nil)
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
        .font(.app(.title).bold())
      Spacer(minLength: 0)
    }
    .padding(.bottom, 14)
  }

  private func refreshAppleItems() async {
    let start = tomorrow
    let end =
      Calendar.current.date(byAdding: .day, value: UpcomingPage.horizonDays, to: start) ?? start
    await remindersService.refreshUpcoming(from: start, to: end)
  }

  private func delete(_ task: TaskItem) {
    focus.forget(task)
    withAnimation(taskInsert) { modelContext.delete(task) }
    try? modelContext.save()
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
    withAnimation(taskInsert) { remindersService.removeUpcomingReminder(id) }
    Task { try? await remindersService.setCompleted(true, identifier: id) }
  }

}

// MARK: - Rendu

/// En-tête de jour (numéro + nom) suivi de ses entrées — absentes si le jour est vide (fenêtre
/// proche uniquement, cf. `UpcomingPage`).
private struct DaySection: View {
  let group: DayGroup
  @Binding var focus: TaskFocus
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
      UpcomingTaskRow(
        task: task, isSelected: focus.isSelected(task), onToggle: { onToggleTask(task) }
      )
      .rowPressGesture(
        isSelected: focus.isSelected(task),
        isEditing: false,
        onSelect: { withAnimation(taskSelectFade) { focus.select(task) } },
        onEdit: {}
      )
      .measureTaskRow(task)
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
          .font(.app(.title).bold())
        Text(weekdayLabel)
          .font(.app(.subheadline))
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
        Text(name).font(.app(.title2).bold())
        Text(rangeLabel).font(.app(.title2).bold()).foregroundStyle(.secondary)
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
  var isSelected: Bool = false
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: rowInset) {
      TaskCheckbox(isCompleted: task.isCompleted, onToggle: onToggle)

      VStack(alignment: .leading, spacing: 1) {
        Text(task.title.isEmpty ? "Sans titre" : task.title)
        if let parent {
          Text(parent)
            .font(.app(.callout))
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .font(.app(.callout))
    .padding(.vertical, 4)
    .taskRowSelection(isSelected)
    .contentShape(Rectangle())
  }

  private var parent: String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
  }
}
