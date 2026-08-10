import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsTab()
        .tabItem { Label("Général", systemImage: "gearshape") }

      ShortcutsSettingsTab()
        .tabItem { Label("Raccourcis", systemImage: "keyboard") }

      TasksSettingsTab()
        .tabItem { Label("Tâches", systemImage: "checklist") }

      PomodoroSettingsTab()
        .tabItem { Label("Pomodoro", systemImage: "timer") }
    }
    .frame(width: 460)
    // Sans ça, `TabView` fait fondre l'ancien panneau dans le nouveau à chaque clic d'onglet.
    .transaction { $0.disablesAnimations = true }
  }
}

// ponytail: shared sizing only, pas de wrapper générique de pane
private struct SettingsPane<Content: View>: View {
  /// 360 va à trois sections courtes (« Général » depuis le profil : 300 le faisait défiler). Un
  /// onglet plus chargé le dit — sans quoi ses dernières rangées ne sont pas absentes, elles sont
  /// SOUS le bord, ce qui est pire : rien ne les annonce.
  var height: CGFloat = 360
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .frame(height: height)
  }
}

private struct GeneralSettingsTab: View {
  @Environment(UserProfile.self) private var profile
  @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
  @State private var autoCheckUpdates = SparkleUpdater.shared.automaticallyChecksForUpdates

  private var version: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  var body: some View {
    SettingsPane {
      Section("Profil") {
        ProfileSettingsRows(profile: profile)
      }

      Section("Apparence") {
        Picker("Thème", selection: $themeRaw) {
          ForEach(AppTheme.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }

      }

      Section("Mises à jour") {
        LabeledContent("Version installée", value: version)

        Toggle("Vérifier automatiquement", isOn: $autoCheckUpdates)
          .onChange(of: autoCheckUpdates) { _, value in
            SparkleUpdater.shared.automaticallyChecksForUpdates = value
          }

        // `LabeledContent` et pas un `HStack` : c'est lui qui aligne le bouton sur la colonne des
        // autres rangées du formulaire groupé, seul, il flottait à gauche.
        LabeledContent("Recherche manuelle") {
          Button("Rechercher une mise à jour") {
            SparkleUpdater.shared.checkForUpdates()
          }
        }
      }
    }
  }
}

/// Nom et photo du profil affiché en haut de la sidebar (cf. `ProfileCard`, qui ne fait plus
/// qu'afficher). Des rangées et pas une vue à part entière : c'est le `Form` de l'onglet qui
/// aligne les libellés sur ceux des autres sections.
private struct ProfileSettingsRows: View {
  @Bindable var profile: UserProfile
  @State private var isImporting = false
  @State private var importError: String?

  var body: some View {
    LabeledContent("Photo") {
      HStack(spacing: 12) {
        AvatarView(profile: profile, size: 40)
        Button("Choisir…") { isImporting = true }
        if profile.avatarData != nil {
          Button("Retirer") { profile.avatarData = nil }
        }
      }
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
      importError = nil
      guard case .success(let url) = result else { return }
      // Sandbox : l'URL retournée par le fileImporter n'est lisible que dans cette portée.
      guard url.startAccessingSecurityScopedResource() else {
        importError = "Photo illisible."
        return
      }
      defer { url.stopAccessingSecurityScopedResource() }
      guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
        importError = "Ce fichier n'est pas une image valide."
        return
      }
      profile.avatarData = data
    }

    TextField("Prénom", text: $profile.firstName)
    TextField("Nom", text: $profile.lastName)

    if let importError {
      Text(importError)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}

/// Enregistreur de raccourci : le bouton passe en écoute et capture la PROCHAINE combinaison
/// frappée. Il ne stocke rien lui-même — il rend une `KeyCombo` à qui l'affiche, que ce soit le
/// réglage de la saisie rapide ou la ligne d'un raccourci d'action.
///
/// Moniteur `NSEvent` local et pas `.onKeyPress` : le second ne voit que ce que SwiftUI veut bien
/// lui laisser (une combinaison à modificateurs part d'abord au menu — ⌘Q quitterait l'app en pleine
/// saisie), alors qu'un moniteur local voit l'événement AVANT le menu et peut le consommer
/// (`return nil`).
private struct HotKeyRecorder: View {
  @Binding var combo: KeyCombo?
  var width: CGFloat = 150

  @State private var monitor: Any?

  var body: some View {
    Button(title) {
      if monitor == nil { start() } else { stop() }
    }
    .frame(width: width)
    // Retirer une combinaison n'a pas de bouton à lui : une croix de plus par ligne ferait trois
    // contrôles pour un réglage qu'on pose une fois. ⌫ pendant l'écoute est le geste des Réglages
    // Système, et l'infobulle est là au moment exact où on cherche comment faire.
    .help("Cliquez puis tapez la combinaison. ⌫ la retire, ⎋ annule.")
    // Un moniteur laissé installé continuerait d'avaler les frappes de toute l'app.
    .onDisappear(perform: stop)
  }

  private var title: String {
    if monitor != nil { return "Tapez…" }
    return combo?.label ?? "Aucun"
  }

  private func start() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      switch Int(event.keyCode) {
      case kVK_Escape where modifiers.isEmpty:
        stop()
        return nil
      case kVK_Delete where modifiers.isEmpty:
        combo = nil
        stop()
        return nil
      default:
        break
      }
      // Un raccourci GLOBAL sans modificateur volerait la touche à toutes les apps : on en exige
      // au moins un, d'où le `nil` que rend `combo(capturing:)`.
      guard let captured = GlobalHotKey.combo(capturing: event) else {
        NSSound.beep()
        return nil
      }
      combo = captured
      stop()
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

/// Les deux façons de déclencher une action, dans deux sections distinctes : la combinaison de
/// touches (qui répond même app en arrière-plan) et l'abréviation tapée dans la capsule. Même
/// vocabulaire d'actions des deux côtés, réglé indépendamment — rien n'oblige une action à porter
/// les deux déclencheurs.
private struct ShortcutsSettingsTab: View {
  var body: some View {
    SettingsPane {
      KeyShortcutsSection()
      TextShortcutsSection()
    }
  }
}

/// Le menu des actions, commun aux deux sections : dates, destinations atteignables, pages de l'app.
/// Le modèle stocke un jeton (`@today`, `#Courses`, `!today`) mais le menu le compose — personne n'a
/// à connaître la syntaxe `@`/`#`/`!` pour se fabriquer un raccourci.
private struct ActionPicker: View {
  @Binding var token: String

  @Query(sort: [SortDescriptor(\TodoList.sortIndex)]) private var lists: [TodoList]

  /// Mêmes destinations qu'ailleurs : l'inbox et les listes DANS un projet. Une liste orpheline
  /// n'est atteignable nulle part dans l'app, la proposer ici serait un raccourci mort.
  private var destinations: [TodoList] { lists.filter { $0.isInbox || $0.project != nil } }

  var body: some View {
    Picker("", selection: $token) {
      Section("Date") {
        ForEach(TextShortcut.dateOptions, id: \.token) { option in
          Text(option.label).tag(option.token)
        }
      }
      Section("Destination") {
        ForEach(destinations) { list in
          // Un jeton ne porte jamais d'espace (cf. `QuickEntry.fold`) : une liste au nom composé
          // ("Bugs / Modifications") écrirait sinon ses mots suivants tels quels dans le champ au
          // lieu de se résoudre en destination.
          Text(list.title).tag("#" + list.title.filter { !$0.isWhitespace })
        }
      }
      Section("Application") {
        // Le minuteur a sa propre section, dans l'onglet Pomodoro — les proposer ici aussi
        // ferait deux endroits pour régler le même raccourci.
        ForEach(AppCommand.allCases.filter { !$0.isPomodoro }) { command in
          Text(command.label).tag(command.token)
        }
      }
    }
    .labelsHidden()
    .frame(maxWidth: .infinity, alignment: .leading)
    // Une liste renommée depuis que ce raccourci la vise casse la correspondance du `Picker` :
    // ses options suivent le titre COURANT (ci-dessus), le jeton enregistré reste à l'ancien nom
    // tant que rien ne l'écrit. `initial: true` répare une liste déjà renommée avant l'ouverture
    // des Réglages ; le déclenchement sur `destinations` répare un renommage vécu PENDANT qu'ils
    // sont ouverts — les deux écrivent la même correction (`QuickEntry.reconciledListToken`).
    .onChange(of: destinations.map(\.title), initial: true) {
      token = QuickEntry.reconciledListToken(token, against: destinations.map(\.title))
    }
  }
}

/// La croix de retrait d'une rangée. Toujours présente — un contrôle qui n'existe qu'au survol est
/// introuvable au clavier — mais en retrait tant que la rangée n'est pas visée : trois croix pleines
/// alignées feraient lire la liste comme une zone de danger.
private struct RemoveButton: View {
  var isHighlighted: Bool
  var action: () -> Void

  static let width: CGFloat = 15

  var body: some View {
    Button(action: action) { Image(systemName: "minus.circle.fill") }
      .buttonStyle(.plain)
      .frame(width: Self.width)
      .foregroundStyle(isHighlighted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
      .help("Supprimer ce raccourci")
  }
}

/// Section 1 — les combinaisons de touches : celle qui ouvre la capsule, puis une par action.
// ponytail: pas de détection de conflit entre deux combinaisons identiques — la première
// enregistrée gagne (cf. `GlobalHotKey.reload`). Un badge si ça devient un vrai problème.
private struct KeyShortcutsSection: View {
  @AppStorage(KeyShortcut.storageKey) private var keyData = Data()
  /// La combinaison de la capsule vit dans trois clés de défauts, pas dans un état de vue : sans
  /// cette observation, rien n'invaliderait le bouton et il afficherait encore l'ancienne
  /// combinaison jusqu'au prochain redessin fortuit.
  @AppStorage(GlobalHotKey.keyCodeStorageKey) private var quickEntryKeyCode = GlobalHotKey
    .quickEntryDefault.keyCode
  @State private var hovered: KeyShortcut.ID?

  private static let keyWidth: CGFloat = 104
  private static let columns: CGFloat = 10

  /// Le minuteur a sa propre section (onglet Pomodoro, même stockage) : ses rangées restent hors
  /// de cette liste pour ne pas se régler à deux endroits, mais `set` les préserve — un ajout ou un
  /// retrait ICI ne doit pas effacer ce que l'onglet Pomodoro a posé.
  private var shortcuts: Binding<[KeyShortcut]> {
    Binding(
      get: { KeyShortcut.decode(keyData).filter { !isPomodoro($0.expansion) } },
      set: { edited in
        let pomodoro = KeyShortcut.decode(keyData).filter { isPomodoro($0.expansion) }
        keyData = KeyShortcut.encode(pomodoro + edited)
      })
  }

  private func isPomodoro(_ token: String) -> Bool {
    AppCommand(token: token)?.isPomodoro ?? false
  }

  private var quickEntryCombo: Binding<KeyCombo?> {
    Binding(
      get: { quickEntryKeyCode >= 0 ? GlobalHotKey.current : nil },
      set: { GlobalHotKey.store($0) })
  }

  var body: some View {
    Section {
      columnHeaders
      quickEntryRow
      ForEach(shortcuts) { $shortcut in row($shortcut) }
      addButton
    } header: {
      Text("Saisie rapide")
    } footer: {
      Text(
        """
        Les combinaisons répondent même quand Today est en arrière-plan. Une action de date ou de \
        liste ouvre la capsule avec le jeton déjà posé.
        """
      )
      .foregroundStyle(.secondary)
    }
    // Les combinaisons sont enregistrées auprès du système : toute modification de la liste (une
    // touche changée, une ligne supprimée) doit les réenregistrer, sinon l'ancienne répond encore.
    .onChange(of: keyData) { GlobalHotKey.shared.reload() }
  }

  /// Les colonnes se nomment une fois, en haut, plutôt qu'un intitulé répété à chaque rangée.
  private var columnHeaders: some View {
    HStack(spacing: Self.columns) {
      // Retrait optique : le texte d'un menu commence à l'intérieur de son cadre, l'en-tête doit
      // s'aligner sur les LETTRES, pas sur les bords.
      Text("Action")
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Touches")
        .frame(width: Self.keyWidth, alignment: .center)
      // La place de la croix de retrait, pour que la colonne « Touches » tombe bien au-dessus des
      // enregistreurs et pas décalée de leur largeur.
      Color.clear.frame(width: RemoveButton.width, height: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  /// L'ouverture de la capsule est une combinaison COMME les autres : sa place est sous les mêmes
  /// colonnes, pas au-dessus d'elles. Elle ne se supprime pas — la colonne de la croix porte donc
  /// son retour aux réglages d'usine, dans la même largeur que les croix des rangées voisines
  /// (« Réinitialiser » en toutes lettres aurait débordé de la colonne et cassé l'alignement).
  private var quickEntryRow: some View {
    HStack(spacing: Self.columns) {
      Text("Ouvrir la capsule")
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
      HotKeyRecorder(combo: quickEntryCombo, width: Self.keyWidth)
      Button {
        GlobalHotKey.store(GlobalHotKey.quickEntryDefault)
      } label: {
        Image(systemName: "arrow.uturn.backward.circle.fill")
      }
      .buttonStyle(.plain)
      .frame(width: RemoveButton.width)
      .foregroundStyle(.tertiary)
      .help("Revenir à ⌃Espace")
    }
  }

  private func row(_ shortcut: Binding<KeyShortcut>) -> some View {
    let id = shortcut.wrappedValue.id
    return HStack(spacing: Self.columns) {
      ActionPicker(token: shortcut.expansion)
      HotKeyRecorder(combo: shortcut.key, width: Self.keyWidth)
      RemoveButton(isHighlighted: hovered == id) {
        withAnimation(.snappy(duration: 0.2)) {
          shortcuts.wrappedValue.removeAll { $0.id == id }
        }
      }
    }
    .onHover { inside in
      if inside {
        hovered = id
      } else if hovered == id {
        hovered = nil
      }
    }
    .animation(.easeOut(duration: 0.12), value: hovered)
  }

  private var addButton: some View {
    AddRowButton("Ajouter une combinaison") {
      shortcuts.wrappedValue.append(KeyShortcut(expansion: "@today"))
    }
    // Une rangée de plus n'apporte rien tant que la précédente n'a pas reçu ses touches.
    .disabled(shortcuts.wrappedValue.contains { $0.key == nil })
  }
}

/// Section 2 — les abréviations tapées dans la capsule : « ajd » puis ⇥ pose la date du jour.
// ponytail: pas de garde-fou sur les doublons de déclencheur — le premier de la liste gagne, et la
// liste est courte et sous les yeux. Un badge de conflit si ça devient un vrai problème.
private struct TextShortcutsSection: View {
  @AppStorage(TextShortcut.storageKey) private var shortcutData = Data()
  @State private var hovered: TextShortcut.ID?

  /// Largeur de la colonne « Raccourci », partagée par l'en-tête et les rangées : c'est elle qui
  /// tient les deux colonnes alignées. Un `Grid` serait de trop pour deux champs par ligne.
  private static let triggerWidth: CGFloat = 96
  private static let columns: CGFloat = 12

  /// Même règle que côté combinaisons de touches (cf. `KeyShortcutsSection.shortcuts`) : les
  /// abréviations du minuteur restent réglables uniquement depuis l'onglet Pomodoro.
  private var shortcuts: Binding<[TextShortcut]> {
    Binding(
      get: { TextShortcut.decode(shortcutData).filter { !isPomodoro($0.expansion) } },
      set: { edited in
        let pomodoro = TextShortcut.decode(shortcutData).filter { isPomodoro($0.expansion) }
        shortcutData = TextShortcut.encode(pomodoro + edited)
      })
  }

  private func isPomodoro(_ token: String) -> Bool {
    AppCommand(token: token)?.isPomodoro ?? false
  }

  var body: some View {
    Section {
      columnHeaders
      if shortcuts.wrappedValue.isEmpty {
        Text("Aucun raccourci")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(shortcuts) { $shortcut in row($shortcut) }
      addButton
    } header: {
      Text("Actions Spotlight")
    } footer: {
      // Le geste est invisible sans ça : rien à l'écran n'annonce que ⇥ valide une abréviation.
      Text("Tapez l'abréviation puis ⇥, dans la saisie rapide comme dans une liste.")
        .foregroundStyle(.secondary)
    }
  }

  /// Les deux colonnes se nomment une fois, en haut, plutôt qu'une flèche répétée à chaque rangée :
  /// la flèche redisait à dix reprises ce qu'un en-tête dit une seule.
  private var columnHeaders: some View {
    HStack(spacing: Self.columns) {
      // Retraits optiques : le texte d'un champ bordé et celui d'un menu commencent à l'intérieur
      // de leur cadre, l'en-tête doit s'aligner sur les LETTRES, pas sur les bords.
      Text("Raccourci")
        .padding(.leading, 5)
        .frame(width: Self.triggerWidth, alignment: .leading)
      Text("Action")
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
      Color.clear.frame(width: RemoveButton.width, height: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func row(_ shortcut: Binding<TextShortcut>) -> some View {
    let id = shortcut.wrappedValue.id
    return HStack(spacing: Self.columns) {
      // Sans texte d'invite : la colonne est déjà nommée au-dessus, et « abrév. » répétait ce mot
      // dans chaque rangée vide.
      // `TextField` + `multilineTextAlignment` ne centre RIEN ici, vérifié à l'écran avec `.plain`
      // comme avec `.roundedBorder` : sur macOS ce modificateur n'atteint pas le champ mono-ligne.
      // `AlignedTextField` pose l'alignement directement sur le `NSTextField` sous-jacent.
      AlignedTextField(text: shortcut.trigger)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)))
        .frame(width: Self.triggerWidth)

      ActionPicker(token: shortcut.expansion)

      RemoveButton(isHighlighted: hovered == id) {
        withAnimation(.snappy(duration: 0.2)) {
          shortcuts.wrappedValue.removeAll { $0.id == id }
        }
      }
    }
    .onHover { inside in
      if inside {
        hovered = id
      } else if hovered == id {
        hovered = nil
      }
    }
    .animation(.easeOut(duration: 0.12), value: hovered)
  }

  private var addButton: some View {
    AddRowButton("Ajouter un raccourci") {
      shortcuts.wrappedValue.append(TextShortcut(trigger: "", expansion: "@today"))
    }
    // Une rangée vierge de plus n'apporte rien tant que la précédente n'a pas de déclencheur.
    .disabled(
      shortcuts.wrappedValue.contains { $0.trigger.trimmingCharacters(in: .whitespaces).isEmpty })
  }
}

/// Champ mono-ligne centré, en `NSTextField` direct : `multilineTextAlignment` sur un `TextField`
/// SwiftUI n'a aucun effet ici, avec `.plain` comme avec `.roundedBorder` (vérifié à l'écran).
/// AppKit reste la seule couche où l'alignement s'applique vraiment.
private struct AlignedTextField: NSViewRepresentable {
  @Binding var text: String
  /// Centré pour une abréviation (une poignée de lettres dans une colonne étroite), à GAUCHE pour
  /// une valeur qu'on lit de son début — un nom de playlist, un lien qui déborde de sa colonne.
  var alignment: NSTextAlignment = .center
  /// `placeholderString` d'AppKit, et pas un `Text` en fond : c'est le champ lui-même qui l'efface
  /// à la première frappe, sans qu'on ait à suivre l'état de la saisie.
  var placeholder: String = ""

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.alignment = alignment
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
    // L'invite suit le LECTEUR choisi : elle change sous la rangée, sans que celle-ci soit refaite.
    if field.placeholderString != placeholder { field.placeholderString = placeholder }
    if field.alignment != alignment { field.alignment = alignment }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  // ponytail: le champ GARDE le focus quand on clique à côté — AppKit ne le retire pas tout seul, et
  // la fenêtre de réglages le donne d'office au premier champ venu. Un moniteur `NSEvent` posé à la
  // prise de focus a été écrit puis RETIRÉ le 9 août 2026 : impossible de démontrer qu'il marchait
  // (un clic synthétique envoyé par `NSApp.sendEvent` ne réveille pas les moniteurs locaux, donc le
  // banc ne prouvait rien dans un sens ni dans l'autre). Le rétablir demande d'abord un moyen de
  // rejouer un VRAI clic — sans quoi on rachète du code qu'on ne peut pas juger.
  final class Coordinator: NSObject, NSTextFieldDelegate {
    let text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      text.wrappedValue = field.stringValue
    }
  }
}

/// Pas un bouton gris encadré : dans une fenêtre de réglages macOS, l'ajout d'une ligne est un lien
/// accentué au pied de la liste (« Ajouter un compte… » des Réglages Système). Le cadre faisait de
/// cette action banale le point le plus lourd de la section.
private struct AddRowButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button {
      withAnimation(.snappy(duration: 0.2), action)
    } label: {
      Label(title, systemImage: "plus.circle.fill")
        .foregroundStyle(.tint)
    }
    .buttonStyle(.plain)
  }
}

private struct TasksSettingsTab: View {
  @AppStorage(CompletedTaskRetention.storageKey) private var retentionRaw = CompletedTaskRetention
    .untilNextDay.rawValue
  @AppStorage(TodoList.autoSortCompletedStorageKey) private var autoSortCompleted = true
  @AppStorage(TaskItem.progressResetsDailyStorageKey) private var progressResetsDaily = true

  var body: some View {
    SettingsPane(height: 500) {
      Section {
        Picker("Conserver", selection: $retentionRaw) {
          ForEach(CompletedTaskRetention.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }

        Toggle("Descendre en bas de la liste", isOn: $autoSortCompleted)
        Toggle("Réinitialiser l'anneau de progression chaque jour", isOn: $progressResetsDaily)
      } header: {
        Text("Tâches cochées")
      } footer: {
        Text(
          "Désactivé, l'anneau d'une liste ou d'un projet cumule tout ce qui a jamais été coché, "
            + "au lieu de repartir de zéro chaque jour."
        )
        .foregroundStyle(.secondary)
      }

      RemindersSyncSection()
    }
  }
}

/// Le pont avec l'app Rappels : UNE liste, et deux sens qu'on active séparément.
///
/// La même liste dans les deux sens, et c'est le réglage qui porte tout le reste : elle borne
/// l'import à ce que l'utilisateur a désigné. Sans elle, activer l'import aspirerait tout ce que
/// contient Rappels — les courses, les rappels d'anniversaire, les listes partagées — dans une app
/// de travail. Les deux bascules restent inertes tant qu'aucune liste n'est choisie, et la vue le
/// DIT plutôt que de le laisser deviner : un réglage qui peut s'oublier en silence est un bug en
/// attente.
private struct RemindersSyncSection: View {
  @Environment(RemindersService.self) private var remindersService
  @AppStorage(RemindersSync.pushStorageKey) private var push = false
  @AppStorage(RemindersSync.importStorageKey) private var importReminders = false
  @AppStorage(RemindersSync.listStorageKey) private var listID = ""
  @AppStorage(RemindersSync.dueHourStorageKey) private var dueHour = RemindersSync.dueHour
  @State private var accessDenied = false

  var body: some View {
    Section("Rappels Apple") {
      if accessDenied {
        Text(RemindersError.accessDenied.errorDescription ?? "")
          .font(.app(.caption)).foregroundStyle(.secondary)
        Button("Ouvrir les Réglages Système") {
          let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
          NSWorkspace.shared.open(url)
        }
      } else {
        Picker("Liste", selection: $listID) {
          Text("Aucune").tag("")
          ForEach(remindersService.writableLists, id: \.calendarIdentifier) { list in
            Text(list.title).tag(list.calendarIdentifier)
          }
        }

        Toggle("Créer un rappel pour les tâches datées", isOn: $push)
        Toggle("Importer les rappels datés comme tâches", isOn: $importReminders)

        if push {
          // L'heure des tâches qui n'en ont pas : une tâche peut porter la sienne (cf.
          // `WhenPicker`), et c'est elle qui prime alors. Sans aucune des deux, le rappel échoirait
          // à minuit et sonnerait la veille au soir.
          // ponytail: heures pleines seulement — les minutes demanderaient de stocker un minutage
          // plutôt qu'une heure, à faire si 8 h 30 manque vraiment comme DÉFAUT (une tâche, elle,
          // sait déjà se poser à 8 h 30).
          Picker("Heure par défaut", selection: $dueHour) {
            ForEach(0..<24, id: \.self) { hour in
              Text(String(format: "%02d:00", hour)).tag(hour)
            }
          }
          Text(
            "Pour les tâches sans heure à elles. Les rappels déjà créés gardent la leur : "
              + "seuls les prochains suivent ce réglage."
          )
          .font(.app(.caption)).foregroundStyle(.secondary)
        }

        if listID.isEmpty && (push || importReminders) {
          // Le triangle plutôt que le texte seul : une bascule allumée a l'air de marcher, et un
          // gris secondaire sous elle se lit comme une note de bas de page. L'icône est ce qui dit
          // que le réglage est INCOMPLET. `.orange` en dur est correct ici — c'est la couleur
          // système de l'avertissement, la même dans les deux thèmes (contrairement à un fond de
          // maquette, qui lui se doublerait).
          Label {
            Text("Choisis une liste : sans elle, rien ne circule dans un sens ni dans l'autre.")
              .font(.app(.caption)).foregroundStyle(.secondary)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }
    }
    // L'accès est demandé à l'ouverture de l'onglet, pas au premier basculement : `writableLists`
    // est VIDE tant qu'il n'est pas accordé, et le Picker n'aurait affiché que « Aucune » — soit
    // un réglage qui a l'air cassé plutôt qu'un réglage qui demande la permission.
    .task { accessDenied = ((try? await remindersService.requestAccess()) == nil) }
  }
}

/// Ce que le champ « Playlist » a compris du lien Spotify collé. Un état de VUE, pas une règle
/// métier : il ne dit rien de plus que « où en est la vérification », et c'est pour ça qu'il vit ici.
private enum SpotifyLinkCheck {
  case idle
  case checking
  case found(String)
  case unknown

  var message: String? {
    switch self {
    case .idle: return nil
    case .checking: return "Vérification…"
    case .found(let title): return title
    case .unknown: return "Lien Spotify non reconnu."
    }
  }

  var icon: String {
    switch self {
    case .found: return "checkmark.circle.fill"
    case .unknown: return "exclamationmark.triangle.fill"
    case .idle, .checking: return "ellipsis.circle"
    }
  }

  /// `.secondary` et pas une couleur figée pour les deux états neutres — et pour les deux autres,
  /// des couleurs SÉMANTIQUES, qui s'adaptent seules au thème sombre (cf. CLAUDE.md, Conventions).
  var tint: Color {
    switch self {
    case .found: return .green
    case .unknown: return .orange
    case .idle, .checking: return .secondary
    }
  }
}

/// Les playlists enregistrées, au MÊME patron que `TextShortcutsSection` : en-têtes de colonnes,
/// une rangée par entrée avec ses champs et son « − » au survol, un lien d'ajout accentué en pied.
/// Le maître-détail qui l'a précédée (un menu qui choisit, des champs qui éditent l'entrée choisie)
/// forçait à apprendre un second vocabulaire pour la même idée — retiré le 9 août 2026.
///
/// Le rond en tête de rangée porte ce que la liste des raccourcis n'a pas à porter : là-bas chaque
/// ligne agit, ici une seule joue.
///
/// Le choix du LECTEUR vit ici, et pas dans la section « Musique » d'à côté, parce que c'est lui qui
/// pilote ce tableau : il change le titre de la colonne, filtre les entrées affichées, et décide
/// d'un champ ou d'un menu. Rangé à côté du volume, la cause était dans un bloc et l'effet dans
/// l'autre — « Musique » dit désormais COMMENT ça joue, « Playlists » dit QUOI, et où.
private struct MusicPlaylistsSection: View {
  @AppStorage(MusicPlayer.appKey) private var musicApp = MusicApp.spotify.rawValue
  @AppStorage(SavedPlaylist.storageKey) private var libraryData = Data()
  @AppStorage(MusicPlayer.selectionKey) private var selection = ""
  @AppStorage(MusicPlayer.legacyPlaylistKey) private var legacyPlaylist = ""

  @State private var hovered: SavedPlaylist.ID?
  @State private var linkCheck = SpotifyLinkCheck.idle
  /// Les noms lus dans Musique. Chargés ici depuis que le choix du lecteur y est : c'est cette
  /// section qui sait quand il change, et elle seule qui s'en sert.
  @State private var musicPlaylists: [String] = []

  private var player: MusicApp { MusicApp(rawValue: musicApp) ?? .spotify }

  private static let nameWidth: CGFloat = 104
  private static let columns: CGFloat = 12
  private static let radioWidth: CGFloat = 16

  /// Même idiome que les deux sections de raccourcis : on n'AFFICHE que les entrées du lecteur
  /// courant, mais l'écriture réinjecte les autres — sans quoi passer à Musique effacerait les
  /// playlists Spotify, sans un mot.
  private var playlists: Binding<[SavedPlaylist]> {
    Binding(
      get: { SavedPlaylist.decode(libraryData).filter { $0.app == player } },
      set: { edited in
        let others = SavedPlaylist.decode(libraryData).filter { $0.app != player }
        libraryData = SavedPlaylist.encode(others + edited)
      })
  }

  /// Comparé en `UUID` et pas en chaîne : `uuidString` sort en MAJUSCULES, et une sélection écrite
  /// autrement ne désignerait plus rien — une liste où aucun rond n'est plein, sans explication.
  private func isSelected(_ id: UUID) -> Bool { UUID(uuidString: selection) == id }

  private var selected: SavedPlaylist? {
    playlists.wrappedValue.first { isSelected($0.id) }
  }

  var body: some View {
    Section {
      Picker("Lecteur", selection: $musicApp) {
        ForEach(MusicApp.allCases) { app in
          Text(app.label).tag(app.rawValue)
        }
      }

      columnHeaders

      if playlists.wrappedValue.isEmpty {
        Text("Aucune playlist")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      ForEach(playlists) { $entry in row($entry) }

      addButton
    } header: {
      Text("Playlists")
    } footer: {
      footer
    }
    .task(id: musicApp) {
      adoptLegacyPlaylist()
      musicPlaylists = player == .music ? await MusicPlayer.shared.musicPlaylistNames() : []
      await checkSelectedLink()
    }
    .task(id: selected) { await checkSelectedLink() }
  }

  private var columnHeaders: some View {
    HStack(spacing: Self.columns) {
      Color.clear.frame(width: Self.radioWidth, height: 0)
      // Retraits optiques : le texte d'un champ bordé commence à l'intérieur de son cadre, l'en-tête
      // s'aligne sur les LETTRES (cf. `TextShortcutsSection.columnHeaders`).
      Text("Nom")
        .padding(.leading, 5)
        .frame(width: Self.nameWidth, alignment: .leading)
      Text(player.linkColumn)
        .padding(.leading, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
      Color.clear.frame(width: RemoveButton.width, height: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func row(_ entry: Binding<SavedPlaylist>) -> some View {
    let id = entry.wrappedValue.id
    return HStack(spacing: Self.columns) {
      // Un rond et pas une case à cocher : une seule playlist joue à la fois, et c'est exactement ce
      // qu'un radio dit sur macOS. Recliquer le rond plein le VIDE — sinon, une fois une playlist
      // choisie, on ne pourrait plus revenir à « reprendre la lecture en cours ».
      Button {
        selection = isSelected(id) ? "" : id.uuidString
      } label: {
        Image(systemName: isSelected(id) ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(isSelected(id) ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .frame(width: Self.radioWidth)
      .help("La playlist qui se lance avec un pomodoro")

      field(entry.name, prompt: "Deep Focus")
        .frame(width: Self.nameWidth)

      // Spotify se COLLE, Musique se CHOISIT : sa bibliothèque est lisible (cf.
      // `MusicPlayer.musicPlaylistNames`), celle de Spotify ne l'est pas. Un menu là où l'on peut
      // proposer, un champ là où il faut coller — le même partage que `ActionPicker` dans la rangée
      // d'un raccourci. Musique fermée, rien à proposer : le champ reprend la main, sans quoi la
      // rangée deviendrait inéditable.
      if player == .music, !musicPlaylists.isEmpty {
        Picker("", selection: entry.link) {
          // La valeur enregistrée peut ne plus exister dans Musique (playlist renommée) : sans cette
          // entrée, le menu s'afficherait vide et l'effacerait au premier rendu.
          if !musicPlaylists.contains(entry.wrappedValue.link) {
            Text(entry.wrappedValue.link.isEmpty ? "Choisir…" : entry.wrappedValue.link)
              .tag(entry.wrappedValue.link)
          }
          ForEach(musicPlaylists, id: \.self) { name in
            Text(name).tag(name)
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
      } else {
        field(entry.link, prompt: player.playlistPrompt)
          .frame(maxWidth: .infinity)
      }

      RemoveButton(isHighlighted: hovered == id) {
        withAnimation(.snappy(duration: 0.2)) {
          playlists.wrappedValue.removeAll { $0.id == id }
          if isSelected(id) { selection = "" }
        }
      }
    }
    .onHover { inside in
      if inside {
        hovered = id
      } else if hovered == id {
        hovered = nil
      }
    }
    .animation(.easeOut(duration: 0.12), value: hovered)
  }

  /// `AlignedTextField` et pas un `TextField` SwiftUI : mêmes métriques exactement que la rangée
  /// d'un raccourci — le `TextField` rendait une boîte plus haute, texte flottant vers le bas
  /// (vérifié à la capture le 9 août 2026). C'est la raison d'être de ce composant.
  private func field(_ text: Binding<String>, prompt: String) -> some View {
    AlignedTextField(text: text, alignment: .left, placeholder: prompt)
      .padding(.horizontal, 5)
      .padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)))
  }

  private var addButton: some View {
    AddRowButton("Ajouter une playlist") {
      let entry = SavedPlaylist(app: player)
      playlists.wrappedValue.append(entry)
      // La nouvelle joue d'office : on vient de demander une playlist, pas de garder l'ancienne.
      selection = entry.id.uuidString
    }
    // Une rangée vierge de plus n'apporte rien tant que la précédente n'a pas de destination — même
    // règle que les raccourcis, et c'est elle qui empêche d'empiler des lignes vides d'un doigt.
    .disabled(
      playlists.wrappedValue.contains { $0.link.trimmingCharacters(in: .whitespaces).isEmpty })
  }

  @ViewBuilder private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let message = linkCheck.message {
        Label(message, systemImage: linkCheck.icon)
          .foregroundStyle(linkCheck.tint)
      }
      Text(
        "Le rond désigne la playlist qui se lance avec un pomodoro — sans lui, Today reprend "
          + "simplement la lecture en cours. Elle repart du début à chaque remise à zéro du "
          + "minuteur, pas après une pause."
      )
      .foregroundStyle(.secondary)
    }
  }

  /// Spotify ne sait pas lister ses playlists, alors la section dit au moins ce qu'elle a COMPRIS du
  /// lien de celle qui joue — la vraie question devant un identifiant de 22 caractères. Et le titre
  /// obtenu la NOMME quand elle n'a pas de nom : celui qu'on taperait est déjà celui de Spotify.
  private func checkSelectedLink() async {
    linkCheck = .idle
    guard player == .spotify, let entry = selected,
      let uri = MusicPlaylist.spotifyURI(from: entry.link)
    else { return }
    // Le champ se remplit caractère par caractère. `.task(id:)` annule la passe précédente à chaque
    // frappe : cette attente fait qu'une seule part vraiment sur le réseau, la dernière.
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled else { return }
    linkCheck = .checking
    guard let title = await MusicPlayer.spotifyTitle(for: uri) else {
      linkCheck = .unknown
      return
    }
    linkCheck = .found(title)
    guard entry.name.isEmpty else { return }
    var all = playlists.wrappedValue
    guard let index = all.firstIndex(where: { $0.id == entry.id }) else { return }
    all[index].name = title
    playlists.wrappedValue = all
  }

  /// Le lien d'avant la bibliothèque, promu en première entrée. `libraryData` vide et pas « décodée
  /// vide » : une bibliothèque que l'utilisateur a VIDÉE contient « [] », et ne doit pas voir
  /// l'ancien lien ressusciter à chaque ouverture des réglages.
  private func adoptLegacyPlaylist() {
    guard libraryData.isEmpty, !legacyPlaylist.isEmpty else { return }
    let entry = SavedPlaylist(link: legacyPlaylist, app: player)
    libraryData = SavedPlaylist.encode([entry])
    selection = entry.id.uuidString
    legacyPlaylist = ""
  }
}

private struct PomodoroSettingsTab: View {
  @AppStorage(PomodoroTimer.autoStartStorageKey) private var pomodoroAutoStart = false
  @AppStorage(MusicPlayer.enabledKey) private var musicEnabled = false
  @AppStorage(MusicPlayer.volumeKey) private var musicVolume = MusicPlayer.defaultVolume
  @AppStorage(MusicPlayer.fadeKey) private var musicFade = MusicPlayer.defaultFadeSeconds

  var body: some View {
    // 820 : ce qu'il faut pour que « Minuteur », « Sons » et « Musique » tiennent SANS défiler —
    // vérifié à la capture d'écran le 9 août 2026 (la section « Sons » est passée d'1 à 4 rangées,
    // une par événement sonore, chacune alignée sur une seule ligne via `LabeledContent`). Les deux
    // sections de raccourcis, elles, débordent et déborderont toujours : leurs tableaux grandissent
    // d'une ligne à chaque raccourci ajouté, aucune hauteur fixe ne peut les contenir. Elles sont en
    // dernier pour cette raison, et c'est le défilement du `Form` qui les sert.
    SettingsPane(height: 820) {
      Section("Minuteur") {
        Toggle("Enchaîner automatiquement les phases", isOn: $pomodoroAutoStart)
      }

      // Les quatre événements sonores du minuteur, chacun réglable indépendamment — sans ça, un son
      // qui rappelle une autre app (ex. le bruit de fin de tâche d'un outil en ligne de commande) ne
      // se change pas.
      Section("Sons") {
        SoundPickerRow(
          label: "Démarrage", key: PomodoroSound.start.storageKey,
          defaultValue: PomodoroSound.start.defaultSoundName)
        SoundPickerRow(
          label: "Pause", key: PomodoroSound.pause.storageKey,
          defaultValue: PomodoroSound.pause.defaultSoundName)
        SoundPickerRow(
          label: "Début de pause", key: PomodoroSound.rest.storageKey,
          defaultValue: PomodoroSound.rest.defaultSoundName)
        SoundPickerRow(
          label: "Alarme", key: PomodoroTimer.alertSoundStorageKey,
          defaultValue: PomodoroTimer.defaultAlertSound)
      }

      // Ce que fait la musique, pas ce qu'elle joue : le choix du lecteur est parti avec le tableau
      // qu'il pilote (cf. `MusicPlaylistsSection`).
      Section("Musique") {
        Toggle("Jouer pendant les phases de travail", isOn: $musicEnabled)

        Stepper("Volume : \(musicVolume) %", value: $musicVolume, in: 0...100, step: 5)

        Stepper("Fondu avant l'alarme : \(musicFade) s", value: $musicFade, in: 3...15)
      }

      MusicPlaylistsSection()

      PomodoroKeyShortcutsSection()
      PomodoroTextShortcutsSection()
    }
  }
}

/// Une rangée « son système + bouton de test », pour un des quatre événements sonores du pomodoro
/// (démarrage, pause, début de pause, alarme — cf. `PomodoroSound` et
/// `PomodoroTimer.alertSoundStorageKey`). Les quatre rangées ne diffèrent que par leur étiquette et
/// leur clé de réglage, d'où la clé passée à l'initialisation plutôt que quatre blocs Picker+Bouton
/// recopiés.
private struct SoundPickerRow: View {
  let label: String
  @AppStorage private var sound: String

  init(label: String, key: String, defaultValue: String) {
    self.label = label
    _sound = AppStorage(wrappedValue: defaultValue, key)
  }

  var body: some View {
    // `LabeledContent`, comme « Recherche manuelle » plus haut : c'est lui qui aligne le picker et
    // le bouton sur la colonne des autres rangées, seuls, ils flotteraient à gauche l'un sous
    // l'autre.
    LabeledContent(label) {
      HStack(spacing: 12) {
        Picker("", selection: $sound) {
          ForEach(PomodoroTimer.availableSounds, id: \.self) { name in
            Text(name).tag(name)
          }
        }
        .labelsHidden()
        .frame(width: 130)

        Button("Tester le son") {
          NSSound(named: sound)?.play()
        }
      }
    }
  }
}

/// Le pendant, pour les cinq commandes du minuteur, de `KeyShortcutsSection` (onglet Raccourcis) :
/// MÊME patron — une ligne par raccourci, chacune choisit sa propre action, ajout/retrait libres —
/// plutôt qu'un tableau à 5 lignes fixes. Le tableau fixe avait fini par cohabiter avec une section
/// de synonymes greffée dessus (le 4 août 2026) : deux façons de lire « une combinaison pour une
/// action » dans la même fenêtre, la confusion signalée. Reprendre le patron déjà clair de l'onglet
/// Raccourcis, restreint aux actions du minuteur via `PomodoroActionPicker`, n'en laisse qu'une.
///
/// Même stockage que l'onglet Raccourcis (`KeyShortcut.storageKey`) : un raccourci Pomodoro réglé ici
/// répondrait aussi à un onglet Raccourcis qui l'afficherait — il ne l'affiche plus (cf.
/// `KeyShortcutsSection.shortcuts`, qui filtre l'inverse), mais rien n'empêcherait de le remontrer un
/// jour sans migration.
private struct PomodoroKeyShortcutsSection: View {
  @AppStorage(KeyShortcut.storageKey) private var keyData = Data()
  @State private var hovered: KeyShortcut.ID?

  private static let keyWidth: CGFloat = 104
  private static let columns: CGFloat = 10

  private var shortcuts: Binding<[KeyShortcut]> {
    Binding(
      get: { KeyShortcut.decode(keyData).filter { isPomodoro($0.expansion) } },
      set: { edited in
        var all = KeyShortcut.decode(keyData)
        all.removeAll { isPomodoro($0.expansion) }
        keyData = KeyShortcut.encode(all + edited)
      })
  }

  private func isPomodoro(_ token: String) -> Bool {
    AppCommand(token: token)?.isPomodoro ?? false
  }

  var body: some View {
    Section {
      if shortcuts.wrappedValue.isEmpty {
        Text("Aucune combinaison")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        columnHeaders
      }
      ForEach(shortcuts) { $shortcut in row($shortcut) }
      addButton
    } header: {
      Text("Saisie rapide")
    } footer: {
      Text("Une combinaison agit même quand Today est en arrière-plan.")
        .foregroundStyle(.secondary)
    }
    // Les combinaisons sont enregistrées auprès du système : sans réenregistrement, l'ancienne
    // répondrait encore (même raison qu'à l'onglet Raccourcis).
    .onChange(of: keyData) { GlobalHotKey.shared.reload() }
  }

  private var columnHeaders: some View {
    HStack(spacing: Self.columns) {
      Text("Action")
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Touches")
        .frame(width: Self.keyWidth, alignment: .center)
      Color.clear.frame(width: RemoveButton.width, height: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func row(_ shortcut: Binding<KeyShortcut>) -> some View {
    let id = shortcut.wrappedValue.id
    return HStack(spacing: Self.columns) {
      PomodoroActionPicker(token: shortcut.expansion)
      HotKeyRecorder(combo: shortcut.key, width: Self.keyWidth)
      RemoveButton(isHighlighted: hovered == id) {
        withAnimation(.snappy(duration: 0.2)) {
          shortcuts.wrappedValue.removeAll { $0.id == id }
        }
      }
    }
    .onHover { inside in
      if inside {
        hovered = id
      } else if hovered == id {
        hovered = nil
      }
    }
    .animation(.easeOut(duration: 0.12), value: hovered)
  }

  private var addButton: some View {
    AddRowButton("Ajouter une combinaison") {
      shortcuts.wrappedValue.append(KeyShortcut(expansion: AppCommand.pomodoroStart.token))
    }
    .disabled(shortcuts.wrappedValue.contains { $0.key == nil })
  }
}

/// Le pendant, pour les cinq commandes du minuteur, de `TextShortcutsSection` — même raison et même
/// patron que `PomodoroKeyShortcutsSection` ci-dessus, côté abréviations tapées dans la capsule.
private struct PomodoroTextShortcutsSection: View {
  @AppStorage(TextShortcut.storageKey) private var textData = Data()
  @State private var hovered: TextShortcut.ID?

  private static let triggerWidth: CGFloat = 96
  private static let columns: CGFloat = 12

  private var shortcuts: Binding<[TextShortcut]> {
    Binding(
      get: { TextShortcut.decode(textData).filter { isPomodoro($0.expansion) } },
      set: { edited in
        var all = TextShortcut.decode(textData)
        all.removeAll { isPomodoro($0.expansion) }
        textData = TextShortcut.encode(all + edited)
      })
  }

  private func isPomodoro(_ token: String) -> Bool {
    AppCommand(token: token)?.isPomodoro ?? false
  }

  var body: some View {
    Section {
      if shortcuts.wrappedValue.isEmpty {
        Text("Aucune abréviation")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        columnHeaders
      }
      ForEach(shortcuts) { $shortcut in row($shortcut) }
      addButton
    } header: {
      Text("Actions Spotlight")
    } footer: {
      Text("Tapez l'abréviation puis ⇥, dans la saisie rapide comme dans une liste.")
        .foregroundStyle(.secondary)
    }
  }

  private var columnHeaders: some View {
    HStack(spacing: Self.columns) {
      Text("Raccourci")
        .padding(.leading, 5)
        .frame(width: Self.triggerWidth, alignment: .leading)
      Text("Action")
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
      Color.clear.frame(width: RemoveButton.width, height: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func row(_ shortcut: Binding<TextShortcut>) -> some View {
    let id = shortcut.wrappedValue.id
    return HStack(spacing: Self.columns) {
      AlignedTextField(text: shortcut.trigger)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)))
        .frame(width: Self.triggerWidth)
      PomodoroActionPicker(token: shortcut.expansion)
      RemoveButton(isHighlighted: hovered == id) {
        withAnimation(.snappy(duration: 0.2)) {
          shortcuts.wrappedValue.removeAll { $0.id == id }
        }
      }
    }
    .onHover { inside in
      if inside {
        hovered = id
      } else if hovered == id {
        hovered = nil
      }
    }
    .animation(.easeOut(duration: 0.12), value: hovered)
  }

  private var addButton: some View {
    AddRowButton("Ajouter une abréviation") {
      shortcuts.wrappedValue.append(
        TextShortcut(trigger: "", expansion: AppCommand.pomodoroStart.token))
    }
    .disabled(
      shortcuts.wrappedValue.contains { $0.trigger.trimmingCharacters(in: .whitespaces).isEmpty })
  }
}

/// Le même menu qu'`ActionPicker`, réduit aux cinq actions du minuteur : les seules concernées ici.
private struct PomodoroActionPicker: View {
  @Binding var token: String

  var body: some View {
    Picker("", selection: $token) {
      ForEach(AppCommand.pomodoroCommands) { command in
        Text(command.label).tag(command.token)
      }
    }
    .labelsHidden()
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
