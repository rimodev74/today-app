import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Page d'un projet : un tableau de CARTES, une par to-do list, chacune avec un aperçu de ce qui
/// reste à y faire (cf. `ProjectBoard`). Cliquer une carte ouvre la page de sa liste, où se fait
/// tout le travail (édition, création, réordonnancement) ; la carte est une vitrine, pas un
/// deuxième endroit où éditer.
///
/// Remplace l'empilement « titre de liste + ses tâches en lecture », qui redonnait à voir la page
/// de chaque liste les unes sous les autres : sur un projet à cinq listes, il fallait faire défiler
/// pour savoir ce que le projet contient. Une carte tient le résumé dans un écran.
struct ProjectPageView: View {
  @Bindable var project: Project
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Binding var pendingTitleFocus: PersistentIdentifier?

  @Environment(\.modelContext) private var modelContext
  /// Supprimer une liste emporte ses tâches ; leurs rappels Apple doivent partir avec elles, sinon
  /// ils restent orphelins et reviennent s'afficher dans les sections « Rappels » de l'app (cf.
  /// `TodoList.delete(from:in:forget:)`).
  @Environment(RemindersService.self) private var remindersService
  @FocusState private var notesFocused: Bool
  /// Liste en attente de confirmation de suppression (non nil ⇒ alerte). Même règle que la
  /// sidebar : vide, elle part sans rien demander (cf. `TodoList.needsDeleteConfirmation`).
  @State private var deletionCandidate: TodoList?

  /// Ce qu'une carte REND, fondu compris — délibérément plus que ce qu'elle laisse voir en entier
  /// (`ListCardView.visibleRows`) : les dernières rangées passent sous le dégradé, et c'est ce
  /// dégradé qui dit « ça continue ».
  private static let previewLimit = 6

  /// Le projet dont les cartes ont fait leur entrée. Elles la rejouent à CHAQUE ouverture : la vue
  /// est détruite dès qu'on quitte le projet (autre branche de `TaskListView.page`), et réutilisée
  /// d'un projet à l'autre — dans les deux cas, ce `@State` ne vaut pas le projet affiché au
  /// premier rendu, les cartes partent donc cachées et `onChange` les fait entrer.
  @State private var entranceTrigger: PersistentIdentifier?
  /// Le dépliant des listes archivées, replié à chaque ouverture d'un projet (cf. `onChange`).
  @State private var archiveExpanded = false

  private static let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 16)]

  var body: some View {
    // Construit UNE fois en tête du body, puis distribué (cf. Conventions) : lu depuis les
    // rangées, chaque chiffre retraverserait SwiftData à chaque rendu. `bounds` aussi : les cartes
    // en cours et celles des archives lisent le réglage de l'anneau au MÊME instant.
    let bounds = DayBounds()
    let board = ProjectBoard.build(from: project, previewLimit: Self.previewLimit, bounds: bounds)
    let cardsShown = entranceTrigger == project.persistentModelID

    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        listsHeader(board)
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
          ForEach(Array(board.cards.enumerated()), id: \.element.id) { rank, card in
            ListCardView(
              card: card,
              open: { selection = .list(card.list) },
              rename: { rename(card.list) },
              archive: card.isFinished ? ("Archiver la liste", { archive(card.list) }) : nil,
              delete: { requestDelete(card.list) }
            )
            .enteringCard(cardsShown, rank: rank)
            // La carte qui part s'efface, celles qui restent COULENT vers leur nouvelle place —
            // le `withAnimation(boardFlow)` des chemins de création/suppression anime le
            // replacement de la grille, cette transition ne concerne que la carte elle-même.
            // Même couple qu'une tâche qui disparaît d'une liste (cf. `TaskRow`) : fondu seul,
            // pas de glissement, sinon la carte part de travers pendant que la grille se retasse.
            .transition(.opacity)
          }
          createCard
            .enteringCard(cardsShown, rank: board.cards.count)
        }
        // Même colonne que `listsHeader` et l'anneau du titre juste au-dessus (cf.
        // `taskContentColumn`) : sans elle, les cartes partaient du bord de section, 20 pt trop à
        // gauche de tout le reste de la page (mesuré le 10 août 2026).
        .padding(.leading, taskContentColumn)

        archiveSection(board, bounds: bounds)
      }
      // `gutter`, comme toutes les autres pages : à `gutter - 8`, l'en-tête et son encadré de notes
      // tombaient 8 pt à gauche de ceux d'une liste — un décalage que rien ne justifiait, visible
      // au moindre aller-retour entre les deux pages.
      .padding(.horizontal, gutter)
      .padding(.top, 30)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(
        onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
    // `initial` ET changement : la vue est RÉUTILISÉE d'un projet à l'autre (pas d'`.id`, cf.
    // `TaskListView.page`), `onAppear` ne verrait que le premier.
    .onChange(of: project.persistentModelID, initial: true) { _, id in
      // Hors transaction : un autre projet ne doit pas hériter du dépliant ouvert sur le précédent.
      archiveExpanded = false
      withAnimation(cardEntrance) { entranceTrigger = id }
    }
    .alert(
      "Supprimer la liste ?",
      isPresented: Binding(
        get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }),
      presenting: deletionCandidate
    ) { list in
      Button("Supprimer", role: .destructive) {
        withAnimation(boardFlow) {
          list.delete(
            from: $selection, in: modelContext, forget: remindersService.forgetAppleItems)
        }
        deletionCandidate = nil
      }
      Button("Annuler", role: .cancel) { deletionCandidate = nil }
    } message: { list in
      Text(list.deleteConfirmationMessage)
    }
  }

  private var header: some View {
    // Même construction QUE `ListPageView.header`, au point près (espacement, retrait de l'anneau,
    // encadré de notes) : les deux pages doivent se lire comme une seule.
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        ProgressRing(progress: project.progress(), size: 26, lineWidth: 3)
          .tint(project.color?.color)
        TextField("Nom du projet", text: $project.title)
          .textFieldStyle(.plain)
          .font(.app(.title).bold())
      }
      // L'anneau se cale sur `taskContentColumn`, comme sur la page d'une liste (cf.
      // `ListPageView.header`) — même colonne que le bord du `NotesBox` juste en dessous.
      .padding(.leading, taskContentColumn)

      // Même encadré que la page de liste (cf. `NotesBox`).
      NotesBox(notes: $project.notes, font: .app(), textColor: .labelColor, focused: $notesFocused)
      {
        notesFocused = false
      }
    }
  }

  /// La ligne qui coiffe la grille : ce qu'on regarde à gauche, ce que ça pèse à droite. Même
  /// colonne que l'anneau du titre juste au-dessus (cf. `taskContentColumn`) — un simple `rowInset`
  /// la laissait 10 pt trop à gauche (mesuré le 10 août 2026).
  private func listsHeader(_ board: ProjectBoard) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Listes").font(.app(.headline))
      Spacer(minLength: 12)
      Text(remainingLabel(board))
        .font(.app(.callout))
        .foregroundStyle(.secondary)
    }
    .padding(.leading, taskContentColumn)
  }

  private func remainingLabel(_ board: ProjectBoard) -> String {
    let count = board.remainingCount
    return count == 0 ? "Rien à faire" : "\(count) tâche\(count > 1 ? "s" : "") à faire"
  }

  /// Carte en pointillés qui crée une liste. Même geste que « + » de la sidebar, même point de
  /// passage (`Project.appendList`) : la nouvelle liste s'ouvre avec son titre en édition.
  private var createCard: some View {
    Button(action: addList) {
      VStack(spacing: 10) {
        Image(systemName: "plus").font(.system(size: 18, weight: .medium))
        Text("Créer une liste").font(.app(.callout).weight(.semibold))
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .frame(height: ListCardView.height)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(
            Color.primary.opacity(0.2),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
      )
    }
    .buttonStyle(.plain)
  }

  private func addList() {
    let list = withAnimation(boardFlow) {
      project.appendList(titled: "Nouvelle liste", in: modelContext)
    }
    rename(list)
  }

  /// Renommer depuis une carte = ouvrir la liste, titre en édition. Le champ du titre vit sur la
  /// page de la liste (`pendingTitleFocus`) : c'est le seul endroit où le nom s'édite, et ça évite
  /// un second état d'édition ici — exactement ce que la sidebar fait déjà pour une liste neuve.
  private func rename(_ list: TodoList) {
    selection = .list(list)
    pendingTitleFocus = list.persistentModelID
  }

  /// « N listes archivées », replié par défaut, sous la grille. Même geste que les tâches archivées
  /// d'une liste (`ListPageView.archiveSection`) : absent tant que rien n'est archivé, et son
  /// contenu RETIRÉ quand il est replié — les cartes des archives ne sont fabriquées qu'ici, à
  /// l'ouverture (cf. `ProjectBoard.archived`).
  @ViewBuilder
  private func archiveSection(_ board: ProjectBoard, bounds: DayBounds) -> some View {
    let count = board.archived.count
    if count > 0 {
      let plural = count > 1 ? "s" : ""
      VStack(alignment: .leading, spacing: 0) {
        Divider().padding(.vertical, 10)

        Button {
          withAnimation(disclosureFlow) { archiveExpanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Text("\(count) liste\(plural) archivée\(plural)")
              .font(.app(.subheadline).weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.app(10, weight: .semibold))
              .rotationEffect(.degrees(archiveExpanded ? 90 : 0))
          }
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if archiveExpanded {
          let cards = ProjectBoard.cards(
            for: board.archived, previewLimit: Self.previewLimit, bounds: bounds)
          LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
            ForEach(cards) { card in
              ListCardView(
                card: card,
                open: { selection = .list(card.list) },
                rename: { rename(card.list) },
                archive: ("Désarchiver", { unarchive(card.list) }),
                delete: { requestDelete(card.list) }
              )
              .transition(.opacity)
            }
          }
          .padding(.top, 16)
          // Fondu EXPLICITE : un vrai retrait/insertion (cf. `PIEGES.md` § Animations).
          .transition(.opacity)
        }
      }
      .padding(.leading, taskContentColumn)
      .transition(.opacity)
    }
  }

  /// La carte quitte la grille en fondu et les autres coulent à sa place, comme une suppression —
  /// sauf que la liste, elle, reste en base.
  private func archive(_ list: TodoList) {
    withAnimation(boardFlow) { list.archive(from: $selection, in: modelContext) }
  }

  private func unarchive(_ list: TodoList) {
    withAnimation(boardFlow) { list.unarchive(in: modelContext) }
  }

  private func requestDelete(_ list: TodoList) {
    if list.needsDeleteConfirmation {
      deletionCandidate = list
    } else {
      withAnimation(boardFlow) {
        list.delete(
          from: $selection, in: modelContext, forget: remindersService.forgetAppleItems)
      }
    }
  }
}

extension View {
  /// L'entrée d'une carte, en cascade. La PAGE déclenche (`withAnimation(cardEntrance)`) ; la carte
  /// n'ajoute que son retard, et seulement quand `shown` bascule — une suppression ou un survol
  /// n'héritent d'aucun délai. Des effets de rendu seuls (pas de cadre qui bouge) : la grille ne se
  /// retasse pas pendant l'entrée, et le body de la carte ne se rejoue pas.
  ///
  /// ponytail: retard plafonné au 8e rang — au-delà, la cascade traînerait sur un gros projet.
  fileprivate func enteringCard(_ shown: Bool, rank: Int) -> some View {
    opacity(shown ? 1 : 0)
      .scaleEffect(shown ? 1 : 0.92)
      .offset(y: shown ? 0 : 12)
      .transaction(value: shown) { $0.animation = $0.animation?.delay(Double(min(rank, 8)) * 0.05) }
  }
}

/// Une carte du tableau d'un projet : anneau + titre, le menu ••• à droite, les tâches à faire,
/// et ce qui reste en bas à gauche. Sans `@Bindable` : rien ne s'édite ici, la carte ouvre la page
/// de sa liste et c'est tout.
private struct ListCardView: View {
  let card: ProjectBoard.Card
  let open: () -> Void
  let rename: () -> Void
  /// « Archiver la liste » sur une carte finie, « Désarchiver » dans les archives, `nil` sinon.
  /// Sans valeur par défaut : chacune des deux grilles se prononce.
  let archive: (title: String, run: () -> Void)?
  let delete: () -> Void

  @State private var hovering = false

  /// Rangées visibles EN ENTIER. Au-delà, l'aperçu continue sous le fondu — d'où une hauteur de
  /// zone qui coupe une rangée en deux (`previewHeight`) plutôt qu'un compte rond : une rangée
  /// tranchée net se lit comme une fin de liste, une rangée qui s'efface se lit comme une suite.
  private static let visibleRows = 4
  private static let rowHeight: CGFloat = 30
  private static let rowSpacing: CGFloat = 6
  private static let previewHeight =
    CGFloat(visibleRows) * rowHeight + CGFloat(visibleRows) * rowSpacing + rowHeight / 2
  private static let padding: CGFloat = 14
  private static let titleHeight: CGFloat = 22
  private static let footerHeight: CGFloat = 16
  private static let spacing: CGFloat = 12

  /// La hauteur d'une carte est la somme de pièces qui DÉCLARENT toutes la leur — aucun terme ne
  /// dépend de ce qu'une police rend à l'écran. Un terme deviné (la hauteur du pied) suffisait à
  /// faire diverger cette somme du contenu réel, et le `Spacer` qui séparait l'aperçu du pied
  /// rattrapait l'écart en poussant celui-ci jusqu'au bord : le retrait du bas disparaissait.
  /// Plus de `Spacer` — il n'y a plus rien à rattraper.
  static let height: CGFloat =
    2 * padding + titleHeight + spacing + previewHeight + spacing + footerHeight

  var body: some View {
    // Le menu est un FRÈRE du bouton, pas un enfant : imbriqué dans le label, c'est le bouton de
    // la carte qui happe le clic et le menu ne s'ouvre jamais.
    ZStack(alignment: .topTrailing) {
      Button(action: open) { cardBody }
        .buttonStyle(.plain)
      menu.padding(Self.padding)
    }
    // Pas de curseur « main » : une carte est de la navigation, pas un lien (cf. CLAUDE.md).
    // Le repère de survol est le contour, comme les lignes de la sidebar.
    .onHover { hovering = $0 }
  }

  private var cardBody: some View {
    VStack(alignment: .leading, spacing: Self.spacing) {
      title
      preview
      footer
    }
    .padding(Self.padding)
    // Exactement la hauteur naturelle du contenu (cf. `height`) : le cadre ne fait plus
    // qu'affirmer que toutes les cartes de la grille ont la même.
    .frame(height: Self.height, alignment: .topLeading)
    .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.08), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var title: some View {
    HStack(spacing: 8) {
      ProgressRing(progress: card.progress, size: 18)
        .tint(card.list.project?.color?.color)
      Text(card.list.title.isEmpty ? "Sans titre" : card.list.title)
        .font(.app(.headline))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    // La place du menu, qui flotte au-dessus : sans elle, un titre long passe dessous.
    .padding(.trailing, 22)
    .frame(height: Self.titleHeight)
  }

  private var footer: some View {
    Text(remainingLabel)
      .font(.app(.caption).weight(.semibold))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      // Hauteur DÉCLARÉE, pas minimale : c'est ce qui garde la somme de `height` exacte quoi que
      // rende la police (le pied tient sur une ligne de 10 pt, 16 est large).
      .frame(height: Self.footerHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Les tâches à faire, empilées. La zone a une hauteur FIXE et coupe au milieu d'une rangée ;
  /// le dégradé n'est posé que s'il y a effectivement une suite — appliqué à quatre tâches qui
  /// tiennent, il effacerait la dernière sans rien annoncer.
  private var preview: some View {
    VStack(spacing: Self.rowSpacing) {
      ForEach(card.preview) { task in previewRow(task) }
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.previewHeight, alignment: .top)
    .clipped()
    .mask(overflows ? AnyView(fade) : AnyView(Color.black))
  }

  private var overflows: Bool { card.preview.count > Self.visibleRows }

  /// Le fondu : opaque sur la première rangée, puis décroissant jusqu'au bas de la zone.
  private var fade: some View {
    LinearGradient(
      stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: 0.18),
        .init(color: .clear, location: 1),
      ],
      startPoint: .top, endPoint: .bottom)
  }

  /// Barrée si c'est de l'archivé venu combler la carte (cf. `ProjectBoard.build`) — même habillage
  /// que la ligne d'une tâche cochée dans une liste (`TaskRow.titleColor`).
  private func previewRow(_ task: TaskItem) -> some View {
    Text(task.title.isEmpty ? "Sans titre" : task.title)
      .font(.app(.callout))
      .foregroundStyle(task.isCompleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .strikethrough(task.isCompleted)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .frame(height: Self.rowHeight)
      .background(
        Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var remainingLabel: String {
    let n = card.remainingCount
    return n == 0 ? "Aucune tâche en attente" : "\(n) tâche\(n > 1 ? "s" : "") en attente"
  }

  /// Le MÊME menu que le clic droit sur une liste dans la sidebar — « Désarchiver » en plus, qu'on
  /// ne peut offrir qu'ici : une archivée n'a pas de ligne dans la sidebar. Renommer ouvre la liste
  /// avec son titre en édition (cf. `ProjectPageView.rename`), faute de champ éditable sur la carte.
  private var menu: some View {
    Menu {
      Button("Renommer") { rename() }
      if let archive {
        Button(archive.title, action: archive.run)
      }
      Divider()
      Button("Supprimer la liste", role: .destructive) { delete() }
    } label: {
      Image(systemName: "ellipsis")
        .font(.app(15, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  /// Fond de carte : un voile sur le fond de page, comme `NotesBox` et les rangées d'aperçu.
  /// Surtout PAS une couleur opaque comme `.controlBackgroundColor` : en sombre la page est un
  /// matériau translucide (cf. `ContentView`), teinté par le bureau — mesuré (37,40,53) — alors
  /// qu'une couleur opaque reste un gris nu (30,30,30). La carte apparaissait comme une plaque
  /// noire posée sur une page bleutée. Un voile compose avec ce qu'il y a dessous : il garde la
  /// teinte de la page dans les deux thèmes, sans valeur à doubler à la main.
  private var cardFill: Color { Color.primary.opacity(0.05) }
}
