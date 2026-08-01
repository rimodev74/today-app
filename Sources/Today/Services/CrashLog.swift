import Foundation

/// Ce qui manquait au rapport de plantage du 1er août : la RAISON.
///
/// Une exception Objective-C non rattrapée (AppKit en lève, cf. la pile `NSStatusItem` →
/// `ViewBridge` de ce jour-là) traverse `_objc_terminate` et finit en `abort()`. Le rapport système
/// garde la pile mais pas le message — le `asi` ne dit qu'« abort() called », et on se retrouve à
/// deviner ce qu'AppKit reprochait. Le gestionnaire ci-dessous est appelé PAR `_objc_terminate`,
/// juste avant l'abandon : c'est le dernier endroit où le nom, la raison et la pile symbolisée
/// existent encore.
///
/// Il ne rattrape RIEN et n'empêche aucun plantage — après une exception ObjC, le process est de
/// toute façon dans un état indéfini et continuer serait pire. Il écrit, puis laisse mourir.
///
/// La trace part dans le journal unifié, à relire avec :
///     log show --last 1h --predicate 'process == "Today"' | grep "PLANTAGE"
/// ponytail: pas de fichier relu au lancement pour montrer un rapport à l'utilisateur — à ajouter
/// le jour où l'app est entre d'autres mains que les nôtres.
enum CrashLog {
  static func install() {
    NSSetUncaughtExceptionHandler { exception in
      NSLog(
        "PLANTAGE — exception non rattrapée\nnom: %@\nraison: %@\npile:\n%@",
        exception.name.rawValue,
        exception.reason ?? "(aucune)",
        exception.callStackSymbols.joined(separator: "\n"))
    }
  }
}
