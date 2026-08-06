import SwiftData

extension ModelContext {
  /// Insère un modèle et l'enregistre aussitôt.
  ///
  /// À utiliser dès que la vue va mémoriser l'identifiant du modèle créé (identité d'un
  /// ForEach, sélection, ligne en cours de renommage).
  ///
  /// Un modèle inséré mais pas encore enregistré porte un `persistentModelID`
  /// *temporaire*, que SwiftData remplace par l'identifiant définitif au premier
  /// enregistrement — c'est-à-dire à l'autosave, quelques instants plus tard. Tout ce qui
  /// avait mémorisé l'ancien pointe alors dans le vide : la ligne semble disparaître puis
  /// revenir, et un état d'édition mémorisé se dénoue tout seul. Enregistrer tout de suite
  /// fixe l'identifiant avant que la vue ne le lise.
  func insertAndSave<T: PersistentModel>(_ model: T) {
    insert(model)
    try? save()
  }

  /// Supprime un modèle et enregistre, en tenant l'`UndoManager` À L'ÉCART de la cascade.
  ///
  /// À réserver aux suppressions qui en emportent d'autres SUR PLUSIEURS NIVEAUX — un projet
  /// emporte ses listes, qui emportent leurs tâches, qui emportent leurs sous-tâches. Là, et
  /// seulement là, SwiftData tombe pendant le `save()` :
  ///
  ///     SwiftData/DataUtilities.swift:541: Fatal error:
  ///     A snapshot should exist before creating a new snapshot for undo
  ///
  /// Mesuré le 6 août 2026 en rejouant la suppression sur une COPIE de la vraie base, une copie
  /// neuve par projet : **sans** manager branché, les 6 projets partent sans un mot ; **avec**, le
  /// premier fait tomber l'app. Même partage pour les listes. Supprimer une TÂCHE, sous-tâches
  /// comprises, ne pose aucun problème — c'est le niveau de cascade supplémentaire qui casse, pas
  /// la cascade elle-même. D'où un helper réservé aux deux appelants concernés (`SidebarView` pour
  /// un projet, `TodoList.delete` pour une liste) : passer TOUTES les suppressions par ici
  /// retirerait ⌘Z de la suppression d'une tâche, qui marche et qui compte (⌫ efface pour de bon,
  /// l'app n'a pas de corbeille).
  ///
  /// La pile d'annulation est VIDÉE au passage, et pas seulement débranchée : ce qu'elle contient
  /// parle peut-être d'objets que la cascade vient d'effacer — une modification de tâche faite
  /// juste avant, par exemple. Un ⌘Z dessus rejouerait une écriture sur un objet qui n'existe plus.
  func deleteCascadeAndSave<T: PersistentModel>(_ model: T) {
    let manager = undoManager
    undoManager = nil
    delete(model)
    try? save()
    // `UndoManager` est isolé au fil principal, pas `ModelContext`. `assumeIsolated` plutôt que
    // marquer tout le helper `@MainActor` : ça remonterait jusqu'à `TodoList.delete`, qui vit dans
    // `Models/` et n'a aucune raison de connaître un acteur. Les deux appelants sont des vues, donc
    // le fil principal — si ce n'était pas le cas, l'app s'arrêterait ici au lieu de corrompre la
    // pile d'annulation en silence.
    MainActor.assumeIsolated { manager?.removeAllActions() }
    undoManager = manager
  }

  /// LA suppression de tâches, pour les cinq pages — l'ordre correct des trois gestes, écrit UNE
  /// fois : lire les identifiants de rappel, supprimer et enregistrer, PUIS effacer les rappels.
  ///
  /// Les cinq pages faisaient l'inverse (`remindersService.forget(task)` AVANT le `delete`), ce qui
  /// est la mécanique exacte qui faisait planter la suppression d'un projet : effacer un rappel fait
  /// écrire EventKit, qui poste `.EKEventStoreChanged`, qui relance la synchro de `ContentView`, qui
  /// RÉENREGISTRE ce même contexte — au milieu de la mutation qu'on est en train d'écrire. Ça n'a
  /// jamais planté sur une tâche seule (sa cascade est bien plus courte que celle d'un projet), mais
  /// c'est la même bombe, six fois. D'où un helper : l'ordre ne peut plus s'écrire à l'envers.
  ///
  /// Des IDENTIFIANTS et pas des tâches, pour la même raison qu'en tête de `TodoList.delete` : une
  /// chaîne survit à ce que SwiftData efface, un objet non.
  ///
  /// Pas de `deleteCascadeAndSave` ici, délibérément : une tâche n'emporte qu'un niveau (ses
  /// sous-tâches), ce que SwiftData encaisse sans broncher, et lui retirer l'`UndoManager` retirerait
  /// ⌘Z de la suppression d'une tâche — qui marche, et qui compte (⌫ efface pour de bon).
  func deleteTasksAndSave(_ tasks: [TaskItem], forgetReminders: ([String]) -> Void) {
    let doomedReminders = tasks.compactMap(\.reminderIdentifier)
    for task in tasks { delete(task) }
    try? save()
    forgetReminders(doomedReminders)
  }
}
