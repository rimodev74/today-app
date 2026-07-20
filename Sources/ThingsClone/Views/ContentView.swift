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
  @Query private var tasks: [TaskItem]

  @State private var selection: SidebarSelection? = .smartList(.all)
  @State private var searchPresented = false
  /// Liste dont le TITRE (gros en-tête de la page) doit passer en édition : posée par la sidebar à
  /// la création d'une liste, consommée par sa page. On édite le nom DANS la page (pas la sidebar)
  /// pour que l'enchaînement « valider le nom → saisir la 1re tâche » reste intra-vue : un seul
  /// `@FocusState` arbitre alors le premier répondeur, sans course avec la key-view chain d'AppKit.
  @State private var pendingTitleFocus: PersistentIdentifier?
  /// Historique de navigation, alimenté à chaque changement de sélection : c'est ce que la
  /// palette « Recherche rapide » montre quand le champ est vide (façon Things).
  @State private var recents: [SidebarSelection] = []

  var body: some View {
    // Layout custom (HStack) MAIS fenêtre à toolbar native → gros rayon système sans inset de sidebar.
    HStack(spacing: 0) {
      SidebarView(
        selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus
      )
      .frame(width: 260)
      .background { Rectangle().fill(sidebarBackground).ignoresSafeArea() }

      Divider().ignoresSafeArea()

      TaskListView(
        selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { Rectangle().fill(pageBackground).ignoresSafeArea() }
    }
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

  /// Recopie la complétion des rappels liés sur leurs tâches (Rappels → app). L'inverse (app →
  /// Rappels) n'est pas branché ici, donc pas de boucle : on ne réécrit que `isCompleted`.
  private func syncCompletionsFromReminders() {
    let linked = tasks.filter { $0.reminderIdentifier != nil }
    guard !linked.isEmpty else { return }
    let states = remindersService.completionStates(for: linked.compactMap(\.reminderIdentifier))
    for task in linked {
      guard let id = task.reminderIdentifier, let done = states[id], task.isCompleted != done
      else { continue }
      task.isCompleted = done
      task.completedAt = done ? Date() : nil
    }
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
        .font(.system(size: 15))
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
        .font(.subheadline)
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
        Image(systemName: "hexagon.fill").font(.system(size: 15)).foregroundStyle(.green)
      }
    default:
      EmptyView()
    }
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.headline)
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
            .font(.system(size: 13, weight: .semibold))
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        hovering ? Color.primary.opacity(0.06) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
