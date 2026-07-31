import AppKit
import SwiftData
import SwiftUI

/// La fenêtre de saisie rapide : une capsule flottante qui s'ouvre PAR-DESSUS l'app en cours sans la
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
  private var dismissal: QuickEntryDismissal?

  private init() {}

  func toggle(container: ModelContainer) {
    if panel != nil { requestClose() } else { show(container: container) }
  }

  func show(container: ModelContainer) {
    close()  // panneau NEUF à chaque ouverture : pas de titre à moitié tapé qui survivrait
    let panel = makePanel(container: container)
    self.panel = panel
    position(panel)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Fermeture DEMANDÉE : la vue joue sa sortie et rappellera `close()` une fois le ressort fini.
  /// Tout ce qui ferme le panneau passe par ici — Échap, le raccourci global rejoué — sans quoi la
  /// fenêtre disparaîtrait au milieu de l'animation.
  func requestClose() {
    guard let dismissal else {
      close()
      return
    }
    dismissal.isRequested = true
  }

  func close() {
    panel?.orderOut(nil)
    panel = nil
    dismissal = nil
  }

  private func makePanel(container: ModelContainer) -> NSPanel {
    // Fenêtre volontairement plus grande que la capsule, et TRANSPARENTE : le verre a besoin de
    // composer sur ce qu'il y a derrière (une fenêtre opaque le réduirait à un aplat), et le
    // ressort d'ouverture comme le dépli des notes doivent avoir de la marge où déborder. On ne
    // redimensionne donc jamais le panneau — c'est le contenu qui bouge à l'intérieur.
    // ponytail: hauteur fixe dimensionnée pour la capsule + ses notes + une dizaine de tâches en
    // attente ; au-delà la fournée déborderait — à passer en `setFrame` animé si ça arrive.
    let panel = FloatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // `.borderless` ne devient jamais clé tout seul (d'où `canBecomeKey` dans la sous-classe), mais
    // c'est le seul style sans chrome ni coins arrondis système imposés sous la capsule.
    let dismissal = QuickEntryDismissal()
    self.dismissal = dismissal
    panel.onCancel = { [weak self] in self?.requestClose() }
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false  // l'ombre vient du verre, à la forme de la capsule
    panel.isMovableByWindowBackground = true
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "")
    let hosting = NSHostingView(
      rootView: QuickEntryView(
        dismissal: dismissal, onClose: { [weak self] in self?.close() }
      )
      .modelContainer(container)
      .preferredColorScheme((theme ?? .system).colorScheme)
    )
    hosting.layer?.backgroundColor = .clear
    panel.contentView = hosting
    return panel
  }

  /// Au tiers supérieur, pas au centre : c'est là que Spotlight se pose, et l'œil y va sans chercher.
  private func position(_ panel: NSPanel) {
    guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
      panel.center()
      return
    }
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(
        x: visible.midX - size.width / 2,
        y: visible.maxY - visible.height * 0.20 - size.height))
  }
}

/// Le canal par lequel AppKit demande à SwiftUI de se retirer. Un objet observé plutôt qu'un appel
/// direct : `cancelOperation` est déclenché par la fenêtre, hors de tout cycle de rendu, et n'a
/// aucun moyen d'atteindre l'état d'une vue autrement.
@MainActor @Observable final class QuickEntryDismissal {
  var isRequested = false
}

/// Une fenêtre sans bordure refuse le focus clavier et ignore Échap tant qu'on ne le lui apprend pas.
private final class FloatingPanel: NSPanel {
  var onCancel: (() -> Void)?

  override var canBecomeKey: Bool { true }

  /// AppKit route Échap ici via la chaîne de responder, y compris depuis le field editor d'un
  /// `TextField` — plus fiable qu'un `.keyboardShortcut(.cancelAction)` sur un bouton caché.
  override func cancelOperation(_ sender: Any?) { onCancel?() }

  /// Cliquer ailleurs referme, comme Spotlight. Perdre la clé est le bon signal plutôt qu'un moniteur
  /// de clics globaux : le panneau la garde pendant le tracking d'un `NSMenu` (le chip de
  /// destination), donc ouvrir le menu ne le ferme pas. `isVisible` écarte le rappel que `orderOut`
  /// provoque à la fermeture, qui relancerait la sortie sur une fenêtre déjà partie.
  override func resignKey() {
    super.resignKey()
    if isVisible { onCancel?() }
  }
}

/// Le contenu du panneau : une capsule d'une ligne — d'où part la tâche, ce qu'elle dit, quand — qui
/// se déplie sur un second bloc pour les notes et les sous-tâches. Pas de barre de validation :
/// Entrée enregistre, Échap ferme, et les deux boutons ne faisaient qu'afficher des raccourcis que
/// tout le monde connaît.
private struct QuickEntryView: View {
  var dismissal: QuickEntryDismissal
  var onClose: () -> Void

  /// Le ressort de la capsule, joué à l'endroit à l'ouverture et à l'envers à la fermeture — c'est
  /// la même courbe, donc le même rebond, dans les deux sens.
  private static let motion = Animation.spring(response: 0.34, dampingFraction: 0.62)
  /// Un poil au-delà du ressort : la fenêtre ne doit pas s'escamoter avant la fin du rebond.
  private static let motionDuration = Duration.milliseconds(380)

  @Environment(\.modelContext) private var modelContext
  @Query(sort: [SortDescriptor(\TodoList.sortIndex)]) private var lists: [TodoList]
  @Query(sort: [SortDescriptor(\Project.sortIndex)]) private var projects: [Project]

  @State private var title = ""
  @State private var notes = ""
  /// Sous-tâches en brouillon : de simples chaînes, pas des `Subtask`. Le modèle n'existera qu'à
  /// l'enregistrement — en créer avant obligerait à les rattacher à une `TaskItem` fantôme, puis à
  /// la nettoyer si le panneau se ferme sur Échap.
  @State private var subtasks: [String] = []
  /// Destination CHOISIE à la main, par son identifiant SwiftData et pas par l'objet : le `Picker`
  /// exige un tag `Hashable` stable, et un `PersistentIdentifier` en est un même si le modèle est
  /// rechargé sous le panneau. Un jeton `#liste` dans le titre l'emporte au moment d'enregistrer.
  @State private var targetID: PersistentIdentifier?
  @State private var when: Date?
  /// La fournée en attente : ⌘↩ y dépose la tâche en cours et rend le champ vide, ↩ enregistre tout
  /// et ferme. Vider trois idées d'affilée ne demande plus de rouvrir le panneau à chaque fois.
  @State private var queued: [PendingTask] = []
  @State private var expanded = false
  @State private var appeared = false
  @FocusState private var focus: Field?
  @Namespace private var morph

  private enum Field: Hashable {
    case title, notes
    case subtask(Int)
  }

  /// Identités de morphing du verre. Distinctes de `Field` : un bloc n'est pas une cible de focus.
  private enum Block: Hashable { case bar, details, queue }

  /// Une tâche déposée mais pas encore écrite : les mêmes champs que la saisie, gelés. Le titre
  /// garde ses jetons (`@demain`, `#liste`), analysés seulement à l'insertion — comme s'il venait
  /// d'être tapé.
  private struct PendingTask: Identifiable {
    let id = UUID()
    var title: String
    var notes: String
    var subtasks: [String]
    var when: Date?
    var targetID: PersistentIdentifier?
  }

  var body: some View {
    glassStack
      .frame(width: 620)
      // L'ancrage haut fait grandir la capsule depuis sa propre ligne : ancrée au centre, elle
      // remonterait pendant le ressort parce que le bloc s'allonge vers le bas quand les notes
      // s'ouvrent.
      .scaleEffect(appeared ? 1 : 0.88, anchor: .top)
      .opacity(appeared ? 1 : 0)
      .padding(.top, 32)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onAppear {
        withAnimation(Self.motion) { appeared = true }
      }
      .onChange(of: dismissal.isRequested) { _, requested in
        if requested { dismiss() }
      }
      // Le focus se pose ICI et pas dans `onAppear` : à ce moment-là le panneau n'est pas encore
      // clé (`makeKeyAndOrderFront` est en cours), et AppKit rend son premier répondeur à la
      // fenêtre juste après — le champ perdait le focus aussitôt reçu. Un tour de boucle suffit à
      // passer après.
      .task {
        try? await Task.sleep(for: .milliseconds(50))
        focus = .title
      }
      // La destination par défaut doit être COCHÉE, pas seulement sous-entendue par le chip. Sur
      // `inbox` et pas dans `onAppear` : la `@Query` peut n'avoir encore rien livré au premier
      // rendu, et le menu s'ouvrirait sans coche.
      .onChange(of: inbox?.persistentModelID, initial: true) { _, id in
        if targetID == nil { targetID = id }
      }
  }

  /// Les blocs de verre dans un `GlassEffectContainer` : c'est lui qui produit l'étirement élastique
  /// entre eux quand l'un apparaît — les formes fusionnent en se pinçant au milieu tant qu'elles
  /// sont à moins de `spacing` l'une de l'autre. Rien de tout ça n'existe sous macOS 26
  /// (Package.swift cible .v14, donc le `#available` est obligatoire) : le repli est un material,
  /// sans morphing.
  @ViewBuilder
  private var glassStack: some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 26) { stack }
    } else {
      stack
    }
  }

  private var stack: some View {
    VStack(spacing: 10) {
      pane(.bar, shape: Capsule()) { bar }
      if expanded {
        pane(.details, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
          detailsBox
        }
        .padding(.horizontal, 26)
      }
      if !queued.isEmpty {
        pane(.queue, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
          queueBox
        }
        .padding(.horizontal, 14)
      }
    }
  }

  /// Un bloc de la pile. Générique sur la forme pour que le repli garde `.strokeBorder` (défini sur
  /// `InsettableShape` seulement), et pour n'écrire qu'une fois le contenu des deux branches.
  @ViewBuilder
  private func pane<S: InsettableShape, V: View>(
    _ id: Block, shape: S, @ViewBuilder content: () -> V
  ) -> some View {
    if #available(macOS 26, *) {
      content()
        // Le verre nu laisse trop passer le bureau : le texte perd son contraste. Le `tint` est la
        // seule densification prévue par l'API — un calque posé par-dessus tuerait les reflets
        // internes. `windowBackgroundColor` suit déjà le thème, pas de couleur figée ici.
        .glassEffect(
          .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)).interactive(),
          in: shape
        )
        .glassEffectID(id, in: morph)
    } else {
      content()
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
    }
  }

  private var bar: some View {
    HStack(spacing: 12) {
      destinationChip
      TextField("Nouvelle tâche", text: $title)
        .textFieldStyle(.plain)
        .font(.app(19))
        .focused($focus, equals: .title)
        // Seul chemin d'enregistrement au clavier depuis que la barre de validation a disparu :
        // plus de bouton par défaut avec qui se dédoubler.
        .onSubmit(save)
        .onKeyPress(phases: .down, action: enqueueShortcut)
        .onKeyPress(.tab) {
          expand(focusing: .notes)
          return .handled
        }
      if canSave {
        // Sans cette mention, l'empilement n'existe que pour qui le connaît déjà.
        Text("⌘↩")
          .font(.app(11, weight: .medium))
          .foregroundStyle(.tertiary)
          .transition(.opacity)
      }
      dateMenu
      notesToggle
      subtaskButton
      sendButton
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private var detailsBox: some View {
    VStack(alignment: .leading, spacing: 9) {
      TextField("Notes", text: $notes, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.app(14))
        .lineLimit(2...6)
        .focused($focus, equals: .notes)
        // Un `TextField` vertical rend Entrée au field editor, qui en fait un saut de ligne ; le
        // panneau, lui, doit enregistrer. `onSubmit` n'est jamais appelé dans ce mode, d'où
        // l'interception directe — ⇧/⌥ + Entrée rend la nouvelle ligne à qui la veut.
        // La variante `phases:` est la seule à livrer le `KeyPress`, donc les modificateurs.
        .onKeyPress(phases: .down) { press in
          guard press.key == .return else { return .ignored }
          if press.modifiers.contains(.command) {
            enqueue()
            return .handled
          }
          guard press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
          save()
          return .handled
        }
      if !subtasks.isEmpty {
        Divider()
        ForEach(subtasks.indices, id: \.self, content: subtaskRow)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Case ronde décorative, comme dans les sous-tâches d'une vraie tâche : il n'y a rien à cocher
  /// sur une étape qu'on est en train d'écrire, mais la ligne doit se lire comme une sous-tâche.
  private func subtaskRow(_ index: Int) -> some View {
    HStack(spacing: 9) {
      TaskCheckbox(isCompleted: false, circular: true) {}
        .allowsHitTesting(false)
      TextField("Sous-tâche", text: $subtasks[index])
        .textFieldStyle(.plain)
        .font(.app(14))
        .focused($focus, equals: .subtask(index))
        .onKeyPress(phases: .down, action: enqueueShortcut)
        // Même geste que dans la page d'une tâche (cf. `enterOnSubtask`) : Entrée enchaîne sur une
        // étape de plus, et n'enregistre que si celle-ci est restée vide.
        .onSubmit {
          if subtasks[index].trimmingCharacters(in: .whitespaces).isEmpty {
            save()
          } else {
            addSubtask()
          }
        }
    }
  }

  /// La fournée en attente. Sa raison d'être est de rendre VISIBLE ce qui est déjà déposé : sans
  /// elle, empiler à l'aveugle reviendrait à taper dans le vide en espérant que ça a pris.
  private var queueBox: some View {
    VStack(spacing: 0) {
      ForEach(Array(queued.enumerated()), id: \.element.id) { index, pending in
        if index > 0 { Divider() }
        queueRow(pending)
      }
    }
    .padding(.vertical, 4)
  }

  private func queueRow(_ pending: PendingTask) -> some View {
    HStack(spacing: 10) {
      TaskCheckbox(isCompleted: false) {}
        .allowsHitTesting(false)
      Text(pending.title).font(.app(14)).lineLimit(1)
      Spacer(minLength: 10)
      if let when = pending.when {
        Text(when.formatted(.dateTime.day().month(.abbreviated)))
          .font(.app(11))
          .foregroundStyle(Color.accentColor)
      }
      // La destination est rappelée sur chaque ligne : rien n'oblige les tâches d'une même fournée
      // à partir au même endroit, le chip peut changer entre deux ⌘↩.
      if let name = list(for: pending.targetID)?.title {
        Text(name).font(.app(11)).foregroundStyle(.tertiary)
      }
      Button {
        withAnimation(.bouncy(duration: 0.35)) { queued.removeAll { $0.id == pending.id } }
      } label: {
        Image(systemName: "xmark").font(.app(10, weight: .semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tertiary)
      .help("Retirer de la fournée")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  /// Où ira la tâche, à gauche du champ : la seule information que la capsule doit porter en
  /// permanence, parce qu'elle est la seule qu'on ne peut pas deviner en lisant ce qu'on tape.
  ///
  /// Un `Picker` inline plutôt qu'une pile de `Button` : c'est lui qui fait poser à AppKit la coche
  /// sur l'entrée active — écrite à la main, elle demanderait de bricoler un `checkmark` dans le
  /// libellé, que `NSMenu` place à gauche, là où va déjà l'icône de la liste.
  private var destinationChip: some View {
    Menu {
      Picker(selection: $targetID) {
        if let inbox {
          Label(inbox.title, systemImage: "tray.full.fill")
            .tag(inbox.persistentModelID as PersistentIdentifier?)
        }
        // Un projet n'est PAS une destination : `TaskItem.project` se déduit de la liste
        // (`list?.project`), une tâche se pose donc toujours dans une liste. Il n'est ici qu'un
        // titre de section, ce qui lui donne au passage le trait de séparation de Things.
        ForEach(projects) { project in
          Section(project.title.isEmpty ? "Sans titre" : project.title) {
            ForEach(project.orderedLists, content: listRow)
          }
        }
        let loose = lists.filter { !$0.isInbox && $0.project == nil }
        if !loose.isEmpty {
          Section("Listes") { ForEach(loose, content: listRow) }
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.inline)
    } label: {
      HStack(spacing: 6) {
        destinationIcon
        Text(destination?.title ?? SmartList.all.label)
      }
      .font(.app(13))
      .padding(.vertical, 4)
      .padding(.horizontal, 11)
      .contentShape(Capsule())
      .background(.quaternary.opacity(0.5), in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  /// Le vrai anneau de la sidebar (`ProgressRing`) sur le chip : il est rendu par SwiftUI, donc rien
  /// n'y limite le tracé. Dans le menu, en revanche, `NSMenu` n'accepte qu'une image — d'où le
  /// symbole approché de `listRow`.
  @ViewBuilder private var destinationIcon: some View {
    if let destination, !destination.isInbox {
      ProgressRing(progress: destination.progress, size: 11, lineWidth: 1.8)
    } else {
      Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
    }
  }

  private func listRow(_ list: TodoList) -> some View {
    Label(list.title.isEmpty ? "Sans titre" : list.title, systemImage: ringSymbol(list.progress))
      .foregroundStyle(Color.accentColor)
      .tag(list.persistentModelID as PersistentIdentifier?)
  }

  /// Anneau de progression réduit à trois paliers : `NSMenu` ne sait afficher qu'une image devant
  /// une entrée, pas une vue, donc pas de `ProgressRing` continu ici.
  // ponytail: trois symboles plutôt qu'un rendu d'anneau en NSImage — à remplacer par un
  // `Image(nsImage:)` dessiné hors écran si l'approximation se voit à l'usage.
  private func ringSymbol(_ progress: Double) -> String {
    switch progress {
    case ..<0.01: "circle"
    case ..<0.99: "circle.lefthalf.filled"
    default: "circle.inset.filled"
    }
  }

  /// La date est le seul réglage que le modèle porte ET que la saisie rapide ne sait pas déjà
  /// exprimer par un jeton.
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
          Text(when.formatted(.dateTime.day().month(.abbreviated))).font(.app(13))
        }
      }
      .foregroundStyle(when == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Planifier la tâche")
  }

  /// Double du Tab : Tab est le geste, mais rien ne l'annonce — l'icône rend le dépli visible.
  private var notesToggle: some View {
    Button {
      if expanded {
        withAnimation(.bouncy(duration: 0.4)) { expanded = false }
        focus = .title
      } else {
        expand(focusing: .notes)
      }
    } label: {
      Image(systemName: "text.alignleft")
        .foregroundStyle(expanded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.plain)
    .help("Ajouter des notes (Tab)")
  }

  private var subtaskButton: some View {
    Button(action: addSubtask) {
      Image(systemName: "checklist")
        .foregroundStyle(
          subtasks.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
    }
    .buttonStyle(.plain)
    .help("Ajouter une sous-tâche")
  }

  private var sendButton: some View {
    Button(action: save) {
      Image(systemName: "arrow.up").font(.app(15, weight: .semibold))
    }
    .buttonStyle(.plain)
    .foregroundStyle(canSave ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
    .disabled(!canSave)
    .scaleEffect(canSave ? 1 : 0.82)
    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: canSave)
    .help(queued.isEmpty ? "Enregistrer (↩)" : "Enregistrer les \(queued.count + 1) tâches (↩)")
  }

  private func expand(focusing field: Field) {
    withAnimation(.bouncy(duration: 0.45)) { expanded = true }
    focus = field
  }

  private func addSubtask() {
    subtasks.append("")
    expand(focusing: .subtask(subtasks.count - 1))
  }

  // MARK: Enregistrement

  private var inbox: TodoList? { lists.first(where: \.isInbox) }
  private func list(for id: PersistentIdentifier?) -> TodoList? {
    id.flatMap { wanted in lists.first { $0.persistentModelID == wanted } } ?? inbox ?? lists.first
  }
  private var destination: TodoList? { list(for: targetID) }
  private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// L'état de saisie, figé tel quel : ce que ⌘↩ dépose dans la fournée et ce que ↩ emporte avec
  /// elle. `nil` si le titre est vide — une tâche sans titre n'existe pas.
  private var draft: PendingTask? {
    guard canSave else { return nil }
    return PendingTask(
      title: title, notes: notes, subtasks: subtasks, when: when, targetID: targetID)
  }

  /// ⌘↩ depuis n'importe quel champ : dépose et rend le champ vide. Partagé plutôt que réécrit sur
  /// chacun — trois copies auraient divergé à la première retouche.
  private func enqueueShortcut(_ press: KeyPress) -> KeyPress.Result {
    guard press.key == .return, press.modifiers.contains(.command) else { return .ignored }
    enqueue()
    return .handled
  }

  private func enqueue() {
    guard let draft else { return }
    withAnimation(.bouncy(duration: 0.4)) {
      queued.append(draft)
      title = ""
      notes = ""
      subtasks = []
      when = nil
      expanded = false  // les notes et sous-tâches sont parties avec la tâche déposée
    }
    // `targetID` survit exprès : trois tâches lancées d'affilée vont le plus souvent au même
    // endroit, et le chip reste modifiable entre deux dépôts.
    focus = .title
  }

  private func save() {
    // Entrée maintenue pendant la sortie : une tâche, pas deux. `dismiss()` a déjà remis `appeared`
    // à false quand il repasse ici.
    guard appeared else { return }
    // La tâche en cours de frappe part avec la fournée : ↩ enregistre TOUT, sans quoi la dernière
    // resterait à l'écran au moment où la fenêtre se ferme.
    let batch = queued + [draft].compactMap { $0 }
    // Rien à enregistrer : on sort par la même porte que Échap, pas en escamotant la fenêtre.
    guard !batch.isEmpty else {
      dismiss()
      return
    }
    batch.forEach(insert)
    dismiss()
  }

  private func insert(_ pending: PendingTask) {
    // Mêmes jetons que partout ailleurs (`@demain`, `#Courses`) : le panneau n'invente pas sa
    // propre syntaxe, il rejoue `applyQuickEntry`.
    let entry = QuickEntry(
      parsing: pending.title, names: lists.map(\.title) + projects.map(\.title))
    let text = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let list = entry.target.flatMap(resolve) ?? list(for: pending.targetID)
    else { return }
    let task = TaskItem(
      title: text, notes: encodedNotes(pending.notes), when: entry.when ?? pending.when, list: list)
    task.sortIndex = (list.orderedTasks.last?.sortIndex ?? -1) + 1
    // Avant l'insertion : SwiftData propage la relation, les sous-tâches entrent avec la tâche.
    for line in pending.subtasks {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }  // lignes ouvertes puis laissées vides
      task.addSubtask().title = trimmed
    }
    modelContext.insertAndSave(task)
  }

  /// La sortie : le ressort d'ouverture rejoué à l'envers, puis seulement le démontage de la
  /// fenêtre. Échap, le raccourci global et la fin de l'accusé de réception y passent tous — un
  /// panneau qui s'évanouit d'un coup après être entré en rebondissant se lit comme un plantage.
  private func dismiss() {
    guard appeared else { return }  // sortie déjà en cours (Échap martelé)
    focus = nil
    withAnimation(Self.motion) { appeared = false }
    Task { @MainActor in
      try? await Task.sleep(for: Self.motionDuration)
      onClose()
    }
  }

  private func resolve(_ name: String) -> TodoList? {
    lists.first { $0.title == name } ?? projects.first { $0.title == name }?.orderedLists.first
  }

  /// Mêmes police et couleur que le cadre de notes des pages (cf. `NotesBox`) : sans elles, le RTF
  /// repartirait sur les défauts d'AppKit (Helvetica 12, noir) et la note changerait d'allure en
  /// s'ouvrant dans la tâche.
  private func encodedNotes(_ source: String) -> Data {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return Data() }
    return NotesCodec.encode(
      NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.app(),
          .foregroundColor: NSColor.labelColor,
        ]))
  }
}
