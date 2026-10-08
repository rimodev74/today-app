import AppKit
import EventKit
import SwiftData
import SwiftUI

struct ContentView: View {
  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  /// Celui de la fenêtre : c'est lui que le menu *Édition ▸ Annuler* atteint (cf. `.onChange`
  /// plus bas, qui le donne au contexte SwiftData).
  @Environment(\.undoManager) private var undoManager

  /// Les raccourcis de saisie rapide (abréviations et combinaisons globales) qui visent une LISTE
  /// portent son nom au jour où ils ont été posés (cf. `reconcileShortcuts`) — lus ici pour pouvoir
  /// les corriger dès qu'une liste est renommée, pas seulement quand les Réglages sont ouverts.
  @AppStorage(TextShortcut.storageKey) private var textShortcutData = Data()
  @AppStorage(KeyShortcut.storageKey) private var keyShortcutData = Data()

  /// La synchro avec Rappels et Calendrier (cf. `RemindersSyncPass`). Créée à la première
  /// notification : elle a besoin du contexte et du service, que l'environnement ne donne qu'au
  /// rendu. Une par fenêtre, comme avant — c'est le verrou du service qui les sérialise.
  @State private var reminderSync: RemindersSyncPass?

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
  /// Les fichiers écartés par `StoreQuarantine` au lancement, s'il y en a eu (cf. l'alerte).
  /// Vide 999 fois sur 1000 — c'est un signal de bug, pas une routine.
  @State private var quarantinedPaths: [String] = []
  /// Le rangement d'une tâche par glisser vers la barre latérale. Il vit ICI parce que c'est le
  /// seul ancêtre commun des deux colonnes : la page publie la ligne en vol, la sidebar publie ses
  /// lignes d'accueil, et la fenêtre dessine le calque par-dessus les deux (cf. `SidebarDrop`).
  @State private var filing = SidebarDrop()
  @State private var grabberHovered = false
  /// Survol de la sidebar elle-même. État SÉPARÉ de `grabberHovered` (et pas le même drapeau posé
  /// des deux côtés) : les deux zones se touchent, et rien ne garantit que SwiftUI livre la sortie
  /// de l'une avant l'entrée dans l'autre — un seul drapeau clignoterait au passage de la frontière.
  @State private var sidebarHovered = false
  /// L'écran d'accueil affiché, ou `nil`. Un `@State` et pas le drapeau des défauts lu en direct :
  /// l'écriture d'un `@AppStorage` échappe à la transaction animée, et l'accueil disparaîtrait sec
  /// (cf. CLAUDE.md § Animations). Sa valeur de départ est tranchée AVANT que la fenêtre existe
  /// (cf. `TodayApp.onboardingPending`) : elle en décide la taille.
  @State private var onboarding: OnboardingStep? = TodayApp.onboardingPending ? .welcome : nil

  /// Le mors se montre dès que la souris est quelque part sur la sidebar OU sur la bande qui la
  /// longe : on ne le cherche pas, il est déjà là quand on arrive au bord.
  private var grabberVisible: Bool { grabberHovered || sidebarHovered }

  /// L'alerte se ferme en vidant la liste : c'est ELLE l'état, pas un second booléen à tenir
  /// synchronisé avec (cf. la règle « avant d'ajouter un `@State`, chercher celui qui porte déjà
  /// ce comportement »).
  private var quarantineAlertPresented: Binding<Bool> {
    Binding(get: { !quarantinedPaths.isEmpty }, set: { if !$0 { quarantinedPaths = [] } })
  }

  /// La couleur de la destination courante, calculée UNE fois ici et distribuée par
  /// l'environnement (cf. `EnvironmentValues.pageTint`). La fenêtre est le seul endroit qui
  /// connaisse la sélection ET qui coiffe les deux colonnes : le lavis du fond et les rangées
  /// doivent lire la même valeur, sans quoi une page s'ambiancerait en orange avec des cases
  /// violettes.
  private var tint: Color { selection?.tint ?? PageTint.inbox }

  /// Ce que le layout affiche vraiment : le drag en cours s'il y en a un, sinon l'état validé.
  private var effectiveWidth: Double {
    dragWidth ?? (sidebarVisible ? sidebarWidth : 0)
  }

  /// Largeur à laquelle le CONTENU est mis en page — distincte de celle qu'on laisse voir.
  /// HORS drag elle vaut la largeur de repos : replier n'est alors qu'un rognage, rien ne se
  /// réorganise. C'est ce qui manquait au repli — le contenu était mis en page à
  /// `max(largeur visible, minSidebarWidth)`, donc il se tassait de 260 à 200 avant de commencer à
  /// être rogné. Invisible sur ce qui est aligné à gauche, flagrant sur la barre du bas, dont le
  /// bouton des réglages est collé à droite par un `Spacer` : il glissait vers la gauche pendant
  /// que tout le reste, lui, était simplement coupé.
  private var layoutWidth: Double {
    guard let dragWidth else { return sidebarWidth }
    return max(dragWidth, Self.minSidebarWidth)
  }

  /// LE verre, posé UNE fois pour toute la fenêtre — et surtout pas une fois par colonne.
  ///
  /// La fenêtre est non opaque (cf. `WindowConfigurator`) : tout pixel que personne ne peint
  /// laisse voir le bureau EN CLAIR, non flouté. Avec un matériau par colonne, le `Divider` qui
  /// les sépare n'était couvert par aucun des deux — d'où la bande de bureau nette sur toute la
  /// hauteur de la fenêtre. Le corriger au séparateur seul aurait laissé le défaut vivant pour le
  /// prochain élément posé entre deux fonds ; un seul calque de verre sous TOUT le contenu rend le
  /// trou impossible, où qu'il s'ouvre.
  ///
  /// Un seul matériau pour les deux colonnes, donc : ce sont leurs voiles qui les distinguent, et
  /// c'était déjà eux qui faisaient l'essentiel de l'écart.
  private var windowGlass: some View {
    WindowGlass(material: .underWindowBackground).ignoresSafeArea()
  }

  /// La colonne qu'on LIT : voile plus couvrant que celui de la sidebar, plus le lavis de la
  /// destination courante. Les trois couches ont chacune leur rôle et aucune ne remplace l'autre —
  /// le verre donne l'ambiance du bureau, le voile rend le texte lisible par-dessus, le lavis dit
  /// sur quelle page on est.
  ///
  /// Sortie du `body` pour le type-checker, pas par goût : la chaîne de la fenêtre est déjà longue
  /// et un `.overlay` de plus la faisait dépasser son budget de résolution.
  /// ponytail: façon Réglages Système (fenêtre entièrement en matériau) plutôt que Finder/Mail,
  /// qui gardent une zone de contenu OPAQUE — c'est un choix d'app, pas le défaut d'AppKit.
  private var pageBackground: some View {
    Scrim.page.overlay(PageTintWash(tint: tint)).ignoresSafeArea()
  }

  /// Le contenu de la fenêtre : l'accueil, OU les deux colonnes — jamais l'un par-dessus l'autre.
  ///
  /// Pendant l'accueil, la fenêtre entière devient son carré (cf. `OnboardingWindowFrame`) et les
  /// colonnes ne sont pas montées. C'est ce qui rend l'accueil sûr sans rien ajouter aux pages : ni le
  /// moniteur de ⌫ et ↑/↓, ni les actions de menu qu'elles publient (⌘N, ⌘⌥N…) n'existent tant
  /// qu'elles ne sont pas là.
  ///
  /// Sortie du `body` pour le type-checker : la fenêtre porte une vingtaine de modificateurs, et
  /// le calque de verre était celui de trop — le compilateur renonçait à résoudre l'expression.
  private var columns: some View {
    Group {
      if let step = onboarding {
        OnboardingView(
          step: Binding(get: { step }, set: { onboarding = $0 }), finish: finishOnboarding
        )
        // Taille EXACTE, et pas « tout ce qui est proposé ». La fenêtre n'étant plus redimensionnable
        // pendant l'accueil, SwiftUI la recale sur la taille idéale de son contenu à chaque écran ; un
        // contenu flexible en hauteur l'étirait donc jusqu'au bas de l'écran (660 × 1 415, mesuré au
        // passage de Bienvenue à Profil le 15 septembre 2026).
        .frame(width: MainWindowSize.onboarding.width, height: MainWindowSize.onboarding.height)
        .transition(.opacity)
      } else {
        appColumns.transition(.opacity)
      }
    }
    // Le verre est posé ICI, sous les deux contenus, et pas sur le `body` : celui-ci porte déjà une
    // vingtaine de modificateurs et un de plus lui faisait dépasser son budget de type-checking.
    .background { windowGlass }
  }

  /// Les deux colonnes, et rien d'autre.
  private var appColumns: some View {
    // Layout custom (HStack) MAIS fenêtre à toolbar native → gros rayon système sans inset de sidebar.
    HStack(spacing: 0) {
      // Montée en permanence, largeur pilotée (0 = repliée) : c'est ce qui permet de la tirer
      // depuis le bord pour la rouvrir, et de l'animer en glissement plutôt qu'en apparition.
      SidebarView(
        selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus
      )
      // Deux cadres : le contenu est mis en page à `layoutWidth`, le cadre extérieur (la vraie
      // largeur) le rogne par la droite. Pendant le drag, au-dessus du minimum la mise en page
      // suit la largeur et les titres se coupent en « … » ; en dessous elle est figée et seul le
      // rognage progresse — la sidebar ne se réorganise jamais pendant le drag, ni au repli.
      .frame(width: layoutWidth, alignment: .leading)
      .frame(width: effectiveWidth, alignment: .leading)
      .clipped()
      // Le voile de la sidebar SEUL : le verre, lui, est posé une fois pour toute la fenêtre
      // (cf. plus bas). Plus léger que celui de la page — la sidebar reste la colonne la plus
      // vitrée des deux, ce qui suffit à les distinguer sans inventer de teinte.
      .background { Scrim.sidebar.ignoresSafeArea() }
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
      .background { pageBackground }
    }
  }

  private func finishOnboarding() {
    UserDefaults.standard.set(true, forKey: Onboarding.completedStorageKey)
    selection = .smartList(.today)
    withAnimation(onboardingFlow) { onboarding = nil }
  }

  var body: some View {
    window
      // Ici plutôt que dans `window` : la chaîne de celle-ci dépassait déjà son budget de
      // type-checking.
      .background(OnboardingWindowFrame(isActive: onboarding != nil))
      // Muettes pendant l'accueil : la palette et la barre latérale appartiennent aux colonnes, qui
      // ne sont pas montées. La palette, elle, s'ouvrirait quand même, champ focalisé mais inutile.
      // *Revoir l'accueil* aussi : en plein accueil, il ramenait à Bienvenue en gardant la tâche
      // notée et le pont connecté de l'essai en cours.
      .focusedSceneValue(\.replayOnboarding, onboarding == nil ? replayOnboardingAction : nil)
      .focusedSceneValue(\.search, onboarding == nil ? searchAction : nil)
      .focusedSceneValue(\.sidebarToggle, onboarding == nil ? sidebarToggleAction : nil)
  }

  private var replayOnboardingAction: MenuAction {
    MenuAction(id: "onboarding.replay") {
      withAnimation(onboardingFlow) { onboarding = .welcome }
    }
  }

  private var searchAction: MenuAction {
    MenuAction(id: "search") { searchPresented = true }
  }

  private var sidebarToggleAction: SidebarToggle {
    SidebarToggle(isVisible: sidebarVisible) { sidebarVisible.toggle() }
  }

  private var window: some View {
    columns
      // Poignée : clic = replier/déplier, glisser = redimensionner. En overlay (pas dans le HStack)
      // pour rester visible sidebar repliée, où il n'y a plus de séparateur auquel s'accrocher.
      // Pas `HSplitView`, qui donnerait le redimensionnement gratuitement mais remplace le layout
      // par un NSSplitView : exit le repli animé et le fond pleine hauteur des colonnes.
      .overlay(alignment: .leading) {
        // Pas pendant l'accueil : sa bande de survol longe le bord gauche de la fenêtre, carré compris.
        if onboarding == nil { grabber }
      }
      .environment(\.pageTint, tint)
      .environment(filing)
      // Le cadre de la ligne en vol remonte de la page jusqu'ici. Une préférence et pas une écriture
      // directe : la rangée est enfouie sous `TaskListView` puis sous sa page, et rien d'autre ne
      // relie ces deux colonnes.
      .onPreferenceChange(DraggedRowFrameKey.self) { filing.track($0) }
      // Le bord où la page rogne. La fenêtre est la seule à le connaître : la sidebar se replie et se
      // tire. `initial` parce que la largeur de repos ne change pas au lancement — sans lui, aucun
      // glissement ne serait « en vol » tant qu'on n'aurait pas touché à la poignée.
      .onChange(of: effectiveWidth, initial: true) { filing.sidebarEdge = effectiveWidth }
      .overlay { taskDragGhost }
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
      // Ce que la barre de menus atteint dans cette fenêtre. ⌘B passait par un bouton CACHÉ posé
      // ici : il marchait, mais rien ne l'annonçait — un raccourci qu'on ne peut pas découvrir
      // n'existe que pour qui l'a écrit. Même chose pour la recherche, qui n'avait que sa loupe.
      // Les deux sont publiées par `body`, où l'accueil les fait taire.
      .onChange(of: selection) { _, new in recordRecent(new) }
      // Un ⌘↩ ou un raccourci texte (« !today ») venu de la capsule de saisie rapide : elle vit dans
      // une autre fenêtre et ne peut pas toucher ce `@State` autrement (cf. `AppCommand`).
      .onReceive(NotificationCenter.default.publisher(for: AppCommand.selectionNotification)) {
        note in
        // La destination est PORTÉE par la notification : une `ContentView` dont la fenêtre est
        // fermée reste abonnée, et un jeton à consommer une fois partait à celle-là (cf. `deliver`).
        guard let wanted = note.object as? SidebarSelection else { return }
        selection = wanted
      }
      // La même commande quand la fenêtre venait d'être fermée : elle est recréée par la commande, et
      // c'est le SEUL chemin dans ce cas — `AppCommand.deliver` ne poste alors AUCUNE notification,
      // qui serait consommée par la `ContentView` sortante, encore abonnée.
      .onAppear(perform: applyPendingSelection)
      // La base a refusé de s'ouvrir au lancement : le dire, ICI, parce que c'est le premier moment
      // où une fenêtre existe (la quarantaine, elle, a lieu pendant la construction du container).
      .onAppear { quarantinedPaths = StoreQuarantine.consumeReport() }
      .alert("Une base illisible a été mise de côté", isPresented: quarantineAlertPresented) {
        // Le seul bouton qui fait quelque chose d'utile : montrer les fichiers. Les retrouver à la
        // main demanderait d'aller dans un dossier que le Finder cache par défaut.
        Button("Afficher dans le Finder") {
          NSWorkspace.shared.activateFileViewerSelecting(
            quarantinedPaths.map { URL(fileURLWithPath: $0) })
        }
        Button("OK", role: .cancel) {}
      } message: {
        Text(
          "Today n'a pas pu ouvrir sa base de données et a redémarré sur une base vide. "
            + "RIEN N'A ÉTÉ SUPPRIMÉ : l'ancienne est à côté, sous un nom horodaté.\n\n"
            + quarantinedPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
            + "\n\nNe ressaisis rien avant d'avoir tenté de la récupérer.")
      }
      // ⌘Z. Le menu *Édition ▸ Annuler* n'annule pas « ce qui vient d'être fait » dans l'absolu : il
      // envoie `undo:` dans la chaîne des répondeurs, qui aboutit à l'`UndoManager` DE LA FENÊTRE.
      // Poser un `UndoManager` neuf sur le contexte SwiftData — ce qui était fait au démarrage —
      // ouvrait une SECONDE pile, correctement alimentée mais que rien ne pouvait atteindre : ⌘Z
      // restait sans effet partout, sans erreur ni menu grisé pour le dire.
      //
      // C'est ce que branche `modelContainer(for:isUndoEnabled:)` quand on laisse SwiftUI fabriquer
      // le container ; le nôtre est bâti à la main (cf. `TodayApp.openStore`, qui sauvegarde la base
      // avant de l'ouvrir), donc ce fil-là est à notre charge. L'environnement donne EXACTEMENT le
      // manager de la fenêtre — celui que le menu atteindra.
      .onChange(of: undoManager, initial: true) { modelContext.undoManager = undoManager }
      // Retour de complétion Rappels → app : EventKit prévient de tout changement du store ;
      // le retour au premier plan couvre le rappel coché pendant que l'app était en arrière-plan.
      .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
        syncWithReminders()
      }
      // Et le sens app → Rappels, qui n'avait AUCUN déclencheur : dater une tâche n'écrit que dans
      // SwiftData, donc ne poste pas `.EKEventStoreChanged`. La tâche partait quand même — mais
      // seulement au prochain réveil venu d'ailleurs (un remaniement iCloud, un retour au premier
      // plan), soit une quinzaine de secondes en moyenne, mesurées à l'usage le 6 août 2026.
      // `ModelContext.didSave` est le pendant exact de la notification d'EventKit, côté nous.
      .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
        syncWithReminders()
      }
      // Une liste renommée doit recoller ses raccourcis tout de suite, pas seulement quand les
      // Réglages passent dessus (cf. `reconcileShortcuts`).
      .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
        reconcileShortcuts()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) {
        _ in syncWithReminders()
      }
      // Ce qui s'installe se démonte : la passe en attente survivrait à la fermeture de la fenêtre.
      .onDisappear { reminderSync?.cancel() }
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
        if !sidebarVisible, onboarding == nil {
          if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) { SidebarMenu(selection: $selection) }
              .sharedBackgroundVisibility(.hidden)
          } else {
            ToolbarItem(placement: .principal) { SidebarMenu(selection: $selection) }
          }
        }
        ToolbarItem(placement: .primaryAction) {
          // 1 pt et non 0 : une taille nulle rend la mesure de l'item AMBIGUË pour AppKit, qui s'en
          // plaint deux fois à chaque lancement (« ambiguous height or width … zero height or
          // width »). Un point transparent ne se voit pas davantage et la mesure est nette.
          Color.clear
            .frame(width: 1, height: 1)
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

  /// La ligne en vol, dessinée par la FENÊTRE et pas par la page.
  ///
  /// C'était l'obstacle du chantier, et il est réel : la rangée qu'on tire vit dans le `ScrollView`
  /// de sa page, qui la rogne à son bord — au-dessus de la barre latérale, elle n'existe tout
  /// simplement pas. Elle en sort par une `PreferenceKey` (cf. `publishTaskDrag`), qui remonte son
  /// cadre DÉJÀ décalé en repère global ; la `GeometryReader` ne fait que le ramener dans celui de
  /// cet overlay.
  ///
  /// Le calque n'apparaît qu'une fois le bord de la page franchi — et à cet instant précis la page
  /// EFFACE sa rangée (`SidebarDrop.isAirborne`, la condition unique des deux côtés). Tant qu'on
  /// réordonne dans la page, c'est la vraie ligne qu'on déplace et rien ne saute au relâchement ;
  /// dès qu'on part vers la sidebar, elle DEVIENT la pilule. Une seule chose à l'écran de bout en
  /// bout du geste.
  @ViewBuilder private var taskDragGhost: some View {
    GeometryReader { proxy in
      let origin = proxy.frame(in: .global).origin
      if filing.isAirborne, let flying = filing.draggedFrame {
        // `.position`, pas `.offset` : elle CENTRE la pilule sur le curseur
        // (`flying.minX + filing.grabOffsetX`), quel que soit l'endroit où la ligne a été
        // empoignée — un bord avant ancré au curseur (essayé d'abord) traînait tout son corps
        // (110 pt) du côté du contenu au moment de basculer, ce qui se lisait comme prématuré. Et
        // pas de rognage à la largeur de la sidebar (essayé aussi) : ce calque doit rester
        // au-dessus de TOUT, sidebar et page confondues — un `.frame().clipped()` posé ici le
        // faisait passer sous les fonds opaques des deux colonnes.
        SidebarDropGhost(tint: tint)
          .position(
            x: flying.minX + filing.grabOffsetX - origin.x,
            y: flying.midY - origin.y)
      }
    }
    .allowsHitTesting(false)
  }

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
      // (`gutter` = 65) : aucune ligne ne commence là, elle ne peut voler aucun clic. Le geste, lui,
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

  /// Réveille la synchro — temporisée et sérialisée là-bas (cf. `RemindersSyncPass.schedule`).
  private func syncWithReminders() {
    if reminderSync == nil {
      reminderSync = RemindersSyncPass(service: remindersService, context: modelContext)
    }
    reminderSync?.schedule()
  }

  /// Recolle les raccourcis (abréviation de la capsule, combinaison globale) qui visent une LISTE
  /// renommée depuis leur pose. `ActionPicker` (Réglages ▸ Raccourcis) le fait déjà, mais seulement
  /// pendant que cette fenêtre est ouverte et affichée ; sans ce passage-ci, une liste renommée
  /// fenêtre fermée laisse le raccourci pointer vers un nom qui n'existe plus jusqu'à la prochaine
  /// ouverture des Réglages — l'abréviation tapée dans la capsule écrit alors le vieux jeton, qui ne
  /// route plus nulle part.
  ///
  /// Fetch à la demande et pas un `@Query` : même raison que `RemindersSyncPass.linkedTasks`, posé sur cette vue
  /// racine il ferait dépendre tout l'arbre de la moindre mutation d'une liste.
  private func reconcileShortcuts() {
    let titles = ((try? modelContext.fetch(FetchDescriptor<TodoList>())) ?? []).map(\.title)
    // Aucun titre = on ne sait RIEN, pas « plus aucune liste n'existe ». Le `try?` ci-dessus rend
    // `[]` aussi bien pour un fetch en échec que pour un store pas encore prêt — et sans cette
    // garde, `reconciled` juge alors mort CHAQUE raccourci de liste et les efface tous, pour de
    // bon. Élaguer demande de savoir ce qui reste ; ici on ne le sait pas.
    guard !titles.isEmpty else { return }

    let text = TextShortcut.decode(textShortcutData)
    let reconciledText = text.reconciled(against: titles)
    if reconciledText != text {
      textShortcutData = TextShortcut.encode(reconciledText)
    }

    let keys = KeyShortcut.decode(keyShortcutData)
    let reconciledKeys = keys.reconciled(against: titles)
    if reconciledKeys != keys {
      keyShortcutData = KeyShortcut.encode(reconciledKeys)
      // Les jetons des combinaisons globales sont capturés dans la closure Carbon à l'enregistrement
      // (cf. `GlobalHotKey.reload`) : sans ce rechargement, la touche continuerait de router vers
      // l'ancien nom jusqu'au prochain réglage touché dans Réglages ▸ Raccourcis.
      GlobalHotKey.shared.reload()
    }
  }

  /// Seules les listes et projets sont des destinations « récentes » ; les vues intelligentes
  /// restent toujours visibles dans la sidebar, inutile de les rappeler ici.
  /// Consomme la page demandée par un raccourci texte, une seule fois : les deux chemins (la
  /// notification, l'apparition d'une fenêtre recréée) mènent ici et le premier arrivé la vide.
  private func applyPendingSelection() {
    guard let pending = AppCommand.pendingSelection else { return }
    AppCommand.pendingSelection = nil
    selection = pending
  }

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

/// Ce qu'on emmène vers la barre latérale : la pilule de sélection, RÉDUITE, et le compte de ce
/// qu'elle transporte.
///
/// Il dit deux choses en ne dessinant presque rien : la teinte est celle de la PAGE d'où la ligne
/// vient, donc l'objet en vol se lit comme « la ligne que je viens de prendre » ; et il est court,
/// donc il ne masque pas la destination qu'on vise. Un calque à la largeur de la rangée
/// recouvrirait la colonne entière au moment précis où il faut la lire.
///
/// Teinté et non `rowSelectionFill` : ce gris neutre vaut 7 % de noir, ce qui suffit à poser une
/// sélection SUR une page mais disparaît quand la pilule survole la barre latérale, dont c'est
/// déjà le fond.
///
/// Son bord AVANT à mi-hauteur est le point qui vise (cf. `SidebarFiling.anchor`) : ce qu'on voit
/// est ce qui touche.
///
/// Pas la vraie `TaskRow`, et pas son titre non plus : le titre est déjà sous les yeux, dans la
/// page d'où la ligne vient. Ce qu'on ne sait pas sans lui, c'est COMBIEN on transporte — d'où le
/// badge, et rien d'autre.
private struct SidebarDropGhost: View {
  let tint: Color

  static let height: CGFloat = 22
  /// Largeur fixe : la pilule ne représente pas un contenu mais un objet en transit — c'est un
  /// curseur de dépôt, pas un aperçu.
  private static let width: CGFloat = 110
  private static let badge: CGFloat = 18

  var body: some View {
    Capsule()
      .fill(tint.opacity(0.85))
      .frame(width: Self.width, height: Self.height)
      // Le badge DÉBORDE, en haut à droite : posé dedans il se lirait comme une pastille de
      // contenu, alors qu'il compte ce que la pilule porte. Il ne change pas la taille de mise en
      // page, donc le centrage vertical du calque reste celui de la pilule.
      .overlay(alignment: .topTrailing) {
        // « 1 » en dur, et pas un paramètre : un glissement empoigne UNE rangée, et une en-tête —
        // le seul cas où un bloc voyage — ne se range pas dans une liste (cf. `ListPageView`). Un
        // `count` passé par l'unique appelant aurait été un faux réglage, toujours littéral. Le
        // jour où la sélection multiple arrivera, ce chiffre deviendra une vraie question.
        Text("1")
          .font(.system(size: 11, weight: .bold))
          // Blanc sur rouge : le contraste ne dépend pas du thème, c'est le badge du système.
          .foregroundStyle(.white)
          .frame(width: Self.badge, height: Self.badge)
          .background(Circle().fill(Color.red))
          .offset(x: Self.badge / 2.5, y: -Self.badge / 2.5)
      }
  }
}
