import Foundation

/// Où vit la base de l'app — et pourquoi ce n'est plus la place que SwiftData donne d'office.
///
/// `ModelConfiguration(schema:)` sans URL écrit dans `~/Library/Application Support/default.store`,
/// À LA RACINE, sous un nom générique que rien ne réserve à personne. Ce n'était pas un risque
/// théorique : le **5 août 2026**, une autre application a écrit SON `default.store` par-dessus
/// celui de Today. La base de l'utilisateur a disparu, l'ouverture suivante a échoué, le fichier
/// étranger est parti en quarantaine (`StoreQuarantine`) et l'app est repartie VIDE. Aucune ligne
/// de Today n'était en cause, et aucune n'aurait pu l'empêcher — le fichier ne lui appartenait plus.
/// Seule la sauvegarde de `StoreBackup` a permis de récupérer les données.
///
/// D'où un sous-dossier au nom de l'app, que personne d'autre n'a de raison d'écrire.
///
/// Le déménagement a lieu UNE fois, au premier lancement qui suit, et seulement si la nouvelle place
/// est LIBRE : ce qui est déjà arrivé à destination fait foi. L'ancien fichier n'est jamais
/// supprimé, seulement déplacé — et s'il ne peut pas l'être, l'app s'ouvre sur une base neuve à la
/// nouvelle adresse plutôt que de retourner écrire dans un fichier qui ne lui appartient pas.
enum StoreLocation {
  /// "Today" par défaut. Surchargeable par `TODAY_APP_SUPPORT_DIR` (posée par `run-dev.sh` via
  /// `open --env`) pour qu'une build de dev écrive dans SON propre sous-dossier au lieu de la vraie
  /// base — sans ça, lancer une deuxième instance revient à empiler deux process sur le même store
  /// SwiftData (cf. run.sh). Absente en production comme en test : les deux gardent "Today".
  static var directoryName: String {
    ProcessInfo.processInfo.environment["TODAY_APP_SUPPORT_DIR"] ?? "Today"
  }
  static let fileName = "default.store"

  /// SQLite écrit TROIS fichiers, pas un. Déménager le seul `.store` en laissant son journal
  /// derrière perdrait tout ce qu'il n'a pas encore replié — et ce journal vit longtemps : celui
  /// mesuré le 5 août pesait 2,2 Mo pour une base de 106 Ko.
  static let companionSuffixes = ["", "-shm", "-wal"]

  /// La place définitive, dans le sous-dossier de l'app.
  static func storeURL(in applicationSupport: URL) -> URL {
    applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent(fileName)
  }

  /// L'ancienne place, à la racine — celle que SwiftData choisit tout seul.
  static func legacyURL(in applicationSupport: URL) -> URL {
    applicationSupport.appendingPathComponent(fileName)
  }

  /// Déménage la base si elle est encore à l'ancienne adresse. Rend `true` si quelque chose a été
  /// déplacé — sert au journal de démarrage et aux tests, rien d'autre n'en dépend.
  ///
  /// Trois refus, et chacun a sa raison :
  /// - la destination existe déjà → elle fait foi, on ne l'écrase sous aucun prétexte ;
  /// - l'ancien fichier n'existe pas → premier lancement, il n'y a rien à déménager ;
  /// - un déplacement échoue → on s'arrête là. Les fichiers déjà déplacés le restent : le `.store`
  ///   part en premier, donc un échec sur le journal laisse une base cohérente à l'arrivée, pas une
  ///   moitié de base à chaque bout.
  @discardableResult
  static func migrateIfNeeded(
    applicationSupport: URL, fileManager: FileManager = .default
  ) -> Bool {
    let destination = storeURL(in: applicationSupport)
    let legacy = legacyURL(in: applicationSupport)
    guard !fileManager.fileExists(atPath: destination.path),
      fileManager.fileExists(atPath: legacy.path)
    else { return false }

    var moved = false
    for suffix in companionSuffixes {
      let from = URL(fileURLWithPath: legacy.path + suffix)
      let to = URL(fileURLWithPath: destination.path + suffix)
      guard fileManager.fileExists(atPath: from.path) else { continue }
      do {
        try fileManager.moveItem(at: from, to: to)
        moved = true
      } catch {
        break
      }
    }
    return moved
  }

  /// L'adresse à donner à `ModelConfiguration`, dossier créé et déménagement fait.
  ///
  /// Ne lance jamais : si le dossier ne peut pas être créé, on rend quand même l'adresse voulue et
  /// c'est l'ouverture du store qui échouera — le chemin d'échec existe déjà et il est traité
  /// (seconde tentative, puis quarantaine, cf. `TodayApp.container`). Retomber sur l'ancienne
  /// adresse « pour que ça marche » serait retomber exactement dans le défaut qu'on corrige.
  nonisolated static func resolve(fileManager: FileManager = .default) -> URL {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      // Sans dossier de support, il n'y a pas d'adresse de repli qui vaille mieux : on rend le
      // chemin par défaut de SwiftData, et l'ouverture dira ce qui ne va pas.
      return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
    }
    return resolve(applicationSupport: applicationSupport, fileManager: fileManager)
  }

  /// La même chose, mais sur un dossier DONNÉ — c'est celle-ci que les tests appellent.
  ///
  /// La séparation n'est pas cosmétique : `resolve()` va chercher le vrai
  /// `~/Library/Application Support` et DÉPLACE ce qu'il y trouve. Un test qui l'appellerait
  /// déménagerait la base réelle de l'utilisateur au milieu d'un `swift test` — exactement ce que
  /// « les tests ne touchent jamais la vraie base » interdit.
  nonisolated static func resolve(applicationSupport: URL, fileManager: FileManager = .default)
    -> URL
  {
    let destination = storeURL(in: applicationSupport)
    try? fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    migrateIfNeeded(applicationSupport: applicationSupport, fileManager: fileManager)
    return destination
  }
}
