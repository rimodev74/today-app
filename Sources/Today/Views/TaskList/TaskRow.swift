// La ligne d'une tâche : au repos, en sélection, en édition. Sortie de `TaskListView.swift`, qui
// mélangeait le routage des pages, la ligne, l'en-tête de section et la case à cocher dans un seul
// fichier de 2 750 lignes. Rien n'a changé de comportement — seuls `HeaderRow` et
// `EditorHeightKey` ont dû passer de `private` à interne pour rester atteignables.

import AppKit
import SwiftData
import SwiftUI

/// Une tâche dans la liste. Deux modes :
/// - **affichage** : case à cocher + titre. Double-clic pour éditer.
/// - **édition** (double-clic) : carte détachée avec titre, notes, et une rangée d'actions
///   (date, tags, checklist, priorité), façon Things.
///
/// Le double-clic est un simple `.onTapGesture(count: 2)` — possible parce qu'on n'est plus sur
/// une `List`/NSTableView (qui avalait ses clics). C'est tout le bénéfice de la refonte.
/// Internal et pas `private` : « Aujourd'hui » la réutilise telle quelle (cf. `TodayPageView`).
/// C'était la seule façon d'y avoir édition, suppression, dates et durée sans réécrire la ligne —
/// une deuxième implémentation aurait dérivé de celle-ci au premier changement.
struct TaskRow: View {
  @Bindable var task: TaskItem
  let isSelected: Bool
  let isEditing: Bool
  /// Listes vers lesquelles déplacer la tâche (toutes sauf la sienne).
  var moveTargets: [TodoList]
  /// Faux dans « Aujourd'hui » : la page ne montre QUE le jour même, la date répétée sur chaque
  /// ligne n'apprend rien. Elle reste indispensable dans une liste, qui mélange les échéances.
  var showsDate: Bool = true
  /// Rattachement affiché à droite du titre. `nil` dans une page de liste (on sait déjà où l'on
  /// est) ; renseigné dans « Aujourd'hui », qui mélange les provenances.
  var parentLabel: String? = nil
  var onBeginEditing: () -> Void
  var onEndEditing: () -> Void
  var onMove: (TodoList) -> Void
  var onDuplicate: () -> Void
  var onDelete: () -> Void
  /// Cocher/décocher : la page décide ce qu'elle en fait (ici, programmer l'archivage).
  var onCompletionChanged: () -> Void

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  /// Focus de la sous-tâche en cours d'édition (clé = uuid stable, pas `persistentModelID` qui
  /// mute à l'autosave), pour poser le focus sur celle qu'on vient de créer.
  /// uuid de la sous-tâche à focaliser (clé de focus stable, cf. `SubtaskRowView`).
  @FocusState private var focusedSubtask: UUID?
  /// Dépliant de sous-tâches ouvert/fermé : permet de replier une longue checklist pour ne pas
  /// surcharger la tâche. ponytail: état éphémère (par vue de tâche), non persisté — se réinitialise
  /// à `true` au redémarrage. À porter sur `TaskItem` si l'on veut le mémoriser.
  @State private var subtasksExpanded = true

  @FocusState private var titleFocused: Bool
  @State private var hovering = false
  // Révélation du corps d'édition. `editorHeight` = sa hauteur naturelle mesurée (cache, sert de
  // cible d'ouverture) ; `editorReveal` = la hauteur RÉELLEMENT dévoilée (animée), 0 = fermé. On
  // anime la fenêtre qui découvre le contenu, jamais le contenu lui-même — il reste figé à sa place.
  @State private var editorHeight: CGFloat = 0
  @State private var editorReveal: CGFloat = 0
  // Le corps d'édition survit à la sortie de `isEditing` : `showEditor` le garde monté pendant la
  // fermeture animée (la fenêtre rétrécit, le clipping ravale le contenu), puis on le démonte pour
  // ne pas garder son NSTextView en vie. `editSession` annule un démontage programmé si une nouvelle
  // session d'édition démarre entre-temps (réouverture rapide).
  @State private var showEditor = false
  @State private var editSession = 0
  // Icône « note » au survol (tâche sans notes) : true entre le clic sur l'icône et l'ouverture de
  // l'édition, pour que le focus atterrisse dans les notes plutôt que dans le titre (cf.
  // `.onChange(of: isEditing)`). Retombe à false à la fin de CETTE édition, pas seulement après usage
  // — sinon une édition suivante ouverte autrement (double-clic) hériterait du focus notes.
  @State private var focusNotesOnAppear = false
  @State private var showReminderSheet = false
  // UN SEUL popover à la fois. Deux `.popover(isPresented:)` sur la même vue = comportement
  // indéfini sur macOS (le second plantait à l'ouverture de l'échéance). Un seul `.popover(item:)`
  // dont le contenu dépend du champ édité.
  @State private var activePicker: DateField?

  private enum DateField: String, Identifiable {
    case when, deadline
    var id: String { rawValue }
  }

  /// UN SEUL arbre de vues, jamais un if/else entre deux racines : c'est ce qui rend la
  /// transition fluide. La ligne titre (case + titre) est TOUJOURS là et garde son identité ;
  /// l'édition ne fait qu'ajouter le corps sous elle et grossir le padding. SwiftUI a donc une
  /// hauteur continue à animer — un if/else échangerait deux vues d'un coup, d'où le « snap ».
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        TaskCheckbox(isCompleted: task.isCompleted) {
          withAnimation(taskInsert) {
            task.toggleCompletion()
            if task.isCompleted { task.list?.moveToEndOfSection(task) }
          }
          Task { await remindersService.pushCompletion(for: task) }
          onCompletionChanged()
        }
        if !isEditing, showsDate { dateTag }
        // Durée estimée, à gauche du titre comme la date : ce sont les deux faces d'une même
        // décision (quand, et pour combien de temps). Rien tant que rien n'est estimé — la page
        // « Aujourd'hui » est le seul endroit qui réclame l'absence de durée.
        if !isEditing, let estimate = Estimate.label(task.estimateMinutes) {
          Text(estimate)
            .font(.app(.callout))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        titleView
        Spacer(minLength: 0)
        // À droite plutôt qu'en sous-titre : la ligne garde sa hauteur d'une seule ligne, donc la
        // même que dans une page de liste — l'ouverture de la carte d'édition reste continue.
        if !isEditing, let parentLabel {
          Text(parentLabel)
            .font(.app(.callout))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        if !isEditing { trailing }
      }

      // Aperçu de la note au repos : sa première ligne sous le titre. Disparaît en édition — le
      // corps d'édition ci-dessous prend le relais avec la note complète et modifiable.
      if !isEditing && !task.notes.isEmpty { notePreview }

      // Montée sur `showEditor`, pas `isEditing` : le corps reste affiché pendant la fermeture animée.
      if showEditor {
        // OUVERTURE **ET** FERMETURE PAR RÉVÉLATION, jamais par translation ni disparition sèche. Le
        // contenu (notes + actions) est posé UNE fois à sa place définitive sous le titre — `fixedSize`
        // lui garde sa hauteur naturelle — et ne bouge JAMAIS : c'est la fenêtre qui le découvre
        // (`frame(height: editorReveal)` + `clipped`, ancrée en haut) qui grandit puis rapetisse.
        // Ouverture : `editorReveal` 0 → hauteur mesurée (le contenu se dévoile du haut vers le bas).
        // Fermeture : hauteur → 0, le clipping ravale icônes puis notes (tout reste affiché, on ne
        // masque rien à la main). Une fois refermée et hors édition, le corps est démonté (cf.
        // `.onChange(of: isEditing)`) pour libérer son NSTextView.
        editorBody
          .padding(.top, 12)
          // Petite respiration sous les icônes, DANS la fenêtre révélée : l'éditeur n'est plus le bas
          // de la carte (le trait + les sous-tâches suivent), inutile d'y porter toute la marge basse.
          .padding(.bottom, 4)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { g in
              Color.clear.preference(key: EditorHeightKey.self, value: g.size.height)
            }
          }
          .frame(height: editorReveal, alignment: .top)
          .clipped()
          // Pas d'interaction hors édition : pendant la fermeture le contenu est encore là mais inerte.
          .allowsHitTesting(isEditing)
          .onPreferenceChange(EditorHeightKey.self) { h in
            guard h > 0 else { return }
            editorHeight = h
            // Ne (re)déployer QUE si l'on édite : sinon la mesure du contenu encore monté pendant la
            // fermeture rouvrirait la fenêtre. En édition : 1re mesure → déploie ; sinon suit le
            // contenu (notes multi-lignes tapées).
            guard isEditing else { return }
            if editorReveal == 0 {
              withAnimation(taskFlow) { editorReveal = h }
            } else {
              editorReveal = h
            }
          }
          .onAppear {
            // Réouverture (hauteur déjà en cache) : déployer tout de suite. Sinon la 1re mesure
            // ci-dessus s'en charge — l'un OU l'autre déclenche l'animation, jamais un saut.
            if isEditing, editorHeight > 0 {
              withAnimation(taskFlow) { editorReveal = editorHeight }
            }
          }
          .transition(.identity)
      }

      // Sous-tâches : montées au repos comme en édition, APRÈS l'éditeur de notes pour respecter
      // l'ordre titre → notes → sous-tâches. Repliées, elles ne sont pas montées du tout — un bloc
      // vide laisserait sa marge haute et gonflerait la ligne fermée de quelques points.
      if showsSubtasks { subtasksSection }
    }
    // Ajout/suppression d'une sous-tâche : `withAnimation` autour de la mutation ne suffit PAS —
    // SwiftData notifie le changement de relation hors de la transaction, la carte sautait donc à sa
    // nouvelle hauteur. On anime ici sur le compte, qui, lui, est observé au rendu.
    .animation(taskFlow, value: task.subtasks.count)
    // Borne le contenu aux limites de la ligne pendant que la carte s'ouvre/se referme.
    .clipped()
    // Décrue : une tâche que personne ne réveille s'efface. Posé sur le CONTENU seulement (avant
    // `.background`), pour que le fond de sélection reste franc — c'est la tâche qui pâlit, pas
    // le fait qu'elle soit sélectionnée. Pleine opacité dès qu'on l'édite : on la touche, elle
    // redevient nette le temps qu'on s'en occupe.
    .opacity(isEditing ? 1 : task.dormancyFade)
    .animation(.easeOut(duration: 0.2), value: isEditing)
    // Le padding grandit en édition : la hauteur de la carte s'ouvre autour du titre resté en place.
    // Sélection et normal partagent le même padding — le texte ne saute donc pas au clic simple.
    // Bas en édition : les sous-tâches sont désormais le dernier élément de la carte (après
    // l'éditeur), il leur faut une respiration jusqu'au bord bas.
    .padding(.top, isEditing ? 16 : 6)
    // Au repos, une tâche DÉPLIÉE finit sur une rangée de sous-tâche et non sur son titre : il lui
    // faut un peu plus de fond que les 6 pt d'une ligne simple. Repliée, elle EST une ligne simple.
    .padding(.bottom, isEditing ? 14 : (showsSubtasks ? 10 : 6))
    .padding(.horizontal, isEditing ? 16 : rowInset)
    .background { rowBackground }
    .contentShape(Rectangle())
    // Survol : révèle le ••• à droite. Clic droit : même menu que le •••, via contentShape ;
    // bascule aussi en édition, via `RightClickObserver` posé par la page (cf. ce type).
    .onHover { hovering = $0 }
    .contextMenu { taskMenu }
    // Les deux sélecteurs de date sont posés sur la ligne (pas sur un bouton du menu, qui
    // disparaît hors survol) : ils ont ainsi toujours une ancre valide, en repos comme en édition.
    .popover(item: $activePicker, arrowEdge: .trailing) { field in
      switch field {
      case .when: whenPicker
      case .deadline: deadlinePicker
      }
    }
    .sheet(isPresented: $showReminderSheet) {
      SchedulePlannerView(task: task, remindersService: remindersService)
    }
    // Sélection / édition / réordonnancement sont pilotés par le geste UNIQUE posé par la page
    // (cf. `dragGesture(for:)`), pour que la sélection réagisse au mouseDown sans voler le drag.
    .onExitCommand(perform: onEndEditing)
    // Le champ titre existe déjà avant l'édition (même TextField) : le focus ne peut plus se
    // poser à son .onAppear. On le pose/retire au basculement d'état — sauf si l'édition a été
    // ouverte depuis l'icône « note » (`focusNotesOnAppear`), auquel cas le focus doit atterrir dans
    // les notes, pas dans le titre.
    // Tâche qui naît déjà en édition (création, insertion d'en-tête) : `onChange` ne se déclenche pas
    // (pas de transition false→true observée), on monte donc le corps ici.
    .onAppear { if isEditing { showEditor = true } }
    // Pas de sous-tâche vide : dès que le focus quitte une sous-tâche restée sans texte, on la
    // supprime (annule une création vide). Couvre aussi la fermeture de la tâche — le focus retombe
    // alors à `nil`, ce qui déclenche la vérification sur la dernière sous-tâche éditée.
    .onChange(of: focusedSubtask) { old, _ in deleteIfEmpty(old) }
    // Tâche cochée : le dépliant se referme tout seul — le détail de ce qui reste à faire n'a plus
    // d'intérêt une fois la tâche finie. Le rouvrir reste possible d'un clic sur le chevron.
    .onChange(of: task.isCompleted) { _, done in
      if done { withAnimation(.easeInOut(duration: 0.2)) { subtasksExpanded = false } }
    }
    .onChange(of: isEditing) { _, editing in
      if editing {
        // Nouvelle session : (ré)affiche le corps et invalide un démontage en attente (réouverture
        // pendant la fermeture animée).
        editSession += 1
        showEditor = true
        titleFocused = !focusNotesOnAppear
        // Réouverture alors que le corps est encore monté (fermeture en cours) : `onAppear` ne
        // rejoue pas, on redéploie ici. La 1re ouverture passe, elle, par la mesure (onPreferenceChange).
        if editorHeight > 0 { withAnimation(taskFlow) { editorReveal = editorHeight } }
      } else {
        titleFocused = false
        focusNotesOnAppear = false
        // Fermeture ANIMÉE : la fenêtre rétrécit (le clipping ravale notes + icônes, laissés
        // affichés), puis on démonte le corps une fois à 0 — sauf si une nouvelle session a redémarré.
        editSession += 1
        let token = editSession
        withAnimation(taskFlow) { editorReveal = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
          if token == editSession { showEditor = false }
        }
      }
    }
    // Pas de .animation(value:) ici : les transitions sont déclenchées en explicite
    // (withAnimation) côté page. Une ligne au repos ne porte donc rien à animer → fluide.
  }

  // MARK: Titre

  /// Le titre est UN SEUL et même `TextField` pour le repos (tâche active) ET l'édition : aucune
  /// bascule d'identité de vue entre les deux, donc SwiftUI n'échange rien. C'est ce qui
  /// supprime l'impression de « rechargement » — un `Text` au repos puis un `TextField` en
  /// édition sont deux types distincts que SwiftUI détruit/recrée en fondu croisé, d'où le
  /// shimmer sur une donnée pourtant identique.
  ///
  /// Au repos le champ ne capte pas les clics (`allowsHitTesting(false)`) : le clic va à la ligne
  /// (sélection), pas au curseur. Seule exception, une tâche complétée au repos : un `TextField`
  /// ne sait pas barrer son contenu, on rend alors un `Text` barré — cas hors de la transition.
  /// Titre : TOUJOURS le même `TextField`, y compris pour une tâche complétée. Aucune bascule
  /// `Text` ↔ `TextField` — ce qui garantit une identité de vue stable (pas de shimmer) ET une
  /// gestion clavier cohérente : un champ recréé à l'édition d'une tâche complétée avait un field
  /// editor « frais » qui avalait le premier Échap, d'où le double appui pour fermer.
  /// Le barré (qu'un `TextField` ne rend pas sur son contenu) est tracé en overlay au repos.
  private var titleView: some View {
    TextField("Nouvelle tâche", text: $task.title)
      .textFieldStyle(.plain)
      .font(.app(.body))
      .foregroundStyle(titleColor)
      .focused($titleFocused)
      .allowsHitTesting(isEditing)
      .onSubmit(onEndEditing)
      .overlay(alignment: .leading) {
        if task.isCompleted && !isEditing {
          // Trait de barré, dimensionné par un Text fantôme de même contenu/police.
          Text(task.title).font(.app(.body)).hidden()
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.secondary))
        }
      }
  }

  private var titleColor: HierarchicalShapeStyle {
    task.isCompleted ? .secondary : (task.title.isEmpty ? .tertiary : .primary)
  }

  // MARK: Corps d'édition

  private var editorBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      notesField

      HStack(spacing: 16) {
        Spacer(minLength: 0)
        dateControl
        // Seul point d'ajout d'une sous-tâche depuis l'édition : l'en-tête du dépliant, qui portait
        // un « + » redondant, a disparu au profit du résumé sur la ligne du titre.
        Button(action: addNewSubtask) {
          actionIcon("list.bullet", active: !task.subtasks.isEmpty)
        }
        .buttonStyle(.plain)
        priorityControl
      }
    }
  }

  /// `TextEditor` (et pas un `TextField`, cf. `notesBox` de la page de liste) : un `TextField`
  /// multiligne (`axis: .vertical`) n'insère pas de vrai retour à la ligne sur Entrée/Maj+Entrée,
  /// seul `TextEditor` le fait nativement. Aligné sous le titre (case 16 + espace 10), pas sous
  /// la case.
  private var notesField: some View {
    ZStack(alignment: .topLeading) {
      if task.notes.isEmpty {
        // Aucun retrait propre : le retrait est posé une seule fois sur le ZStack (padding
        // commun ci-dessous), donc le placeholder part exactement du même x que le texte tapé.
        Text("Notes")
          .foregroundStyle(.tertiary)
          .allowsHitTesting(false)
      }
      RichTextEditor(
        data: $task.notes,
        font: .app(),
        textColor: .labelColor,
        // Entrée valide la tâche (comme le titre) plutôt que d'ouvrir une ligne dans la note :
        // le retour à la ligne reste possible, mais seulement via Maj+Entrée.
        handleReturn: { shiftHeld in
          guard !shiftHeld else { return false }
          onEndEditing()
          return true
        },
        autoFocus: focusNotesOnAppear
      )
      .fixedSize(horizontal: false, vertical: true)
    }
    .font(.app(.body))
    .foregroundStyle(.secondary)
    .padding(.leading, 26)
  }

  // MARK: Fond

  /// UN SEUL fond pour les trois états, jamais deux formes qui se remplacent — c'est ce qui rend
  /// la transition select→édition fluide (la pilule GRANDIT en carte au lieu qu'une carte d'une
  /// autre forme apparaisse par-dessus). La même `RoundedRectangle` est toujours là ; seuls des
  /// nombres varient, et comme la bascule d'état est enveloppée d'un `withAnimation` côté page,
  /// SwiftUI les interpole :
  /// - `cornerRadius` 8 → 14 : le coin s'ouvre en même temps que la hauteur.
  /// - calque lavande : visible en SÉLECTION SEULE (`isSelected && !isEditing`), jamais sous la
  ///   carte. S'il restait à pleine opacité pendant l'édition, la fermeture (blanc + lavande qui
  ///   s'effacent ensemble) le laisserait transparaître une fraction de seconde sous le blanc qui
  ///   part → un flash « edit → select → normal ». Caché en édition, il n'a rien à révéler.
  /// - calque blanc : ne monte qu'en édition, par-dessus le lavande → à l'ouverture la pilule
  ///   « devient » carte (crossfade lavande→blanc sur le même rect qui grandit).
  /// - bordure : ne se révèle qu'en édition.
  /// On n'interpole PAS entre deux `Color` dynamiques (lavande accent ↔ blanc système), ce qui
  /// scintille ; on anime l'OPACITÉ de calques à couleur fixe, c'est stable.
  ///
  /// L'ombre reste à zéro hors édition : un `.shadow` réellement rendu sur chaque ligne force un
  /// rendu offscreen et fait saccader le scroll. À couleur `.clear` / rayon 0, Core Animation
  /// court-circuite la passe d'ombre — le coût n'existe que sur la ligne éditée (une seule à la fois).
  /// ponytail: si le scroll saccade malgré le rayon nul, remettre l'ombre derrière un garde d'état.
  private var rowBackground: some View {
    let radius: CGFloat = isEditing ? 14 : 8
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return ZStack {
      shape.fill(thingsSelectionFill).opacity(isSelected && !isEditing ? 1 : 0)
      shape.fill(Color(nsColor: .controlBackgroundColor)).opacity(isEditing ? 1 : 0)
      shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        .opacity(isEditing ? 1 : 0)
    }
    .shadow(
      color: .black.opacity(isEditing ? 0.18 : 0),
      radius: isEditing ? 12 : 0, y: isEditing ? 4 : 0)
  }

  // MARK: Date

  /// Tag de jour planifié (`when`), à GAUCHE du titre (cf. Things) : petit fond gris arrondi,
  /// « 31 juil. ». Distinct de l'échéance (drapeau, à droite). Rien si aucune date.
  @ViewBuilder
  private var dateTag: some View {
    if let when = task.when {
      TokenPill(text: when.formatted(.dateTime.day().month(.abbreviated)))
    }
  }

  private var dateControl: some View {
    Button {
      activePicker = .when
    } label: {
      actionIcon("calendar", active: task.when != nil)
    }
    .buttonStyle(.plain)
  }

  /// Contenu du sélecteur « Quand » (jour planifié). Posé en popover sur la ligne.
  private var whenPicker: some View {
    VStack(spacing: 10) {
      DatePicker(
        "",
        // La tâche n'a pas forcément de date : le picker en exige une. Aujourd'hui
        // sert de point de départ, écrit seulement si l'utilisateur choisit.
        selection: Binding(get: { task.when ?? Date() }, set: { task.when = $0 }),
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .labelsHidden()

      if task.when != nil {
        Divider()
        Button("Retirer la date") {
          task.when = nil
          activePicker = nil
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
  }

  // MARK: Échéance

  /// Contenu du sélecteur « Échéance » (deadline). Même gabarit que `whenPicker`.
  private var deadlinePicker: some View {
    VStack(spacing: 10) {
      DatePicker(
        "",
        selection: Binding(get: { task.deadline ?? Date() }, set: { task.deadline = $0 }),
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .labelsHidden()

      if task.deadline != nil {
        Divider()
        Button("Retirer l'échéance") {
          task.deadline = nil
          activePicker = nil
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
  }

  /// Badge d'échéance à droite de la ligne (cf. Things) : un drapeau + une date relative,
  /// rouge une fois l'échéance atteinte ou passée, gris sinon.
  @ViewBuilder
  private var deadlineBadge: some View {
    if let deadline = task.deadline {
      let overdue = daysUntil(deadline) <= 0
      HStack(spacing: 4) {
        Image(systemName: "flag.fill").font(.app(11))
        Text(deadlineLabel(deadline)).font(.app(.callout))
      }
      .foregroundStyle(overdue ? Color.red : Color.secondary)
    }
  }

  private func daysUntil(_ date: Date) -> Int {
    let cal = Calendar.current
    return cal.dateComponents(
      [.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)
    ).day ?? 0
  }

  private func deadlineLabel(_ date: Date) -> String {
    switch daysUntil(date) {
    case 0: return "aujourd'hui"
    case 1: return "dans 1 jour"
    case let d where d > 1: return "dans \(d) jours"
    case -1: return "hier"
    case let d: return "il y a \(-d) jours"
    }
  }

  /// En édition, toujours tout afficher (on manipule les sous-tâches) ; en mode normal, le repli
  /// est piloté par `subtasksExpanded`.
  private var showsSubtasks: Bool {
    !task.orderedSubtasks.isEmpty && (isEditing || subtasksExpanded)
  }

  private var subtasksSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(task.orderedSubtasks, id: \.uuid) { subtask in
        SubtaskRowView(
          subtask: subtask,
          isEditing: isEditing,
          focus: $focusedSubtask,
          onEnter: { enterOnSubtask(subtask) },
          onDelete: { removeSubtask(subtask) }
        )
        // La rangée se fond en glissant depuis le haut pendant que la carte s'ouvre ; sans
        // transition elle apparaît nette d'un coup au milieu d'une hauteur encore en mouvement.
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .transition(.opacity)
    // Aligné sur le DÉBUT DU TEXTE du titre (case 16 + espace 10 = 26), comme l'aperçu de note :
    // les cases des sous-tâches partent de cette colonne.
    .padding(.leading, 26)
    // Flèche de filiation, dans la gouttière laissée par ce retrait : elle descend de la case de la
    // tâche parente vers la PREMIÈRE sous-tâche, et elle seule — répétée sur chaque rangée, elle
    // ferait une colonne de bruit là où une seule suffit à dire « ce qui suit dépend d'au-dessus ».
    // En overlay et non dans un HStack : elle ne prend aucune place, la colonne des cases ne bouge
    // donc pas selon qu'elle est là ou non.
    .overlay(alignment: .topLeading) {
      Image(systemName: "arrow.turn.down.right")
        .font(.app(11))
        .foregroundStyle(.tertiary)
        // Largeur de la case parente : la flèche est centrée dessous, pas collée au bord.
        .frame(width: 16)
        .padding(.top, 2)
    }
    .padding(.top, isEditing ? 10 : 5)
  }

  /// Résumé du dépliant, POSÉ SUR LA LIGNE DU TITRE (à droite) et non dans un bloc sous elle :
  /// anneau de progression + « N sous-tâches » + chevron de repli. Le bloc précédent (trait +
  /// en-tête en gras sur sa propre ligne) doublait la hauteur d'une tâche à sous-tâches et cassait
  /// l'alignement de la liste ; ici la tâche garde exactement la hauteur d'une ligne simple.
  /// Absent en édition : la liste y est toujours dépliée, il n'y a rien à replier.
  private var subtasksSummary: some View {
    let total = task.subtasks.count
    let done = task.subtasks.filter(\.isDone).count
    return Button {
      withAnimation(.easeInOut(duration: 0.2)) { subtasksExpanded.toggle() }
    } label: {
      HStack(spacing: 6) {
        SubtaskProgressRing(fraction: total == 0 ? 0 : Double(done) / Double(total))
          .frame(width: 12, height: 12)
        Text("\(total) sous-tâche\(total > 1 ? "s" : "")")
          .font(.app(.callout))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
        Image(systemName: "chevron.right")
          .font(.app(11, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(subtasksExpanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Ajoute une sous-tâche vide, déplie le dépliant (pour la voir) et pose le focus dessus.
  /// `withAnimation` : sans lui la carte saute à sa nouvelle hauteur (la mutation SwiftData tombe
  /// hors transaction animée) — cf. `removeSubtask`/`deleteIfEmpty`, même raison.
  private func addNewSubtask() {
    withAnimation(taskFlow) {
      subtasksExpanded = true
      focusedSubtask = task.addSubtask().uuid
    }
  }

  /// Entrée sur une sous-tâche : vide → termine (défocalise) ; non vide → nouvelle sous-tâche + focus.
  /// ponytail: la nouvelle va toujours en FIN (pas d'insertion au milieu) — sans réordonnancement,
  /// le flux « taper, Entrée, taper » reste toujours sur la dernière, donc « en dessous » en pratique.
  private func enterOnSubtask(_ subtask: Subtask) {
    if subtask.title.trimmingCharacters(in: .whitespaces).isEmpty {
      focusedSubtask = nil
    } else {
      focusedSubtask = task.addSubtask().uuid
    }
  }

  /// Suppression d'une sous-tâche (corbeille au survol ou clic droit).
  private func removeSubtask(_ subtask: Subtask) {
    withAnimation(taskFlow) { modelContext.delete(subtask) }
  }

  /// Supprime la sous-tâche d'uuid donné si son titre est vide (appelé au départ du focus). Suppression
  /// d'un SEUL objet retrouvé par uuid — pas d'énumération de `task.subtasks` pendant la mutation
  /// (le piège qui a causé le crash `_maintainInverseRelationship`).
  private func deleteIfEmpty(_ uuid: UUID?) {
    guard let uuid,
      let subtask = task.subtasks.first(where: { $0.uuid == uuid }),
      subtask.title.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    withAnimation(taskFlow) { modelContext.delete(subtask) }
  }

  // MARK: Actions au survol / clic droit

  /// Icône discrète révélée au survol quand la tâche n'a pas encore de notes : sans elle,
  /// l'existence même du champ notes (caché derrière un double-clic) n'est pas devinable. Un clic
  /// ouvre directement l'édition avec le focus posé dans les notes (cf. `focusNotesOnAppear`).
  /// Le fondu au survol est porté par le groupe de droite (cf. `trailing`), pas ici.
  private var noteHint: some View {
    Button {
      focusNotesOnAppear = true
      onBeginEditing()
    } label: {
      Image(systemName: "note.text")
        .font(.app(13, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Aperçu de la note au repos : sa première ligne en gris, tronquée. Rappelle le CONTENU de la
  /// note sans l'ouvrir — une simple icône dirait juste « il y en a une », pas ce qu'elle contient.
  /// Aligné sous le titre (case 16 + espace 10 = 26), comme le champ d'édition. Une ligne : les
  /// retours à la ligne sont repliés en amont (cf. `NotesCodec.plainText`).
  private var notePreview: some View {
    Text(NotesCodec.plainText(task.notes))
      .font(.app(.body))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.leading, 26)
  }

  /// Colonne réservée EN PERMANENCE aux icônes de survol (note + •••), vide ou non. C'est elle qui
  /// garantit que le résumé des sous-tâches ne bouge pas quand la souris entre dans la ligne.
  private static let hoverActionsWidth: CGFloat = 54

  /// Zone de droite, collée au bord. Deux régimes, et la frontière est l'INTERACTIVITÉ :
  ///
  /// - le résumé des sous-tâches porte un chevron, donc une cible de clic. Il est ANCRÉ : la
  ///   colonne de survol lui garde sa place à droite, vide ou non. Le faire glisser comme le reste
  ///   se retournait contre l'utilisateur — il voit le chevron, il y va, et le chevron s'échappe
  ///   sous son curseur au moment précis où le survol commence. Une cible de clic ne se déplace
  ///   jamais au survol ;
  /// - le badge d'échéance ne se clique pas. Il reste SUPERPOSÉ aux icônes (ZStack) et glisse vers
  ///   la gauche pour leur céder la place — comme Things, et sans réserver d'espace à sa droite.
  ///
  /// L'animation est bornée à `value: hovering` : elle ne se recalcule qu'au survol, pas au scroll.
  private var trailing: some View {
    HStack(spacing: 8) {
      if !task.subtasks.isEmpty { subtasksSummary }
      ZStack(alignment: .trailing) {
        deadlineBadge.offset(x: hovering ? -Self.hoverActionsWidth : 0)
        HStack(spacing: 6) {
          if task.notes.isEmpty { noteHint }
          Menu {
            taskMenu
          } label: {
            Image(systemName: "ellipsis")
              .font(.app(14, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 22, height: 22)
              .contentShape(Rectangle())
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
        // Largeur FIXE, pas la largeur réelle du contenu : sans elle la colonne vaudrait 54 pt sur
        // une tâche sans notes et 26 sur une tâche qui en a, et le résumé ne serait plus aligné
        // d'une ligne à l'autre.
        .frame(width: Self.hoverActionsWidth, alignment: .trailing)
        .opacity(hovering ? 1 : 0)
      }
    }
    .animation(.easeOut(duration: 0.15), value: hovering)
  }

  /// Cibles de classement groupées par projet, les listes libres en dernier — un projet est ce
  /// qu'on cherche d'abord quand on range une tâche qui traîne. `filter` plutôt qu'un `sorted` :
  /// le tri de Swift n'est pas stable, il aurait mélangé l'ordre des projets entre eux.
  private var targetsByProject: [(project: String?, lists: [TodoList])] {
    var order: [String?] = []
    var buckets: [String?: [TodoList]] = [:]
    for target in moveTargets {
      let key = target.project?.title
      if buckets[key] == nil { order.append(key) }
      buckets[key, default: []].append(target)
    }
    let sorted = order.filter { $0 != nil } + order.filter { $0 == nil }
    return sorted.map { (project: $0, lists: buckets[$0] ?? []) }
  }

  /// Menu partagé par le ••• et le clic droit.
  @ViewBuilder
  private var taskMenu: some View {
    Button {
      activePicker = .when
    } label: {
      Label("Quand…", systemImage: "calendar")
    }
    Menu {
      if moveTargets.isEmpty {
        Text("Aucune autre liste")
      } else {
        ForEach(targetsByProject, id: \.project) { group in
          // Un projet ne porte pas de tâche directement (cf. `Project`) : l'« assigner à un
          // projet » revient à choisir l'une de ses listes, d'où le sous-menu.
          if let project = group.project {
            Menu(project) {
              ForEach(group.lists) { target in
                Button(target.title) { onMove(target) }
              }
            }
          } else {
            ForEach(group.lists) { target in
              Button(target.title) { onMove(target) }
            }
          }
        }
      }
    } label: {
      // Une tâche sans projet n'est pas « déplacée », elle est CLASSÉE — c'est le geste qui
      // manquait à la page « Tâches », où tout le non-classé arrive.
      Label(
        task.project == nil ? "Assigner la tâche" : "Déplacer vers…", systemImage: "arrow.right")
    }
    Button {
      activePicker = .deadline
    } label: {
      Label("Échéance…", systemImage: "flag")
    }
    // Durée estimée : elle n'a d'effet visible que dans « Aujourd'hui » (la barre de capacité),
    // mais elle se pose ici, là où l'on planifie.
    Menu {
      ForEach(Estimate.presets, id: \.self) { minutes in
        Button(Estimate.label(minutes) ?? "") { task.estimateMinutes = minutes }
      }
      if task.estimateMinutes > 0 {
        Divider()
        Button("Retirer la durée") { task.estimateMinutes = 0 }
      }
    } label: {
      Label("Durée…", systemImage: "timer")
    }
    Button {
      showReminderSheet = true
    } label: {
      Label(
        task.reminderIdentifier == nil ? "Envoyer vers Rappels…" : "Modifier le rappel…",
        systemImage: "bell")
    }
    Divider()
    Button {
      onDuplicate()
    } label: {
      Label("Dupliquer", systemImage: "plus.square.on.square")
    }
    Button(role: .destructive) {
      onDelete()
    } label: {
      Label("Supprimer", systemImage: "trash")
    }
  }

  // MARK: Priorité

  private var priorityControl: some View {
    Menu {
      // `.none` est dans allCases : il fait office de « retirer », pas besoin d'un bouton
      // séparé.
      ForEach(Priority.allCases) { priority in
        Button {
          task.priority = priority
        } label: {
          Label(priority.label, systemImage: priority.systemImage)
        }
      }
    } label: {
      actionIcon("flag", active: task.priority != .none, tint: task.priority.color)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  /// Icône de la rangée d'actions : éteinte tant que rien n'est défini, teintée dès qu'une
  /// valeur existe.
  private func actionIcon(_ name: String, active: Bool = false, tint: Color? = nil) -> some View {
    Image(systemName: name)
      .font(.app(15))
      .foregroundStyle(
        active
          ? (tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.accentColor))
          : AnyShapeStyle(.secondary)
      )
      .frame(width: 22, height: 22)
      .contentShape(Rectangle())
  }
}
