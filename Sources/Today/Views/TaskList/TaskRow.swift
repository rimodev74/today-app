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
  /// Respiration de la carte d'édition, en place du `rowInset` d'une ligne au repos. Nommée parce
  /// que le retrait gauche s'en déduit, pour que la case ne bouge pas au clic.
  private static let editInset: CGFloat = 16

  @Bindable var task: TaskItem
  let isSelected: Bool
  let isEditing: Bool
  /// Listes vers lesquelles déplacer la tâche (toutes sauf la sienne).
  var moveTargets: [TodoList]
  /// Faux dans « Aujourd'hui » : la page ne montre QUE le jour même, la date répétée sur chaque
  /// ligne n'apprend rien. Elle reste indispensable dans une liste, qui mélange les échéances.
  var showsDate: Bool = true
  /// Rattachement affiché devant le titre. `nil` dans une page de liste (on sait déjà où l'on
  /// est) ; renseigné dans « Aujourd'hui », qui mélange les provenances.
  var parentTag: TaskParentTag? = nil
  var onBeginEditing: () -> Void
  var onEndEditing: () -> Void
  var onMove: (TodoList) -> Void
  var onDuplicate: () -> Void
  var onDelete: () -> Void
  /// Cocher/décocher : la page décide ce qu'elle en fait (ici, programmer l'archivage).
  var onCompletionChanged: () -> Void
  /// La ligne VOYAGE : ses sous-tâches se replient le temps du geste, quel que soit l'état du
  /// chevron, et il ne part sous le curseur que le titre.
  ///
  /// Une tâche à huit sous-tâches ouvrait sinon un trou de neuf lignes derrière elle : les cadres
  /// sont GELÉS à l'empoignade, donc la hauteur retenue pour le trou, le calque et l'écartement des
  /// voisines était celle de la ligne DÉPLIÉE. D'où le séquencement côté page — replier d'abord,
  /// empoigner ensuite (cf. `ListPageView.dragGesture`) : le repli doit avoir eu sa passe de mise en
  /// page AVANT que le gel n'arrive, sinon on replie l'image sans corriger le calcul.
  ///
  /// Valeur par défaut assumée, contrairement à `TaskPageBase.reorder` : une page sans glissement
  /// n'a rien à replier, `false` n'y est pas un oubli.
  var collapsedForDrag: Bool = false

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  /// Focus de la sous-tâche en cours d'édition (clé = uuid stable, pas `persistentModelID` qui
  /// mute à l'autosave), pour poser le focus sur celle qu'on vient de créer.
  /// uuid de la sous-tâche à focaliser (clé de focus stable, cf. `SubtaskRowView`).
  @FocusState private var focusedSubtask: UUID?
  /// Dépliant de sous-tâches ouvert/fermé : permet de replier une longue checklist pour ne pas
  /// surcharger la tâche.
  ///
  /// `nil` = « pas encore touché sur cette vue » et non « fermé » : `isSubtasksExpanded` retombe
  /// alors sur ce que `SubtaskExpansion` a retenu du dernier lancement. Sans cet état à trois
  /// valeurs, il faudrait un `init` explicite pour poser la valeur de départ (les pages construisent
  /// `TaskRow` par son init mémberwise), ou la lire dans un `onAppear` — auquel cas une tâche
  /// repliée s'afficherait ouverte une image avant de se refermer sous les yeux.
  @State private var subtasksExpanded: Bool?

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
  @State private var showReminderSheet = false

  // UN SEUL popover à la fois. Deux `.popover(isPresented:)` sur la même vue = comportement
  // indéfini sur macOS (le second plantait à l'ouverture de l'échéance). Un seul `.popover(item:)`
  // dont le contenu dépend du champ édité.
  @State private var activePicker: TaskDateField?

  enum TaskDateField: String, Identifiable {
    case when
    var id: String { rawValue }
  }

  /// Ouvre un panneau de date. Un seul point d'entrée pour les trois chemins (icône au survol,
  /// menu ▸ *Quand…*, carte d'édition) — sans quoi ils divergeraient au premier réglage ajouté.
  private func openDatePicker(_ task: TaskItem, _ field: TaskDateField) {
    activePicker = field
  }

  /// UN SEUL arbre de vues, jamais un if/else entre deux racines : c'est ce qui rend la
  /// transition fluide. La ligne titre (case + titre) est TOUJOURS là et garde son identité ;
  /// l'édition ne fait qu'ajouter le corps sous elle et grossir le padding. SwiftUI a donc une
  /// hauteur continue à animer — un if/else échangerait deux vues d'un coup, d'où le « snap ».
  var body: some View {
    // UNE traversée de la relation pour toute la rangée, distribuée ensuite (cf. `SubtaskTally`).
    let subtasks = SubtaskTally(task)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        TaskCheckbox(isCompleted: task.isCompleted) {
          withAnimation(taskInsert) {
            task.toggleCompletion()
            if task.isCompleted {
              task.list?.moveToEndOfSection(task)
            } else {
              task.list?.moveAboveCompleted(task)
            }
          }
          Task { await remindersService.pushCompletion(for: task) }
          onCompletionChanged()
        }
        if !isEditing { dateTag }
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
        // DEVANT le titre, avec la date et la durée, et pas après lui. Le titre est un `TextField`,
        // donc glouton : il prend toute la largeur restante, et tout ce qui le suit se retrouve
        // collé au bord droit de la fenêtre quelle que soit la longueur du texte. C'est ce que
        // faisait ce libellé — une colonne de gris en dents de scie, détachée des titres qu'elle
        // qualifie. Ici il rejoint le cluster des attributs de la tâche (quand, combien de temps,
        // d'où), qui est fixe et se lit d'un bloc avec le titre.
        // Toujours sur UNE ligne : la ligne garde la hauteur qu'elle a dans une page de liste,
        // l'ouverture de la carte d'édition reste donc continue.
        if !isEditing, let parentTag { parentPill(parentTag) }
        titleView
        Spacer(minLength: 0)
        if !isEditing { trailing(subtasks) }
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
      if showsSubtasks(subtasks) { subtasksSection }
    }
    // Ajout/suppression d'une sous-tâche : `withAnimation` autour de la mutation ne suffit PAS —
    // SwiftData notifie le changement de relation hors de la transaction, la carte sautait donc à sa
    // nouvelle hauteur. On anime ici sur le compte, qui, lui, est observé au rendu.
    .animation(taskFlow, value: subtasks.total)
    // PAS de `.clipped()` ici. Il y en avait un, « pour borner le contenu pendant que la carte
    // s'ouvre » — écrit quand une ligne avait une hauteur FIXE. Depuis que le titre est un
    // `TextField(axis: .vertical)`, la hauteur d'une ligne dépend du repli de son texte, donc de la
    // largeur qui lui reste : cocher une tâche la fait descendre (`moveToEndOfSection`), la colonne
    // d'icônes de survol change la largeur utile au passage, le texte se replie autrement — et le
    // clip COUPAIT ce qui dépassait pendant toute l'animation. Le seul contenu qui a vraiment besoin
    // d'être borné, c'est la fenêtre de révélation de l'éditeur, et elle porte déjà son propre
    // `.clipped()` sur son `frame(height: editorReveal)` (cf. plus haut). Celui-ci n'ajoutait que
    // le défaut.
    // Décrue : une tâche que personne ne réveille s'efface. Posé sur le CONTENU seulement (avant
    // `.background`), pour que le fond de sélection reste franc — c'est la tâche qui pâlit, pas
    // le fait qu'elle soit sélectionnée. Pleine opacité dès qu'on l'édite : on la touche, elle
    // redevient nette le temps qu'on s'en occupe.
    .opacity(isEditing ? 1 : task.dormancyFade)
    // PAS de `.animation(value: isEditing)` ici, et c'est le correctif du 6 août 2026 : il y en
    // avait un (`.easeOut(0.2)`), et il COUPAIT la carte en deux.
    //
    // Un `.animation(_:value:)` ne s'applique qu'à ce qui le PRÉCÈDE dans la chaîne. Celui-ci
    // couvrait donc le contenu (titre, éditeur, sous-tâches) mais PAS ce qui suit — les paddings,
    // le fond, le rayon du coin. À l'ouverture, le contenu partait en `easeOut(0.2)` pendant que le
    // cadre partait en `taskFlow` (`timingCurve(0.4, 0, 0.2, 1)`), déclenché par le `withAnimation`
    // de la page. Deux courbes de même durée mais de forme différente sur UNE seule transition :
    // le contenu prend de l'avance au début, le cadre le rattrape à la fin, et la carte se déforme
    // en s'ouvrant. C'est ce que « ça ne fait pas natif » désignait.
    //
    // Retiré plutôt qu'aligné : les CINQ pages enveloppent déjà toutes leurs transitions d'édition
    // dans `withAnimation(taskFlow)` (vérifié site par site), il n'y a donc rien à rattraper ici.
    // C'est aussi ce que la convention du projet demande — les transitions se déclenchent en
    // explicite, côté page.
    // Le padding grandit en édition : la hauteur de la carte s'ouvre autour du titre resté en place.
    // Sélection et normal partagent le même padding — le texte ne saute donc pas au clic simple.
    // Bas en édition : les sous-tâches sont désormais le dernier élément de la carte (après
    // l'éditeur), il leur faut une respiration jusqu'au bord bas.
    .padding(.top, isEditing ? 16 : 4)
    // Au repos, une tâche DÉPLIÉE finit sur une rangée de sous-tâche et non sur son titre : il lui
    // faut un peu plus de fond que les 4 pt d'une ligne simple. Repliée, elle EST une ligne simple.
    .padding(.bottom, isEditing ? 14 : (showsSubtasks(subtasks) ? 8 : 4))
    .padding(.horizontal, isEditing ? Self.editInset : rowInset)
    .background { rowBackground }
    // Le bloc ENTIER glisse (fond ET case), le retrait interne reste intact : la case tombe sur
    // `taskRowColumn`, donc sur le TEXTE d'une en-tête, et le fond un `rowInset` avant, à l'aplomb
    // de la pilule de cette en-tête. En édition, le retrait interne passe à `editInset` : on retire
    // d'autant à gauche pour que la case ne BOUGE PAS au clic — la carte s'ouvre autour d'elle, en
    // débordant seulement de ce qu'elle a gagné en respiration.
    .padding(.leading, isEditing ? taskRowColumn - Self.editInset : taskContentColumn)
    .contentShape(Rectangle())
    // Survol : révèle le ••• à droite. Clic droit : même menu que le •••, via contentShape ;
    // bascule aussi en édition, via `RightClickObserver` posé par la page (cf. ce type).
    .onHover { hovering = $0 }
    .contextMenu { taskMenu }
    // Les deux panneaux de date, posés sur la ligne (pas sur un bouton du menu, qui disparaît hors
    // survol) : ils ont ainsi toujours une ancre valide, en repos comme en édition.
    //
    // Ils se referment DERRIÈRE le choix (cf. `WhenPicker.dayBinding`) : écrire une date retrie la
    // liste, donc déplace la rangée qui sert d'ancre — et une fenêtre enfant ré-affichée sur une
    // ancre qui bouge est ce qui plantait (`NSPopover showRelativeToRect:` → `addChildWindow` →
    // `NSRemoteView`, trois rapports le 5 août 2026).
    .popover(item: $activePicker, arrowEdge: .trailing) { field in
      switch field {
      case .when: WhenPicker(task: task) { activePicker = nil }
      }
    }
    .sheet(isPresented: $showReminderSheet) {
      SchedulePlannerView(task: task, remindersService: remindersService)
    }
    // Le défilement referme le panneau : la rangée qui lui sert d'ancre s'en va sous lui. Monté
    // seulement quand il y en a un d'ouvert — un moniteur par rangée en permanence ferait passer
    // chaque cran de molette par toute la page.
    .background {
      if activePicker != nil {
        ScrollDismissObserver { activePicker = nil }
      }
    }
    // Ces deux états pilotent une FENÊTRE, hors de l'arbre de vues : ils survivraient au démontage
    // de la rangée, et leurs contenus tiennent la tâche en `@Bindable` — laissés ouverts, ils
    // liraient un modèle effacé. On referme donc en partant. Le survol, la sélection, l'édition
    // meurent avec la rangée : rien à faire pour eux.
    //
    // Ce commentaire invoquait le `LazyVStack` des pages de liste (« une rangée qui sort de l'écran
    // est démontée »). Il n'y en a plus — les trois pages qui glissent sont en `VStack` (cf.
    // l'en-tête de `TaskListView`). La raison qui RESTE est la vraie : la tâche peut partir
    // d'ailleurs, sans que la rangée n'y soit pour rien (⌘Z, synchro Rappels, suppression depuis
    // une autre fenêtre).
    .onDisappear {
      activePicker = nil
      showReminderSheet = false
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
    // NON retenu, contrairement au clic sur le chevron : c'est une conséquence de la coche, pas une
    // préférence de repli. Décochée puis relancée, la tâche retrouve l'état que l'on avait CHOISI.
    .onChange(of: task.isCompleted) { _, done in
      if done { withAnimation(disclosureFlow) { subtasksExpanded = false } }
    }
    .onChange(of: isEditing) { _, editing in
      if editing {
        // Nouvelle session : (ré)affiche le corps et invalide un démontage en attente (réouverture
        // pendant la fermeture animée).
        editSession += 1
        showEditor = true
        // Toujours le titre : c'est le seul champ qu'on ouvre. Il y avait une exception quand
        // l'édition partait de l'icône « note » du survol, retirée depuis.
        //
        // DÉCALÉ D'UN TICK, et dans `taskFlow` : les deux sont délibérés, et un `titleFocused = true`
        // posé nu ici fige la hauteur du champ à 0 pour toute la session d'édition. Le mécanisme et
        // la mesure sont dans `PIEGES.md` § Layout.
        let session = editSession
        DispatchQueue.main.async {
          guard session == editSession else { return }
          withAnimation(taskFlow) { titleFocused = true }
        }
        // Réouverture alors que le corps est encore monté (fermeture en cours) : `onAppear` ne
        // rejoue pas, on redéploie ici. La 1re ouverture passe, elle, par la mesure (onPreferenceChange).
        if editorHeight > 0 { withAnimation(taskFlow) { editorReveal = editorHeight } }
      } else {
        titleFocused = false
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
    // Les transitions d'ÉTAT (normal ↔ select ↔ édition) sont déclenchées en explicite
    // (`withAnimation`) côté page : une ligne au repos ne porte rien à animer pour elles.
    //
    // Ce commentaire affirmait « Pas de .animation(value:) ici ». C'était faux — il y en avait
    // trois, dont une qui cassait l'ouverture de la carte (cf. plus haut). Il en reste DEUX, et
    // chacune anime quelque chose que le `withAnimation` de la page ne peut pas atteindre :
    //
    // - `value: task.subtasks.count` — SwiftData notifie un changement de relation HORS de la
    //   transaction, un `withAnimation` autour de la mutation ne le capture donc pas ;
    // - `value: hovering` dans `trailing` — le survol est un état local à la rangée, aucune page
    //   ne le déclenche.
    //
    // La règle qui s'en dégage, et qui vaut pour la prochaine : un `.animation(value:)` ne se
    // justifie que pour un changement qu'AUCUNE transaction de page ne couvre. Dès qu'une page
    // pilote l'état, c'est elle qui anime, et un modificateur posé ici entre en concurrence avec
    // elle sur une partie seulement de la rangée.
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
  ///
  /// `axis: .vertical` : un titre trop long pour la ligne REVIENT à la ligne au lieu de déborder du
  /// viewport (`TextField` à axe horizontal ne fait jamais ça, il défile en interne sans jamais
  /// grandir). Pas de `lineLimit` : la tâche s'affiche en entier, quelle que soit sa longueur.
  /// Enter n'insère jamais de retour à la ligne dans un titre — un champ vertical le ferait par
  /// défaut (le field editor absorbe Entrée avant `onSubmit`, qui ne se déclenche plus dans ce
  /// mode), d'où l'interception : Entrée termine TOUJOURS l'édition, comme avant.
  private var titleView: some View {
    TextField("Nouvelle tâche", text: $task.title, axis: .vertical)
      .textFieldStyle(.plain)
      .font(.app(.body))
      .foregroundStyle(titleColor)
      .focused($titleFocused)
      .allowsHitTesting(isEditing)
      // `allowsHitTesting` ne ferme que la porte de la SOURIS. Le champ restait dans la boucle de
      // tabulation d'AppKit, donc « attrapable » au clavier — et AppKit attrape tout seul : quand
      // une fenêtre auxiliaire se referme (le panneau de date), il repose le premier répondeur sur
      // le premier champ texte venu de la fenêtre. Résultat mesuré le 5 août 2026 : le curseur
      // atterrissait dans le titre d'une tâche AU HASARD, éditable sans que la ligne soit en
      // édition — donc sans le `withAnimation`, sans la carte ouverte, et sans que ⌫ ni ↑/↓ ne
      // sachent qu'un champ avait la main.
      //
      // C'est le même défaut que `WindowConfigurator` neutralise au lancement avec
      // `makeFirstResponder(nil)` : lui traite le symptôme une fois, celui-ci ferme la porte.
      .focusable(isEditing)
      .onKeyPress(phases: .down) { press in
        guard press.key == .return else { return .ignored }
        onEndEditing()
        return .handled
      }
      // Le champ s'efface DERRIÈRE le barré, il ne disparaît pas. Un `if` entre `Text` et
      // `TextField` échangerait deux identités de vue (shimmer + field editor neuf, cf. plus haut) ;
      // l'opacité garde la même vue, le même focus, la même hauteur. Sans ça, les deux textes se
      // superposaient — le champ affichant toujours le sien sous celui de l'overlay, et les deux ne
      // se repliant pas forcément aux mêmes endroits sur un titre long.
      .opacity(isStruck ? 0 : 1)
      .overlay(alignment: .leading) {
        if isStruck {
          // Un `Text` réel plutôt que le `TextField` : lui seul rend `.strikethrough`, et il
          // revient à la ligne comme le champ qu'il recouvre — un simple trait tracé à la main
          // n'aurait barré qu'une ligne sur un titre replié en plusieurs.
          Text(task.title).font(.app(.body)).foregroundStyle(titleColor).strikethrough()
        }
      }
  }

  /// Le titre se rend barré : tâche cochée, et pas en cours d'édition (on édite un titre lisible,
  /// jamais un titre barré).
  private var isStruck: Bool { task.isCompleted && !isEditing }

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
        }
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
  /// « 31 juil. », « 31 juil. 14:30 » si la tâche porte une heure. Distinct de l'échéance (drapeau,
  /// à droite). Rien si aucune date.
  ///
  /// Sur une page qui ne montre pas les dates (« Aujourd'hui », où le jour est implicite), l'HEURE
  /// reste affichée seule : c'est la seule chose que la page ne dit pas déjà, et c'est justement ce
  /// qui ordonne une journée.
  @ViewBuilder
  private var dateTag: some View {
    if let when = task.when {
      // Chaque libellé est mis en forme DANS la branche qui l'affiche, jamais au-dessus : une date
      // formatée pour toutes les lignes de toutes les pages puis jetée par « Aujourd'hui » (qui ne
      // montre que l'heure) n'est pas gratuite, et une ligne se redessine plusieurs fois par image
      // pendant une animation.
      if showsDate {
        TokenPill(text: TokenPill.schedule(when, minutes: task.whenMinutes))
      } else if let minutes = task.whenMinutes {
        TokenPill(text: TokenPill.time(minutes))
      }
    }
  }

  /// La provenance de la tâche, en pastille : un point de la couleur du projet, puis son nom.
  ///
  /// Teintée plutôt que grise parce que c'est ce que la couleur sert déjà à dire ailleurs — c'est
  /// la même que l'icône du projet dans la sidebar et que ses anneaux de progression. Une page qui
  /// mélange les provenances devient donc lisible d'un coup d'œil, sans lire les noms.
  /// Gris quand il n'y a pas de couleur à montrer : une liste hors projet n'en porte pas.
  ///
  /// ponytail: pas de largeur maximale — un nom de projet à rallonge rognerait la place du titre.
  /// Si ça arrive, `.frame(maxWidth:)` sous le `fixedSize` avec `.truncationMode(.tail)`.
  private func parentPill(_ tag: TaskParentTag) -> some View {
    // Toutes dynamiques (`PaletteColor` passe par les `systemXxx`, `.primary`/`.secondary` sont
    // hiérarchiques) : rien à doubler pour le mode sombre.
    let tint = tag.color?.color
    return HStack(spacing: 4) {
      Circle()
        .fill(tint ?? Color.secondary)
        .frame(width: 5, height: 5)
      Text(tag.title)
        .font(.app(11, weight: .medium))
        .lineLimit(1)
    }
    .foregroundStyle(tint ?? Color.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(tint?.opacity(0.12) ?? Color.primary.opacity(0.06), in: Capsule())
    .fixedSize()
  }

  private var dateControl: some View {
    Button {
      openDatePicker(task, .when)
    } label: {
      actionIcon("calendar", active: task.when != nil)
    }
    .buttonStyle(.plain)
  }

  /// L'état du dépliant : celui de cette vue s'il a été touché, sinon celui retenu du dernier
  /// lancement. Un simple appel de `Set.contains` — pas de lecture de `UserDefaults` par rangée
  /// (cf. `SubtaskExpansion`).
  private var isSubtasksExpanded: Bool {
    subtasksExpanded ?? SubtaskExpansion.isExpanded(task)
  }

  /// En édition, toujours tout afficher (on manipule les sous-tâches) ; en mode normal, le repli
  /// est piloté par `isSubtasksExpanded` — et le temps d'un glissement, par `collapsedForDrag`, qui
  /// l'emporte sur les deux.
  private func showsSubtasks(_ subtasks: SubtaskTally) -> Bool {
    !collapsedForDrag && !subtasks.isEmpty && (isEditing || isSubtasksExpanded)
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
  private func subtasksSummary(_ subtasks: SubtaskTally) -> some View {
    let total = subtasks.total
    return Button {
      // Le SEUL geste qui exprime une préférence, donc le seul qu'on retienne. `withAnimation`
      // enveloppe l'écriture du `@State`, qui est ce qui rend ; l'enregistrement à côté n'a pas à
      // entrer dans la transaction (cf. `SubtaskExpansion`).
      let next = !isSubtasksExpanded
      withAnimation(disclosureFlow) { subtasksExpanded = next }
      SubtaskExpansion.set(next, for: task)
    } label: {
      HStack(spacing: 6) {
        SubtaskProgressRing(fraction: subtasks.fraction)
          .frame(width: 12, height: 12)
        Text("\(total) sous-tâche\(total > 1 ? "s" : "")")
          .font(.app(.callout))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
        Image(systemName: "chevron.right")
          .font(.app(11, weight: .semibold))
          .foregroundStyle(.tertiary)
          // Sur `showsSubtasks` et non sur `subtasksExpanded` : pendant un glissement le dépliant
          // est fermé sans que le chevron n'ait été touché, et un chevron qui pointe vers le bas
          // au-dessus de rien est un mensonge à l'écran.
          .rotationEffect(.degrees(showsSubtasks(subtasks) ? 90 : 0))
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

  // L'icône « note » a été RETIRÉE du survol. Elle existait pour rendre le champ notes devinable,
  // mais son geste — ouvrir l'édition de la tâche — est déjà celui du clic sur la ligne, et le
  // double emploi se voyait : posée à côté de l'icône calendrier, qui elle fait quelque chose de
  // précis SANS ouvrir l'édition, elle donnait deux icônes voisines dont une seule tenait la
  // promesse de son affordance. Le champ notes reste atteignable par le clic sur la ligne et par
  // le menu ▸ ••• , et son aperçu (`notePreview`) dit déjà qu'il y a quelque chose à lire.

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

  /// Icône « calendrier » au survol : elle ouvre le sélecteur « Quand » SUR-LE-CHAMP, sans passer
  /// par l'édition. C'est le geste que son affordance promet — avant, l'icône n'existait que dans
  /// la carte d'édition, donc dater une tâche demandait d'abord de l'ouvrir, puis de recliquer au
  /// même endroit. C'est le MÊME panneau que le menu ▸ *Quand…* et que celui de la carte d'édition :
  /// les trois chemins passent par `openTaskDatePicker`, un seul panneau, présenté par la page.
  private var dateHint: some View {
    Button {
      openDatePicker(task, .when)
    } label: {
      Image(systemName: "calendar")
        .font(.app(13, weight: .regular))
        .foregroundStyle(task.when != nil ? Color.accentColor : Color.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Quand…")
  }

  /// Colonne réservée EN PERMANENCE aux icônes de survol (calendrier + •••), vide ou non. C'est
  /// elle qui garantit que le résumé des sous-tâches ne bouge pas quand la souris entre dans la
  /// ligne. Deux icônes : la même largeur qu'avant l'ajout du calendrier, qui a simplement pris la
  /// place de l'icône « note » retirée.
  private static let hoverActionsWidth: CGFloat = 54

  /// Zone de droite, collée au bord. Le résumé des sous-tâches porte un chevron, donc une cible de
  /// clic : il est ANCRÉ, la colonne de survol lui garde sa place à droite, vide ou non. Le faire
  /// glisser comme le reste se retournait contre l'utilisateur — il voit le chevron, il y va, et le
  /// chevron s'échappe sous son curseur au moment précis où le survol commence. Une cible de clic ne
  /// se déplace jamais au survol.
  ///
  /// L'animation est bornée à `value: hovering` : elle ne se recalcule qu'au survol, pas au scroll.
  private func trailing(_ subtasks: SubtaskTally) -> some View {
    HStack(spacing: 8) {
      if !subtasks.isEmpty { subtasksSummary(subtasks) }
      HStack(spacing: 6) {
        dateHint
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
    // Les deux mêmes raccourcis qu'en tête de `WhenPicker`, mêmes symboles : c'est le même geste,
    // il ne peut pas se présenter autrement d'un endroit à l'autre. Le panneau reste pour le reste.
    Button {
      task.when = Calendar.current.startOfDay(for: Date())
    } label: {
      Label("Aujourd'hui", systemImage: "star.fill")
    }
    Button {
      let today = Calendar.current.startOfDay(for: Date())
      task.when = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
    } label: {
      Label("Demain", systemImage: "sunrise.fill")
    }
    Button {
      openDatePicker(task, .when)
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
