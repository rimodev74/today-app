import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// La vue « Projets » : tous les projets d'un coup d'œil, une carte chacun, avec leur avancement
/// CUMULÉ (cf. `ProjectsOverview`). Une vitrine, comme les cartes d'un projet : cliquer ouvre le
/// projet ou l'une de ses listes, rien ne s'édite ici.
///
/// `LazyVGrid` est permis : rien ne s'y glisse au doigt (la règle de `CLAUDE.md` § 1 ne vise que
/// les pages qui se réordonnent). Montée seulement quand elle est sélectionnée (`TaskListView`) :
/// ses deux `@Query` ne coûtent rien ailleurs.
struct ProjectsPageView: View {
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool

  /// Même tri que la sidebar : les cartes suivent l'ordre qu'on y a posé à la main.
  @Query(sort: [SortDescriptor(\Project.sortIndex), SortDescriptor(\Project.createdAt)])
  private var projects: [Project]
  /// La table entière, comme `SidebarTallySource` : mesuré le 8 octobre 2026, un `@Query` bat la
  /// traversée des relations d'un facteur huit.
  @Query private var allTasks: [TaskItem]
  @Environment(ProjectCovers.self) private var covers
  @State private var cardsShown = false

  private static let columns = [
    GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16, alignment: .top)
  ]

  var body: some View {
    // Construit UNE fois en tête du body, puis distribué (cf. Conventions).
    let overview = ProjectsOverview.build(
      projects: projects,
      counts: SidebarCounts(tasks: allTasks, bounds: ProjectsOverview.cumulativeBounds()))

    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header(overview)
        if overview.cards.isEmpty {
          Text("Aucun projet. Créez-en un depuis la barre latérale.")
            .foregroundStyle(.tertiary)
            .padding(.leading, taskContentColumn)
        }
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
          ForEach(Array(overview.cards.enumerated()), id: \.element.id) { rank, card in
            ProjectCardView(
              card: card, stamp: covers.stamps[card.uuid],
              openProject: { selection = .project(card.project) },
              openList: { selection = .list($0) }
            )
            .enteringCard(cardsShown, rank: rank)
          }
        }
        .padding(.leading, taskContentColumn)
      }
      .padding(.horizontal, gutter)
      .padding(.top, 30)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
    .onAppear { withAnimation(cardEntrance) { cardsShown = true } }
  }

  private func header(_ overview: ProjectsOverview) -> some View {
    let left = overview.cards.reduce(0) { $0 + $1.total.remaining }
    // Même bandeau que « Tâches » et « Archives » : centré (pas sur la ligne de base, qui
    // remontait le cartouche) et calé sur `taskContentColumn`, comme les cartes dessous.
    return HStack(spacing: 10) {
      PageHeaderIcon(systemImage: "square.grid.2x2.fill", tint: PageTint.projects)
      Text("Projets").font(.app(.title).bold())
      Spacer(minLength: 12)
      if !overview.cards.isEmpty {
        Text(left == 0 ? "Rien à faire" : "\(left) tâche\(left > 1 ? "s" : "") à faire")
          .font(.app(.callout))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, taskContentColumn)
  }
}

/// La carte d'un projet : couverture, titre, avancement, puis ses listes en cours.
///
/// Le haut (couverture + titre + barre) et chaque ligne de liste sont des boutons FRÈRES, pas
/// imbriqués : un bouton dans le label d'un autre ne reçoit jamais le clic (cf. `ListCardView`).
private struct ProjectCardView: View {
  let card: ProjectsOverview.Card
  let stamp: Date?
  let openProject: () -> Void
  let openList: (TodoList) -> Void

  @State private var hovering = false

  /// La carte est une vitrine, pas un inventaire : au-delà, « + N autres ».
  private static let maxLists = 5
  private static let radius: CGFloat = 16

  var body: some View {
    let tint = card.project.color?.color ?? PageTint.projects
    let shown = card.lists.prefix(Self.maxLists)
    let hidden = card.lists.count - shown.count

    VStack(alignment: .leading, spacing: 0) {
      Button(action: openProject) {
        VStack(alignment: .leading, spacing: 0) {
          ProjectCoverView(uuid: card.uuid, stamp: stamp, tint: tint, height: 150, maxPixel: 760)
          VStack(alignment: .leading, spacing: 8) {
            Text(card.project.title.isEmpty ? "Sans titre" : card.project.title)
              .font(.app(.headline))
              .lineLimit(1)
            ProgressBar(progress: card.total.progress, tint: tint)
            Text(Self.countLabel(card.total))
              .font(.app(.caption).weight(.semibold))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          .padding(.horizontal, 14)
          .padding(.top, 12)
          .padding(.bottom, card.lists.isEmpty ? 14 : 8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !card.lists.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(shown) { line in
            Button {
              openList(line.list)
            } label: {
              listLine(line, tint: tint)
            }
            .buttonStyle(.plain)
          }
          if hidden > 0 {
            Text("+ \(hidden) autre\(hidden > 1 ? "s" : "")")
              .font(.app(.caption))
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 8)
              .padding(.top, 2)
          }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
      }
    }
    // Même voile que les cartes d'un projet : il compose avec le verre de la page dans les deux
    // thèmes (cf. `ListCardView.cardFill`).
    .background(
      Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    )
    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        .strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.08), lineWidth: 1)
    )
    .onHover { hovering = $0 }
  }

  private func listLine(_ line: ProjectsOverview.ListLine, tint: Color) -> some View {
    HStack(spacing: 8) {
      Text(line.list.title.isEmpty ? "Sans titre" : line.list.title)
        .font(.app(.callout))
        .lineLimit(1)
      Spacer(minLength: 8)
      Text("\(line.row.done)/\(line.row.countable)")
        .font(.app(.caption))
        .foregroundStyle(.secondary)
        .monospacedDigit()
      ProgressBar(progress: line.row.progress, tint: tint, height: 4)
        .frame(width: 44)
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .contentShape(Rectangle())
  }

  static func countLabel(_ row: SidebarCounts.Row) -> String {
    guard row.countable > 0 else { return "Aucune tâche" }
    return "\(row.done) / \(row.countable) tâches faites"
  }
}

/// Le fil d'Ariane d'une page rangée dans un projet, façon Notion : « Projets / App - Today /
/// Bugs », chaque étape avec son icône et une pastille au survol. Chaque étape sauf la dernière
/// ramène à sa page ; la dernière est celle qu'on regarde.
struct Breadcrumb: View {
  struct Step {
    let title: String
    let systemImage: String
    let tint: Color
    /// `nil` = la page courante.
    let destination: SidebarSelection?
  }

  let steps: [Step]
  @Binding var selection: SidebarSelection?

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        if index > 0 {
          Text("/")
            .font(.app(14))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
        }
        BreadcrumbItem(step: step) {
          if let destination = step.destination { selection = destination }
        }
      }
    }
    .lineLimit(1)
  }

  /// Le fil de la destination courante, ou `nil` hors d'un projet.
  static func steps(for selection: SidebarSelection?) -> [Step]? {
    switch selection {
    case .project(let project): return steps(project: project, list: nil)
    case .list(let list): return list.project.map { steps(project: $0, list: list) }
    default: return nil
    }
  }

  /// Les étapes d'une liste rangée dans un projet (ou d'un projet seul, `list == nil`).
  static func steps(project: Project, list: TodoList?) -> [Step] {
    let tint = project.color?.color ?? PageTint.projects
    var steps = [
      Step(
        title: "Projets", systemImage: "square.grid.2x2.fill", tint: PageTint.projects,
        destination: .projects),
      Step(
        title: project.title, systemImage: "folder.fill", tint: tint,
        destination: list == nil ? nil : .project(project)),
    ]
    if let list {
      steps.append(
        Step(title: list.title, systemImage: "list.bullet", tint: tint, destination: nil))
    }
    return steps
  }
}

/// Le fil d'Ariane dans la BARRE DE TITRE, comme Notion — un vrai élément de barre d'outils :
/// posé dans le contenu sous la barre, la zone de titre de la fenêtre avalait ses clics.
/// Vue à part : c'est elle, et pas `ContentView`, qui lit les titres (renommer un projet ne doit
/// pas rejouer le corps de la fenêtre).
struct ToolbarBreadcrumb: View {
  @Binding var selection: SidebarSelection?
  /// Décalage depuis le bord gauche de la barre pour tomber à l'aplomb de la colonne de contenu
  /// (la barre commence après les feux, la page après la sidebar).
  let leading: CGFloat

  var body: some View {
    if let steps = Breadcrumb.steps(for: selection) {
      Breadcrumb(steps: steps, selection: $selection)
        .padding(.leading, max(0, leading))
    }
  }
}

private struct BreadcrumbItem: View {
  let step: Breadcrumb.Step
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    let isCurrent = step.destination == nil
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: step.systemImage)
          .font(.app(12, weight: .semibold))
          .foregroundStyle(step.tint)
        Text(step.title.isEmpty ? "Sans titre" : step.title)
          .font(.app(14, weight: .medium))
          .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        Color.primary.opacity(hovering && !isCurrent ? 0.07 : 0),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isCurrent)
    .onHover { hovering = $0 }
  }
}

/// L'avancement CUMULÉ d'un projet ou d'une liste. Une barre et jamais un anneau : l'anneau dit
/// l'élan du JOUR (il se remet à zéro à minuit), la barre dit tout ce qui a été fait — deux
/// quantités, deux formes, pour que l'une ne passe pas pour une contradiction de l'autre.
struct ProgressBar: View {
  let progress: Double
  let tint: Color
  var height: CGFloat = 6

  var body: some View {
    Capsule()
      .fill(Color.primary.opacity(0.08))
      // La géométrie dans un `overlay` : la barre se cale sur la largeur de la piste sans jamais
      // en proposer une (cf. CLAUDE.md § Layout, une forme en FRÈRE gonflerait sa rangée).
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule()
            .fill(tint)
            .frame(width: proxy.size.width * min(max(progress, 0), 1))
        }
      }
      .frame(height: height)
  }
}

/// Une couverture : le bandeau à la teinte du projet, et l'image par-dessus dès qu'elle est
/// décodée — hors du fil principal (`ProjectCovers.image`). Pas d'image ⇒ pas un accès disque.
struct ProjectCoverView: View {
  let uuid: UUID
  let stamp: Date?
  let tint: Color
  let height: CGFloat
  /// Le plus grand côté décodé, en pixels : la largeur d'affichage ×2 (Retina).
  let maxPixel: Int

  @Environment(ProjectCovers.self) private var covers
  @State private var image: CGImage?

  var body: some View {
    LinearGradient(
      colors: [tint.opacity(0.85), tint.opacity(0.45)],
      startPoint: .topLeading, endPoint: .bottomTrailing
    )
    // L'image en `overlay` : `scaledToFill` déborde par construction, en frère elle imposerait sa
    // taille au bandeau.
    .overlay {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFill()
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
    .clipped()
    // Clé = projet ET version : la vue est RÉUTILISÉE d'un projet à l'autre (cf. `TaskListView`),
    // une clé sur la seule date laisserait l'image du précédent. Remise à nil d'abord (sinon elle
    // flashe), et rien d'écrit par une tâche annulée — un décodage lent arrivé APRÈS celui du
    // projet suivant écraserait sa couverture.
    .task(id: "\(uuid)-\(stamp?.timeIntervalSince1970 ?? 0)") {
      image = nil
      guard let stamp else { return }
      let loaded = await covers.image(for: uuid, stamp: stamp, maxPixel: maxPixel)
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.2)) { image = loaded }
    }
  }
}

/// Le bandeau en tête de la page d'un projet, et ce qui le change : « Changer la couverture… »,
/// « Retirer », ou une image déposée depuis le Finder.
struct ProjectCoverBanner: View {
  let uuid: UUID
  let tint: Color

  @Environment(ProjectCovers.self) private var covers
  @State private var hovering = false

  /// Sans couverture, RIEN : la page d'un projet ne change pas d'un point. L'ajout passe par
  /// `CoverPickerButton`, dans l'en-tête.
  var body: some View {
    if let stamp = covers.stamps[uuid] {
      ProjectCoverView(uuid: uuid, stamp: stamp, tint: tint, height: 260, maxPixel: 2_400)
        .overlay(alignment: .bottomTrailing) {
          if hovering {
            HStack(spacing: 6) {
              Button("Changer la couverture…") { chooseCover(for: uuid, in: covers) }
              Button("Retirer") { covers.remove(for: uuid) }
            }
            .controlSize(.small)
            .padding(10)
            .transition(.opacity)
          }
        }
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
        .coverDrop(uuid: uuid, covers: covers, tint: tint)
    }
  }
}

/// L'icône « Ajouter une couverture » de l'en-tête d'un projet qui n'en a pas — et la cible où
/// déposer une image depuis le Finder.
struct CoverPickerButton: View {
  let uuid: UUID
  let tint: Color

  @Environment(ProjectCovers.self) private var covers

  var body: some View {
    if covers.stamps[uuid] == nil {
      Button {
        chooseCover(for: uuid, in: covers)
      } label: {
        Image(systemName: "photo.badge.plus")
          .font(.app(15, weight: .medium))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.borderless)
      .help("Ajouter une couverture (ou déposer une image sur ce titre)")
    }
  }
}

extension View {
  /// Déposer une image depuis le Finder en fait la couverture du projet.
  func coverDrop(uuid: UUID, covers: ProjectCovers, tint: Color) -> some View {
    modifier(CoverDrop(uuid: uuid, covers: covers, tint: tint))
  }
}

private struct CoverDrop: ViewModifier {
  let uuid: UUID
  let covers: ProjectCovers
  let tint: Color
  @State private var targeted = false

  func body(content: Content) -> some View {
    content
      .overlay {
        if targeted {
          RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint, lineWidth: 2)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first, isImage(url) else { return false }
        Task { await covers.set(from: url, for: uuid) }
        return true
      } isTargeted: {
        targeted = $0
      }
  }

  private func isImage(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
  }
}

/// `NSOpenPanel` lancé depuis l'ACTION d'un bouton, jamais `.fileImporter` : SwiftUI présente
/// celui-ci depuis le layout, et ordonner une fenêtre pendant le layout de la fenêtre principale
/// tue le process (→ `PIEGES.md` § Fenêtres, même chemin que `OnboardingView.choosePhoto`).
@MainActor
private func chooseCover(for uuid: UUID, in covers: ProjectCovers) {
  let panel = NSOpenPanel()
  panel.allowedContentTypes = [.image]
  panel.allowsMultipleSelection = false
  panel.begin { response in
    guard response == .OK, let url = panel.url else { return }
    Task { await covers.set(from: url, for: uuid) }
  }
}
