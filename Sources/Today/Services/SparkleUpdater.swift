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
