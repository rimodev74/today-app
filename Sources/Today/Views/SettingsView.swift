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

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.alignment = .center
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

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

  var body: some View {
    SettingsPane(height: 470) {
      Section("Tâches cochées") {
        Picker("Conserver", selection: $retentionRaw) {
          ForEach(CompletedTaskRetention.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }

        Toggle("Descendre en bas de la liste", isOn: $autoSortCompleted)
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

private struct PomodoroSettingsTab: View {
  @AppStorage(PomodoroTimer.autoStartStorageKey) private var pomodoroAutoStart = false
  @AppStorage(PomodoroTimer.alertSoundStorageKey) private var pomodoroAlertSound = PomodoroTimer
    .defaultAlertSound

  var body: some View {
    // ponytail: 640 est une estimation (pas re-mesurée à l'écran comme les 610 d'origine) — à
    // ajuster si les deux sections de raccourcis débordent une fois quelques lignes ajoutées.
    SettingsPane(height: 640) {
      Section("Minuteur") {
        Toggle("Enchaîner automatiquement les phases", isOn: $pomodoroAutoStart)
      }

      Section("Alerte") {
        Picker("Son d'alarme", selection: $pomodoroAlertSound) {
          ForEach(PomodoroTimer.availableSounds, id: \.self) { name in
            Text(name).tag(name)
          }
        }

        Button("Tester le son") {
          NSSound(named: pomodoroAlertSound)?.play()
        }
      }

      PomodoroKeyShortcutsSection()
      PomodoroTextShortcutsSection()
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
