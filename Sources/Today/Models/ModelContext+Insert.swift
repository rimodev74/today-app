import SwiftData

extension ModelContext {
  /// Insère un modèle et l'enregistre aussitôt.
  ///
  /// À utiliser dès que la vue va mémoriser l'identifiant du modèle créé (identité d'un
  /// ForEach, sélection, ligne en cours de renommage).
  ///
  /// Un modèle inséré mais pas encore enregistré porte un `persistentModelID`
  /// *temporaire*, que SwiftData remplace par l'identifiant définitif au premier
  /// enregistrement — c'est-à-dire à l'autosave, quelques instants plus tard. Tout ce qui
  /// avait mémorisé l'ancien pointe alors dans le vide : la ligne semble disparaître puis
  /// revenir, et un état d'édition mémorisé se dénoue tout seul. Enregistrer tout de suite
  /// fixe l'identifiant avant que la vue ne le lise.
  func insertAndSave<T: PersistentModel>(_ model: T) {
    insert(model)
    try? save()
  }
}
