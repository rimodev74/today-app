import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Les images de couverture des projets — des FICHIERS, pas un champ SwiftData.
///
/// `Covers/<project.uuid>.jpg`, à côté de la base (même `StoreLocation.directoryName` : la build de
/// dev a les siennes). Pas d'`@Attribute(.externalStorage)` sur `Project`, pour trois raisons :
/// une montée de schéma sur la vraie base pour un octet DÉCORATIF ; SwiftData range ces blobs dans
/// un dossier caché que `StoreBackup` et `StoreQuarantine` ignorent (ils ne copient que le `.store`
/// et son journal), donc une sauvegarde les aurait perdus sans un mot ; et lire l'attribut depuis
/// une vue est une lecture de fichier synchrone sur le fil qui dessine.
///
/// ponytail: hors sauvegarde et hors synchro — une image perdue se re-choisit. Le jour où CloudKit
/// arrive, migrer vers un attribut `externalStorage`.
///
/// Rien d'ici ne décode sur le fil principal : l'import et l'affichage passent par ImageIO dans une
/// tâche détachée. Une vue ne lit que `stamps` (« ce projet a-t-il une couverture, de quand ? »),
/// rempli une fois au lancement par un listage du dossier.
@Observable
@MainActor
final class ProjectCovers {
  /// Le plus grand côté stocké : couvre un bandeau de 1 000 pt en Retina. Au-delà, l'image est
  /// légèrement agrandie — accepté, c'est une décoration.
  nonisolated static let storedMaxPixel = 2_000

  /// Quels projets ont une couverture, et sa version. Une nouvelle date = une nouvelle image : c'est
  /// ce qui relance le chargement d'une vue (`.task(id:)`) et ce qui invalide le cache.
  private(set) var stamps: [UUID: Date] = [:]

  /// Plafond de mémoire du cache d'images décodées, en OCTETS. Une couverture décodée à 2 000 px de
  /// large pèse plusieurs mégaoctets : sans plafond de coût, `NSCache` ne se vide que sous la
  /// pression du système, c'est-à-dire trop tard.
  nonisolated static let cacheCostLimit = 64 * 1024 * 1024

  /// Ce qu'une image coûte au cache : ses octets décodés (`bytesPerRow × height`), pas un compte.
  nonisolated static func cacheCost(of image: CGImage) -> Int {
    image.bytesPerRow * image.height
  }

  @ObservationIgnored let directory: URL
  @ObservationIgnored private let cache = NSCache<NSString, CGImage>()
  /// Les clés de cache de chaque projet : `NSCache` ne sait pas énumérer les siennes, et sans ce
  /// registre ni remplacer ni retirer une couverture ne pourrait purger ses anciennes images.
  @ObservationIgnored private var cachedKeys: [UUID: Set<NSString>] = [:]

  nonisolated static var defaultDirectory: URL {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return support.appendingPathComponent(StoreLocation.directoryName, isDirectory: true)
      .appendingPathComponent("Covers", isDirectory: true)
  }

  init(directory: URL = ProjectCovers.defaultDirectory) {
    self.directory = directory
    cache.totalCostLimit = Self.cacheCostLimit
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files where file.pathExtension == "jpg" {
      guard let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
        continue
      }
      let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      stamps[uuid] = date ?? .distantPast
    }
  }

  func url(for uuid: UUID) -> URL {
    directory.appendingPathComponent(uuid.uuidString).appendingPathExtension("jpg")
  }

  /// Importe une image choisie ou déposée : réduite, réencodée en JPEG, écrite d'un bloc. `false`
  /// si le fichier ne se décode pas — rien n'est alors touché, l'ancienne couverture reste.
  @discardableResult
  func set(from source: URL, for uuid: UUID) async -> Bool {
    let target = url(for: uuid)
    let directory = directory
    let written = await Task.detached(priority: .userInitiated) {
      Self.importImage(from: source, to: target, directory: directory)
    }.value
    guard written else { return false }
    stamps[uuid] = Date()
    // L'ancienne image n'est plus atteignable (la clé porte le stamp) mais garderait sa mémoire.
    purgeCache(for: uuid)
    return true
  }

  func remove(for uuid: UUID) {
    try? FileManager.default.removeItem(at: url(for: uuid))
    stamps[uuid] = nil
    purgeCache(for: uuid)
  }

  private func purgeCache(for uuid: UUID) {
    for key in cachedKeys.removeValue(forKey: uuid) ?? [] { cache.removeObject(forKey: key) }
  }

  /// Vrai si cette version de la couverture est en cache — pour les tests.
  func hasCachedImage(for uuid: UUID, stamp: Date, maxPixel: Int) -> Bool {
    cache.object(forKey: Self.cacheKey(uuid, stamp, maxPixel)) != nil
  }

  private static func cacheKey(_ uuid: UUID, _ stamp: Date, _ maxPixel: Int) -> NSString {
    "\(uuid.uuidString)-\(stamp.timeIntervalSince1970)-\(maxPixel)" as NSString
  }

  /// L'image prête à dessiner, réduite à `maxPixel` (plus grand côté, en pixels — ×2 pour le
  /// Retina). Décodée HORS du fil principal et tout de suite (`ShouldCacheImmediately`), sinon le
  /// décodage aurait lieu au premier dessin, c'est-à-dire sur le fil qui dessine.
  func image(for uuid: UUID, stamp: Date, maxPixel: Int) async -> CGImage? {
    let key = Self.cacheKey(uuid, stamp, maxPixel)
    if let cached = cache.object(forKey: key) { return cached }
    let file = url(for: uuid)
    let decoded = await Task.detached(priority: .userInitiated) {
      Self.decode(file, maxPixel: maxPixel).map(SendableImage.init)
    }.value?.image
    // Rien en cache si la couverture a été retirée ou remplacée pendant le décodage : l'entrée
    // n'appartiendrait plus à aucune version vivante, et `purgeCache` est déjà passé.
    if let decoded, stamps[uuid] == stamp {
      cache.setObject(decoded, forKey: key, cost: Self.cacheCost(of: decoded))
      cachedKeys[uuid, default: []].insert(key)
    }
    return decoded
  }

  nonisolated static func importImage(from source: URL, to target: URL, directory: URL) -> Bool {
    // Une URL rendue par un panneau ou un dépôt peut être à portée limitée (bac à sable).
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    guard let decoded = decode(source, maxPixel: storedMaxPixel),
      let image = opaque(decoded)
    else { return false }

    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
    guard
      let destination = CGImageDestinationCreateWithURL(
        temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? fileManager.removeItem(at: temporary)
      return false
    }
    // Remplacement d'un bloc : une lecture concurrente voit l'ancienne image ou la nouvelle, jamais
    // une moitié.
    do {
      if fileManager.fileExists(atPath: target.path) {
        _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: target)
      }
      return true
    } catch {
      try? fileManager.removeItem(at: temporary)
      return false
    }
  }

  /// Le JPEG n'a pas d'alpha : posée telle quelle, une zone transparente ressortirait NOIRE. On
  /// l'aplatit sur du blanc.
  nonisolated static func opaque(_ image: CGImage) -> CGImage? {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return image
    default: break
    }
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)
    return context.makeImage()
  }

  nonisolated static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    // Jamais au-delà de la taille d'origine : la vignette AGRANDIRAIT une petite image.
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maxPixel
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maxPixel
    let maxPixel = min(maxPixel, max(width, height))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

/// `CGImage` est immuable une fois créée ; l'emballage ne sert qu'à la faire traverser la frontière
/// de la tâche détachée sans diagnostic de concurrence.
private struct SendableImage: @unchecked Sendable {
  let image: CGImage
}
