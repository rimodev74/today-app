import Foundation

/// Le repli des sous-tâches d'une tâche, retenu d'un lancement à l'autre. **Ouvert par défaut.**
///
/// On enregistre les REPLIÉES et pas les ouvertes : le défaut étant « ouvert », une tâche absente de
/// l'ensemble est ouverte. Une base entière sans un seul repli ne pèse donc rien, et une tâche neuve
/// arrive dépliée sans qu'on ait eu à l'inscrire.
///
/// Pas un champ de `TaskItem` : ce serait une montée de schéma, une étape de migration et une
/// fixture (cf. `TodaySchema.swift`) pour un booléen d'affichage que ni la synchro Rappels ni
/// CloudKit ne regardent. Même arbitrage que `SavedPlaylist` et `TextShortcut`.
///
/// Et surtout PAS un `@AppStorage` lu par la rangée : l'écriture d'un `UserDefaults` échappe à la
/// transaction animée, et le dépliant redeviendrait instantané (cf. `PIEGES.md` § Animations). D'où
/// le partage des rôles — le `@State` de `TaskRow` pilote le rendu et l'animation, ce type ne fait
/// que lui donner sa valeur de DÉPART et retenir la dernière.
///
// ponytail: l'identifiant d'une tâche supprimée reste dans l'ensemble. Une entrée pèse 16 octets et
// rien ne la relit jamais — purger demanderait de balayer la base au lancement, à faire le jour où
// quelqu'un replie des milliers de tâches puis les supprime.
@MainActor
enum SubtaskExpansion {
  static let storageKey = "collapsedSubtasks"

  /// Décodé UNE fois par lancement puis tenu en mémoire : `isExpanded` est lu par CHAQUE rangée à
  /// chaque rendu, et le relire dans les défauts en ferait un aller-retour `UserDefaults` par ligne
  /// — exactement ce que `SidebarCounts` existe pour éviter un cran plus haut.
  private static var collapsed: Set<UUID> = decode(
    UserDefaults.standard.data(forKey: storageKey) ?? Data())

  static func isExpanded(_ task: TaskItem) -> Bool { !collapsed.contains(task.uuid) }

  static func set(_ expanded: Bool, for task: TaskItem) {
    let changed =
      expanded ? collapsed.remove(task.uuid) != nil : collapsed.insert(task.uuid).inserted
    guard changed else { return }
    UserDefaults.standard.set(encode(collapsed), forKey: storageKey)
  }

  // MARK: Le codage

  /// `nonisolated` pour la même raison que `MusicPlayer.fadedVolume` : ces deux-là ne touchent à
  /// rien du fil principal, et un test n'a pas à s'y placer pour les appeler.
  nonisolated static func decode(_ data: Data) -> Set<UUID> {
    (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
  }

  nonisolated static func encode(_ ids: Set<UUID>) -> Data {
    (try? JSONEncoder().encode(ids)) ?? Data()
  }
}
