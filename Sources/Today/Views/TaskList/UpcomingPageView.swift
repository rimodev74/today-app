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

  /// Rappels/événements Apple — mis en cache dans `remindersService` (même raison que
  /// `TodayPageView`) : cette page est recréée à chaque réouverture de l'onglet, une `@State`
  /// locale rechargeait donc visiblement tout à chaque fois.
  /// Ce que la page montre du côté Apple : ni un rappel ni un ÉVÉNEMENT déjà rattaché à une tâche
  /// — l'un comme l'autre sont déjà à l'écran sous forme de ligne. Une fonction appelée en tête du
  /// `body`, pour la raison expliquée dans `TodayPageView.appleItems`.
  private func appleItems() -> (events: [EKEvent], reminders: [EKReminder]) {
    let linked = Set(RemindersService.appleIdentifiers(of: allTasks))
    return (
      remindersService.upcomingEvents.filter { !linked.contains($0.eventIdentifier ?? "") },
      remindersService.upcomingReminders.filter { !linked.contains($0.calendarItemIdentifier) }
    )
  }

  private var tomorrow: Date { DayBounds().startOfTomorrow }

  var body: some View {
    // Construit UNE fois par rendu, puis distribué — le calcul lui-même vit dans `UpcomingPage`,
    // avec ses tests (cf. la règle « une vue orchestre et anime ; elle ne calcule pas »).
    // Calculé une fois puis distribué, comme `agenda` (cf. `appleItems`).
    let apple = appleItems()
    let agenda = UpcomingPage(
      tasks: allTasks, events: apple.events, reminders: apple.reminders)
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
    // Ni réordonnancement (la page est ordonnée par une date) ni création : ⌘N n'y fait rien.
    .taskPageBase(
      focus: $focus, blocks: { agenda.taskBlocks }, delete: delete, reorder: nil, newTask: nil
    )
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
    // Colonne des repères de section, comme les bandeaux des autres pages.
    .padding(.leading, taskContentColumn)
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
    withAnimation(taskInsert) {
      modelContext.deleteTasksAndSave([task], forget: remindersService.forgetAppleItems)
    }
  }

  private func toggle(_ task: TaskItem) {
    withAnimation(taskInsert) {
      task.toggleCompletion()
      if task.isCompleted {
        task.list?.moveToEndOfSection(task)
      } else {
        task.list?.moveAboveCompleted(task)
      }
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
    // Repère de SECTION : la colonne des en-têtes, pas celle des cases. Sur le BLOC, donc le trait
    // suit — laissé pleine largeur il partait à gauche de toute la page (cf. `AppleItemsSection`).
    .padding(.leading, taskContentColumn)
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
    // Même colonne que `DayHeader` juste en dessous, trait compris : deux repères de section de
    // rangs différents, mais un seul bord gauche.
    .padding(.leading, taskContentColumn)
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

      // L'heure devant le titre, sur la MÊME ligne et comme une ligne d'événement : sur une page qui
      // range la journée dans l'ordre, une tâche à 14 h doit DIRE qu'elle est à 14 h, sinon son
      // rang paraît arbitraire.
      if let minutes = task.whenMinutes {
        Text(String(format: "%02d:%02d", minutes / 60, minutes % 60))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize()
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(task.title.isEmpty ? "Sans titre" : task.title)
        if let parent = TaskParentTag(of: task) {
          Text(parent.title)
            .font(.app(.callout))
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .font(.app(.callout))
    .padding(.vertical, 4)
    .taskRowSelection(isSelected)
    // `taskRowColumn` et pas `taskContentColumn`, contrairement à `TaskRow` et `ReminderRow` :
    // celles-là portent un `rowInset` INTÉRIEUR qui pousse leur case, alors que `taskRowSelection`
    // écarte puis reprend le sien (il n'élargit que le fond). Sans retrait intérieur à ajouter,
    // c'est donc la colonne des cases qui se pose ici — le fond de sélection retombe alors tout
    // seul sur `taskContentColumn`, exactement comme sur les autres pages.
    // Cette page était restée à plat : sa case, celle d'un rappel et l'encadré d'un événement se
    // trouvaient à trois retraits différents dans la MÊME journée.
    .padding(.leading, taskRowColumn)
    .contentShape(Rectangle())
  }
}
