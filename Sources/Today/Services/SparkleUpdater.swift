import Sparkle

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

    try? updater.start()
  }

  var automaticallyChecksForUpdates: Bool {
    get { updater.automaticallyChecksForUpdates }
    set { updater.automaticallyChecksForUpdates = newValue }
  }

  func checkForUpdates() {
    updater.checkForUpdates()
  }
}
