import Foundation
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
  /// À réserver aux suppressions qui emportent des objets que PERSONNE N'A LUS — un projet emporte
  /// ses listes, qui emportent leurs tâches, qui emportent leurs sous-tâches ; une tâche supprimée
  /// par la synchro sort d'un fetch, sous-tâches jamais rendues. Avec le manager branché, SwiftData
  /// tombe alors pendant le `save()` :
  ///
  ///     SwiftData/DataUtilities.swift:541: Fatal error:
  ///     A snapshot should exist before creating a new snapshot for undo
  ///
  /// Mesuré le 6 août 2026 en rejouant la suppression sur une COPIE de la vraie base, une copie
  /// neuve par projet : **sans** manager branché, les 6 projets partent sans un mot ; **avec**, le
  /// premier fait tomber l'app. Ce n'est PAS la profondeur qui décide, c'est l'instantané manquant
  /// d'un objet jamais lu (cf. `PIEGES.md` § « L'annulation et la cascade ») : ⌫ y échappe parce
  /// qu'une ligne supprimable a forcément été rendue. D'où un helper réservé aux appelants qui
  /// suppriment hors de l'affichage (`SidebarView` pour un projet, `TodoList.delete` pour une
  /// liste, `RemindersSyncPass` pour une tâche dont le rappel a disparu) : passer TOUTES les
  /// suppressions par ici retirerait ⌘Z de la suppression d'une tâche, qui marche et qui compte
  /// (⌫ efface pour de bon, l'app n'a pas de corbeille).
  ///
  /// La pile d'annulation est VIDÉE au passage, et pas seulement débranchée : ce qu'elle contient
  /// parle peut-être d'objets que la cascade vient d'effacer — une modification de tâche faite
  /// juste avant, par exemple. Un ⌘Z dessus rejouerait une écriture sur un objet qui n'existe plus.
  ///
  /// Rend `false` si l'enregistrement a échoué. La suppression reste alors EN ATTENTE dans le
  /// contexte (rien n'est annulé, cf. `saveReportingSuccess`), et l'appelant ne doit rien effacer
  /// côté Apple tout de suite : le disque relie encore ces tâches à leurs rappels. Qu'il passe par
  /// `runAfterNextSave`.
  ///
  /// Et le manager reste DÉBRANCHÉ jusqu'à ce qu'un enregistrement réussisse : la cascade en
  /// attente sera écrite par l'autosave, et l'écrire manager branché est précisément le plantage
  /// que ce helper existe pour éviter. ⌘Z est muet le temps de cet état — rare, et sans perte.
  @discardableResult
  func deleteCascadeAndSave<T: PersistentModel>(_ model: T) -> Bool {
    let manager = undoManager
    undoManager = nil
    delete(model)
    let saved = saveReportingSuccess()
    // `UndoManager` est isolé au fil principal, pas `ModelContext`. `assumeIsolated` plutôt que
    // marquer tout le helper `@MainActor` : ça remonterait jusqu'à `TodoList.delete`, qui vit dans
    // `Models/` et n'a aucune raison de connaître un acteur. Les appelants sont des vues et la passe
    // de synchro, donc le fil principal — si ce n'était pas le cas, l'app s'arrêterait ici au lieu
    // de corrompre la pile d'annulation en silence.
    MainActor.assumeIsolated { manager?.removeAllActions() }
    // Rien à rendre si le manager était déjà débranché (un échec précédent l'a retiré, et c'est sa
    // propre restauration en attente qui le rebranchera) : réaffecter ici écraserait le vrai
    // manager par `nil`, et ⌘Z serait perdu pour la session.
    if let manager {
      if saved {
        undoManager = manager
      } else {
        runAfterNextSave { [weak self] in self?.undoManager = manager }
      }
    }
    return saved
  }

  /// Enregistre et dit si c'est fait — SANS rien annuler en cas d'échec.
  ///
  /// **Pas de `rollback()`, et c'est mesuré** (30 octobre 2026, sur un store temporaire) : annuler
  /// la suppression d'une tâche dont les sous-tâches n'ont jamais été lues fait TOMBER SwiftData
  /// (`ModelSnapshot.swift:268: Unexpected backing data for snapshot creation`) ; et si elles ont
  /// été lues, l'annulation laisse la tâche « non supprimée » (`isDeleted == false`) mais absente
  /// de tous les fetchs — un état qu'aucune vue ne sait montrer. Ce contexte est en outre celui de
  /// l'interface : annuler emporterait la saisie en attente de l'autosave. Les changements restent
  /// donc en attente ; l'autosave, ou le prochain enregistrement, les écrira.
  func saveReportingSuccess() -> Bool {
    do {
      try save()
      return true
    } catch {
      return false
    }
  }

  /// Joue `effect` après le prochain enregistrement RÉUSSI de ce contexte, une fois, puis s'en va.
  ///
  /// C'est le chemin des effets externes (effacer un rappel, un événement) qu'un enregistrement raté
  /// a retenus. Les jouer quand même effaçait le rappel d'une tâche que le disque portait encore ;
  /// ne jamais les jouer laissait, si l'autosave réussissait ensuite, un rappel orphelin — visible
  /// dans les sections « Rappels », et réimporté en tâche si l'import est actif. `didSave` ne sonne
  /// qu'après un enregistrement réussi (vérifié : rien sur un échec), et pour ce contexte-ci.
  ///
  /// ponytail: en mémoire seulement — quitter l'app avant le prochain enregistrement laisse les
  /// deux côtés tels que le disque les décrit, ce qui est cohérent. Un observateur en attente vit
  /// jusque-là ; il se retire lui-même dès qu'il a joué.
  func runAfterNextSave(_ effect: @escaping () -> Void) {
    AfterNextSave.schedule(on: self, effect)
  }

  /// LA suppression de tâches, pour les cinq pages — l'ordre correct des trois gestes, écrit UNE
  /// fois : lire les identifiants Apple, supprimer et enregistrer, PUIS effacer rappels et événements.
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
  /// Pas de `deleteCascadeAndSave` ici, délibérément : les tâches supprimées par une page ont été
  /// RENDUES, donc lues — SwiftData a leur instantané et encaisse la suppression sans broncher (cf.
  /// l'en-tête de `deleteCascadeAndSave`) —, et lui retirer l'`UndoManager` retirerait ⌘Z de la
  /// suppression d'une tâche — qui marche, et qui compte (⌫ efface pour de bon).
  ///
  /// Enregistrement raté ⇒ `forget` n'est PAS appelé tout de suite : le disque relie encore ces
  /// tâches à leurs rappels. Il l'est au prochain enregistrement réussi (`runAfterNextSave`), pour
  /// les seules tâches encore supprimées à ce moment-là — un ⌘Z entre-temps les a rendues à la vie,
  /// et leurs rappels avec.
  @discardableResult
  func deleteTasksAndSave(_ tasks: [TaskItem], forget: @escaping ([String]) -> Void) -> Bool {
    // Les identifiants Apple lus ICI, tâche par tâche, tant que tout est debout : après un
    // enregistrement, relire un attribut d'une tâche supprimée peut faire tomber SwiftData. Ensuite
    // on ne regarde plus que son ÉTAT de suppression, jamais ses attributs.
    let pairs = tasks.map { ($0, RemindersService.appleIdentifiers(of: [$0])) }
    let doomed = pairs.flatMap(\.1)
    for task in tasks { delete(task) }
    guard saveReportingSuccess() else {
      runAfterNextSave {
        forget(pairs.filter { $0.0.isDeleted || $0.0.modelContext == nil }.flatMap(\.1))
      }
      return false
    }
    forget(doomed)
    return true
  }
}

/// Les effets en attente d'un enregistrement réussi (cf. `ModelContext.runAfterNextSave`).
///
/// `nonisolated(unsafe)` et une précondition plutôt que `@MainActor` : isoler le type ferait
/// TRAVERSER au contexte et à l'effet (non-`Sendable` l'un comme l'autre) une frontière d'acteur
/// qu'ils ne franchissent pas en réalité — tout se passe sur le fil principal, où vivent les
/// appelants et où `didSave` est posté pour ce contexte (synchrone, sur le fil qui enregistre).
/// La précondition le vérifie au lieu de le supposer. Même motif que `CrashLog.originalReport`.
private enum AfterNextSave {
  private nonisolated(unsafe) static var waiting:
    [UUID: (observer: NSObjectProtocol, effect: () -> Void)] = [:]

  static func schedule(on context: ModelContext, _ effect: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let key = UUID()
    let observer = NotificationCenter.default.addObserver(
      forName: ModelContext.didSave, object: context, queue: nil
    ) { _ in fire(key) }
    waiting[key] = (observer, effect)
  }

  private static func fire(_ key: UUID) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let entry = waiting.removeValue(forKey: key) else { return }
    NotificationCenter.default.removeObserver(entry.observer)
    entry.effect()
  }
}
