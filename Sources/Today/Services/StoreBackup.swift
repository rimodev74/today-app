import CryptoKit
import Foundation
import SwiftData

/// Met la base de côté AVANT de l'ouvrir, quand la forme des modèles a changé depuis la dernière
/// ouverture réussie.
///
/// C'est le pendant à l'exécution de `SchemaCompatibilityTests`, et les deux se complètent sans se
/// recouvrir : le test attrape un changement cassant AU MOMENT OÙ ON L'ÉCRIT, sur une base d'essai ;
/// celui-ci protège la VRAIE base au moment où elle s'ouvre — y compris contre ce que le test ne
/// peut pas voir (un disque qui lâche en pleine migration, un bug de SwiftData, une version
/// installée par-dessus une autre sans passer par nous).
///
/// À ne pas confondre avec `StoreQuarantine`, qui intervient APRÈS coup : lui écarte un store déjà
/// illisible, quand le mal est fait. Ici on copie tant que tout va encore bien.
///
/// ## Le déclencheur : l'empreinte de la forme
///
/// Ni « à chaque lancement » (coûteux et inutile 99 fois sur 100), ni « à chaque nouvelle version »
/// (le numéro de build ne bouge pas entre deux `./run.sh`, or c'est justement en développement qu'on
/// casse un modèle). Le seul signal juste est la FORME elle-même : entités, propriétés, et leur type.
/// Elle se dérive du `Schema` que le container va utiliser — donc de la même source de vérité, pas
/// d'une liste à tenir à jour en parallèle.
///
/// Empreinte cryptographique et pas `hashValue` : le hachage standard de Swift est resalé à chaque
/// lancement du process, l'empreinte aurait changé toute seule et déclenché une copie par démarrage.
enum StoreBackup {
  /// Voisin du store, sous un nom qui dit à qui il appartient : `default.store` vit à la racine de
  /// `~/Library/Application Support/`, sans dossier au nom du bundle (cf. CLAUDE.md), un
  /// `Backups/` générique y serait un squat.
  static var directoryName: String { "\(StoreLocation.directoryName)-Backups" }

  /// ponytail: trois copies gardées, ~3,5 Mo pièce journal SQLite compris. De quoi revenir sur
  /// « je l'ai cassé il y a deux builds » sans surveiller un quota. À passer en réglage si la place
  /// devient un sujet.
  static let keep = 3

  static let fingerprintKey = "storeShapeFingerprint"

  /// Copie le store si la forme a changé, puis élague les plus anciennes copies.
  /// Renvoie le dossier créé, ou `nil` si rien n'était à faire.
  ///
  /// Ne lève JAMAIS et n'empêche jamais le lancement : une sauvegarde qui échoue (disque plein,
  /// droits) ne doit pas coûter l'app à l'utilisateur. Elle se voit à son absence, pas par un
  /// plantage.
  @discardableResult
  static func snapshotIfShapeChanged(
    of url: URL,
    schema: Schema,
    defaults: UserDefaults = .standard,
    now: Date = Date()
  ) -> URL? {
    let current = fingerprint(of: schema)
    guard defaults.string(forKey: fingerprintKey) != current else { return nil }

    // L'empreinte est écrite MÊME si la copie ne donne rien (première ouverture, base encore
    // inexistante) : sans ça, chaque lancement reprendrait le même chemin pour rien.
    defer { defaults.set(current, forKey: fingerprintKey) }

    let destination = copy(url, now: now)
    prune(in: url.deletingLastPathComponent())
    return destination
  }

  /// Ce qui identifie la FORME du modèle : le nom de chaque entité, le nom de chaque propriété et
  /// son type. Exactement les trois choses dont la modification perd des données — renommer,
  /// supprimer, changer un type — et rien d'autre.
  ///
  /// Surtout PAS `String(describing:)` de la propriété, qui paraît plus complet : sa description
  /// embarque la valeur par défaut, et une valeur par défaut est une EXPRESSION évaluée à la
  /// construction du schéma. `var createdAt: Date = Date()` et `var uuid: UUID = UUID()` en donnent
  /// donc une différente à chaque lancement du process — l'empreinte changeait à chaque démarrage et
  /// recopiait la base à chaque fois. Mesuré, puis corrigé ici.
  ///
  /// Conséquence assumée : changer une valeur par défaut ne déclenche pas de copie. Ça ne déplace
  /// aucune donnée existante, seules les lignes créées ensuite en dépendent.
  ///
  /// Trié aux deux niveaux : l'ordre des entités comme celui des propriétés ne veut rien dire et
  /// n'est pas garanti d'une construction à l'autre.
  static func fingerprint(of schema: Schema) -> String {
    let shape =
      schema.entities
      .sorted { $0.name < $1.name }
      .map { entity in
        let properties =
          entity.properties
          .sorted { $0.name < $1.name }
          .map { "\($0.name):\($0.valueType)" }
          .joined(separator: "|")
        return "\(entity.name){\(properties)}"
      }
      .joined(separator: ";")
    let digest = SHA256.hash(data: Data("\(schema.version)::\(shape)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Copie le store et son journal dans un dossier horodaté. `nil` s'il n'y a pas encore de base.
  ///
  /// Les trois fichiers ou rien : `-wal` et `-shm` sont le journal SQLite, et une copie amputée du
  /// journal restituerait un état antérieur aux dernières écritures — une sauvegarde qui ment est
  /// pire que pas de sauvegarde. Même raisonnement que `StoreQuarantine`.
  private static func copy(_ url: URL, now: Date) -> URL? {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return nil }

    let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
    let directory =
      url
      .deletingLastPathComponent()
      .appendingPathComponent(directoryName)
      .appendingPathComponent(stamp)
    guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
    else { return nil }

    for suffix in ["", "-wal", "-shm"] {
      let source = URL(fileURLWithPath: url.path + suffix)
      guard manager.fileExists(atPath: source.path) else { continue }
      let target = directory.appendingPathComponent(source.lastPathComponent)
      try? manager.copyItem(at: source, to: target)
    }
    return directory
  }

  /// Ne garde que les `keep` copies les plus récentes. Les noms sont des horodatages ISO 8601 :
  /// leur ordre alphabétique EST leur ordre chronologique, pas besoin d'interroger le système de
  /// fichiers pour les dater.
  private static func prune(in parent: URL) {
    let manager = FileManager.default
    let directory = parent.appendingPathComponent(directoryName)
    guard
      let entries = try? manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    let sorted = entries.map(\.lastPathComponent).sorted()
    guard sorted.count > keep else { return }
    for stale in sorted.dropLast(keep) {
      try? manager.removeItem(at: directory.appendingPathComponent(stale))
    }
  }
}
