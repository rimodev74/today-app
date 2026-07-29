import Sparkle

final class SparkleUpdater {
  static let shared = SparkleUpdater()

  private let updater: SPUUpdater

  private init() {
    let hostBundle = Bundle.main
    let feedURL = URL(string: "https://raw.githubusercontent.com/rimodev74/today-app/main/appcast.xml")!

    self.updater = SPUUpdater(
      hostBundle: hostBundle,
      applicationBundle: hostBundle,
      userDriver: SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil),
      delegate: nil
    )

    updater.setFeedURL(feedURL)
    updater.automaticallyChecksForUpdates = true
    try? updater.start()
  }

  func checkForUpdates() {
    updater.checkForUpdates()
  }
}
