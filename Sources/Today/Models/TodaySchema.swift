import SwiftData

/// Le schéma COURANT : ce que le code décrit *maintenant*, estampillé d'un numéro de version.
///
/// `models` est une FLÈCHE vers les classes vivantes, pas une copie — et c'est voulu : le schéma
/// courant, par définition, est ce que les modèles disent aujourd'hui. D'où le nom : rien ici ne
/// prétend décrire une version passée. Les versions passées, elles, sont figées (cf. plus bas).
///
/// Corollaire à connaître : `versionIdentifier` ne se met PAS à jour tout seul. Modifier un
/// `@Model` sans toucher ce numéro redéfinit silencieusement ce que « 1.0.0 » veut dire, pendant
/// que la base sur disque, elle, n'a pas bougé. Deux issues, aucune bruyante :
///
/// - changement ADDITIF (champ optionnel ou à valeur par défaut) → SwiftData migre seul, rien à
///   faire, et c'est le cas courant ;
/// - changement CASSANT (renommer, supprimer, changer un type) → **la donnée part sans un mot**.
///   Mesuré sur cette app : renommer un champ stocké laisse `swift build` passer, laisse le store
///   s'ouvrir SANS erreur, et vide la colonne (SwiftData lit un renommage comme « supprime
///   l'ancien, ajoute le neuf »). Pas de quarantaine, pas d'alerte — juste des dates devenues nil.
///
/// Aucune API ne prévient de ça : la chaîne de versions de SwiftData sait TRANSPORTER une donnée
/// d'une forme à l'autre, elle ne sait pas REPÉRER qu'on a changé de forme sans le dire. C'est donc
/// à nous, et ça tient en une contrepartie écrite : la forme réellement présente sur les disques est
/// figée dans `Tests/TodayTests/SchemaV1Snapshot.swift`, et `SchemaCompatibilityTests` vérifie à
/// chaque `swift test` que `CurrentSchema` sait encore relire une base écrite à cette forme-là.
/// Tant que ce test est vert, l'estampille 1.0.0 est légitime. Rouge = elle ment, ne pas lancer
/// l'app avant d'avoir suivi la marche ci-dessous.
enum CurrentSchema: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)

  static var models: [any PersistentModel.Type] {
    [Project.self, TodoList.self, TaskItem.self, Subtask.self]
  }
}

/// Chaîne de migration de l'app : les formes PASSÉES, dans l'ordre, puis la forme courante.
///
/// Vide de versions passées pour l'instant — personne n'a encore de base à une autre forme que
/// celle d'aujourd'hui. Le plan existe déjà pour que la première migration soit un ajout et pas un
/// socle à inventer dans l'urgence.
///
/// ## Le jour où un changement cassant l'exige
///
/// 1. Déplacer `SchemaV1Snapshot` (cible de tests) ici, renommé `SchemaV1`. Ses types sont
///    IMBRIQUÉS dans l'enum, donc indépendants du code vivant : c'est ce qui lui permet de
///    continuer à décrire l'ANCIENNE forme une fois les modèles modifiés. Vérifié : imbriquer un
///    `@Model` ne change pas l'entité de store qu'il décrit — une base écrite par les modèles de
///    premier niveau s'y relit sans perte, relations comprises.
/// 2. Modifier librement les modèles vivants, puis monter `CurrentSchema.versionIdentifier` à
///    2.0.0. Il n'y a JAMAIS de `SchemaV2` figée : la forme courante n'est décrite qu'une fois,
///    par les modèles eux-mêmes. On ne fige une version qu'au moment où elle devient passée.
/// 3. `schemas = [SchemaV1.self, CurrentSchema.self]`.
/// 4. `stages = [.lightweight(...)]` si le changement est additif, `.custom(...)` s'il faut
///    transporter de la donnée d'un champ à l'autre — c'est le cas d'un renommage, et c'est LUI qui
///    sauve les valeurs que SwiftData jetterait sinon.
/// 5. Re-figer la nouvelle forme dans `SchemaV1Snapshot` (qui garde son rôle : « ce que contiennent
///    les disques »), et rendre `SchemaCompatibilityTests` vert.
///
/// Le test, lui, ne change jamais de nature : il vérifie toujours qu'une base au format déployé
/// s'ouvre par `TodayApp.openStore`. C'est ce qui rend l'ajout d'une version mécanique.
enum TodayMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [CurrentSchema.self] }
  static var stages: [MigrationStage] { [] }
}
