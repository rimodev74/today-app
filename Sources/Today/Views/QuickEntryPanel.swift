import AppKit
import SwiftData
import SwiftUI

/// La fenêtre de saisie rapide : un panneau flottant qui s'ouvre PAR-DESSUS l'app en cours sans la
/// désactiver. C'est le seul point de l'app qui capture une tâche sans qu'on ait à venir à l'app.
///
/// Un `NSPanel` et pas une `Window` SwiftUI : une scène SwiftUI ne sait ni devenir clé sans activer
/// Today (la fenêtre principale passerait devant, exactement ce qu'on veut éviter), ni flotter
/// au-dessus des autres apps. `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded = false` donne le
/// couple recherché : le panneau prend le clavier, l'app de premier plan garde la main. Le contenu,
/// lui, reste du SwiftUI ordinaire adossé au même `ModelContainer` que la fenêtre principale — une
/// tâche créée ici apparaît immédiatement dans les listes.
@MainActor
final class QuickEntryWindow {
  static let shared = QuickEntryWindow()

  private var panel: NSPanel?

  private init() {}

  func toggle(container: ModelContainer) {
    if panel != nil { close() } else { show(container: container) }
  }

  func show(container: ModelContainer) {
    close()  // panneau NEUF à chaque ouverture : pas de titre à moitié tapé qui survivrait
    let panel = makePanel(container: container)
    self.panel = panel
    panel.center()
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    panel?.orderOut(nil)
    panel = nil
  }

  private func makePanel(container: ModelContainer) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 230),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // Barre de titre invisible mais PRÉSENTE : un panneau `.borderless` ne devient pas clé sans
    // sous-classer `canBecomeKey`, et perd les coins arrondis système.
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "")
    panel.contentView = NSHostingView(
      rootView: QuickEntryView(onClose: { [weak self] in self?.close() })
        .modelContainer(container)
        .preferredColorScheme((theme ?? .system).colorScheme)
    )
    return panel
  }
}

/// Le contenu du panneau : une tâche en cours d'écriture (case, titre, notes, date) posée sur une
/// barre qui dit où elle ira et propose de valider.
private struct QuickEntryView: View {
  var onClose: () -> Void

  @Environment(\.modelContext) private var modelContext
  @Query(sort: [SortDescriptor(\TodoList.sortIndex)]) private var lists: [TodoList]
  @Query(sort: [SortDescriptor(\Project.sortIndex)]) private var projects: [Project]

  @State private var title = ""
  @State private var notes = ""
  /// Destination CHOISIE à la main ; `nil` = celle par défaut (« Tâches »). Un jeton `#liste` dans
  /// le titre l'emporte sur les deux au moment d'enregistrer.
  @State private var target: TodoList?
  @State private var when: Date?
  @FocusState private var titleFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      card
      Divider()
      bottomBar
    }
    .onAppear { titleFocused = true }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        // Décorative : il n'y a rien à cocher sur une tâche qu'on est en train d'écrire. Elle est
        // là pour que le panneau se lise comme une ligne de liste, comme dans Things.
        TaskCheckbox(isCompleted: false) {}
          .allowsHitTesting(false)
        TextField("Nouvelle tâche", text: $title)
          .textFieldStyle(.plain)
          .font(.system(size: 15))
          .focused($titleFocused)
        // Pas de `.onSubmit(save)` : Entrée est DÉJÀ le bouton par défaut de la barre du bas, et
        // les deux chemins créeraient deux tâches pour une seule frappe.
      }
      TextField("Notes", text: $notes, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(2...4)
        .padding(.leading, 26)
      Spacer(minLength: 8)
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        dateMenu
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// Une seule icône d'action, contre quatre dans Things : la date est le seul de ces réglages que
  /// le modèle porte ET que la saisie rapide ne sait pas déjà exprimer.
  // ponytail: pas de tag (le modèle n'en a pas), pas de checklist ni de drapeau ici — ils
  // s'ajoutent en deux clics sur la tâche une fois créée.
  private var dateMenu: some View {
    Menu {
      Button("Aujourd'hui") { when = Calendar.current.startOfDay(for: Date()) }
      Button("Demain") {
        when = Calendar.current.date(
          byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
      }
      if when != nil {
        Divider()
        Button("Aucune date") { when = nil }
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "calendar")
        if let when {
          Text(when.formatted(.dateTime.day().month(.abbreviated)))
        }
      }
      .foregroundStyle(when == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Planifier la tâche")
  }

  private var bottomBar: some View {
    HStack(spacing: 10) {
      destinationMenu
      Spacer(minLength: 8)
      Button("Annuler", action: onClose)
        .keyboardShortcut(.cancelAction)
      Button("Enregistrer", action: save)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.quaternary.opacity(0.35))
  }

  private var destinationMenu: some View {
    Menu {
      if let inbox {
        Button(inbox.title) { target = inbox }
      }
      ForEach(projects) { project in
        Section(project.title.isEmpty ? "Sans titre" : project.title) {
          ForEach(project.orderedLists) { list in
            Button(list.title.isEmpty ? "Sans titre" : list.title) { target = list }
          }
        }
      }
      let loose = lists.filter { !$0.isInbox && $0.project == nil }
      if !loose.isEmpty {
        Section("Listes") {
          ForEach(loose) { list in
            Button(list.title.isEmpty ? "Sans titre" : list.title) { target = list }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: destination?.isInbox == false ? "list.bullet" : "tray.full.fill")
          .foregroundStyle(.secondary)
        Text(destination?.title ?? SmartList.all.label)
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 10)
      .contentShape(Capsule())
      .background(.quaternary.opacity(0.5), in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  // MARK: Enregistrement

  private var inbox: TodoList? { lists.first(where: \.isInbox) }
  private var destination: TodoList? { target ?? inbox ?? lists.first }

  private func save() {
    // Mêmes jetons que partout ailleurs (`@demain`, `#Courses`) : le panneau n'invente pas sa
    // propre syntaxe, il rejoue `applyQuickEntry`.
    let entry = QuickEntry(
      parsing: title, names: lists.map(\.title) + projects.map(\.title))
    let text = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let list = entry.target.flatMap(resolve) ?? destination else {
      onClose()
      return
    }
    let task = TaskItem(
      title: text, notes: encodedNotes, when: entry.when ?? when, list: list)
    task.sortIndex = (list.orderedTasks.last?.sortIndex ?? -1) + 1
    modelContext.insertAndSave(task)
    onClose()
  }

  private func resolve(_ name: String) -> TodoList? {
    lists.first { $0.title == name } ?? projects.first { $0.title == name }?.orderedLists.first
  }

  /// Mêmes police et couleur que le cadre de notes des pages (cf. `NotesBox`) : sans elles, le RTF
  /// repartirait sur les défauts d'AppKit (Helvetica 12, noir) et la note changerait d'allure en
  /// s'ouvrant dans la tâche.
  private var encodedNotes: Data {
    let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return Data() }
    return NotesCodec.encode(
      NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
          .foregroundColor: NSColor.labelColor,
        ]))
  }
}
