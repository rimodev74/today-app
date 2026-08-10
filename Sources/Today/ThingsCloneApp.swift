import AppKit
import SwiftData
import SwiftUI

@main
struct TodayApp: App {
  @State private var pomodoroTimer = PomodoroTimer.shared
  @State private var remindersService = RemindersService()
  @State private var profile = UserProfile()
  @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

  init() {
    CrashLog.install()  // en premier : tout ce qui suit peut lever
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    _ = SparkleUpdater.shared
    // Saisie rapide : le raccourci global vit indépendamment des fenêtres (il doit répondre app en
    // arrière-plan), il est donc posé ici et pas dans une vue.
    GlobalHotKey.shared.action = { QuickEntryWindow.shared.toggle(container: Self.container) }
    // Le pendant clavier des abréviations : la MÊME action, atteinte sans passer par la capsule.
    // Une commande d'app emmène ailleurs et n'écrit rien ; un jeton de saisie (`@today`, `#Courses`)
    // n'a de sens que sur une tâche, il ouvre donc la capsule (ou vise celle déjà ouverte).
    GlobalHotKey.shared.perform = { token in
      if let command = AppCommand(token: token) {
        command.run()
      } else {
        QuickEntryWindow.shared.apply(token: token, container: Self.container)
      }
    }
    GlobalHotKey.shared.reload()
    // La même bascule, atteignable depuis l'EXTÉRIEUR du process (Raccourcis, Raycast, un
    // `osascript` d'une ligne). Le raccourci global, lui, passe par le serveur d'événements : rien
    // hors d'une app ayant le droit « Accessibilité » ne peut le simuler, donc rien ne pouvait
    // ouvrir la capsule par script — y compris pour la regarder pendant qu'on la travaille.
    DistributedNotificationCenter.default().addObserver(
      forName: .init(QuickEntryWindow.toggleNotification), object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { QuickEntryWindow.shared.toggle(container: Self.container) }
    }
  }

  // `prewarmRichTextEditing()` vivait ici : deux fenêtres hors écran où un `NSTextField` et un
  // `NSTextView` prenaient le premier répondeur, pour payer AVANT l'affichage le flash de panneau
  // système du tout premier focus. RETIRÉ le 10 août 2026 : c'était la cause des 27 plantages
  // « NSRemoteView … but expected (null) ». Donner le premier répondeur à un champ de texte fait
  // créer la liste de complétion d'AppKit, qui vit HORS PROCESS ; l'abonnement de cette vue
  // distante survit sans fenêtre conteneur, et la fenêtre suivante ordonnée à l'écran — l'icône de
  // barre de menus au lancement, la capsule — fait lever une assertion d'Apple qui tue le process.
  // Mesuré, 5 manches de 80 ouvertures de capsule : 4 manches mortes dès la 1re ouverture avec le
  // préchauffage, 1 morte sur 333 ouvertures sans. Retenir les fenêtres, les ordonner à l'écran,
  // couper la complétion, n'en garder qu'une moitié : tout mesuré, rien n'y change.
  // → `PIEGES.md` § Fenêtres. Le flash du premier focus est revenu : c'est le prix.

  /// Ouvre un store avec le schéma et le plan de migration de l'app — SANS plan B : c'est
  /// l'appelant qui décide quoi faire d'un échec. Le `container` ci-dessous met le store de côté et
  /// repart à neuf ; les tests, eux, veulent voir l'erreur, c'est tout leur objet.
  ///
  /// SEUL endroit qui sait ouvrir un store de cette app, et c'est ce qui donne sa valeur à
  /// `SchemaCompatibilityTests` : le test emprunte ce chemin-ci, pas une reconstitution qui
  /// pourrait diverger en silence le jour où le schéma ou le plan change.
  /// `nonisolated` : construire un `ModelContainer` ne touche à rien d'isolé, et l'appelant est le
  /// `container` statique ci-dessous — évalué paresseusement, hors de tout acteur.
  nonisolated static func openStore(_ configuration: ModelConfiguration) throws -> ModelContainer {
    try ModelContainer(
      for: Schema(versionedSchema: CurrentSchema.self),
      migrationPlan: TodayMigrationPlan.self,
      configurations: configuration)
  }

  /// Le store de l'app. Ouvert à travers `TodayMigrationPlan` : les changements de schéma passent
  /// par une migration déclarée (cf. `CurrentSchema`), plus par une base repartie de zéro.
  ///
  /// Le plan B ne SUPPRIME plus rien : un store illisible est mis de côté sous un nom horodaté
  /// (cf. `StoreQuarantine`) et l'app redémarre sur une base neuve. L'utilisateur voit une app
  /// vide — ce qui se remarque — au lieu de perdre son travail sans trace récupérable.
  ///
  /// Non privé : le panneau de saisie rapide vit dans sa propre fenêtre AppKit, hors de l'arbre de
  /// vues, et doit s'adosser au MÊME container que la fenêtre principale.
  static let container: ModelContainer = {
    let schema = Schema(versionedSchema: CurrentSchema.self)
    // URL EXPLICITE, dans un sous-dossier au nom de l'app. Sans elle, SwiftData écrit dans
    // `~/Library/Application Support/default.store` — à la racine, sous un nom que rien ne réserve
    // à personne, et qu'une autre application a effectivement écrasé le 5 août 2026 (cf.
    // `StoreLocation`, qui porte le déménagement de l'ancienne adresse).
    let configuration = ModelConfiguration(schema: schema, url: StoreLocation.resolve())
    // AVANT toute ouverture : si la forme des modèles a bougé depuis la dernière fois, on met une
    // copie de côté pendant que la base est encore intacte. C'est la seule protection qui joue chez
    // l'utilisateur — le test de compatibilité, lui, ne protège qu'au moment où l'on écrit le code.
    StoreBackup.snapshotIfShapeChanged(of: configuration.url, schema: schema)
    func open() throws -> ModelContainer { try openStore(configuration) }
    let container: ModelContainer
    do {
      container = try open()
    } catch {
      // SECONDE tentative sur les mêmes octets AVANT de mettre quoi que ce soit de côté. Ce n'est
      // pas une superstition, c'est mesuré : le 4 août 2026, l'app a été tuée en plein travail et a
      // laissé un journal WAL de 2,4 Mo non rejoué ; l'ouverture suivante a échoué — mais elle avait
      // rejoué le journal au passage, et la base ainsi RÉPARÉE s'est rouverte sans une erreur (21
      // tâches, 5 listes). La quarantaine du premier échec a donc coûté une app vide pour une panne
      // qui n'existait déjà plus. Une tentative de plus est le prix le moins cher du dossier.
      do {
        container = try open()
      } catch {
        StoreQuarantine.quarantine(configuration.url)
        // Si ça échoue encore, la base NEUVE elle-même est impossible à créer (disque plein,
        // droits) : il n'y a plus d'app à lancer, autant planter ici avec l'erreur sous les yeux.
        container = try! open()
      }
    }
    // Pas d'`UndoManager` posé ici. SwiftData enregistre bien tout seul dans celui du contexte,
    // mais un manager fabriqué au démarrage n'est relié à RIEN : le menu *Édition ▸ Annuler* parle
    // à celui de la FENÊTRE, qui n'existe pas encore à cet instant. C'est `ContentView` qui fait le
    // branchement, une fois la fenêtre là — la démonstration est dans son `.onChange`.
    //
    // Ça n'a rien d'un confort : ⌫ supprime DÉFINITIVEMENT et l'app n'a pas de corbeille. Depuis
    // que la touche vaut sur toutes les pages (cf. `TaskPageBase`), les occasions de perdre une
    // tâche d'un geste ont été multipliées par le nombre de pages.
    ensureInbox(in: container)
    return container
  }()

  /// Garantit l'existence de la liste singleton « Tâches » (Inbox) et lui rattache les tâches
  /// laissées sans liste par l'ancien champ libre d'« Aujourd'hui » — sans ça, ces tâches
  /// resteraient orphelines et invisibles après l'introduction de la page « Tâches ».
  /// Idempotent : no-op dès le second lancement (plus aucune tâche n'est créée avec `list: nil`).
  private static func ensureInbox(in container: ModelContainer) {
    let context = ModelContext(container)
    let inbox: TodoList
    if let existing = try? context.fetch(
      FetchDescriptor<TodoList>(
        predicate: #Predicate { $0.isInbox }
      )
    ).first {
      inbox = existing
    } else {
      inbox = TodoList(title: "Tâches")
      inbox.isInbox = true
      context.insert(inbox)
    }

    let orphans =
      (try? context.fetch(
        FetchDescriptor<TaskItem>(
          predicate: #Predicate { $0.list == nil },
          sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
    var next = (inbox.tasks.map(\.sortIndex).max() ?? -1) + 1
    for task in orphans {
      task.list = inbox
      task.sortIndex = next
      next += 1
    }

    try? context.save()
  }

  var body: some Scene {
    // Titre vide explicite : sinon SwiftUI ré-assigne "Today" (nom du bundle) à la
    // fenêtre à chaque re-render du toolbar, provoquant un flash du titre natif.
    WindowGroup("") {
      ContentView()
        .environment(pomodoroTimer)
        .environment(remindersService)
        .environment(profile)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }
    .modelContainer(Self.container)
    .defaultSize(width: 1400, height: 900)
    // Menu Format natif (gras Cmd+B, italique Cmd+I, etc.) câblé sur le premier répondeur —
    // `RichTextEditor` (isRichText) gère déjà ces actions nativement, aucune logique à écrire.
    // Le second groupe ajoute Cmd+K : panneau natif AppKit pour ajouter/modifier/retirer un lien
    // sur la sélection courante (même mécanisme que Mail/Notes/TextEdit).
    .commands {
      // ⌘N N'OUVRE PAS DE FENÊTRE. `WindowGroup` installe d'office un *Fichier ▸ Nouvelle fenêtre*
      // sur ⌘N, et comme macOS regroupe les fenêtres en onglets, la frappe ouvrait un ONGLET —
      // sur « Tâches », « Aujourd'hui » et la page d'un projet, c'est-à-dire partout où aucune page
      // ne réclamait la touche pour elle. Une page de liste, elle, avait son propre moniteur ⌘N et
      // masquait le problème : le même raccourci faisait donc deux choses selon l'onglet.
      //
      // Retiré ICI, une fois, plutôt que neutralisé page par page : une page qui ne sait pas créer
      // de tâche (« À venir », « Archives », un projet, le Pomodoro) doit voir ⌘N ne RIEN faire,
      // pas ouvrir une fenêtre dont cette app n'a aucun usage — elle n'a qu'un seul document.
      // Celles qui savent créer se branchent sur `TaskPageBase.newTask`.
      CommandGroup(replacing: .newItem) {}
      TextFormattingCommands()
      CommandGroup(after: .textEditing) {
        Button("Ajouter un lien…") {
          NSApp.sendAction(#selector(NSTextView.orderFrontLinkPanel(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("k", modifiers: .command)
      }
    }

    Settings {
      // Même thème que la fenêtre principale : sans ça, choisir « Sombre » avec un système clair
      // laissait la fenêtre de réglages en clair (le scheme n'est pas hérité entre Scenes).
      SettingsView()
        .environment(profile)
        // Le pont avec Rappels se règle ici : l'onglet Tâches doit pouvoir énumérer les listes.
        .environment(remindersService)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }
    // Les raccourcis texte proposent les listes comme destination : cette Scene a besoin du MÊME
    // container que la fenêtre principale, elle ne l'héritait pas.
    .modelContainer(Self.container)

    MenuBarExtra {
      PomodoroMenuBarView()
        .environment(pomodoroTimer)
    } label: {
      // Vue à part, et pas un `if pomodoroTimer.isRunning` inline : lire le timer ici
      // ferait dépendre le body de la Scene entière (WindowGroup inclus) de `remaining`,
      // donc une invalidation de tout l'arbre à chaque seconde.
      MenuBarTimerLabel(timer: pomodoroTimer)
    }
  }
}

private struct MenuBarTimerLabel: View {
  let timer: PomodoroTimer

  var body: some View {
    // `hasStarted` et pas `isRunning` : une session en pause GARDE son temps affiché. Le faire
    // disparaître se lisait comme « c'est fini », alors qu'il reste 12 minutes à reprendre.
    if timer.hasStarted {
      // En style .menu, MenuBarExtra rend son label dans le bouton du NSStatusItem et ignore
      // .font()/.frame() sur un Text : la largeur suit la chasse réelle des glyphes (SF est
      // proportionnel, "11:11" = 27.6pt vs "88:88" = 36.7pt) et toute la barre de menu se
      // décale à chaque seconde. Une Image a une taille intrinsèque non négociable.
      Image(nsImage: MenuBarTimerImage.make(timer.formattedRemaining, paused: !timer.isRunning))
    } else {
      Image(systemName: "timer")
    }
  }
}

/// Rend le temps restant dans une image dont la largeur ne dépend pas des chiffres affichés.
@MainActor
enum MenuBarTimerImage {
  // Chiffres tabulaires : les glyphes 0-9 ont tous la même chasse, donc la largeur mesurée ne
  // dépend que du nombre de caractères — constante à format constant, sans gabarit à maintenir.
  private static let font = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
    weight: .regular
  )

  /// Le glyphe de pause, à la taille du texte. Noir comme lui : l'image entière part en `isTemplate`
  /// juste en dessous, c'est elle qui prendra la couleur de la barre.
  private static let pauseGlyph: NSImage? = {
    let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
    guard
      let symbol = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "En pause")?
        .withSymbolConfiguration(configuration)
    else { return nil }
    return symbol
  }()

  /// `paused` préfixe le temps d'un glyphe ⏸. Sans lui, un compte à rebours arrêté est
  /// indiscernable d'un compte à rebours en marche tant qu'on ne l'a pas fixé une seconde entière —
  /// c'est le prix à payer pour garder le temps affiché en pause.
  static func make(_ text: String, paused: Bool = false) -> NSImage {
    let string = NSMutableAttributedString()
    if paused, let glyph = pauseGlyph {
      let attachment = NSTextAttachment()
      attachment.image = glyph
      string.append(NSAttributedString(attachment: attachment))
      string.append(NSAttributedString(string: " "))
    }
    string.append(
      NSAttributedString(
        string: text,
        attributes: [.font: font, .foregroundColor: NSColor.black]
      ))
    let size = string.size()
    let image = NSImage(
      size: NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up)),
      flipped: false
    ) { _ in
      string.draw(at: .zero)
      return true
    }
    image.isTemplate = true  // suit la couleur de la barre : clair/sombre et état sélectionné
    return image
  }
}
