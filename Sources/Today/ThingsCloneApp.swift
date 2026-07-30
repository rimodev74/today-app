import AppKit
import SwiftData
import SwiftUI

@main
struct TodayApp: App {
  @State private var pomodoroTimer = PomodoroTimer()
  @State private var remindersService = RemindersService()
  @State private var profile = UserProfile()
  @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

  init() {
    Self.prewarmRichTextEditing()
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    _ = SparkleUpdater.shared
  }

  /// La toute première fois qu'un champ de texte devient premier répondeur dans le process,
  /// AppKit fait flasher un panneau système une fraction de seconde — observé sur le TITRE d'une
  /// tâche (un `TextField` SwiftUI ordinaire, passant par le « field editor » partagé d'AppKit,
  /// instancié paresseusement au tout premier focus) ET sur les notes en texte riche
  /// (`NSTextView` avec `isRichText`, RTF non vide). Ce sont deux coûts distincts qui se
  /// chevauchaient jusque-là dans un même flash apparent (confirmé par bissection : en régler un
  /// laisse l'autre réapparaître seul, sur la prochaine tâche ouverte en premier — notes ou pas).
  /// On rejoue les deux scènes ici, dans une fenêtre jamais affichée (hors de l'écran, `orderFront`
  /// jamais appelé) : les coûts sont payés avant l'affichage de la fenêtre principale plutôt qu'au
  /// premier double-clic de l'utilisateur.
  private static func prewarmRichTextEditing() {
    func offscreenWindow(_ view: NSView) -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
        styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView = view
      window.makeFirstResponder(view)
      return window
    }

    // Titre : champ de texte simple, comme `TextField` — force l'instanciation du field editor
    // partagé d'AppKit. Fenêtre distincte de celle des notes : réattribuer `contentView` sur une
    // même fenêtre laisserait planer un doute sur l'ordre exact de démontage du premier champ.
    _ = offscreenWindow(NSTextField(string: " "))

    // Notes : texte riche avec du RTF non vide à décoder, comme `RichTextEditor`.
    let textView = NSTextView()
    textView.isRichText = true
    textView.isAutomaticLinkDetectionEnabled = true
    let sample = NotesCodec.encode(NSAttributedString(string: " "))
    textView.textStorage?.setAttributedString(NotesCodec.decode(sample))
    _ = offscreenWindow(textView)
  }

  /// Le store est ouvert à travers `TodayMigrationPlan` : les changements de schéma passent
  /// désormais par une migration déclarée (cf. `SchemaV1`), plus par une base repartie de zéro.
  ///
  /// Le plan B ne SUPPRIME plus rien : un store illisible est mis de côté sous un nom horodaté
  /// (cf. `StoreQuarantine`) et l'app redémarre sur une base neuve. L'utilisateur voit une app
  /// vide — ce qui se remarque — au lieu de perdre son travail sans trace récupérable.
  private static let container: ModelContainer = {
    let schema = Schema(versionedSchema: SchemaV1.self)
    let configuration = ModelConfiguration(schema: schema)
    func open() throws -> ModelContainer {
      try ModelContainer(
        for: schema, migrationPlan: TodayMigrationPlan.self, configurations: configuration)
    }
    let container: ModelContainer
    do {
      container = try open()
    } catch {
      StoreQuarantine.quarantine(configuration.url)
      // Si ça échoue encore, la base neuve elle-même est impossible à créer (disque plein, droits) :
      // il n'y a plus d'app à lancer, autant planter ici avec l'erreur sous les yeux.
      container = try! open()
    }
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
    if let existing = try? context.fetch(FetchDescriptor<TodoList>(
      predicate: #Predicate { $0.isInbox }
    )).first {
      inbox = existing
    } else {
      inbox = TodoList(title: "Tâches")
      inbox.isInbox = true
      context.insert(inbox)
    }

    let orphans = (try? context.fetch(FetchDescriptor<TaskItem>(
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
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }

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
    if timer.isRunning {
      // En style .menu, MenuBarExtra rend son label dans le bouton du NSStatusItem et ignore
      // .font()/.frame() sur un Text : la largeur suit la chasse réelle des glyphes (SF est
      // proportionnel, "11:11" = 27.6pt vs "88:88" = 36.7pt) et toute la barre de menu se
      // décale à chaque seconde. Une Image a une taille intrinsèque non négociable.
      Image(nsImage: MenuBarTimerImage.make(timer.formattedRemaining))
    } else {
      Image(systemName: "timer")
    }
  }
}

/// Rend le temps restant dans une image dont la largeur ne dépend pas des chiffres affichés.
enum MenuBarTimerImage {
  // Chiffres tabulaires : les glyphes 0-9 ont tous la même chasse, donc la largeur mesurée ne
  // dépend que du nombre de caractères — constante à format constant, sans gabarit à maintenir.
  private static let font = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
    weight: .regular
  )

  static func make(_ text: String) -> NSImage {
    let string = NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: NSColor.black]
    )
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
