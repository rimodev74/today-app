import Foundation

/// Met un store SwiftData illisible DE CÔTÉ au lieu de le supprimer.
///
/// L'app doit pouvoir démarrer même si la base ne s'ouvre pas — mais « démarrer » ne doit jamais
/// vouloir dire « effacer le travail de l'utilisateur sans le dire ». Renommer coûte le même
/// nombre de lignes que supprimer et laisse le fichier récupérable à la main.
///
/// Avec `TodayMigrationPlan` en place, ce chemin n'est plus la routine d'un changement de schéma :
/// c'est un signal de bug (étape de migration manquante, fichier corrompu, disque en vrac).
enum StoreQuarantine {
  /// Où les chemins écartés attendent qu'une fenêtre existe pour être dits à l'utilisateur.
  ///
  /// Les défauts, et pas une variable globale : la quarantaine a lieu pendant la construction du
  /// `ModelContainer` (cf. `TodayApp.container`), c'est-à-dire hors de tout acteur et AVANT que la
  /// moindre vue n'existe. Les défauts sont le seul canal déjà partagé par ces deux moments — même
  /// motif que `StoreBackup.fingerprintKey`, pour la même raison.
  static let reportKey = "quarantinedStorePaths"

  /// Déplace `url` et ses fichiers satellites vers `<nom>.corrupt-<horodatage>`, et renvoie les
  /// chemins écartés. Les erreurs sont avalées : si le renommage échoue, `ModelContainer` échouera
  /// juste après et c'est LUI qui doit le dire, pas une exception jetée depuis un plan B.
  @discardableResult
  static func quarantine(
    _ url: URL, now: Date = Date(), defaults: UserDefaults = .standard
  ) -> [URL] {
    let manager = FileManager.default
    // Horodatage sans « : » — interdit en nom de fichier côté Finder (il l'affiche en « / »).
    let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
    var moved: [URL] = []
    // `-wal` et `-shm` sont le journal SQLite du store : n'en déplacer qu'une partie laisserait un
    // store neuf s'ouvrir sur le journal de l'ancien — la corruption qu'on essaie justement de fuir.
    for suffix in ["", "-wal", "-shm"] {
      let file = URL(fileURLWithPath: url.path + suffix)
      guard manager.fileExists(atPath: file.path) else { continue }
      let destination = URL(fileURLWithPath: file.path + ".corrupt-\(stamp)")
      guard (try? manager.moveItem(at: file, to: destination)) != nil else { continue }
      moved.append(destination)
    }
    // Rien écarté = rien à raconter, et surtout pas d'écrasement d'un rapport pas encore lu : une
    // quarantaine qui échoue entièrement ne doit pas faire taire la précédente.
    if !moved.isEmpty { defaults.set(moved.map(\.path), forKey: reportKey) }
    return moved
  }

  /// Les chemins écartés depuis la dernière lecture, puis oubliés — l'alerte se montre UNE fois.
  ///
  /// Sans elle, l'app repartait sur une base neuve sans un mot : l'utilisateur voyait une app vide
  /// et n'avait aucun moyen de savoir que son travail était encore là, à côté, sous un autre nom.
  /// Le vrai risque n'était pas de ne pas remarquer, c'était de tout retaper par-dessus.
  static func consumeReport(defaults: UserDefaults = .standard) -> [String] {
    let paths = defaults.stringArray(forKey: reportKey) ?? []
    guard !paths.isEmpty else { return [] }
    defaults.removeObject(forKey: reportKey)
    return paths
  }
}
