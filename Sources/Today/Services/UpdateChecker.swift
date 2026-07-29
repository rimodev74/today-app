import Foundation

actor UpdateChecker {
  struct Release: Decodable {
    let tagName: String
    let htmlUrl: String
    let name: String

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlUrl = "html_url"
      case name
    }
  }

  static let shared = UpdateChecker()

  private let repoOwner = "rimodev74"
  private let repoName = "today-app"

  nonisolated private func currentVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  nonisolated private func isNewerVersion(_ remote: String, _ local: String) -> Bool {
    let remoteComponents = remote.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
    let localComponents = local.split(separator: ".").compactMap { Int($0) }

    for i in 0..<max(remoteComponents.count, localComponents.count) {
      let r = remoteComponents.indices.contains(i) ? remoteComponents[i] : 0
      let l = localComponents.indices.contains(i) ? localComponents[i] : 0
      if r > l { return true }
      if r < l { return false }
    }
    return false
  }

  func checkForUpdates() async {
    let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    guard let url = URL(string: urlString) else { return }

    let request = URLRequest(url: url)
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return }

    let localVersion = currentVersion()
    if isNewerVersion(release.tagName, localVersion) {
      showNotification(version: release.tagName, url: release.htmlUrl)
    }
  }

  nonisolated private func showNotification(version: String, url: String) {
    let notification = NSUserNotification()
    notification.title = "Mise à jour disponible"
    notification.subtitle = "Today \(version)"
    notification.informativeText = "Une nouvelle version est disponible."
    notification.soundName = NSUserNotificationDefaultSoundName
    notification.userInfo = ["updateURL": url]

    NSUserNotificationCenter.default.deliver(notification)
  }
}
