import AppKit
import Foundation
import ObjectiveC

/// Ce qui manque à TOUS les rapports de plantage de ce projet : la RAISON.
///
/// Une exception Objective-C non rattrapée tue le process, et le rapport système garde la pile
/// mais PAS le message — on se retrouve à deviner ce qu'AppKit reprochait. Les deux points
/// d'accroche ci-dessous attrapent la raison au dernier endroit où elle existe encore.
///
/// Ils ne rattrapent RIEN et n'empêchent aucun plantage — après une exception ObjC, le process est
/// de toute façon dans un état indéfini et continuer serait pire. Ils écrivent, puis laissent
/// mourir.
///
/// ## Pourquoi un FICHIER et pas `NSLog`
///
/// Il a écrit dans le journal unifié pendant des semaines, et sa propre documentation renvoyait à
/// `log show --predicate 'process == "Today"'`. Cette commande rend **0 ligne** pour ce process —
/// c'est écrit noir sur blanc ailleurs dans `CLAUDE.md`, y compris pour un `NSLog` que le binaire
/// exécute vraiment. Autrement dit : le gestionnaire tournait et parlait dans le vide, et les deux
/// plantages du 6 août 2026 (la palette d'une en-tête, puis « Rechercher les mises à jour ») sont
/// restés muets alors qu'il y avait quelqu'un pour les écouter.
///
/// Le fichier est posé à côté de la base, dans `~/Library/Application Support/Today/`. L'app n'a
/// aucun entitlement de sandbox : il s'écrit sans rien demander, et depuis un gestionnaire de
/// terminaison où l'on ne peut compter sur presque rien.
///
/// ## Pourquoi `NSSetUncaughtExceptionHandler` ne SUFFIT PAS
///
/// Il ne suffit pas, et pire : dans une app AppKit il ne sert presque jamais. **Vérifié le 6 août
/// 2026** en levant une vraie `NSException` depuis un bloc posté sur la file principale — l'app
/// meurt, et le gestionnaire n'écrit RIEN. La raison : toute exception levée pendant que la boucle
/// d'événements tourne est attrapée par AppKit, qui appelle `+[NSApplication _crashOnException:]`
/// et déclenche un SIGTRAP AVANT `_objc_terminate`. Or c'est `_objc_terminate` qui appelle le
/// gestionnaire. Il ne reste donc couvert que ce qui lève hors boucle — presque rien.
///
/// C'est ce qui a rendu MUETS les deux plantages du 6 août 2026 (la palette d'une en-tête, puis
/// « Rechercher les mises à jour »), alors qu'un gestionnaire était installé depuis des semaines
/// et qu'on le croyait en poste.
///
/// D'où le second point d'accroche : `-[NSApplication reportException:]`, qu'AppKit appelle avec
/// l'exception AVANT de tuer le process. Il est posé par échange d'implémentation (`swizzle`), et
/// c'est délibéré faute d'alternative native : la voie propre serait une sous-classe de
/// `NSApplication` déclarée en `NSPrincipalClass`, mais `TodayApp.init` touche
/// `NSApplication.shared` avant que `NSApplicationMain` ne lise cette clé — la classe est déjà
/// figée, la sous-classe ne serait jamais instanciée. L'échange ne modifie aucun comportement : il
/// écrit, puis appelle l'implémentation d'origine.
enum CrashLog {
  /// À côté de la base : même dossier, même raison d'exister (cf. `StoreLocation`).
  static var fileURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent(StoreLocation.directoryName).appendingPathComponent(
      "crash.log")
  }

  static func install() {
    // Garde le cas « hors boucle d'événements » : rare, mais c'est le seul que l'échange ci-dessous
    // ne voit pas (AppKit n'est pas encore, ou plus, en train de servir la boucle).
    // Tout qualifié par `CrashLog.` : `NSSetUncaughtExceptionHandler` veut un pointeur de fonction
    // C, et un appel non qualifié capturerait implicitement le `Self` du contexte.
    NSSetUncaughtExceptionHandler { exception in
      CrashLog.write(CrashLog.describe(exception, caught: "gestionnaire non rattrapé"))
    }
    installAppKitHook()
  }

  /// L'implémentation d'origine de `reportException:`, à rappeler après avoir écrit — on OBSERVE,
  /// on ne détourne pas. `nonisolated(unsafe)` : écrite une fois à l'installation, lue depuis le
  /// fil principal uniquement (AppKit n'appelle `reportException:` que là).
  private nonisolated(unsafe) static var originalReport:
    (@convention(c) (AnyObject, Selector, NSException) -> Void)?

  private static func installAppKitHook() {
    let selector = #selector(NSApplication.reportException(_:))
    guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
    originalReport = unsafeBitCast(
      method_getImplementation(method),
      to: (@convention(c) (AnyObject, Selector, NSException) -> Void).self)
    let replacement: @convention(block) (AnyObject, NSException) -> Void = { app, exception in
      CrashLog.write(describe(exception, caught: "reportException:"))
      originalReport?(app, selector, exception)
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
  }

  private static func describe(_ exception: NSException, caught by: String) -> String {
    """
    par     : \(by)
    nom     : \(exception.name.rawValue)
    raison  : \(exception.reason ?? "(aucune)")
    pile    :
    \(exception.callStackSymbols.joined(separator: "\n"))
    """
  }

  /// Écriture la plus bête possible : le process est en train de mourir, ce n'est pas le moment de
  /// dépendre de quoi que ce soit. Pas de `FileHandle` à refermer, pas de `Codable`, pas d'`async`.
  /// En ajout, pour garder les précédents — un plantage qui se répète se lit dans la série.
  static func write(_ body: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "\n===== PLANTAGE \(stamp) =====\n\(body)\n"
    let url = fileURL
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = entry.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      try? handle.write(contentsOf: data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
    // Doublé dans le journal unifié : inutile pour NOUS (il ne rend rien pour ce process), mais
    // c'est ce que lira un `Console.app` ouvert au bon moment, et ça ne coûte rien.
    NSLog("PLANTAGE — %@", body)
  }
}
