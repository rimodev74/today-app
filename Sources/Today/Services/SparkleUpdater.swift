import Sparkle

/// Isolé au fil principal : `SPUUpdater` et son pilote d'interface sont des objets AppKit, et le
/// singleton est construit depuis `TodayApp.init`. Sans cette annotation, `shared` est une variable
/// globale mutable partagée — ce que Swift 6 refuse, à juste titre.
@MainActor
final class SparkleUpdater {
  static let shared = SparkleUpdater()

  private let updater: SPUUpdater

  private init() {
    let hostBundle = Bundle.main

    self.updater = SPUUpdater(
      hostBundle: hostBundle,
      applicationBundle: hostBundle,
      userDriver: SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil),
      delegate: nil
    )

    // L'URL du flux vit dans Info.plist (SUFeedURL). Purge l'ancienne valeur
    // écrite dans les UserDefaults par setFeedURL, sinon elle a la priorité.
    updater.clearFeedURLFromUserDefaults()

    // ponytail: Sparkle persiste ce réglage ; ne forcer qu'au premier lancement
    if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
      updater.automaticallyChecksForUpdates = true
    }

    // Sparkle vérifie toutes les 24 h par défaut, trop lent pour un rythme de
    // publication quotidien : une version poussée le matin ne serait proposée
    // que le lendemain. 1 h reste discret (Sparkle ne notifie que s'il trouve
    // vraiment une mise à jour) et rend `git quick` visible dans la journée.
    updater.updateCheckInterval = 3600

    // Un échec ici (bundle mal signé, `SUFeedURL` absente) coupe les mises à jour pour toute la
    // session, et `try?` le rendait invisible. Rien à montrer à l'utilisateur, qui ne peut rien y
    // faire — mais une trace. `NSLog` et pas `CrashLog`, qui n'écrit que des plantages ; le journal
    // unifié ne rend rien de ce process à `log show` (cf. `CrashLog`), Console.app le montre.
    do {
      try updater.start()
    } catch {
      NSLog("Sparkle n'a pas démarré — pas de mises à jour cette session : %@", "\(error)")
    }
  }

  var automaticallyChecksForUpdates: Bool {
    get { updater.automaticallyChecksForUpdates }
    set { updater.automaticallyChecksForUpdates = newValue }
  }

  func checkForUpdates() {
    updater.checkForUpdates()
  }
}
