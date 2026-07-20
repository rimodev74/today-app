import AppKit
import SwiftData
import SwiftUI

struct SidebarView: View {
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  /// Posée à la création d'une liste : sa page y réagit en passant son TITRE en édition.
  /// Cf. `ContentView.pendingTitleFocus`.
  @Binding var pendingTitleFocus: PersistentIdentifier?

  @Environment(\.modelContext) private var modelContext
  @Query private var allTasks: [TaskItem]
  @Query(sort: [SortDescriptor(\Project.sortIndex), SortDescriptor(\Project.createdAt)])
  private var projects: [Project]

  /// Un seul état de renommage pour toute la sidebar : projets et listes ne peuvent
  /// pas être édités en même temps, deux états séparés se désynchroniseraient.
  @State private var editingID: PersistentIdentifier?
  @State private var collapsedProjects: Set<PersistentIdentifier> = []
  @FocusState private var renameFocused: Bool

  // La sidebar est un « pan » focalisable : ⌫ ne supprime la sélection QUE quand la sidebar a le
  // focus (posé au clic sur une ligne). Sans ce garde-fou, un ⌫ tapé en travaillant dans la page
  // de droite effacerait la liste courante — la sélection de la sidebar est toujours non-nil.
  @FocusState private var sidebarFocused: Bool
  // Liste/projet en attente de confirmation de suppression (non-vide) ⇒ alerte affichée.
  @State private var deletionCandidate: DeletionCandidate?

  private enum DeletionCandidate: Identifiable {
    case list(TodoList)
    case project(Project)
    var id: PersistentIdentifier {
      switch self {
      case .list(let l): return l.persistentModelID
      case .project(let p): return p.persistentModelID
      }
    }
  }

  // MARK: Réordonnancement (drag) — même moteur que la liste de tâches (mesure des positions de
  // repos, ligne soulevée qui suit le curseur, voisines qui s'écartent, ordre écrit au drop),
  // adapté à la hiérarchie. Un PROJET se réordonne entre projets en emmenant ses listes comme un
  // bloc (jamais dans une liste) ; une LISTE se réordonne et peut CHANGER de projet.
  // `dragID` = ligne empoignée ; `draggedKeys` = son groupe ; `dragOffset` sa translation sous le
  // curseur ; `rowFrames` la position de repos mesurée de chaque ligne (gelée pendant le drag).
  @State private var dragID: PersistentIdentifier?
  @State private var dragIsProject = false
  @State private var dragOffset: CGSize = .zero
  @State private var draggedKeys: [RowKey] = []
  @State private var rowFrames: [RowKey: CGRect] = [:]

  private static let dragSpace = "sidebarReorder"

  /// Clé de mesure d'une ligne. Un projet et sa rangée « + » partagent le `persistentModelID` du
  /// projet : l'énum les distingue pour que leurs cadres ne s'écrasent pas.
  private enum RowKey: Hashable {
    case project(PersistentIdentifier)
    case list(PersistentIdentifier)
    case addList(PersistentIdentifier)
  }

  private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [RowKey: CGRect] = [:]
    static func reduce(value: inout [RowKey: CGRect], nextValue: () -> [RowKey: CGRect]) {
      value.merge(nextValue()) { _, new in new }
    }
  }

  private let smartLists: [SmartList] = [.all, .today, .upcoming, .archive]

  var body: some View {
    VStack(spacing: 0) {
      ProfileCard()
        .padding(.horizontal, 10)
        .padding(.top, 30)  // dégage les feux tricolores intégrés à la sidebar

      searchButton
        .padding(.horizontal, 10)
        .padding(.top, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          smartListGroup
          pomodoroRow

          Divider()
            .padding(.vertical, 10)
            .padding(.horizontal, 8)

          projectsGroup
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollContentBackground(.hidden)
    }
    .safeAreaInset(edge: .bottom) { bottomBar }
    // Focus posé au clic sur une ligne (cf. `sidebarRow`) ; `focusEffectDisabled` retire l'anneau
    // système qu'un conteneur focalisable afficherait. Cliquer dans la page de droite vole le
    // premier répondeur → `sidebarFocused` repasse à false, et ⌫ n'agit plus sur la sidebar.
    .focusable()
    .focused($sidebarFocused)
    .focusEffectDisabled()
    .onDeleteCommand(perform: requestDeleteSelection)
    // Confirmation seulement si l'élément n'est pas vide ; sinon la suppression est immédiate
    // (cf. `requestDeleteSelection`).
    .alert(
      deletionCandidate.map(alertTitle) ?? "",
      isPresented: Binding(
        get: { deletionCandidate != nil },
        set: { if !$0 { deletionCandidate = nil } }
      ),
      presenting: deletionCandidate
    ) { candidate in
      Button("Supprimer", role: .destructive) {
        performDelete(candidate)
        deletionCandidate = nil
      }
      Button("Annuler", role: .cancel) { deletionCandidate = nil }
    } message: { candidate in
      Text(alertMessage(candidate))
    }
  }

  // MARK: Recherche

  /// Ce n'est plus un champ mais un bouton : la saisie et les résultats vivent dans un
  /// popover (cf. `SearchPopover`), pas dans la sidebar. Il garde l'allure d'un champ de
  /// recherche (capsule, loupe, placeholder gris) pour rester lisible comme tel.
  private var searchButton: some View {
    Button {
      searchPresented = true
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.system(size: 12))
        Text("Rechercher…")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 12)
      .contentShape(Capsule())
      .background(.quaternary.opacity(0.5), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: Listes intelligentes

  private var smartListGroup: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(smartLists, id: \.self) { list in
        sidebarRow(isSelected: { selection == .smartList(list) }) {
          selection = .smartList(list)
        } label: {
          HStack(spacing: 8) {
            Label {
              Text(list.label)
            } icon: {
              Image(systemName: list.systemImage).foregroundStyle(list.color)
            }
            Spacer(minLength: 0)
            if let count = badge(for: list) {
              Text("\(count)").foregroundStyle(.secondary)
            }
          }
          .font(.system(size: 14, weight: .semibold))
        }
      }
    }
  }

  // Compteur seulement là où il aide à décider quoi faire maintenant.
  private func badge(for list: SmartList) -> Int? {
    guard list == .today else { return nil }
    let count = list.filter(allTasks).count
    return count > 0 ? count : nil
  }

  private var pomodoroRow: some View {
    sidebarRow(isSelected: { selection == .pomodoro }) {
      selection = .pomodoro
    } label: {
      Label {
        Text("Pomodoro")
      } icon: {
        Image(systemName: "timer").foregroundStyle(.red)
      }
      .font(.system(size: 14, weight: .semibold))
    }
  }

  // MARK: Projets et to-do lists

  private var projectsGroup: some View {
    let plan = dragPlan()
    return VStack(alignment: .leading, spacing: 4) {
      if projects.isEmpty {
        Text("Aucun projet")
          .font(.callout)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
      }
      ForEach(sortedProjects) { project in
        projectRow(project, plan: plan)
        if !collapsedProjects.contains(project.persistentModelID) {
          ForEach(project.orderedLists) { list in
            listRow(list, plan: plan)
          }
          addListRow(project, plan: plan)
        }
      }
    }
    // Espace de coordonnées partagé : mesure des positions de repos ET translation du drag.
    .coordinateSpace(name: Self.dragSpace)
    // Placeholder du trou d'insertion, derrière les lignes (visible seulement dans l'écart ouvert).
    // MÊME rectangle que la surbrillance de sélection d'une ligne (`sidebarRow` : même couleur,
    // même rayon, même gabarit mesuré) — juste vide, sans anneau ni titre.
    .background(alignment: .topLeading) {
      if let plan, let r = placeholderRect(plan: plan) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
          .frame(width: r.width, height: r.height)
          .offset(x: r.minX, y: r.minY)
          .allowsHitTesting(false)
      }
    }
    // Gel des cadres pendant le drag : réinjecter des cadres déjà décalés relancerait la boucle
    // offset→cadre→offset (même piège que côté TaskListView).
    .onPreferenceChange(RowFrameKey.self) { frames in
      guard dragID == nil else { return }
      rowFrames = frames
    }
  }

  private func projectRow(_ project: Project, plan: DragPlan?) -> some View {
    let id = project.persistentModelID
    let row = sidebarRow(isSelected: { selection == .project(project) }, verticalPadding: 3) {
      selection = .project(project)
    } label: {
      HStack(spacing: 6) {
        // Pas un Button : le `.onTapGesture` du `sidebarRow` (posé sur toute la ligne via
        // contentShape) avale le clic d'un Button imbriqué. Un `highPriorityGesture` sur le
        // chevron passe DEVANT le tap de la ligne — il déroule sans aussi sélectionner le projet.
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(collapsedProjects.contains(id) ? 0 : 90))
          // Cible de clic élargie : la flèche fait 9pt mais sa zone tactile couvre 24×20 (tout le
          // flanc gauche de la rangée), bien plus facile à viser que le glyphe seul. Hauteur 20 (et
          // padding vertical réduit) pour une rangée de projet plus compacte.
          .frame(width: 24, height: 20)
          .contentShape(Rectangle())
          .highPriorityGesture(
            TapGesture().onEnded {
              withAnimation(.snappy(duration: 0.2)) { toggleCollapse(id) }
            }
          )

        editableTitle(id: id, text: Bindable(project).title, placeholder: "Nom du projet") {
          if project.title.trimmingCharacters(in: .whitespaces).isEmpty {
            project.title = "Nouveau projet"
          }
        }
        .font(.system(size: 13, weight: .semibold))
      }
    } onRename: {
      startRename(id)
    }
    .contextMenu {
      Button("Renommer") { startRename(id) }
      Button("Nouvelle to-do list") { addList(to: project) }
      Divider()
      Button("Supprimer le projet", role: .destructive) { requestDelete(project) }
    }
    return reorderable(row, key: .project(id), id: id, isProject: true, plan: plan)
  }

  private func listRow(_ list: TodoList, plan: DragPlan?) -> some View {
    let id = list.persistentModelID
    let row = sidebarRow(isSelected: { selection == .list(list) }) {
      selection = .list(list)
    } label: {
      HStack(spacing: 8) {
        ProgressRing(progress: list.progress, showsFill: true)
        editableTitle(id: id, text: Bindable(list).title, placeholder: "Nom de la liste") {
          if list.title.trimmingCharacters(in: .whitespaces).isEmpty {
            list.title = "Nouvelle liste"
          }
        }
        .font(.system(size: 13))
        if list.remainingCount > 0 {
          Text("\(list.remainingCount)")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
      }
    } onRename: {
      startRename(id)
    }
    .contextMenu {
      Button("Renommer") { startRename(id) }
      Divider()
      Button("Supprimer la liste", role: .destructive) { requestDelete(list) }
    }
    // L'indentation de 18 est posée APRÈS le wrapper de mesure : ainsi le cadre mesuré = la zone
    // exacte de la surbrillance de sélection (`sidebarRow`), pas la ligne + son retrait. C'est ce
    // cadre qui dimensionne le placeholder → il coïncide pile avec une liste sélectionnée.
    return reorderable(row, key: .list(id), id: id, isProject: false, plan: plan)
      .padding(.leading, 18)
  }

  private func addListRow(_ project: Project, plan: DragPlan?) -> some View {
    let button = Button {
      addList(to: project)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 12)
        Text("Nouvelle liste")
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      .foregroundStyle(.tertiary)
      .padding(.vertical, 3)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.leading, 18)
    // Non déplaçable, mais mesurée et décalée comme les autres : elle fait partie du bloc d'un
    // projet tiré, et sa hauteur doit entrer dans les écarts. Pendant N'IMPORTE QUEL drag (liste
    // ou projet), toutes les rangées « + Nouvelle liste » s'effacent — elles encombreraient le
    // déplacement. `opacity` (et pas un retrait) : elles gardent leur place dans le calcul d'écart.
    return measured(button, key: .addList(project.persistentModelID), plan: plan)
      .opacity(dragID != nil ? 0 : 1)
      .animation(.easeInOut(duration: 0.2), value: dragID != nil)
  }

  // MARK: Ligne générique

  /// Une ligne = fond + padding identiques en tout temps, seul le contenu change.
  /// `onRename` (clic sur une ligne déjà sélectionnée) est optionnel : les listes
  /// intelligentes ne se renomment pas.
  /// `isSelected` est un GETTER, pas une valeur : au double-clic, le 2e clic arrive souvent
  /// avant que SwiftUI n'ait re-rendu la ligne avec la sélection posée par le 1er, donc un
  /// `Bool` capturé par la closure du geste serait encore périmé. Un getter relit `selection`
  /// en direct à l'exécution — jamais périmé, même geste que `TaskListView` (`selectedID`
  /// lu en direct dans `dragGesture`, jamais capturé).
  private func sidebarRow<L: View>(
    isSelected: @escaping () -> Bool,
    verticalPadding: CGFloat = 5,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> L,
    onRename: (() -> Void)? = nil
  ) -> some View {
    label()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, verticalPadding)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
      .background(
        isSelected() ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      // Renommage façon Finder — clic sur une ligne DÉJÀ sélectionnée — plutôt qu'un vrai
      // double-clic : un `TapGesture(count: 2)` simultané à ce tap se fait doubler par CHAQUE
      // clic qui le compose (le second déclenche aussi le tap simple), sans garantie d'ordre —
      // le renommage démarrait puis `editingID` retombait aussitôt à nil. Même pattern que
      // TaskRow (cf. `dragGesture` dans TaskListView).
      //
      // Le clic n'est JAMAIS gardé par `editingID == nil` : si un renommage restait
      // coincé (champ qui ne prend pas le focus), plus une seule ligne de la sidebar
      // ne répondait. Cliquer ailleurs pendant une édition la valide et sélectionne.
      .onTapGesture {
        if isSelected(), editingID == nil, let onRename {
          onRename()
        } else {
          editingID = nil
          sidebarFocused = true  // le pan sidebar devient actif → ⌫ agit sur cette sélection
          action()
        }
      }
  }

  /// Titre qui bascule en champ de saisie pendant le renommage, sans changer de gabarit.
  @ViewBuilder
  private func editableTitle(
    id: PersistentIdentifier,
    text: Binding<String>,
    placeholder: String,
    commit: @escaping () -> Void
  ) -> some View {
    if editingID == id {
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .focused($renameFocused)
        // Le focus se pose ICI, quand le champ existe. Le poser depuis startRename()
        // le perdait : SwiftUI ignore un @FocusState visant une vue pas encore montée,
        // et `editingID` restait alors bloqué pour toujours. Posé un tour de runloop après le
        // montage : synchrone, il entrait parfois en concurrence avec le relâchement du focus
        // du conteneur sidebar (cf. `startRename`), encore en cours d'application côté AppKit.
        .onAppear {
          DispatchQueue.main.async { renameFocused = true }
        }
        .onSubmit {
          commit()
          editingID = nil
          sidebarFocused = true  // rend le focus au conteneur : ⌫ redevient actif sur la ligne
        }
        .onExitCommand {
          commit()
          editingID = nil
          sidebarFocused = true
        }
        .onChange(of: renameFocused) { _, focused in
          if focused {
            // Tout le texte sélectionné à l'entrée en édition — signale que c'est modifiable et
            // qu'une frappe remplace le nom entier (comme un renommage Finder). Pas d'API SwiftUI
            // pour ça avant macOS 15 (`TextField` + `selection:`, hors de portée du minimum .v14
            // du projet) ; on passe par l'éditeur de champ AppKit, posé un tour de runloop après
            // le focus (sinon `firstResponder` pointe encore l'ancien élément).
            DispatchQueue.main.async {
              (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            }
          } else {
            commit()
            editingID = nil
            sidebarFocused = true
          }
        }
    } else {
      Text(text.wrappedValue)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: Barre du bas

  private var bottomBar: some View {
    HStack {
      Button(action: addProject) {
        Label("Nouveau projet", systemImage: "plus")
      }
      .buttonStyle(.plain)
      .padding(.leading, 4)

      Spacer()

      SettingsLink {
        Image(systemName: "slider.horizontal.3")
      }
      .buttonStyle(.plain)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }

  // MARK: Actions

  private func toggleCollapse(_ id: PersistentIdentifier) {
    if collapsedProjects.contains(id) {
      collapsedProjects.remove(id)
    } else {
      collapsedProjects.insert(id)
    }
  }

  private func startRename(_ id: PersistentIdentifier) {
    // Libère le focus du CONTENEUR sidebar avant de le donner au champ : sinon les deux
    // `@FocusState` (celui-ci et `renameFocused`) se disputent le premier répondeur — le champ
    // gagnait le focus un instant (surbrillance visible) puis le reperdait aussitôt au profit
    // du conteneur, qui restait à `true` depuis le clic de sélection qui précède le renommage.
    sidebarFocused = false
    editingID = id  // le focus suit dans .onAppear du champ
  }

  private func addProject() {
    let project = Project(title: "Nouveau projet")
    project.sortIndex = (projects.map(\.sortIndex).max() ?? -1) + 1
    modelContext.insertAndSave(project)
    // Un projet vide n'est pas utilisable : il lui faut au moins une liste pour poser une tâche.
    let list = TodoList(title: "Nouvelle liste", project: project)
    modelContext.insertAndSave(list)
    selection = .project(project)
    startRename(project.persistentModelID)
  }

  private func addList(to project: Project) {
    let list = TodoList(title: "Nouvelle liste", project: project)
    list.sortIndex = (project.lists.map(\.sortIndex).max() ?? -1) + 1
    modelContext.insertAndSave(list)
    collapsedProjects.remove(project.persistentModelID)
    selection = .list(list)
    // Le nom s'édite dans le TITRE de la page (pas la sidebar) : c'est ce qui permet à la validation
    // (Entrée) d'enchaîner sur la 1re tâche sans course de focus inter-vues.
    pendingTitleFocus = list.persistentModelID
  }

  private func delete(_ project: Project) {
    if selection == .project(project) { selection = .smartList(.all) }
    modelContext.delete(project)
  }

  private func delete(_ list: TodoList) {
    if selection == .list(list) {
      selection = list.project.map { .project($0) } ?? .smartList(.all)
    }
    modelContext.delete(list)
  }

  /// Suppression directe si l'élément est vide (liste sans tâche, projet sans liste), sinon
  /// confirmation via l'alerte. Point de passage commun à ⌫ et au menu contextuel.
  private func requestDelete(_ list: TodoList) {
    if list.tasks.isEmpty { delete(list) } else { deletionCandidate = .list(list) }
  }

  private func requestDelete(_ project: Project) {
    if project.lists.isEmpty { delete(project) } else { deletionCandidate = .project(project) }
  }

  /// ⌫ sur la sélection. Ne fait rien pendant un renommage.
  private func requestDeleteSelection() {
    guard editingID == nil else { return }
    switch selection {
    case .list(let list): requestDelete(list)
    case .project(let project): requestDelete(project)
    default:
      break  // vues intelligentes, pomodoro : rien à supprimer
    }
  }

  private func performDelete(_ candidate: DeletionCandidate) {
    switch candidate {
    case .list(let list): delete(list)
    case .project(let project): delete(project)
    }
  }

  private func alertTitle(_ candidate: DeletionCandidate) -> String {
    switch candidate {
    case .list: return "Supprimer la liste ?"
    case .project: return "Supprimer le projet ?"
    }
  }

  private func alertMessage(_ candidate: DeletionCandidate) -> String {
    switch candidate {
    case .list(let list):
      let name = list.title.isEmpty ? "Cette liste" : "« \(list.title) »"
      let n = list.tasks.count
      return "\(name) contient \(n) tâche\(n > 1 ? "s" : ""). Elles seront aussi supprimées."
    case .project(let project):
      let name = project.title.isEmpty ? "Ce projet" : "« \(project.title) »"
      let n = project.lists.count
      return "\(name) contient \(n) liste\(n > 1 ? "s" : ""). Elles seront aussi supprimées."
    }
  }

  // MARK: Réordonnancement — moteur
  //
  // Réordonnancement « physique » comme dans TaskListView : on ne prend PAS d'instantané
  // (`.onDrag`), la vraie ligne est décalée sous le curseur tandis que les voisines s'écartent.
  // Au drop, l'ordre atteint est écrit dans les `sortIndex` (et le `project` d'une liste qui a
  // changé de parent), puis les décalages retombent à 0 : rien ne saute.

  /// Enveloppe mesure + décalage d'une ligne NON empoignable (la rangée « + »), sans geste.
  private func measured(_ content: some View, key: RowKey, plan: DragPlan?) -> some View {
    content
      .background {
        GeometryReader { g in
          Color.clear.preference(
            key: RowFrameKey.self, value: [key: g.frame(in: .named(Self.dragSpace))])
        }
      }
      .opacity(folding(key) ? 0 : 1)
      .offset(offset(for: key, plan: plan))
      .zIndex(draggedKeys.contains(key) ? 1 : 0)
      .animation(
        draggedKeys.contains(key) ? nil : .snappy(duration: 0.22),
        value: offset(for: key, plan: plan)
      )
      .animation(.easeInOut(duration: 0.2), value: folding(key))
  }

  /// Une liste ou la rangée « + » d'un PROJET tiré : elle se replie (invisible) pendant le transport,
  /// seul l'en-tête voyage — exactement comme les tâches d'une en-tête tirée dans TaskListView.
  private func folding(_ key: RowKey) -> Bool {
    guard dragIsProject, let id = dragID, draggedKeys.contains(key) else { return false }
    if case .project(let pid) = key, pid == id { return false }  // l'en-tête reste visible
    return true
  }

  /// Idem `measured`, plus le soulevé (ombre/échelle de la ligne empoignée) et le geste de drag.
  private func reorderable(
    _ content: some View, key: RowKey, id: PersistentIdentifier, isProject: Bool, plan: DragPlan?
  ) -> some View {
    let grabbed = dragID == id
    // `simultaneousGesture` + `minimumDistance` : un simple clic (sélection) et le double-clic
    // (renommage) posés par `sidebarRow` restent prioritaires ; le drag ne s'arme qu'au-delà du
    // seuil de mouvement. Sur macOS, un glisser dans une ScrollView ne la fait pas défiler → aucun
    // conflit avec le scroll.
    return measured(content, key: key, plan: plan)
      .scaleEffect(grabbed ? 1.02 : 1)
      .shadow(
        color: .black.opacity(grabbed ? 0.18 : 0), radius: grabbed ? 8 : 0, y: grabbed ? 4 : 0
      )
      .simultaneousGesture(reorderGesture(id: id, isProject: isProject))
  }

  private func reorderGesture(id: PersistentIdentifier, isProject: Bool) -> some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.dragSpace))
      .onChanged { value in
        guard editingID == nil else { return }  // pas de drag pendant un renommage
        if dragID == nil {
          dragID = id
          dragIsProject = isProject
          draggedKeys = groupKeys(id: id, isProject: isProject)
        }
        guard dragID == id else { return }
        dragOffset = value.translation
      }
      .onEnded { _ in
        guard dragID == id else { return }
        commitDrag()
      }
  }

  /// Projets triés EN MÉMOIRE par `sortIndex` (comme `TodoList.orderedTasks`). Indispensable pour le
  /// drag : changer un `sortIndex` réordonne ce tableau tout de suite (synchrone), là où le `@Query`
  /// `projects` ne se re-trie qu'au tour de boucle suivant — ce délai décollait le réordonnancement
  /// de la retombée des offsets au drop (trou transitoire).
  private var sortedProjects: [Project] {
    projects.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  /// Ordre visuel des lignes déplaçables (et de la rangée « + »), de haut en bas. Base de tout le
  /// calcul d'insertion. Stable pendant un drag (ni l'ordre ni le repli ne changent avant le drop).
  private var physicalRows: [RowKey] {
    var rows: [RowKey] = []
    for p in sortedProjects {
      rows.append(.project(p.persistentModelID))
      if !collapsedProjects.contains(p.persistentModelID) {
        for l in p.orderedLists { rows.append(.list(l.persistentModelID)) }
        rows.append(.addList(p.persistentModelID))
      }
    }
    return rows
  }

  /// Lignes qu'emporte le drag : un projet emmène son bloc (lui + ses listes + sa rangée « + »),
  /// une liste voyage seule. Figé à l'empoignade dans `draggedKeys`.
  private func groupKeys(id: PersistentIdentifier, isProject: Bool) -> [RowKey] {
    guard isProject, let p = project(id) else { return [.list(id)] }
    var keys: [RowKey] = [.project(id)]
    if !collapsedProjects.contains(id) {
      keys += p.orderedLists.map { .list($0.persistentModelID) }
      keys.append(.addList(id))
    }
    return keys
  }

  private func project(_ id: PersistentIdentifier) -> Project? {
    projects.first { $0.persistentModelID == id }
  }
  private func list(_ id: PersistentIdentifier) -> TodoList? {
    projects.lazy.flatMap(\.lists).first { $0.persistentModelID == id }
  }

  /// Rectangle englobant d'un ensemble de lignes contiguës (positions de repos mesurées).
  private func rect(of keys: [RowKey]) -> CGRect? {
    let frames = keys.compactMap { rowFrames[$0] }
    guard let f0 = frames.first else { return nil }
    let minY = frames.map(\.minY).min() ?? 0
    let maxY = frames.map(\.maxY).max() ?? 0
    return CGRect(x: f0.minX, y: minY, width: f0.width, height: maxY - minY)
  }

  /// Plan du drag courant. `nil` hors drag (ou positions pas encore mesurées).
  ///
  /// Repli façon en-tête (cf. TaskListView) : un PROJET tiré se réduit à son en-tête, qui seul
  /// voyage ; ses listes + rangée « + » se replient (invisibles). `unit` = hauteur du placeholder
  /// et pas d'écartement des voisines (l'en-tête pour un projet, la ligne pour une liste). `delta`
  /// = ce que le bloc perd en se repliant → les lignes SOUS lui remontent d'autant.
  private struct DragPlan {
    var others: [RowKey]
    var insert: Int
    var groupStart: Int  // B : nb de lignes avant le groupe (dans l'espace `others`)
    var unit: CGFloat
    var delta: CGFloat
    var firstFrame: CGRect
  }

  private func dragPlan() -> DragPlan? {
    guard dragID != nil, !draggedKeys.isEmpty,
      let groupRect = rect(of: draggedKeys),
      let firstFrame = rowFrames[draggedKeys[0]]
    else { return nil }
    let phys = physicalRows
    let dragged = Set(draggedKeys)
    guard let g0 = phys.firstIndex(where: { dragged.contains($0) }) else { return nil }
    let others = phys.filter { !dragged.contains($0) }
    let unit = dragIsProject ? firstFrame.height : groupRect.height
    let delta = dragIsProject ? (groupRect.height - firstFrame.height) : 0
    // Centre de l'élément qui VOYAGE (en-tête pour un projet, la ligne pour une liste) sous le curseur.
    let center = firstFrame.midY + dragOffset.height
    let insert =
      dragIsProject
      ? projectInsert(center: center, others: others, delta: delta, B: g0)
      : listInsert(center: center, others: others)
    return DragPlan(
      others: others, insert: min(insert, others.count), groupStart: g0,
      unit: unit, delta: delta, firstFrame: firstFrame)
  }

  /// Insertion d'une LISTE : TOUJOURS dans la section-listes d'un projet (jamais au-dessus du
  /// premier projet ni dans un inter-projet). On trouve d'abord le projet cible par sa bande
  /// verticale (de son en-tête jusqu'à l'en-tête suivant), puis la place parmi SES listes.
  private func listInsert(center: CGFloat, others: [RowKey]) -> Int {
    // Projet cible = dernier dont l'en-tête est au-dessus du curseur ; au-dessus de tous → le premier.
    var start: Int?
    for (i, k) in others.enumerated() {
      guard case .project(let pid) = k, let hf = rowFrames[.project(pid)] else { continue }
      if center >= hf.minY {
        start = i
      } else {
        break
      }
    }
    let target =
      start ?? others.firstIndex { if case .project = $0 { return true } else { return false } }
    guard let head = target else { return others.count }  // aucun projet : rien à insérer
    // Dans le projet cible : avant la première liste dont le centre passe sous le curseur, sinon en
    // fin de section (avant la rangée « + » ou le projet suivant).
    var insert = head + 1
    var i = head + 1
    while i < others.count {
      switch others[i] {
      case .list(let lid):
        if let lf = rowFrames[.list(lid)], center < lf.midY { return insert }
        insert = i + 1
      case .addList, .project:
        return insert
      }
      i += 1
    }
    return insert
  }

  /// Insertion d'un PROJET, dans l'espace REPLIÉ. On compare le centre de l'EN-TÊTE tiré au centre de
  /// chaque autre bloc-projet ; les blocs SOUS le bloc tiré (index `s >= B` dans `others`) sont
  /// d'abord remontés de `delta` (le bloc s'est replié). L'insertion se cale au DÉBUT d'un bloc.
  private func projectInsert(center: CGFloat, others: [RowKey], delta: CGFloat, B: Int) -> Int {
    var starts: [Int] = []
    for (i, k) in others.enumerated() { if case .project = k { starts.append(i) } }
    for (n, s) in starts.enumerated() {
      let end = n + 1 < starts.count ? starts[n + 1] : others.count
      guard let r = rect(of: Array(others[s..<end])) else { continue }
      let blockCenter = r.midY - (s >= B ? delta : 0)
      if center < blockCenter { return s }
    }
    return others.count
  }

  /// Décalage vertical d'une ligne restante. Deux termes cumulés (branche en-tête de TaskListView) :
  /// les lignes SOUS le bloc tiré remontent d'abord de `delta` (repli) ; puis celles entre l'ancienne
  /// et la nouvelle place glissent de ±`unit` pour ouvrir le trou.
  private func rowShift(_ key: RowKey, plan: DragPlan) -> CGFloat {
    guard let j = plan.others.firstIndex(of: key) else { return 0 }
    let (insert, B, unit, delta) = (plan.insert, plan.groupStart, plan.unit, plan.delta)
    let fold: CGFloat = j >= B ? -delta : 0
    let gap: CGFloat =
      (insert < B && (insert..<B).contains(j))
      ? unit
      : (insert > B && (B..<insert).contains(j)) ? -unit : 0
    return fold + gap
  }

  private func offset(for key: RowKey, plan: DragPlan?) -> CGSize {
    if draggedKeys.contains(key) { return dragOffset }  // le groupe tiré suit le curseur
    guard let plan else { return .zero }
    return CGSize(width: 0, height: rowShift(key, plan: plan))
  }

  /// Rectangle du trou d'insertion (le placeholder), dans l'espace de la sidebar. Présent DÈS
  /// l'empoignade, à l'emplacement d'origine (comme dans TaskListView) : la ligne s'en détache en
  /// suivant le curseur, le trou reste visible et se déplace au fil du drag.
  private func placeholderRect(plan: DragPlan) -> CGRect? {
    let insert = plan.insert
    let (B, unit, delta) = (plan.groupStart, plan.unit, plan.delta)
    let gapTop: CGFloat
    if insert == 0 {
      // Haut de la zone = min sur TOUTES les lignes, tirée incluse (sinon, pour le PREMIER projet à
      // sa place d'origine, on pointerait le 2e projet au lieu de sa propre place tout en haut).
      let othersMin = plan.others.compactMap { rowFrames[$0]?.minY }.min() ?? plan.firstFrame.minY
      gapTop = min(othersMin, plan.firstFrame.minY)
    } else {
      guard let f = rowFrames[plan.others[insert - 1]] else { return nil }
      let j = insert - 1
      let fold: CGFloat = j >= B ? -delta : 0
      let gap: CGFloat = (insert > B && (B..<insert).contains(j)) ? -unit : 0
      gapTop = f.minY + fold + gap + f.height
    }
    return CGRect(x: plan.firstFrame.minX, y: gapTop, width: plan.firstFrame.width, height: unit)
  }

  /// Écrit l'ordre atteint (et le nouveau parent d'une liste) puis désarme le drag, le tout dans UNE
  /// transaction animée. Comme `sortedProjects` / `orderedTasks` re-trient en mémoire (synchrone),
  /// le réordonnancement et la retombée des offsets se produisent dans le même pas : les lignes sont
  /// déjà à leur cible, la bascule ordre↔offset ne saute pas (même mécanique que TaskListView).
  private func commitDrag() {
    let plan = dragPlan()
    let movedID = dragID
    let isProject = dragIsProject
    withAnimation(.snappy(duration: 0.22)) {
      if let plan, let movedID {
        if isProject {
          commitProjectMove(movedID, plan: plan)
        } else {
          commitListMove(movedID, plan: plan)
        }
      }
      dragID = nil
      dragOffset = .zero
      draggedKeys = []
    }
    try? modelContext.save()
  }

  private func commitProjectMove(_ id: PersistentIdentifier, plan: DragPlan) {
    guard let moved = project(id) else { return }
    var order = sortedProjects.filter { $0.persistentModelID != id }
    // `insert` pointe le début d'un bloc-projet : le nombre de projets AVANT lui dans `others` est
    // la position cible parmi les projets restants.
    let before = plan.others[0..<plan.insert].reduce(into: 0) { n, k in
      if case .project = k { n += 1 }
    }
    order.insert(moved, at: min(before, order.count))
    for (i, p) in order.enumerated() { p.sortIndex = i }
  }

  private func commitListMove(_ id: PersistentIdentifier, plan: DragPlan) {
    guard let moved = list(id) else { return }
    // Parent cible = dernier projet rencontré au-dessus du point d'insertion ; index = nombre de
    // listes comptées depuis ce projet (remis à zéro à chaque nouveau projet). Sans projet au-dessus
    // (insertion tout en haut), on rattache au premier projet.
    var targetID: PersistentIdentifier?
    var index = 0
    for k in plan.others[0..<plan.insert] {
      switch k {
      case .project(let pid):
        targetID = pid
        index = 0
      case .list: index += 1
      case .addList: break
      }
    }
    guard let target = targetID.flatMap({ project($0) }) ?? projects.first else { return }
    moved.project = target
    var lists = target.orderedLists.filter { $0.persistentModelID != id }
    lists.insert(moved, at: min(index, lists.count))
    for (i, l) in lists.enumerated() { l.sortIndex = i }
    collapsedProjects.remove(target.persistentModelID)  // déplie le projet cible pour révéler le drop
  }
}
