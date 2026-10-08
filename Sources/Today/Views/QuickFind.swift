// La recherche rapide (palette ⌘K) et la sidebar réduite en pilule de barre de titre, sorties de
// `ContentView` : deux vues autonomes qui partagent leurs lignes (`QuickFindRow`), sans rien de la
// fenêtre qui les héberge.

import SwiftData
import SwiftUI

/// La sidebar réduite à une pilule de barre de titre. Pas un `Menu` natif : les lignes veulent
/// les icônes de la sidebar (anneau de progression, pastilles colorées, compteur) qu'un menu
/// AppKit ne sait pas rendre. C'est donc un popover qui réutilise les lignes de la palette.
struct SidebarMenu: View {
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
    // Les anneaux des rangées, calculés en UNE passe puis distribués — jamais `list.progress()`
    // par rangée, qui retraverse les tâches de sa liste à chaque rendu (cf. `SidebarCounts`).
    let counts = SidebarCounts(tasks: allTasks)
    return VStack(spacing: 0) {
      searchField
      ScrollView {
        VStack(spacing: 1) {
          if needle.isEmpty { groupedRows(counts) } else { filteredRows(counts) }
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
  @ViewBuilder private func groupedRows(_ counts: SidebarCounts) -> some View {
    ForEach(SmartList.allCases, id: \.self) { smartRow($0) }
    separator
    row(.pomodoro, title: "Pomodoro") {
      Image(systemName: "timer").foregroundStyle(.red)
    }
    ForEach(projects) { project in
      separator
      projectRow(project)
      ForEach(project.activeLists) { listRow($0, counts) }
    }
  }

  @ViewBuilder private func filteredRows(_ counts: SidebarCounts) -> some View {
    let smart = SmartList.allCases.filter { $0.label.localizedCaseInsensitiveContains(needle) }
    let matchedProjects = projects.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    let matchedLists = projects.flatMap(\.activeLists).filter {
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
      ForEach(matchedLists) { listRow($0, counts) }
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
      Image(systemName: "folder.fill").font(.app(15))
        .foregroundStyle(project.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
    }
  }

  private func listRow(_ list: TodoList, _ counts: SidebarCounts) -> some View {
    row(.list(list), title: title(list.title)) {
      ProgressRing(progress: counts[list].progress, size: 16)
        .tint(list.project?.color?.color)
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
struct QuickFindPanel: View {
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
    // Une passe pour tous les anneaux, distribuée aux rangées (cf. `SidebarCounts`) : `row(for:)`
    // lisait `list.progress()`, donc retraversait les tâches de chaque liste affichée, à chaque
    // rendu — et champ vide, la palette les montre TOUTES.
    let counts = SidebarCounts(tasks: tasks)
    return VStack(spacing: 0) {
      searchField
      content(counts)
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
  private func content(_ counts: SidebarCounts) -> some View {
    if needle.isEmpty {
      recentsContent(counts)
    } else {
      resultsContent(counts)
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

  private func recentsContent(_ counts: SidebarCounts) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader("Récents")
      Divider().padding(.horizontal, 14)

      ScrollView {
        VStack(spacing: 1) {
          ForEach(Array(recentItems.enumerated()), id: \.offset) { _, sel in
            row(for: sel, counts)
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
  private func resultsContent(_ counts: SidebarCounts) -> some View {
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
            ForEach(matchingProjects) { row(for: .project($0), counts) }
          }
          if !matchingLists.isEmpty {
            sectionHeader("Listes")
            ForEach(matchingLists) { row(for: .list($0), counts) }
          }
          if !matchingTasks.isEmpty {
            sectionHeader("Tâches")
            ForEach(matchingTasks) { task in
              QuickFindRow(
                title: task.title,
                subtitle: task.list?.title,
                action: { if let list = task.list { onSelect(.list(list)) } }
              ) {
                // Cochée = la case l'est aussi (même règle que `QuickPalette.taskRow`).
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(.secondary)
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
  private func row(for selection: SidebarSelection, _ counts: SidebarCounts) -> some View {
    switch selection {
    case .list(let list):
      QuickFindRow(
        title: list.title,
        isCurrent: current == selection,
        action: { onSelect(selection) }
      ) {
        ProgressRing(progress: counts[list].progress, size: 16)
          .tint(list.project?.color?.color)
      }
    case .project(let project):
      QuickFindRow(
        title: project.title,
        bold: true,
        isCurrent: current == selection,
        action: { onSelect(selection) }
      ) {
        Image(systemName: "folder.fill").font(.app(15))
          .foregroundStyle(
            project.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
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
struct QuickFindRow<Icon: View>: View {
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
