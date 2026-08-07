import EventKit
import SwiftData
import SwiftUI

/// Page « Aujourd'hui » : ce qu'on a décidé de faire aujourd'hui.
///
/// Seules les tâches datées du JOUR MÊME (`SmartList.today`) apparaissent. Ni la veille ni le
/// lendemain : une tâche d'hier non faite quitte la page au passage de minuit et retourne dans sa
/// liste ou son projet. Pas de repêchage des retards — c'est ce qui empêche la page de devenir une
/// pile.
///
/// Une tâche créée ici est datée d'aujourd'hui d'office (cf. `createTask`) : c'est la raison
/// d'être de la page — noter ce qu'on fait maintenant sans avoir à choisir un projet.
///
/// Les tâches se réordonnent à la main (`TaskItem.smartOrder`) : c'est la raison d'être de la
/// page — on planifie sa journée en glissant, pas en ajustant des priorités jusqu'à ce que le tri
/// automatique tombe juste.
///
/// Le reste (édition, suppression, dates, durée, rappels, sous-tâches) vient de la `TaskRow` de
/// `TaskListView`, la même que les pages de liste.
struct TodayPageView: View {
  @Binding var searchPresented: Bool

  @Environment(RemindersService.self) private var remindersService
  /// Le glisser vers la barre latérale : la page n'en connaît que le nom, tout se joue au
  /// relâchement (cf. `dropTaskDrag`).
  @Environment(SidebarDrop.self) private var filing
  @Environment(\.modelContext) private var modelContext
  @Query private var allTasks: [TaskItem]
  // Destination de la tâche libre créée depuis cette page (cf. `createTask`) : l'Inbox, comme
  // toute tâche sans projet — « Aujourd'hui » ne fait que la filtrer par date, ce n'est pas sa
  // liste propre.
  @Query(filter: #Predicate<TodoList> { $0.isInbox }) private var inboxLists: [TodoList]
  /// Cibles du « Déplacer vers… » : depuis cette page, toutes les listes sont des destinations
  /// possibles (les tâches affichées viennent déjà d'un peu partout).
  @Query private var allLists: [TodoList]
  // Ce que la page appelle « aujourd'hui » ne doit pas être figé à l'ouverture : `startOfToday`
  // en dépend (la date posée à une tâche créée ici), et le rafraîchissement EventKit aussi. Sans
  // re-rendu régulier, une page laissée ouverte à travers minuit daterait d'hier.
  @State private var now = Date()
  // `@State` et pas un `let` construit dans le body : le tick change `now`, donc le body se
  // ré-évalue, donc un publisher construit là serait remplacé à chaque minute — `onReceive` se
  // réabonnerait, invalidant puis recréant un Timer à chaque fois. Ici il est créé une seule fois.
  @State private var ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
  /// Brouillon de la tâche libre (sans liste ni projet) créable depuis cette page.
  @State private var draft = ""
  @FocusState private var draftFocused: Bool
  /// Sélection (clic) et édition (clic sur une ligne déjà sélectionnée) — c'est `TaskRow` qui les
  /// consomme. Même type que les autres pages de tâches (cf. `TaskFocus`) : les transitions y sont
  /// écrites une fois, les courbes restent ici.
  @State private var focus = TaskFocus()
  /// Le glissement en cours, et les positions de repos qui lui servent de repère.
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

          ForEach(rows) { task in
            taskRow(
              for: task, offset: offsets[.task(task.persistentModelID)] ?? .zero, draggable: true,
              rows: rows)
          }
          newTaskRow
          remindersSection
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
      focus: $focus, blocks: { page.blocks }, delete: delete,
      reorder: $reorder,
      // Le MÊME geste que le ⊕ de la barre du bas : le champ de saisie prend le focus.
      newTask: createTaskInEditMode
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

  // MARK: Lignes de tâche

  /// La MÊME `TaskRow` que dans une page de liste : édition, suppression, dates, durée, rappels et
  /// sous-tâches viennent avec, sans une ligne de plus ici.
  private func taskRow(
    for task: TaskItem, showsParent: Bool = true,
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
      parentTag: showsParent ? TaskParentTag(of: task) : nil,
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
    .taskRowDragLayer(reorder, task: task, offset: offset, airborne: filing.isAirborne)
    // La même entrée que sur une page de liste : créée, ou revenue par ⌘Z.
    .taskRowInsertion()
    // Ce qui permet au socle de savoir qu'un clic est tombé À CÔTÉ des tâches, et au glissement de
    // savoir où la ligne peut se poser.
    .measureTaskRow(task)
  }

  /// Relâchement. La mécanique (lire le plan avant de désarmer, tout écrire en une transaction)
  /// est dans `dropTaskDrag` ; ici il ne reste que ce qui appartient à cette page — le rang.
  private func dropDraggedTask() {
    dropTaskDrag(&reorder, onto: filing, lists: allLists, in: modelContext) { ordered in
      TaskItem.stampSmartOrder(ordered)
      try? modelContext.save()
    }
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
    task.move(to: target)
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
    // Son rappel part avec elle : laissé derrière, il revient dans la section « Rappels » de
    // cette même page (cf. `RemindersService.forgetReminders`).
    withAnimation(taskInsert) {
      modelContext.deleteTasksAndSave([task], forgetReminders: remindersService.forgetReminders)
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
        // Même police qu'un titre de tâche (cf. `ListPageView.newTaskRow`) : le `body` natif est
        // 1 pt plus petit que l'échelle `Typo` de l'app.
        .font(.app(.body))
        .focused($draftFocused)
        .onSubmit(createTask)
    }
    // Mêmes paddings qu'une `TaskRow` au repos (vertical 6, `rowInset` horizontal) : la rangée de
    // création garde exactement le rythme des tâches — même règle que `ListPageView.draftRow`.
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
  }

  /// ⌘N : la tâche est créée VIDE et s'ouvre AUSSITÔT en édition — carte complète, avec notes,
  /// sous-tâches, date et priorité. C'est le geste de `ListPageView.createTaskInEditMode`, et il
  /// vaut désormais sur toutes les pages qui savent créer : le même raccourci ne peut pas donner
  /// deux résultats selon l'onglet.
  ///
  /// À ne pas confondre avec le ⊕ de la barre du bas (et le clic dans le champ « Nouvelle tâche »),
  /// qui posent seulement le focus sur ce champ : là on tape un titre et on valide, sans ouvrir la
  /// carte. Les deux chemins coexistent volontairement — l'un pour noter vite, l'autre pour
  /// détailler tout de suite.
  private func createTaskInEditMode() {
    // Datée d'aujourd'hui d'office, exactement comme une tâche notée dans le champ du bas : c'est
    // ce qui fait la page.
    let task = TaskItem(title: "", when: startOfToday, list: inboxLists.first)
    withAnimation(taskInsert) { modelContext.insertAndSave(task) }
    let id = task.persistentModelID
    // Au tour de boucle SUIVANT : la rangée doit exister dans l'arbre de vues avant que le focus
    // puisse s'y poser. Même raison, et même remède, que sur une page de liste.
    DispatchQueue.main.async {
      withAnimation(taskFlow) { focus.edit(id: id) }
    }
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
