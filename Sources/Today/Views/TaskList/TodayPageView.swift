import EventKit
import SwiftData
import SwiftUI

/// Page « Aujourd'hui » : ce qu'on a décidé de faire aujourd'hui, plus la réserve de tout ce qui
/// n'a pas de date et qu'on peut attraper au vol.
///
/// Deux étages, et la frontière est nette :
/// - en haut, les tâches datées du JOUR MÊME (`SmartList.today`). Ni la veille ni le lendemain :
///   une tâche d'hier non faite quitte la page au passage de minuit et retourne dans sa liste ou
///   son projet. Pas de repêchage des retards — c'est ce qui empêche la page de devenir une pile ;
/// - en bas, repliée, la réserve des tâches sans date, tous projets confondus.
///
/// Une tâche créée ici est datée d'aujourd'hui d'office (cf. `createTask`) : c'est la raison
/// d'être de la page — noter ce qu'on fait maintenant sans avoir à choisir un projet.
///
/// Les tâches DU JOUR se réordonnent à la main (`TaskItem.smartOrder`) : c'est la raison d'être de
/// la page — on planifie sa journée en glissant, pas en ajustant des priorités jusqu'à ce que le
/// tri automatique tombe juste. La réserve, elle, garde son tri automatique : c'est un fourre-tout
/// où l'on pioche, un ordre manuel n'y voudrait rien dire.
///
/// Le reste (édition, suppression, dates, durée, rappels, sous-tâches) vient de la `TaskRow` de
/// `TaskListView`, la même que les pages de liste.
struct TodayPageView: View {
  @Binding var searchPresented: Bool

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  @Query private var allTasks: [TaskItem]
  // Destination de la tâche libre créée depuis cette page (cf. `createTask`) : l'Inbox, comme
  // toute tâche sans projet — « Aujourd'hui » ne fait que la filtrer par date, ce n'est pas sa
  // liste propre.
  @Query(filter: #Predicate<TodoList> { $0.isInbox }) private var inboxLists: [TodoList]
  /// Cibles du « Déplacer vers… » : depuis cette page, toutes les listes sont des destinations
  /// possibles (les tâches affichées viennent déjà d'un peu partout).
  @Query private var allLists: [TodoList]
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
  /// Repliée par défaut, et l'état survit au relancement : la réserve est un fourre-tout qu'on
  /// ouvre quand on cherche quoi faire, pas la première chose qu'on doit lire en arrivant.
  @AppStorage("todayUndatedExpanded") private var undatedExpanded = false
  /// Sélection (clic) et édition (clic sur une ligne déjà sélectionnée) — c'est `TaskRow` qui les
  /// consomme. Même type que les autres pages de tâches (cf. `TaskFocus`) : les transitions y sont
  /// écrites une fois, les courbes restent ici.
  @State private var focus = TaskFocus()
  /// Le glissement en cours, et les positions de repos qui lui servent de repère. Seules les tâches
  /// DU JOUR se réordonnent : la réserve reste triée automatiquement, c'est un fourre-tout où l'on
  /// pioche, pas quelque chose qu'on met en ordre.
  @State private var reorder = TaskPageReorder()

  /// La date posée par la page (création et ⊕ de la réserve). Adossée à `now`, que le ticker
  /// rafraîchit : une fenêtre laissée ouverte toute la nuit date bien du bon jour au matin.
  private var startOfToday: Date { Calendar.current.startOfDay(for: now) }

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

  private func capacity(of tasks: [TaskItem]) -> DayCapacity {
    // Sans les cochées : elles restent affichées mais ne pèsent plus sur le temps qui reste.
    DayCapacity(
      estimates: tasks.filter { !$0.isCompleted }.map(\.estimateMinutes), now: now,
      endOfDayHour: endOfDayHour)
  }

  var body: some View {
    // Construite UNE fois par rendu, puis distribuée. Avant, chaque lecture de `tasks` refiltrait
    // et retriait toute la base — plusieurs fois par image.
    let page = TodayPage.build(from: allTasks)
    // La séquence VIVANTE, comme sur les autres pages. Elle ne bouge pas d'elle-même pendant un
    // geste (rien n'est écrit avant le relâchement), et c'est ce qui compte : rendre une séquence
    // figée puis rebasculer sur la vivante au lâcher faisait DEUX mouvements en même temps — le
    // `ForEach` réordonnait ses identités pendant que les décalages revenaient à zéro. La rangée
    // partait à l'opposé avant de revenir se poser.
    //
    // Le geste, lui, garde bien sa copie figée pour son calcul (cf. `TaskPageReorder`) : ce qui est
    // rendu et ce qui est calculé n'ont pas les mêmes contraintes.
    let rows = page.tasks
    // Calculés UNE fois et distribués aux rangées : les interroger par ligne referait le même
    // balayage à chaque rangée, à chaque image du glissement (cf. `ReorderLayout.offsets`).
    let offsets = reorder.offsets()
    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        Group {
          eventsSection

          // ponytail: barre de capacité masquée à la demande de Ryan (« je jugerai plus tard ») —
          // le code (`capacityBar`, `capacity`, `planned`/`remaining`) reste intact pour la
          // rebrancher d'une ligne plutôt que de la reconstruire si elle revient.
          ForEach(rows) { task in
            taskRow(
              for: task, offset: offsets[task.persistentModelID] ?? .zero, draggable: true,
              rows: rows)
          }
          newTaskRow
          remindersSection

          undatedSection(page)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    // Le trou d'insertion, la couche de glissement des rangées, la courbe : tout vient de
    // `TaskPageChrome`. Une page qui glisse ne redécrit rien de ce qui se voit.
    .taskReorderPlaceholder(reorder)
    // Le socle commun des pages de tâches : ⌫ et ↑/↓.
    // Le socle porte AUSSI les cadres des lignes : une seule mesure pour le clic dans le vide et
    // pour le glissement, gelée pendant un geste. Sans ce `reorder:`, la page mesure dans le vide —
    // le socle range les cadres chez lui et le glissement n'en voit aucun.
    .taskPageBase(
      focus: $focus, blocks: { page.blocks(undatedExpanded: undatedExpanded) }, delete: delete,
      reorder: $reorder
    )
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
        .font(.app(.title).bold())
      Spacer(minLength: 0)
    }
    // Même retrait que les lignes : depuis que la page rend des `TaskRow`, celles-ci portent
    // `rowInset` à l'intérieur de leur fond. Sans ça l'icône du titre déborde de 10 pt à gauche
    // de la colonne des cases à cocher (cf. `ListPageView.inboxHeader`, même règle).
    .padding(.leading, rowInset)
    .padding(.bottom, 14)
  }

  /// La barre de réalité. `ProgressView` linéaire plutôt qu'un tracé maison : teinte, hauteur et
  /// contraste suivent le système (et le mode sombre) sans une ligne de plus.
  private func capacityBar(of tasks: [TaskItem]) -> some View {
    let capacity = capacity(of: tasks)
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
      .font(.app(.callout))
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

  // MARK: Lignes de tâche

  /// La MÊME `TaskRow` que dans une page de liste : édition, suppression, dates, durée, rappels et
  /// sous-tâches viennent avec, sans une ligne de plus ici.
  private func taskRow(
    for task: TaskItem, showsParent: Bool = true, onSchedule: (() -> Void)? = nil,
    offset: CGSize = .zero, draggable: Bool = false, rows: [TaskItem] = []
  ) -> some View {
    // Typés ici : un ternaire entre une closure et `nil` ne s'infère pas au milieu d'une chaîne de
    // modificateurs, et le compilateur n'en dit rien d'utile.
    let onDrag: ((CGSize) -> Void)? = draggable ? { reorder.track(task, by: $0, in: rows) } : nil
    let onDrop: (() -> Void)? = draggable ? { dropDraggedTask() } : nil
    return TaskRow(
      task: task,
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      moveTargets: allLists.filter { $0.persistentModelID != task.list?.persistentModelID },
      showsDate: false,
      parentLabel: showsParent ? parentLabel(of: task) : nil,
      onSchedule: onSchedule,
      onBeginEditing: { beginEditing(task) },
      onEndEditing: { endEditing(task) },
      onMove: { move(task, to: $0) },
      onDuplicate: { duplicate(task) },
      onDelete: { delete(task) },
      onCompletionChanged: {}
    )
    // Un geste unique, comme dans `ListPageView` — pas deux `.onTapGesture` : le tap simple aurait
    // attendu la fin de la fenêtre de double-clic avant d'être délivré (cf. `RowPressGesture`,
    // qui documente la demi-seconde que ça coûtait ici).
    .rowPressGesture(
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      onSelect: { select(task) },
      onEdit: { beginEditing(task) },
      onDrag: onDrag,
      onDrop: onDrop
    )
    // Rien n'est capturé en image : c'est la vraie rangée qui se déplace, donc rien ne disparaît
    // ni ne réapparaît au relâchement.
    .taskRowDragLayer(reorder, task: task, offset: offset)
    // La même entrée que sur une page de liste : créée, ou revenue par ⌘Z.
    .taskRowInsertion()
    // Ce qui permet au socle de savoir qu'un clic est tombé À CÔTÉ des tâches, et au glissement de
    // savoir où la ligne peut se poser.
    .measureTaskRow(task)
  }

  /// Relâchement. La mécanique (lire le plan avant de désarmer, tout écrire en une transaction)
  /// est dans `dropTaskDrag` ; ici il ne reste que ce qui appartient à cette page — le rang.
  private func dropDraggedTask() {
    dropTaskDrag(&reorder) { ordered in
      TaskItem.stampSmartOrder(ordered)
      try? modelContext.save()
    }
  }

  private func parentLabel(of task: TaskItem) -> String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
  }

  private func select(_ task: TaskItem) {
    withAnimation(taskSelectFade) { focus.select(task) }
    // Même raison que dans `ListPageView.select` : sans ça le champ « Nouvelle tâche » reste le
    // premier répondeur AppKit et intercepte ⌫ au lieu de la suppression de la sélection.
    draftFocused = false
  }

  private func beginEditing(_ task: TaskItem) {
    withAnimation(taskFlow) { focus.edit(task) }
    draftFocused = false
  }

  private func endEditing(_ task: TaskItem) {
    guard focus.isEditing(task) else { return }
    withAnimation(taskFlow) { focus.endEditing(task) }
  }

  /// Pose la tâche à la fin de sa nouvelle liste, comme `ListPageView.move`.
  private func move(_ task: TaskItem, to target: TodoList) {
    focus.forget(task)
    task.list = target
    task.sortIndex = (target.tasks.map(\.sortIndex).max() ?? -1) + 1
    try? modelContext.save()
  }

  private func duplicate(_ task: TaskItem) {
    guard let list = task.list else { return }
    let clone = task.copy(into: list)
    clone.sortIndex = task.sortIndex + 1
    modelContext.insertAndSave(clone)
  }

  private func delete(_ task: TaskItem) {
    focus.forget(task)
    withAnimation(taskInsert) {
      modelContext.delete(task)
      try? modelContext.save()
    }
  }

  /// Fait passer une tâche de la réserve à la journée. Pas d'heure : comme partout ailleurs dans
  /// l'app, on ne pose qu'un jour (cf. `hasTime`, écrit mais jamais lu).
  private func schedule(_ task: TaskItem) {
    withAnimation(taskInsert) { task.when = startOfToday }
  }

  // MARK: Réserve (tâches sans date)

  /// `DisclosureGroup` plutôt qu'un chevron maison : le triangle, son animation, le clic sur le
  /// libellé et l'accessibilité viennent avec, et l'indentation du contenu sépare visuellement la
  /// réserve de l'engagement du jour sans une ligne de mise en page.
  @ViewBuilder private func undatedSection(_ page: TodayPage) -> some View {
    if !page.undated.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Divider().padding(.vertical, 10)
        DisclosureGroup(isExpanded: $undatedExpanded) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(page.undated) { group in
              Text(group.name)
                .font(.app(.callout).weight(.semibold))
                .foregroundStyle(.secondary)
                // Aplomb sur la colonne des cases à cocher, que les `TaskRow` décalent de
                // `rowInset` : un en-tête de groupe se lit comme la tête de sa colonne.
                .padding(.leading, rowInset)
                .padding(.top, 10)
                .padding(.bottom, 2)
              ForEach(group.tasks) { task in
                // Pas de rattachement sur la ligne : l'en-tête du groupe le porte déjà.
                taskRow(for: task, showsParent: false, onSchedule: { schedule(task) })
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "tray.full")
              .font(.app(11))
            Text("Tâches sans date")
            Text("\(page.undatedCount)")
              .foregroundStyle(.tertiary)
          }
          .font(.app(.subheadline).weight(.semibold))
          .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 8)
    }
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
            .font(.app(9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .frame(width: 16, height: 16)
      TextField("Nouvelle tâche…", text: $draft)
        .textFieldStyle(.plain)
        .focused($draftFocused)
        .onSubmit(createTask)
    }
    // Mêmes paddings qu'une `TaskRow` au repos (vertical 6, `rowInset` horizontal) : la rangée de
    // création garde exactement le rythme des tâches — même règle que `ListPageView.draftRow`.
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
  }

  private func createTask() {
    let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = ""
    guard !title.isEmpty else {
      draftFocused = false
      return
    }
    // Datée d'aujourd'hui d'office : c'est ce qui fait la page. Une tâche notée ici est une tâche
    // qu'on fait aujourd'hui — sinon elle se note dans « Tâches », qui ne date rien.
    let task = TaskItem(title: title, when: startOfToday, list: inboxLists.first)
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
          .font(.app(11))
        Text(title)
      }
      .font(.app(.subheadline).weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.bottom, 6)
      content
    }
    .padding(.top, 8)
  }
}

/// Ligne d'un rappel Apple — MÊME design qu'une tâche (`TaskCheckbox`, titre), pour qu'il se lise
/// comme une tâche du jour parmi les autres, sans repère de provenance.
struct ReminderRow: View {
  let reminder: EKReminder
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      TaskCheckbox(isCompleted: false, onToggle: onToggle)
      Text((reminder.title?.isEmpty == false ? reminder.title : nil) ?? "Sans titre")
        .font(.app(.body))
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
    .contentShape(Rectangle())
  }
}

/// Ligne d'un événement du Calendrier Apple — encadré teinté de la couleur du calendrier
/// d'origine, plutôt qu'une simple pastille : c'est le repère visuel le plus direct pour
/// distinguer un rendez-vous fixe d'une tâche ou d'un rappel.
struct EventRow: View {
  let event: EKEvent

  // `calendar` et `cgColor` sont tous deux `null_unspecified` côté EventKit (donc implicitement
  // déballés) : un calendrier d'abonnement peut n'avoir aucune couleur, et l'`init` de `Color` la
  // veut non optionnelle — la teinte système sert alors de repli plutôt que de planter.
  private var tint: Color {
    (event.calendar?.cgColor).map(Color.init(cgColor:)) ?? .accentColor
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(timeLabel)
        .foregroundStyle(tint)
        .monospacedDigit()
      Text(event.title ?? "Sans titre")
      Spacer(minLength: 0)
    }
    .font(.app(.callout))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(tint.opacity(0.4))
    )
  }

  private var timeLabel: String {
    event.isAllDay
      ? "Toute la journée" : event.startDate.formatted(date: .omitted, time: .shortened)
  }
}

// `TodayRow`, `UndatedRow` et `EstimateTag` ont été retirés : la page rend désormais la `TaskRow`
// de `TaskListView`, qui apporte édition, suppression, dates, durée, rappels et sous-tâches.
// Une ligne propre à cette page aurait redivergé au premier changement de l'autre.
