import AppKit
import SwiftData
import SwiftUI

@main
struct ThingsCloneApp: App {
  @State private var pomodoroTimer = PomodoroTimer()
  @State private var remindersService = RemindersService()
  @State private var profile = UserProfile()

  init() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  /// Le schéma change sans plan de migration à ce stade. Plutôt que de refuser de démarrer
  /// sur un store incompatible, on repart d'un store vide.
  /// ponytail: acceptable tant qu'il n'y a pas de donnée réelle — écrire un VersionedSchema
  /// le jour où l'app est utilisée pour de vrai.
  private static let container: ModelContainer = {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self])
    let configuration = ModelConfiguration(schema: schema)
    if let existing = try? ModelContainer(for: schema, configurations: configuration) {
      return existing
    }
    try? FileManager.default.removeItem(at: configuration.url)
    return try! ModelContainer(for: schema, configurations: configuration)
  }()

  var body: some Scene {
    // Titre vide explicite : sinon SwiftUI ré-assigne "ThingsClone" (nom du bundle) à la
    // fenêtre à chaque re-render du toolbar, provoquant un flash du titre natif.
    WindowGroup("") {
      ContentView()
        .environment(pomodoroTimer)
        .environment(remindersService)
        .environment(profile)
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
      SettingsView()
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
