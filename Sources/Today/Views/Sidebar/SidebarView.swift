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
  // Brouillon du renommage en cours : jamais écrit dans `list.title`/`project.title` avant la
  // SORTIE du champ (cf. `editableTitle`), pour que la page de la liste/du projet — qui lit la
  // même propriété — ne se mette pas à jour frappe par frappe en même temps que la sidebar.
  @State private var draftTitle: String = ""
  // Écriture du brouillon dans le modèle, posée par le champ actif (cf. `editableTitle`).
  // Indispensable pour que N'IMPORTE QUELLE sortie sauvegarde : `editingID = nil` DÉTRUIT le
  // champ, et son `.onChange(of: renameFocused)` — seul point de sauvegarde côté champ — ne
  // s'exécute alors jamais. Un clic sur une autre ligne jetait donc la saisie.
  @State private var applyDraft: (() -> Void)?
  @State private var collapsedProjects: Set<PersistentIdentifier> = []
  @FocusState private var renameFocused: Bool
  // Surveillance des clics pendant un renommage (cf. `clickOutsideMonitor` dans le body).
  @State private var clickMonitor: Any?

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
        .padding(.top, 12)  // dégage les feux tricolores intégrés à la sidebar

      searchButton
        .padding(.horizontal, 10)
        .padding(.top, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          smartListGroup

          Divider()
            .padding(.vertical, 10)
            .padding(.horizontal, 8)

          projectsGroup
        }
        .padding(.horizontal, 10)
        .padding(.top, 24)  // détache la zone de navigation du bloc profil + recherche
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollContentBackground(.hidden)
    }
    .safeAreaInset(edge: .bottom) { bottomBar }
    // Suppression uniquement via le clic droit → « Supprimer » (cf. `contextMenu` de `projectRow`/
    // `listRow`) : pas de raccourci clavier (⌫) sur la sélection de la sidebar.
    // Confirmation seulement si l'élément n'est pas vide ; sinon la suppression est immédiate
    // (cf. `requestDelete`).
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
    .onChange(of: editingID) { _, id in clickOutsideMonitor(active: id != nil) }
    // Le moniteur ne se démonte QUE sur `editingID` : disparaître pendant un renommage (fermeture
    // de la fenêtre, sidebar repliée) le laissait installé pour la vie du process.
    .onDisappear { clickOutsideMonitor(active: false) }
  }

  /// Sortie du renommage au clic AILLEURS dans la fenêtre. Rien ne le provoque tout seul : cliquer
  /// une zone SwiftUI non focusable (liste de tâches, fond de la sidebar) ne fait PAS démissionner
  /// le first responder AppKit — le champ gardait le focus, donc `renameFocused` ne bougeait pas et
  /// l'édition restait ouverte. Un moniteur d'événements local plutôt qu'un tap catcher : il couvre
  /// toute la fenêtre, y compris la zone de contenu, que la sidebar ne peut pas envelopper.
  private func clickOutsideMonitor(active: Bool) {
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    guard active else { return }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
      guard let window = event.window,
        let editor = window.firstResponder as? NSView
      else { return event }
      // Clic DANS le champ (repositionner le curseur, sélectionner un mot) : on ne sort pas.
      // Test sur le CADRE de l'éditeur de champ, pas sur la parenté des vues : SwiftUI rend toute
      // la fenêtre dans une seule NSHostingView, donc `hitTest` renvoie ce même conteneur pour
      // n'importe quel clic — l'éditeur en est toujours un descendant, et le test « clic dedans »
      // était toujours vrai partout dans la sidebar.
      if editor.convert(editor.bounds, to: nil).contains(event.locationInWindow) { return event }
      endRename()
      return event  // le clic poursuit sa route : sélectionner une autre ligne marche toujours
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

  /// Pomodoro fait partie du groupe (il est au-dessus du séparateur) : il doit partager son
  /// espacement, sinon il se détacherait des listes intelligentes dès qu'on le resserre.
  private var smartListGroup: some View {
    VStack(alignment: .leading, spacing: 2) {
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
          .font(.system(size: 14, weight: .medium))
        }
      }
      pomodoroRow
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
      .font(.system(size: 14, weight: .medium))
    }
  }

  // MARK: Projets et to-do lists

  private var projectsGroup: some View {
    let plan = dragPlan()
    return VStack(alignment: .leading, spacing: 6) {
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
          .fill(Self.rowFill)
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
    let row = sidebarRow(
      id: id, isSelected: { selection == .project(project) }, verticalPadding: 5
    ) {
      selection = .project(project)
    } label: {
      HStack(spacing: 6) {
        // Icône « dossier » sur le flanc gauche : à l'œil, un projet (dossier) se distingue
        // d'une liste (anneau de progression) au premier regard.
        Image(systemName: "folder")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(width: 20)

        editableTitle(id: id, text: Bindable(project).title, placeholder: "Nom du projet") {
          if project.title.trimmingCharacters(in: .whitespaces).isEmpty {
            project.title = "Nouveau projet"
          }
        }
        .font(.system(size: 14, weight: .medium))

        // Chevron à DROITE : le flanc gauche porte désormais l'icône. Pas un Button : le
        // `.onTapGesture` du `sidebarRow` (posé sur toute la ligne via contentShape) avale le clic
        // d'un Button imbriqué. Un `highPriorityGesture` passe DEVANT le tap de la ligne — il
        // déroule sans aussi sélectionner le projet.
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(collapsedProjects.contains(id) ? 0 : 90))
          // Cible de clic élargie : la flèche fait 9pt mais sa zone tactile couvre 24×20 (le flanc
          // droit de la rangée), bien plus facile à viser que le glyphe seul. Hauteur 20 (et padding
          // vertical réduit) pour une rangée de projet plus compacte. `alignment: .trailing` cale le
          // glyphe sur le bord DROIT de cette zone (pas son centre) : c'est ce bord qui doit tomber
          // pile sur celui du badge numérique d'une liste (`listRow`), lui sans zone de clic élargie.
          .frame(width: 24, height: 20, alignment: .trailing)
          .contentShape(Rectangle())
          .highPriorityGesture(
            TapGesture().onEnded {
              withAnimation(.snappy(duration: 0.2)) { toggleCollapse(id) }
            }
          )
      }
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
    let row = sidebarRow(id: id, isSelected: { selection == .list(list) }) {
      selection = .list(list)
    } label: {
      HStack(spacing: 8) {
        // Trait seul (pas de camembert plein) : une liste vide reste un anneau GRIS ; le bleu
        // n'apparaît qu'avec la progression, disque plein bleu quand tout est fait.
        ProgressRing(progress: list.progress)
        editableTitle(id: id, text: Bindable(list).title, placeholder: "Nom de la liste") {
          if list.title.trimmingCharacters(in: .whitespaces).isEmpty {
            list.title = "Nouvelle liste"
          }
        }
        .font(.system(size: 14, weight: .medium))
        if list.remainingCount > 0 {
          Text("\(list.remainingCount)")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
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
      .font(.system(size: 13))
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

  /// Fond d'une ligne survolée ou sélectionnée. Teinte FIXE imposée par la maquette (#E5E6E6 /
  /// #3A3C3F) et non `unemphasizedSelectedContentBackgroundColor` : la couleur système suit
  /// l'accent et le focus de la fenêtre, ce qui la faisait varier d'un état à l'autre.
  /// `NSColor` à provider plutôt qu'un `@Environment(\.colorScheme)` : une seule définition,
  /// utilisable aussi depuis le placeholder de drag qui doit être exactement de la même couleur.
  fileprivate static let rowFill = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0x3A / 255, green: 0x3C / 255, blue: 0x3F / 255, alpha: 1)
        : NSColor(srgbRed: 0xE5 / 255, green: 0xE6 / 255, blue: 0xE6 / 255, alpha: 1)
    })

  /// Fond d'une ligne de sidebar : sélection en priorité, sinon un survol léger.
  /// État `@State` propre à cette enveloppe — un survol vit et meurt avec la ligne, il n'y a pas
  /// besoin de le remonter à `SidebarView`.
  private struct HoverBackground<Content: View>: View {
    var isSelected: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
      content()
        .background(
          isSelected || hovering ? SidebarView.rowFill : .clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        // Pas de curseur « main » : ces lignes sont de la navigation, pas des liens — le curseur
        // flèche reste celui du reste de l'app.
        .onHover { hovering = $0 }
    }
  }

  /// Une ligne = fond + padding identiques en tout temps, seul le contenu change.
  /// La ligne ne fait QUE sélectionner ; le renommage est un double-clic porté par le titre
  /// lui-même (cf. `editableTitle`).
  ///
  /// `id` identifie la ligne pour une seule raison, mais elle est essentielle : le 2e clic d'un
  /// double-clic déclenche AUSSI ce tap simple, sans garantie d'ordre vis-à-vis du double. En
  /// fermant l'édition sans condition, il refermait aussitôt celle que le double venait d'ouvrir
  /// (c'est ce qui avait fait abandonner le double-clic). Ne fermer que si l'édition en cours
  /// concerne une AUTRE ligne rend les deux ordres possibles équivalents.
  private func sidebarRow<L: View>(
    id: PersistentIdentifier? = nil,
    isSelected: @escaping () -> Bool,
    verticalPadding: CGFloat = 6,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> L
  ) -> some View {
    HoverBackground(isSelected: isSelected()) {
      label()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
    .onTapGesture {
      if let editingID, editingID != id { endRename() }  // valide le renommage d'une autre ligne
      action()
    }
  }

  /// Titre qui bascule en champ de saisie pendant le renommage, sans changer de gabarit.
  /// Édite un BROUILLON local (`draftTitle`), jamais `text` en direct : la sidebar et la page de
  /// la liste/du projet lisent la même propriété (`list.title`/`project.title`) — la modifier à
  /// chaque frappe la ferait apparaître aussi dans le titre de la page, EN MÊME TEMPS que la
  /// sidebar. `text.wrappedValue` n'est réécrit qu'à la SORTIE du champ (Entrée, Échap, clic
  /// ailleurs) : la page ne se met donc à jour qu'une fois le renommage terminé.
  @ViewBuilder
  private func editableTitle(
    id: PersistentIdentifier,
    text: Binding<String>,
    placeholder: String,
    commit: @escaping () -> Void
  ) -> some View {
    if editingID == id {
      TextField(placeholder, text: $draftTitle)
        .textFieldStyle(.plain)
        .focused($renameFocused)
        // Le focus se pose ICI, quand le champ existe. Le poser depuis startRename()
        // le perdait : SwiftUI ignore un @FocusState visant une vue pas encore montée,
        // et `editingID` restait alors bloqué pour toujours. Posé un tour de runloop après le
        // montage : synchrone, il entrait parfois en concurrence avec le relâchement du focus
        // du conteneur sidebar (cf. `startRename`), encore en cours d'application côté AppKit.
        .onAppear {
          draftTitle = text.wrappedValue
          // `draftTitle` est lu à l'APPEL, pas capturé : @State passe par un stockage externe,
          // la copie de `self` figée dans la closure lit donc bien la saisie courante.
          applyDraft = {
            text.wrappedValue = draftTitle
            commit()
          }
          DispatchQueue.main.async { renameFocused = true }
        }
        .onSubmit { endRename() }
        .onExitCommand { endRename() }
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
            endRename()
          }
        }
    } else {
      Text(text.wrappedValue)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Double-clic sur le TITRE seul — le geste attendu, et nulle part ailleurs sur la rangée
        // (ni le chevron, ni l'icône, ni le badge). Le tap simple de la rangée continue de passer
        // et de sélectionner : c'est `sidebarRow` qui garantit qu'il ne referme pas cette édition.
        .onTapGesture(count: 2) { startRename(id) }
    }
  }

  // MARK: Barre du bas

  private var bottomBar: some View {
    HStack {
      Button(action: addProject) {
        Label("Nouveau projet", systemImage: "plus")
      }
      .buttonStyle(.plain)
      .hoverBordered()
      .padding(.leading, 4)

      Spacer()

      SettingsLink {
        Image(systemName: "slider.horizontal.3")
      }
      .buttonStyle(.plain)
      .hoverBordered()
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }

  /// Bordure discrète au survol, façon bouton « + Nouvelle liste » des réglages.
  fileprivate struct HoverBorder: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
      content
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(hovering ? 0.15 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { inside in hovering = inside }
    }
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
    endRename()  // valide un renommage déjà ouvert ailleurs (clic droit → « Renommer »)
    editingID = id  // le focus suit dans .onAppear du champ
  }

  /// SEULE sortie du renommage : écrit le brouillon puis ferme. Toute fermeture doit passer par
  /// ici — un `editingID = nil` direct détruit le champ avant qu'il n'ait pu sauvegarder.
  private func endRename() {
    applyDraft?()
    applyDraft = nil
    editingID = nil
  }

  private func addProject() {
    let project = Project(title: "Nouveau projet")
    project.sortIndex = (projects.map(\.sortIndex).max() ?? -1) + 1
    modelContext.insertAndSave(project)
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

  // Enregistrement explicite comme partout ailleurs dans l'app : s'en remettre à l'autosave
  // laissait une fenêtre où une suppression en cascade (un projet emporte ses listes, qui
  // emportent leurs tâches) n'était pas encore sur le disque.
  private func delete(_ project: Project) {
    if selection == .project(project) { selection = .smartList(.all) }
    modelContext.delete(project)
    try? modelContext.save()
  }

  private func delete(_ list: TodoList) {
    if selection == .list(list) {
      selection = list.project.map { .project($0) } ?? .smartList(.all)
    }
    modelContext.delete(list)
    try? modelContext.save()
  }

  /// Suppression directe si l'élément est vide (liste sans tâche, projet sans liste), sinon
  /// confirmation via l'alerte. Point de passage commun à ⌫ et au menu contextuel.
  private func requestDelete(_ list: TodoList) {
    if list.tasks.isEmpty { delete(list) } else { deletionCandidate = .list(list) }
  }

  private func requestDelete(_ project: Project) {
    if project.lists.isEmpty { delete(project) } else { deletionCandidate = .project(project) }
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

extension View {
  fileprivate func hoverBordered() -> some View {
    modifier(SidebarView.HoverBorder())
  }
}
