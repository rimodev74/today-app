import AppKit
import SwiftUI

/// Une action que la barre de menus déclenche dans la scène au premier plan.
///
/// L'identité est une chaîne, pas la fermeture : `focusedSceneValue` republie sa valeur à chaque
/// rendu de la vue qui la porte, et une fermeture est neuve à chaque passe. Sans identité stable,
/// toute la barre de menus se réévaluerait à chaque frappe.
///
/// **En contrepartie, l'identité doit nommer l'action ET SA CIBLE.** `focusedSceneValue` compare
/// avec ce `==` et n'écrit RIEN quand la valeur est égale : deux pages qui publient le même `id`
/// laissent la fermeture de la PREMIÈRE en place, et le raccourci reste branché sur la page qu'on
/// a quittée. Tracé le 9 septembre 2026 avec un `id` de `"newTask"` partout : arrivé sur « Tâches »,
/// ⌘N exécutait encore la création d'« Aujourd'hui ». La tâche naissait donc hors de la page
/// regardée, et rien n'y apparaissait. D'où les `id` suffixés par la page ou par l'`uuid` de ce
/// qu'ils visent.
struct MenuAction: Equatable {
  /// Ce que l'action fait ET sur quoi. Jamais le seul nom du geste : cf. le commentaire du type.
  let id: String
  let run: () -> Void

  static func == (lhs: MenuAction, rhs: MenuAction) -> Bool { lhs.id == rhs.id }
}

/// La bascule de la barre latérale. Un type à part parce que l'item de menu doit connaître l'ÉTAT
/// pour se libeller (« Masquer » / « Afficher »), là où les autres n'ont qu'à agir.
struct SidebarToggle: Equatable {
  let isVisible: Bool
  let run: () -> Void

  static func == (lhs: SidebarToggle, rhs: SidebarToggle) -> Bool { lhs.isVisible == rhs.isVisible }
}

// `FocusedValueKey` à la main et pas la macro `@Entry` : celle-ci demande macOS 15, le minimum du
// projet est 14 — et le compilateur ne le dirait pas (cf. CLAUDE.md § « Ce qui doit rester vrai »).
private struct NewTaskKey: FocusedValueKey { typealias Value = MenuAction }
private struct NewHeaderKey: FocusedValueKey { typealias Value = MenuAction }
private struct NewListKey: FocusedValueKey { typealias Value = MenuAction }
private struct NewProjectKey: FocusedValueKey { typealias Value = MenuAction }
private struct SearchKey: FocusedValueKey { typealias Value = MenuAction }
private struct SidebarToggleKey: FocusedValueKey { typealias Value = SidebarToggle }

extension FocusedValues {
  /// ⌘N — publiée par `TaskPageBase`, donc par les cinq pages d'un coup. `nil` sur une page qui ne
  /// crée rien (« À venir », « Archives ») : l'item se GRISE, au lieu de rester muet.
  var newTask: MenuAction? {
    get { self[NewTaskKey.self] }
    set { self[NewTaskKey.self] = newValue }
  }
  /// ⌘⇧N — publiée par la seule page qui porte des en-têtes de section (`ListPageView`).
  var newHeader: MenuAction? {
    get { self[NewHeaderKey.self] }
    set { self[NewHeaderKey.self] = newValue }
  }
  var newList: MenuAction? {
    get { self[NewListKey.self] }
    set { self[NewListKey.self] = newValue }
  }
  var newProject: MenuAction? {
    get { self[NewProjectKey.self] }
    set { self[NewProjectKey.self] = newValue }
  }
  var search: MenuAction? {
    get { self[SearchKey.self] }
    set { self[SearchKey.self] = newValue }
  }
  var sidebarToggle: SidebarToggle? {
    get { self[SidebarToggleKey.self] }
    set { self[SidebarToggleKey.self] = newValue }
  }
}

/// La barre de menus de Today.
///
/// Deux mécanismes, et deux seulement :
/// - **`AppCommand`** pour ce qui EMMÈNE quelque part ou pilote le minuteur. Il existait déjà pour
///   les raccourcis texte (`!today`) et sait ramener une fenêtre fermée au bouton rouge ; un item
///   de menu n'est qu'un déclencheur de plus sur le même chemin.
/// - **`FocusedValues`** pour ce qui agit DANS la page affichée. C'est le mécanisme natif prévu
///   pour qu'un menu parle à la scène active, et il apporte le grisage sans une ligne de plus.
///
/// Ce qui n'est PAS ici est délibéré : durée, rappel, dupliquer, priorité, couleur, renommer
/// restent au clic droit. Un menu qui liste tout est un menu que personne ne lit.
struct MainMenuCommands: Commands {
  @FocusedValue(\.newTask) private var newTask
  @FocusedValue(\.newHeader) private var newHeader
  @FocusedValue(\.newList) private var newList
  @FocusedValue(\.newProject) private var newProject
  @FocusedValue(\.search) private var search
  @FocusedValue(\.sidebarToggle) private var sidebarToggle

  /// Déclenche une action qui agit DANS la fenêtre principale — et seulement si c'est bien elle
  /// qui a le clavier.
  ///
  /// AppKit propose les équivalents clavier au MENU avant de les donner à la fenêtre clé. Sans
  /// cette garde, ⌘N frappé dans la capsule de saisie rapide créait une tâche dans la fenêtre de
  /// derrière — mesuré le 23 août 2026, et c'est le défaut exact que le moniteur `NSEvent`
  /// d'avant écartait par son test `event.window === window`. La capsule et le HUD sont des
  /// panneaux sans bordure, donc jamais `canBecomeMain` : le test tient en une ligne.
  ///
  /// Les Réglages, eux, sont une Scene à part : leurs valeurs focalisées ne sont pas celles de la
  /// fenêtre principale, l'item y est déjà grisé sans qu'on ait à s'en mêler.
  private func inMainWindow(_ action: MenuAction?) {
    guard NSApp.keyWindow?.canBecomeMain ?? false else { return }
    action?.run()
  }

  var body: some Commands {
    // *Fichier*. `replacing: .newItem` : c'est CE groupe qui portait le *Nouvelle fenêtre* d'office
    // de `WindowGroup` — celui qui ouvrait un onglet sur ⌘N. Il était vidé ; il est maintenant
    // rempli par les créations de l'app, ce qui fait revenir le menu *Fichier* avec.
    CommandGroup(replacing: .newItem) {
      Button("Nouvelle tâche") { inMainWindow(newTask) }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(newTask == nil)
      Button("Nouvel en-tête") { inMainWindow(newHeader) }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(newHeader == nil)
      Divider()
      Button("Nouvelle to-do list") { inMainWindow(newList) }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(newList == nil)
      Button("Nouveau projet") { inMainWindow(newProject) }
        .keyboardShortcut("n", modifiers: [.command, .option, .shift])
        .disabled(newProject == nil)
    }

    // La recherche de mise à jour n'existait que dans *Réglages ▸ Général*, là où personne ne va
    // la chercher : c'est le menu de l'app qui la porte sur macOS.
    CommandGroup(after: .appInfo) {
      Button("Rechercher les mises à jour…") { SparkleUpdater.shared.checkForUpdates() }
    }

    // *Édition*. ⌘F n'avait AUCUN raccourci : la palette ne s'ouvrait qu'à la souris, par la loupe.
    CommandGroup(after: .textEditing) {
      Button("Rechercher…") { inMainWindow(search) }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(search == nil)
      Divider()
      // Panneau natif AppKit pour ajouter/modifier/retirer un lien sur la sélection courante
      // (même mécanisme que Mail/Notes/TextEdit).
      Button("Ajouter un lien…") {
        NSApp.sendAction(#selector(NSTextView.orderFrontLinkPanel(_:)), to: nil, from: nil)
      }
      .keyboardShortcut("k", modifiers: .command)
    }

    // *Présentation*. Le raccourci existait déjà, porté par un bouton CACHÉ dans `ContentView` :
    // il marchait sans que rien ne l'annonce. Le menu *Format* possède aussi ⌘B (Gras) et vient
    // avant celui-ci ; AppKit ignorant les items désactivés, ⌘B bascule la barre latérale partout
    // SAUF dans une note en cours d'édition, où Gras l'emporte. C'était déjà le comportement.
    CommandGroup(after: .sidebar) {
      Button(
        sidebarToggle?.isVisible == false
          ? "Afficher la barre latérale" : "Masquer la barre latérale"
      ) {
        guard NSApp.keyWindow?.canBecomeMain ?? false else { return }
        sidebarToggle?.run()
      }
      .keyboardShortcut("b", modifiers: .command)
      .disabled(sidebarToggle == nil)
    }

    // ⌘1…⌘5 suivent la POSITION de la touche, pas le caractère : c'est le défaut de SwiftUI
    // (`localization: .automatic`) et c'est le bon. Mesuré sur ce clavier AZERTY : en `.custom`,
    // l'équivalent reste le chiffre « 1 » — le menu affiche « ⌘1 », mais il faut alors presser
    // ⌘⇧1, puisque le chiffre y est en majuscule. Le défaut stocke « & », « é », « " »… : le menu
    // les affiche tels quels, et la touche répond seule, comme dans Chrome ou Firefox.
    CommandMenu("Aller") {
      Button(SmartList.all.label) { AppCommand.reveal(.smartList(.all)) }
        .keyboardShortcut("1", modifiers: .command)
      Button(SmartList.today.label) { AppCommand.reveal(.smartList(.today)) }
        .keyboardShortcut("2", modifiers: .command)
      Button(SmartList.upcoming.label) { AppCommand.reveal(.smartList(.upcoming)) }
        .keyboardShortcut("3", modifiers: .command)
      Button(SmartList.archive.label) { AppCommand.reveal(.smartList(.archive)) }
        .keyboardShortcut("4", modifiers: .command)
      Divider()
      Button("Pomodoro") { AppCommand.reveal(.pomodoro) }
        .keyboardShortcut("5", modifiers: .command)
    }

    // Les cinq commandes du minuteur, telles qu'`AppCommand` les déclare déjà — libellés compris.
    // Pas de raccourci : les combinaisons GLOBALES des réglages jouent ce rôle, et elles ont
    // l'avantage de répondre app en arrière-plan.
    CommandMenu("Pomodoro") {
      ForEach(AppCommand.pomodoroCommands) { command in
        Button(command.label) { command.run() }
      }
    }
  }
}
