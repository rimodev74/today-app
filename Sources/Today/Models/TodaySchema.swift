import SwiftData

/// Le schéma, versionné. Rien de neuf ici : `SchemaV1` décrit EXACTEMENT les modèles déjà en base
/// (SwiftData versionne implicitement en 1.0.0 quand on lui passe un `Schema([...])` nu). Le
/// déclarer ne migre donc rien — ça donne juste un nom au point de départ, sans quoi il n'y a
/// aucune version depuis laquelle migrer le jour d'un changement cassant.
///
/// ## Ajouter une V2
///
/// 1. Copier les `@Model` d'aujourd'hui dans un `enum SchemaV2` (les types y sont imbriqués, ce qui
///    laisse V1 décrire l'ANCIENNE forme même après modification du code) ;
/// 2. ajouter `SchemaV2.self` à `schemas` ;
/// 3. ajouter l'étape dans `stages` : `.lightweight` si le changement est additif (nouvelle
///    propriété optionnelle ou à valeur par défaut), `.custom` s'il faut transformer de la donnée.
///
/// Tant que les changements restent additifs, SwiftData migre tout seul et il n'y a rien à écrire.
/// C'est le renommage, la suppression et le changement de type qui exigent une étape.
enum SchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)

  static var models: [any PersistentModel.Type] {
    [Project.self, TodoList.self, TaskItem.self, Subtask.self]
  }
}

/// Chaîne de migration de l'app. Une seule version pour l'instant, donc aucune étape : le plan
/// existe pour que la V2 n'ait qu'une ligne à ajouter au lieu d'un socle à inventer en urgence.
enum TodayMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}
