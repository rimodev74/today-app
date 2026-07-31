import AppKit
import EventKit
import SwiftData
import SwiftUI

/// Fonds opaques des deux colonnes. En clair : valeurs Things exactes (#ffffff / #f9f9fa) ;
/// en sombre : couleurs système natives, faute de valeurs de référence fournies.
private let pageBackground = Color(
  nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? .textBackgroundColor
      : NSColor(white: 1, alpha: 1)
  })
private let sidebarBackground = Color(
  nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? .windowBackgroundColor
      : NSColor(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xFA / 255, alpha: 1)
  })

struct ContentView: View {
  @Environment(RemindersService.self) private var remindersService
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.modelContext) private var modelContext

  @State private var selection: SidebarSelection? = .smartList(.today)
  @State private var searchPresented = false
  /// Liste dont le TITRE (gros en-tête de la page) doit passer en édition : posée par la sidebar à
  /// la création d'une liste, consommée par sa page. On édite le nom DANS la page (pas la sidebar)
  /// pour que l'enchaînement « valider le nom → saisir la 1re tâche » reste intra-vue : un seul
  /// `@FocusState` arbitre alors le premier répondeur, sans course avec la key-view chain d'AppKit.
  @State private var pendingTitleFocus: PersistentIdentifier?
  /// Historique de navigation, alimenté à chaque changement de sélection : c'est ce que la
  /// palette « Recherche rapide » montre quand le champ est vide (façon Things).
  @State private var recents: [SidebarSelection] = []
  @State private var sidebarVisible = true
  /// Largeur persistée entre les lancements (comme un NSSplitView autosauvegardé). Pas
  /// `@AppStorage` : il écrirait dans UserDefaults à chaque frame du drag ; on n'enregistre
  /// qu'au relâchement.
  @State private var sidebarWidth: Double =
    UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 260
  /// Largeur au début du drag : la translation d'un `DragGesture` est cumulée, pas incrémentale.
  @State private var dragStartWidth: Double?
  /// Largeur LIBRE pendant le drag, non bornée en bas : la sidebar suit le curseur jusqu'au bord
  /// de la fenêtre. Rien n'est validé tant qu'elle vaut autre chose que nil ; c'est le
  /// relâchement qui tranche entre replier et ouvrir. Sans cette valeur séparée, la sidebar
  /// butait sur son minimum pendant que le curseur continuait.
  @State private var dragWidth: Double?
  @State private var grabberHovered = false
  /// Survol de la sidebar elle-même. État SÉPARÉ de `grabberHovered` (et pas le même drapeau posé
  /// des deux côtés) : les deux zones se touchent, et rien ne garantit que SwiftUI livre la sortie
  /// de l'une avant l'entrée dans l'autre — un seul drapeau clignoterait au passage de la frontière.
  @State private var sidebarHovered = false

  /// Le mors se montre dès que la souris est quelque part sur la sidebar OU sur la bande qui la
  /// longe : on ne le cherche pas, il est déjà là quand on arrive au bord.
  private var grabberVisible: Bool { grabberHovered || sidebarHovered }

  /// Ce que le layout affiche vraiment : le drag en cours s'il y en a un, sinon l'état validé.
  private var effectiveWidth: Double {
    dragWidth ?? (sidebarVisible ? sidebarWidth : 0)
  }

  var body: some View {
    // Layout custom (HStack) MAIS fenêtre à toolbar native → gros rayon système sans inset de sidebar.
    HStack(spacing: 0) {
      // Montée en permanence, largeur pilotée (0 = repliée) : c'est ce qui permet de la tirer
      // depuis le bord pour la rouvrir, et de l'animer en glissement plutôt qu'en apparition.
      SidebarView(
        selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus
      )
      // Deux cadres : le contenu est TOUJOURS mis en page à `minSidebarWidth` au minimum, le
      // cadre extérieur (la vraie largeur) le rogne par la droite. Au-dessus du minimum la mise
      // en page suit la largeur et les titres se coupent en « … » ; en dessous elle est figée et
      // seul le rognage progresse — la sidebar ne se réorganise jamais pendant le drag.
      .frame(width: max(effectiveWidth, Self.minSidebarWidth), alignment: .leading)
      .frame(width: effectiveWidth, alignment: .leading)
      .clipped()
      // En sombre, les fonds opaques natifs des deux colonnes sont la MÊME valeur (#1E1E1E pour
      // window/text/controlBackgroundColor) : les colonnes se confondaient, seul le séparateur les
      // distinguait. Le matériau `.bar` rend l'étagement vibrant d'une sidebar native (Finder,
      // Réglages) sans inventer de teinte. En clair on garde la valeur Things exacte.
      .background {
        Rectangle()
          .fill(colorScheme == .dark ? AnyShapeStyle(.bar) : AnyShapeStyle(sidebarBackground))
          .ignoresSafeArea()
      }
      // Survoler la sidebar suffit à faire apparaître son mors, sans aller le chercher au bord.
      .onHover { sidebarHovered = $0 }

      if effectiveWidth > 0 {
        Divider().ignoresSafeArea()
      }

      TaskListView(
        selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Matériau plus épais que celui de la sidebar : les deux colonnes gardent des tons distincts
      // (une même vibrance des deux côtés les refondrait en une seule surface, cf. le cas des fonds
      // opaques ci-dessus), tout en partageant la teinte que le matériau prélève sur le bureau.
      // ponytail: façon Réglages Système (fenêtre entièrement en matériau) plutôt que Finder/Mail,
      // qui gardent une zone de contenu OPAQUE — c'est un choix d'app, pas le défaut d'AppKit.
      .background {
        Rectangle()
          .fill(
            colorScheme == .dark ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(pageBackground)
          )
          .ignoresSafeArea()
      }
    }
    // Poignée : clic = replier/déplier, glisser = redimensionner. En overlay (pas dans le HStack)
    // pour rester visible sidebar repliée, où il n'y a plus de séparateur auquel s'accrocher.
    // Pas `HSplitView`, qui donnerait le redimensionnement gratuitement mais remplace le layout
    // par un NSSplitView : exit le repli animé et le fond pleine hauteur des colonnes.
    .overlay(alignment: .leading) { grabber }
    // La palette flotte AU-DESSUS de toute la fenêtre (centrée en haut), elle n'est pas
    // ancrée au bouton : c'est le comportement Spotlight demandé.
    .overlay {
      if searchPresented {
        QuickFindPanel(
          recents: recents,
          current: selection,
          onSelect: {
            selection = $0
            searchPresented = false
          },
          onDismiss: { searchPresented = false }
        )
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.12), value: searchPresented)
    .animation(.easeOut(duration: 0.2), value: sidebarVisible)
    // Cmd+B au niveau fenêtre (même astuce que le bouton Échap de la palette). Le menu Format
    // possède déjà Cmd+B (Gras) : NSMenu.performKeyEquivalent ignore les items désactivés, donc
    // le raccourci ne bascule la sidebar que HORS édition d'une note — dans l'éditeur, Gras gagne.
    .background {
      Button("", action: { sidebarVisible.toggle() })
        .keyboardShortcut("b", modifiers: .command)
        .hidden()
    }
    .onChange(of: selection) { _, new in recordRecent(new) }
    // Retour de complétion Rappels → app : EventKit prévient de tout changement du store ;
    // le retour au premier plan couvre le rappel coché pendant que l'app était en arrière-plan.
    .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
      syncCompletionsFromReminders()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in syncCompletionsFromReminders()
    }
    // Une vraie toolbar (transparente) : c'est elle qui donne le gros rayon « moderne ».
    // L'item doit exister pour que macOS attache un NSToolbar réel, mais ce n'est PAS un
    // bouton (macOS applique un fond "glass" à tout contrôle bouton dans la toolbar) :
    // une vue neutre suffit à garder le rayon sans afficher de chrome.
    .toolbar {
      // Sidebar repliée → plus aucun moyen de changer de destination à la souris : on remonte
      // la sidebar dans la barre de titre, sous forme de sélecteur.
      // macOS 26 pose un fond « glass » partagé sur le conteneur de l'item lui-même (pas sur le
      // contrôle) : sans cet opt-out, la pilule apparaît DANS une seconde capsule système.
      // Rien à faire avant macOS 26, qui n'a pas ce fond.
      if !sidebarVisible {
        if #available(macOS 26, *) {
          ToolbarItem(placement: .principal) { SidebarMenu(selection: $selection) }
            .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .principal) { SidebarMenu(selection: $selection) }
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Color.clear
          .frame(width: 0, height: 0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .toolbarBackground(.hidden, for: .windowToolbar)
    .background(WindowConfigurator())
  }

  /// Curseur cohérent avec ce que le geste permet réellement (comme un NSSplitView) : main quand
  /// seul le clic agit, flèche vers la gauche seule en butée de largeur max.
  private var grabberCursor: NSCursor {
    if effectiveWidth <= 0 { return .resizeRight }
    return effectiveWidth >= Self.maxSidebarWidth ? .resizeLeft : .resizeLeftRight
  }

  /// En dessous de `minSidebarWidth` la sidebar tasse son contenu au lieu de rétrécir ; tirer
  /// plus loin que `collapseSidebarWidth` la replie, comme un NSSplitView tiré au-delà du minimum.
  private static let minSidebarWidth = 200.0
  private static let maxSidebarWidth = 420.0
  private static let collapseSidebarWidth = 150.0
  /// Largeur de la bande qui révèle le mors au survol, mesurée depuis le bord de la sidebar.
  private static let grabberHoverWidth = 40.0

  /// Le mors : une pilule verticale posée sur le bord de la sidebar, à mi-hauteur. Invisible au
  /// repos — il n'apparaît qu'au survol de la bande qui longe ce bord, sidebar ouverte comme
  /// repliée, plutôt que de traîner en permanence sur une fenêtre au repos.
  private var grabber: some View {
    Capsule()
      .fill(Color.secondary.opacity(0.55))
      .frame(width: 8, height: 40)
      .opacity(grabberVisible ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: grabberVisible)
      // Cible de clic élargie autour d'un visuel volontairement fin. Asymétrique : la bande démarre
      // 1 pt DANS la sidebar (cf. l'offset, plus bas), ce pt est repris ici pour que la pilule reste
      // posée au même endroit qu'avant, juste à droite du séparateur.
      .padding(.leading, 11)
      .padding(.trailing, 7)
      .contentShape(Rectangle())
      // Un seul geste pour les deux actions : `DragGesture(minimumDistance: 0)` avale de toute
      // façon le clic, donc c'est lui qui l'interprète — déplacement nul au relâchement = clic.
      // `.global` OBLIGATOIRE : en coordonnées locales, la translation serait mesurée contre une
      // poignée que le drag déplace lui-même → valeur rétroalimentée, sidebar qui tremble.
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { value in
            let base = dragStartWidth ?? effectiveWidth
            dragStartWidth = base
            // Aucune borne basse ici : sous le minimum la sidebar continue de suivre le curseur
            // jusqu'au bord de la fenêtre. Rien n'est décidé tant que le bouton est enfoncé.
            dragWidth = min(Self.maxSidebarWidth, max(0, base + value.translation.width))
          }
          .onEnded { value in
            let dropped = dragWidth ?? effectiveWidth
            dragStartWidth = nil
            withAnimation(.easeOut(duration: 0.2)) {
              if abs(value.translation.width) < 3 {
                // Déplacement nul : c'était un clic.
                sidebarVisible.toggle()
              } else if dropped < Self.collapseSidebarWidth {
                // Lâchée sous le seuil : elle se replie, y compris si elle était fermée au départ
                // et qu'on n'a pas tiré assez loin. La largeur validée reste intacte pour la
                // prochaine ouverture.
                sidebarVisible = false
              } else {
                sidebarVisible = true
                sidebarWidth = max(Self.minSidebarWidth, dropped)
                UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth")
              }
              dragWidth = nil
            }
          }
      )
      .help(sidebarVisible ? "Masquer la barre latérale (⌘B)" : "Afficher la barre latérale (⌘B)")
      // Bande de survol : 40 pt de large depuis le bord de la sidebar, sur TOUTE la hauteur — c'est
      // elle qui révèle le mors, où qu'on approche du bord. Elle tient dans la marge de la page
      // (`gutter` = 75) : aucune ligne ne commence là, elle ne peut voler aucun clic. Le geste, lui,
      // reste sur le mors seul — une bande cliquable sur toute la hauteur replierait la sidebar au
      // moindre clic tombé loin de la poignée.
      .frame(width: Self.grabberHoverWidth, alignment: .leading)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onHover {
        grabberHovered = $0
        // `.set()` plutôt que push/pop : la pile de curseurs se déséquilibre dès qu'un survol se
        // termine pendant un drag, et le curseur reste bloqué en flèche.
        $0 ? grabberCursor.set() : NSCursor.arrow.set()
      }
      // La bande démarre 1 pt DANS la sidebar, pas après : au pixel près, deux zones seulement
      // adjacentes laissent un liseré que ni l'une ni l'autre ne revendique, et la pilule y
      // clignotait. Ce chevauchement les soude — les deux survols sont vrais en même temps, et
      // `grabberVisible` est un OU. Sidebar repliée, la bande se colle au bord gauche de la fenêtre.
      .offset(x: effectiveWidth - 1)
  }

  /// Recopie la complétion des rappels liés sur leurs tâches (Rappels → app). L'inverse (app →
  /// Rappels) n'est pas branché ici, donc pas de boucle : on ne réécrit que `isCompleted`.
  ///
  /// Fetch à la demande et PAS un `@Query` : posé sur cette vue racine, il ferait dépendre TOUT
  /// l'arbre (sidebar comprise) de la moindre mutation d'une tâche — une frappe dans un titre
  /// réinvalidait la fenêtre entière. Les tâches liées se relisent deux fois par notification,
  /// c'est le seul endroit qui en a besoin.
  private func syncCompletionsFromReminders() {
    let descriptor = FetchDescriptor<TaskItem>(
      predicate: #Predicate { $0.reminderIdentifier != nil })
    guard let linked = try? modelContext.fetch(descriptor), !linked.isEmpty else { return }
    let states = remindersService.completionStates(for: linked.compactMap(\.reminderIdentifier))
    var changed = false
    for task in linked {
      guard let id = task.reminderIdentifier, let done = states[id], task.isCompleted != done
      else { continue }
      task.isCompleted = done
      task.completedAt = done ? Date() : nil
      changed = true
    }
    if changed { try? modelContext.save() }
  }

  /// Seules les listes et projets sont des destinations « récentes » ; les vues intelligentes
  /// restent toujours visibles dans la sidebar, inutile de les rappeler ici.
  private func recordRecent(_ selection: SidebarSelection?) {
    guard let selection else { return }
    switch selection {
    case .list, .project:
      recents.removeAll { $0 == selection }
      recents.insert(selection, at: 0)
      if recents.count > 7 { recents.removeLast(recents.count - 7) }
    default:
      break
    }
  }
}

/// La sidebar réduite à une pilule de barre de titre. Pas un `Menu` natif : les lignes veulent
/// les icônes de la sidebar (anneau de progression, pastilles colorées, compteur) qu'un menu
/// AppKit ne sait pas rendre. C'est donc un popover qui réutilise les lignes de la palette.
private struct SidebarMenu: View {
  @Binding var selection: SidebarSelection?

  @Query(sort: [SortDescriptor(\Project.sortIndex), SortDescriptor(\Project.createdAt)])
  private var projects: [Project]
  @Query private var allTasks: [TaskItem]

  @State private var presented = false
  @State private var query = ""
  @FocusState private var focused: Bool

  private var needle: String { query.trimmingCharacters(in: .whitespaces) }

  var body: some View {
    Button {
      presented = true
    } label: {
      HStack(spacing: 7) {
        Text(currentTitle)
        Image(systemName: "chevron.up.chevron.down")
          .font(.app(10, weight: .semibold))
      }
      .foregroundStyle(.secondary)
      .padding(.vertical, 3)
      .padding(.horizontal, 20)
      .contentShape(Capsule())
      .overlay { Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .fixedSize()
    .popover(isPresented: $presented, arrowEdge: .bottom) { panel }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      searchField
      ScrollView {
        VStack(spacing: 1) {
          if needle.isEmpty { groupedRows } else { filteredRows }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .frame(maxHeight: 420)
    }
    .frame(width: 320)
    // Le champ ne prend le focus qu'à l'ouverture du popover ; `query` est remis à zéro à la
    // fermeture pour rouvrir sur la liste complète.
    .onAppear { focused = true }
    .onDisappear { query = "" }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Recherche rapide", text: $query)
        .textFieldStyle(.plain)
        .focused($focused)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .padding(10)
  }

  /// Ordre de la sidebar : vues intelligentes, Pomodoro, puis chaque projet suivi de ses listes.
  @ViewBuilder private var groupedRows: some View {
    ForEach(SmartList.allCases, id: \.self) { smartRow($0) }
    separator
    row(.pomodoro, title: "Pomodoro") {
      Image(systemName: "timer").foregroundStyle(.red)
    }
    ForEach(projects) { project in
      separator
      projectRow(project)
      ForEach(project.orderedLists) { listRow($0) }
    }
  }

  @ViewBuilder private var filteredRows: some View {
    let smart = SmartList.allCases.filter { $0.label.localizedCaseInsensitiveContains(needle) }
    let matchedProjects = projects.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    let matchedLists = projects.flatMap(\.orderedLists).filter {
      $0.title.localizedCaseInsensitiveContains(needle)
    }
    if smart.isEmpty && matchedProjects.isEmpty && matchedLists.isEmpty {
      Text("Aucun résultat")
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    } else {
      ForEach(smart, id: \.self) { smartRow($0) }
      ForEach(matchedProjects) { projectRow($0) }
      ForEach(matchedLists) { listRow($0) }
    }
  }

  private var separator: some View { Divider().padding(.vertical, 4) }

  private func smartRow(_ smart: SmartList) -> some View {
    // Compteur seulement sur « Aujourd'hui », même règle que la sidebar.
    let count = smart == .today ? smart.filter(allTasks).count : 0
    return row(.smartList(smart), title: smart.label, badge: count > 0 ? "\(count)" : nil) {
      Image(systemName: smart.systemImage).foregroundStyle(smart.color)
    }
  }

  private func projectRow(_ project: Project) -> some View {
    row(.project(project), title: title(project.title), bold: true) {
      Image(systemName: "hexagon.fill").font(.app(15)).foregroundStyle(.green)
    }
  }

  private func listRow(_ list: TodoList) -> some View {
    row(.list(list), title: title(list.title)) {
      ProgressRing(progress: list.progress, size: 16)
    }
  }

  private func row<Icon: View>(
    _ destination: SidebarSelection, title: String, badge: String? = nil, bold: Bool = false,
    @ViewBuilder icon: @escaping () -> Icon
  ) -> some View {
    QuickFindRow(
      title: title, subtitle: badge, bold: bold, isCurrent: selection == destination,
      action: {
        selection = destination
        presented = false
      },
      icon: icon
    )
  }

  private func title(_ raw: String) -> String { raw.isEmpty ? "Sans titre" : raw }

  private var currentTitle: String {
    switch selection {
    case .smartList(let smart): return smart.label
    case .project(let project): return title(project.title)
    case .list(let list): return title(list.title)
    case .pomodoro: return "Pomodoro"
    case nil: return "Aller à"
    }
  }
}

/// Palette « Recherche rapide » : une carte flottante, façon Spotlight. Champ vide → historique
/// (« Récents ») avec une coche sur la destination courante ; en tapant → résultats groupés
/// (projets, listes, tâches). Un clic navigue et referme.
/// ponytail: filtrage en mémoire, par titre seulement (pas les notes) — passer en #Predicate et
/// étendre aux notes si le volume ou le besoin l'exigent.
private struct QuickFindPanel: View {
  var recents: [SidebarSelection]
  var current: SidebarSelection?
  var onSelect: (SidebarSelection) -> Void
  var onDismiss: () -> Void

  @Query private var tasks: [TaskItem]
  @Query private var lists: [TodoList]
  @Query private var projects: [Project]

  @State private var query = ""
  @FocusState private var focused: Bool

  private var needle: String { query.trimmingCharacters(in: .whitespaces) }

  var body: some View {
    ZStack(alignment: .top) {
      // Couche de rejet : un clic hors de la carte referme.
      Color.black.opacity(0.06)
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)

      card.padding(.top, 70)
    }
    // Échap ferme même quand le focus est dans le champ : un bouton .cancelAction agit au
    // niveau fenêtre, sans dépendre du premier répondeur (cf. même astuce dans ListPageView).
    .background {
      Button("", action: onDismiss).keyboardShortcut(.cancelAction).hidden()
    }
  }

  private var card: some View {
    VStack(spacing: 0) {
      searchField
      content
    }
    .frame(width: 520)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Recherche rapide", text: $query)
        .textFieldStyle(.plain)
        .font(.app(15))
        .focused($focused)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .padding(14)
    .onAppear { focused = true }
  }

  @ViewBuilder
  private var content: some View {
    if needle.isEmpty {
      recentsContent
    } else {
      resultsContent
    }
  }

  // MARK: État vide — Récents

  /// Les récents filtrés du vivant (une liste/un projet supprimé depuis ne doit pas être rendu :
  /// lire une propriété d'un `@Model` effacé peut planter). Rien de récent → on propose toutes
  /// les listes puis projets pour ne pas afficher une carte vide.
  private var recentItems: [SidebarSelection] {
    let live = recents.filter { sel in
      switch sel {
      case .list(let list): return lists.contains { $0 == list }
      case .project(let project): return projects.contains { $0 == project }
      default: return false
      }
    }
    if !live.isEmpty { return live }
    return lists.map { .list($0) } + projects.map { .project($0) }
  }

  private var recentsContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader("Récents")
      Divider().padding(.horizontal, 14)

      ScrollView {
        VStack(spacing: 1) {
          ForEach(Array(recentItems.enumerated()), id: \.offset) { _, sel in
            row(for: sel)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
      }
      .frame(maxHeight: 300)

      Divider()
      Text("Changez rapidement de liste,\ntrouvez des tâches, recherchez des mots-clés…")
        .font(.app(.subheadline))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
    }
  }

  // MARK: Résultats de recherche

  private var matchingTasks: [TaskItem] {
    // Sans liste rattachée, une tâche n'a pas de page où naviguer : on l'écarte.
    tasks.filter {
      !$0.isHeader && $0.list != nil && $0.title.localizedCaseInsensitiveContains(needle)
    }
  }
  private var matchingLists: [TodoList] {
    lists.filter { $0.title.localizedCaseInsensitiveContains(needle) }
  }
  private var matchingProjects: [Project] {
    projects.filter { $0.title.localizedCaseInsensitiveContains(needle) }
  }

  @ViewBuilder
  private var resultsContent: some View {
    if matchingTasks.isEmpty && matchingLists.isEmpty && matchingProjects.isEmpty {
      Text("Aucun résultat")
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          if !matchingProjects.isEmpty {
            sectionHeader("Projets")
            ForEach(matchingProjects) { row(for: .project($0)) }
          }
          if !matchingLists.isEmpty {
            sectionHeader("Listes")
            ForEach(matchingLists) { row(for: .list($0)) }
          }
          if !matchingTasks.isEmpty {
            sectionHeader("Tâches")
            ForEach(matchingTasks) { task in
              QuickFindRow(
                title: task.title,
                subtitle: task.list?.title,
                action: { if let list = task.list { onSelect(.list(list)) } }
              ) {
                Image(systemName: "circle").foregroundStyle(.secondary)
              }
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
      }
      .frame(maxHeight: 360)
    }
  }

  // MARK: Lignes

  /// Ligne pour une destination (liste ou projet), avec son icône façon sidebar et la coche
  /// bleue si c'est la destination courante.
  @ViewBuilder
  private func row(for selection: SidebarSelection) -> some View {
    switch selection {
    case .list(let list):
      QuickFindRow(
        title: list.title,
        isCurrent: current == selection,
        action: { onSelect(selection) }
      ) {
        ProgressRing(progress: list.progress, size: 16)
      }
    case .project(let project):
      QuickFindRow(
        title: project.title,
        bold: true,
        isCurrent: current == selection,
        action: { onSelect(selection) }
      ) {
        Image(systemName: "hexagon.fill").font(.app(15)).foregroundStyle(.green)
      }
    default:
      EmptyView()
    }
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.app(.headline))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.top, 8)
      .padding(.bottom, 4)
  }
}

/// Une ligne de la palette : icône + titre, sous-titre gris optionnel, coche si courant, et un
/// léger fond au survol (comme un menu). Le survol vit dans la ligne pour ne pas remonter d'état.
private struct QuickFindRow<Icon: View>: View {
  let title: String
  var subtitle: String? = nil
  var bold: Bool = false
  var isCurrent: Bool = false
  let action: () -> Void
  @ViewBuilder let icon: () -> Icon

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        icon().frame(width: 18, height: 18)
        Text(title.isEmpty ? "Sans titre" : title)
          .fontWeight(bold ? .semibold : .regular)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle).foregroundStyle(.tertiary).lineLimit(1)
        }
        if isCurrent {
          Image(systemName: "checkmark")
            .foregroundStyle(Color.accentColor)
            .font(.app(13, weight: .semibold))
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        hovering
          ? Color.primary.opacity(0.06) : (isCurrent ? Color.accentColor.opacity(0.18) : .clear),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
