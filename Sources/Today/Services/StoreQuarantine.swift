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
  /// Déplace `url` et ses fichiers satellites vers `<nom>.corrupt-<horodatage>`, et renvoie les
  /// chemins écartés. Les erreurs sont avalées : si le renommage échoue, `ModelContainer` échouera
  /// juste après et c'est LUI qui doit le dire, pas une exception jetée depuis un plan B.
  @discardableResult
  static func quarantine(_ url: URL, now: Date = Date()) -> [URL] {
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
    return moved
  }
}
