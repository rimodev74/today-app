// La recherche rapide (palette ⌘K) et la sidebar réduite en pilule de barre de titre, sorties de
// `ContentView` : deux vues autonomes, sans rien de la fenêtre qui les héberge.

import SwiftData
import SwiftUI

/// La sidebar réduite à une pilule de barre de titre : elle dit OÙ l'on est, et ouvre la recherche
/// rapide (`QuickFindPanel`, qui montre les récents champ vide) pour aller ailleurs.
///
/// Elle présentait avant un popover avec son propre champ de recherche, monté dans la barre
/// d'outils. Un popover est une FENÊTRE présentée depuis le layout, et y donner le premier
/// répondeur à un `TextField` est la famille de plantages de `PIEGES.md` § Fenêtres. La palette
/// de la fenêtre fait déjà le même travail, DANS la fenêtre.
struct SidebarMenu: View {
  var selection: SidebarSelection?
  var onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
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
  }

  private func title(_ raw: String) -> String { raw.isEmpty ? "Sans titre" : raw }

  private var currentTitle: String {
    switch selection {
    case .smartList(let smart): return smart.label
    case .project(let project): return title(project.title)
    case .list(let list): return title(list.title)
    case .projects: return "Projets"
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
    // Tout ce qui se calcule l'est ICI, UNE fois par rendu, puis distribué : les correspondances
    // étaient des propriétés calculées relues jusqu'à six fois par frappe (chacune refiltre toute
    // la base), et le décompte des anneaux se reconstruisait même quand aucune liste n'était à
    // l'écran.
    let matches = needle.isEmpty ? nil : currentMatches
    // Les anneaux servent aux rangées de LISTE seulement : les récents (champ vide) et les
    // résultats qui en contiennent. Une frappe qui ne ramène que des tâches n'en a pas besoin.
    let needsRings = matches.map { !$0.lists.isEmpty } ?? true
    // Une passe pour tous les anneaux, distribuée aux rangées (cf. `SidebarCounts`) : `row(for:)`
    // lisait `list.progress()`, donc retraversait les tâches de chaque liste affichée, à chaque
    // rendu — et champ vide, la palette les montre TOUTES.
    let counts = SidebarCounts(tasks: needsRings ? tasks : [])
    return VStack(spacing: 0) {
      searchField
      if let matches {
        resultsContent(matches, counts)
      } else {
        recentsContent(counts)
      }
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

  /// Ce que la frappe trouve, calculé UNE fois par rendu (cf. `card`).
  private struct Matches {
    var tasks: [TaskItem]
    var lists: [TodoList]
    var projects: [Project]
    var isEmpty: Bool { tasks.isEmpty && lists.isEmpty && projects.isEmpty }
  }

  private var currentMatches: Matches {
    Matches(
      // Sans liste rattachée, une tâche n'a pas de page où naviguer : on l'écarte.
      tasks: tasks.filter {
        !$0.isHeader && $0.list != nil && $0.title.localizedCaseInsensitiveContains(needle)
      },
      lists: lists.filter { $0.title.localizedCaseInsensitiveContains(needle) },
      projects: projects.filter { $0.title.localizedCaseInsensitiveContains(needle) })
  }

  @ViewBuilder
  private func resultsContent(_ matches: Matches, _ counts: SidebarCounts) -> some View {
    if matches.isEmpty {
      Text("Aucun résultat")
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          if !matches.projects.isEmpty {
            sectionHeader("Projets")
            ForEach(matches.projects) { row(for: .project($0), counts) }
          }
          if !matches.lists.isEmpty {
            sectionHeader("Listes")
            ForEach(matches.lists) { row(for: .list($0), counts) }
          }
          if !matches.tasks.isEmpty {
            sectionHeader("Tâches")
            ForEach(matches.tasks) { task in
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
