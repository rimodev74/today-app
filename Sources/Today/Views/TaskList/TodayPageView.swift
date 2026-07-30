import EventKit
import SwiftData
import SwiftUI

/// Page « Aujourd'hui » : les tâches planifiées pour aujourd'hui, précédées d'une barre qui
/// confronte leur durée totale au temps qu'il reste réellement dans la journée.
///
/// C'est le seul endroit de l'app qui refuse de mentir sur la journée. Le reste (listes, projets)
/// accepte n'importe quel volume ; ici, planifier neuf heures dans un après-midi de trois se voit.
///
/// ponytail: page en lecture + estimation seulement — pas d'édition, de réordonnancement ni de
/// drag, contrairement à une page de liste. C'est une sonde : si la barre change la façon de
/// planifier, on lui branchera la machinerie complète de `ListPageView`.
struct TodayPageView: View {
  @Binding var searchPresented: Bool

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  @Query private var allTasks: [TaskItem]
  // Destination de la tâche libre créée depuis cette page (cf. `createTask`) : l'Inbox, comme
  // toute tâche sans projet — « Aujourd'hui » ne fait que la filtrer par date, ce n'est pas sa
  // liste propre.
  @Query(filter: #Predicate<TodoList> { $0.isInbox }) private var inboxLists: [TodoList]
  @AppStorage(DayCapacity.endOfDayHourKey) private var endOfDayHour = DayCapacity
    .defaultEndOfDayHour
  // Le temps restant fond pendant que la page est ouverte : sans re-rendu régulier, la barre
  // affiche la capacité de l'instant où l'on a ouvert la page, pas celle de maintenant.
  @State private var now = Date()
  // `@State` et pas un `let` construit dans le body : le tick change `now`, donc le body se
  // ré-évalue, donc un publisher construit là serait remplacé à chaque minute — `onReceive` se
  // réabonnerait, invalidant puis recréant un Timer à chaque fois. Ici il est créé une seule fois.
  @State private var ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
  /// Brouillon de la tâche libre (sans liste ni projet) créable depuis cette page.
  @State private var draft = ""
  @FocusState private var draftFocused: Bool

  private var tasks: [TaskItem] {
    SmartList.today.sort(SmartList.today.filter(allTasks))
  }

  /// Rappels Apple déjà rattachés à une tâche de l'app : à exclure de la section « Rappels »
  /// pour ne pas les montrer deux fois (une fois comme tâche, une fois comme rappel brut).
  private var linkedReminderIdentifiers: Set<String> {
    Set(allTasks.compactMap(\.reminderIdentifier))
  }

  /// Rappels/événements Apple du jour — mis en cache dans `remindersService` (cf. son
  /// commentaire), pas ici : une `@State` locale repartirait de zéro à chaque réouverture de
  /// l'onglet, ce qui rechargeait visiblement la page à chaque fois.
  private var events: [EKEvent] { remindersService.todayEvents }
  private var reminders: [EKReminder] { remindersService.todayReminders }

  private var unlinkedReminders: [EKReminder] {
    reminders.filter { !linkedReminderIdentifiers.contains($0.calendarItemIdentifier) }
  }

  private var capacity: DayCapacity {
    DayCapacity(estimates: tasks.map(\.estimateMinutes), now: now, endOfDayHour: endOfDayHour)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // `header` (le titre de l'onglet) reste HORS du fondu, cf. `PageReveal`.
        header

        Group {
          eventsSection

          // ponytail: barre de capacité masquée à la demande de Ryan (« je jugerai plus tard ») —
          // le code (`capacityBar`, `capacity`, `planned`/`remaining`) reste intact pour la
          // rebrancher d'une ligne plutôt que de la reconstruire si elle revient.
          ForEach(tasks) { task in
            TodayRow(task: task, onToggle: { toggle(task) })
          }
          newTaskRow

          remindersSection
        }
        .pageReveal()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(
        onNewTask: { draftFocused = true }, onInsertHeader: nil,
        onSearch: { searchPresented = true })
    }
    .onReceive(ticker) { now = $0 }
    .task { await refreshAppleItems() }
    // Un rappel/événement peut changer côté Rappels/Calendrier pendant que Today est ouvert ou
    // en arrière-plan — même double déclencheur que `ContentView.syncCompletionsFromReminders`.
    .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
      Task { await refreshAppleItems() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await refreshAppleItems() }
    }
  }

  /// Silencieux si l'accès Rappels/Calendrier est refusé : les sections restent vides, le reste
  /// de la page fonctionne normalement (pas d'écran d'erreur pour une section informative).
  private func refreshAppleItems() async {
    await remindersService.refreshToday(now: now)
  }

  private var header: some View {
    HStack(spacing: 10) {
      PageHeaderIcon(systemImage: SmartList.today.systemImage, tint: SmartList.today.color)
      Text(SmartList.today.label)
        .font(.title.bold())
      Spacer(minLength: 0)
    }
    .padding(.bottom, 14)
  }

  /// La barre de réalité. `ProgressView` linéaire plutôt qu'un tracé maison : teinte, hauteur et
  /// contraste suivent le système (et le mode sombre) sans une ligne de plus.
  private var capacityBar: some View {
    let capacity = capacity
    return VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: capacity.fill)
        .tint(capacity.isOverbooked ? .red : .accentColor)

      HStack(spacing: 6) {
        Text(planned(capacity))
          .foregroundStyle(capacity.isOverbooked ? Color.red : .secondary)
        Text("·").foregroundStyle(.tertiary)
        Text(remaining(capacity))
          .foregroundStyle(.secondary)
        if capacity.unestimatedCount > 0 {
          Text("·").foregroundStyle(.tertiary)
          Text("\(capacity.unestimatedCount) sans durée")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.callout)
    }
  }

  private func planned(_ capacity: DayCapacity) -> String {
    guard let total = Estimate.label(capacity.plannedMinutes) else { return "Rien d'estimé" }
    guard capacity.isOverbooked else { return "\(total) planifiées" }
    // Le chiffre qui compte est le dépassement, pas le total : c'est lui qui appelle une décision.
    return "\(total) planifiées, \(Estimate.label(capacity.overflowMinutes) ?? "") de trop"
  }

  private func remaining(_ capacity: DayCapacity) -> String {
    guard let left = Estimate.label(capacity.availableMinutes) else {
      return "journée finie (\(endOfDayHour) h)"
    }
    return "\(left) avant \(endOfDayHour) h"
  }

  private func toggle(_ task: TaskItem) {
    withAnimation(taskInsert) {
      task.toggleCompletion()
      if task.isCompleted { task.list?.moveToEndOfSection(task) }
    }
    Task { await remindersService.pushCompletion(for: task) }
  }

  /// Coche le VRAI rappel Apple (`RemindersService.setCompleted`, déjà utilisé pour les tâches
  /// liées à un rappel) — retrait optimiste immédiat de la liste locale, comme `toggle(_:)` pour
  /// une tâche : on ne montre jamais que des rappels non complétés, cocher en fait donc sortir un
  /// tout de suite plutôt que d'attendre le prochain rafraîchissement.
  private func completeReminder(_ reminder: EKReminder) {
    let id = reminder.calendarItemIdentifier
    withAnimation(taskInsert) { remindersService.removeTodayReminder(id) }
    Task { try? await remindersService.setCompleted(true, identifier: id) }
  }

  /// Champ de création d'une tâche libre : ni liste ni projet, seulement datée d'aujourd'hui.
  /// Même retrait que `TodayRow` (case à cocher fantôme) pour rester aligné avec les titres.
  private var newTaskRow: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
        .overlay {
          Image(systemName: "plus")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .frame(width: 16, height: 16)
      TextField("Nouvelle tâche…", text: $draft)
        .textFieldStyle(.plain)
        .focused($draftFocused)
        .onSubmit(createTask)
    }
    .padding(.vertical, 4)
  }

  private func createTask() {
    let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = ""
    guard !title.isEmpty else {
      draftFocused = false
      return
    }
    let task = TaskItem(
      title: title, when: Calendar.current.startOfDay(for: Date()), list: inboxLists.first)
    withAnimation(taskInsert) { modelContext.insertAndSave(task) }
    draftFocused = true
  }

  // MARK: Rappels et événements Apple (lecture seule)

  /// Absente si vide — une page neuve ne montre pas une section sans rien dedans (même
  /// convention que `archiveSection`/`dormantSummary` de `ListPageView`).
  @ViewBuilder private var remindersSection: some View {
    if !unlinkedReminders.isEmpty {
      AppleItemsSection(title: "Rappels", systemImage: "bell") {
        ForEach(unlinkedReminders, id: \.calendarItemIdentifier) { reminder in
          ReminderRow(reminder: reminder, onToggle: { completeReminder(reminder) })
        }
      }
    }
  }

  /// Pas de bandeau ni de `Divider` ici (contrairement à « Rappels ») : à la demande de Ryan,
  /// les événements s'affichent seuls, tout en haut de la page.
  @ViewBuilder private var eventsSection: some View {
    if !events.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(events, id: \.eventIdentifier) { EventRow(event: $0) }
      }
      .padding(.top, 10)
      .padding(.bottom, 20)
    }
  }
}

/// Bandeau + contenu partagés par les sections « Rappels » et « Événements » : lecture seule,
/// donc pas de champ de création ni de menu — juste un titre et ses lignes.
private struct AppleItemsSection<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider().padding(.vertical, 10)
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.system(size: 11))
        Text(title)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.bottom, 6)
      content
    }
    .padding(.top, 8)
  }
}

/// Ligne d'un rappel Apple — MÊME design qu'une tâche (`TaskCheckbox`, titre, sous-titre), pour
/// qu'il se lise comme une tâche du jour parmi les autres. La case est cochable : cocher coche
/// le vrai rappel (cf. `TodayPageView.completeReminder`) — un tag à droite rappelle sa source,
/// seule différence visuelle avec une tâche de l'app.
struct ReminderRow: View {
  let reminder: EKReminder
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      TaskCheckbox(isCompleted: false, onToggle: onToggle)

      VStack(alignment: .leading, spacing: 1) {
        Text((reminder.title?.isEmpty == false ? reminder.title : nil) ?? "Sans titre")
        if let listTitle {
          Text(listTitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      SourceTag(label: dueTime.map { "Rappels · \($0)" } ?? "Rappels")
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var listTitle: String? {
    reminder.calendar.title.isEmpty ? nil : reminder.calendar.title
  }

  /// `nil` si le rappel n'a qu'une date sans heure (`dueDateComponents.hour` absent).
  private var dueTime: String? {
    guard let components = reminder.dueDateComponents, components.hour != nil,
      let date = Calendar.current.date(from: components)
    else { return nil }
    return date.formatted(date: .omitted, time: .shortened)
  }
}

/// Ligne d'un événement du Calendrier Apple — encadré teinté de la couleur du calendrier
/// d'origine, plutôt qu'une simple pastille : c'est le repère visuel le plus direct pour
/// distinguer un rendez-vous fixe d'une tâche ou d'un rappel.
struct EventRow: View {
  let event: EKEvent

  private var tint: Color { Color(cgColor: event.calendar.cgColor) }

  var body: some View {
    HStack(spacing: 8) {
      Text(timeLabel)
        .foregroundStyle(tint)
        .monospacedDigit()
      Text(event.title ?? "Sans titre")
      Spacer(minLength: 0)
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(tint.opacity(0.4))
    )
  }

  private var timeLabel: String {
    event.isAllDay ? "Toute la journée" : event.startDate.formatted(date: .omitted, time: .shortened)
  }
}

/// Pastille neutre indiquant qu'une ligne vient de Rappels/Calendrier — même gabarit
/// qu'`EstimateTag` (même hauteur de ligne), teinte volontairement neutre : ce n'est pas une
/// donnée actionnable de l'app, juste un repère de provenance.
struct SourceTag: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .fixedSize()
  }
}

/// Ligne d'« Aujourd'hui » : case, titre, rattachement, et le contrôle de durée à droite —
/// toujours visible (pas au survol) : sans durée, la barre du haut ne veut rien dire, l'estimation
/// doit donc être le geste le plus offert de la page.
private struct TodayRow: View {
  @Bindable var task: TaskItem
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
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
      estimateControl
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var estimateControl: some View {
    Menu {
      ForEach(Estimate.presets, id: \.self) { minutes in
        Button(Estimate.label(minutes) ?? "") { task.estimateMinutes = minutes }
      }
      if task.estimateMinutes > 0 {
        Divider()
        Button("Retirer la durée") { task.estimateMinutes = 0 }
      }
    } label: {
      EstimateTag(minutes: task.estimateMinutes)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  private var parent: String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
  }
}

/// Pastille de durée. Estimée : teintée. Vide : un tiret gris qui reste cliquable — une tâche
/// sans durée doit se voir dans la liste, c'est elle qui fausse le compte.
struct EstimateTag: View {
  let minutes: Int

  var body: some View {
    Text(Estimate.label(minutes) ?? "—")
      .font(.callout)
      .monospacedDigit()
      .foregroundStyle(minutes > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        Color.primary.opacity(minutes > 0 ? 0.06 : 0.03),
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .fixedSize()
  }
}
