import SwiftData
import XCTest

@testable import Today

/// **Le cliquet du schéma : la forme des `@Model` ne peut plus changer en silence.**
///
/// Le trou qu'il bouche, et qui a coûté deux quarantaines : `CurrentSchema.versionIdentifier` est un
/// numéro tapé à la main, que RIEN ne dérive de la forme réelle. On modifie un `@Model`, la forme
/// change, le numéro ne bouge pas — et SwiftData compare les NUMÉROS, jamais les formes. Il conclut
/// « rien à faire », ne joue aucune étape de migration, et l'ouverture échoue. Compilateur muet,
/// tests verts, app vide au lancement suivant.
///
/// Ici la forme se PRONONCE. `StoreBackup.fingerprint` en calcule déjà l'empreinte — nom de chaque
/// entité, nom et type de chaque propriété, plus le numéro de version — pour décider s'il faut
/// sauvegarder. Le même calcul, confronté à une valeur versionnée, transforme l'oubli en test rouge.
///
/// L'empreinte n'est pas une redite du numéro de version : elle bouge quand la FORME bouge, lui ne
/// bouge que quand on y pense. C'est tout l'écart entre les deux qu'il s'agit de rendre visible.
///
/// ## Quand ce test passe au rouge
///
/// C'est qu'un `@Model` a changé. **Ne pas recopier l'empreinte pour faire taire le test** — ce
/// serait exactement l'oubli qu'il attrape, avec une étape en plus. Suivre les cinq points en tête
/// de `TodaySchema.swift` : figer la forme sortante en `SchemaV<N>`, monter
/// `CurrentSchema.versionIdentifier`, déclarer l'étape, déposer la base fixture (cf.
/// `StoreFixtureTests`). L'empreinte se met à jour EN DERNIER, une fois tout le reste vert.
final class SchemaFingerprintTests: XCTestCase {
  /// L'empreinte de la forme 5.0.0. Mise à jour uniquement à l'issue de la marche ci-dessus.
  private static let expected =
    "5d3d7ace143d0ff1a386f8081df1f6e60c7adae0deb353a8b077fcdf0cd07826"

  func testCurrentSchemaShapeIsTheDeclaredOne() {
    let actual = StoreBackup.fingerprint(of: Schema(versionedSchema: CurrentSchema.self))
    XCTAssertEqual(
      actual, Self.expected,
      """
      La forme des `@Model` a changé.

      Attendue : \(Self.expected)
      Obtenue  : \(actual)

      NE PAS se contenter de recopier l'empreinte : c'est l'oubli que ce test attrape. Suivre les \
      cinq points en tête de `TodaySchema.swift` (figer `SchemaV<N>`, monter le numéro de version, \
      déclarer l'étape, déposer la fixture), PUIS mettre `expected` à jour.
      """)
  }

  /// L'empreinte doit être stable d'un calcul à l'autre dans le même process, et d'un lancement à
  /// l'autre. Sans ça, le cliquet serait rouge au hasard et on finirait par le désactiver — ce qui
  /// a failli arriver : une première version incluait les valeurs par DÉFAUT, or `Date()` et
  /// `UUID()` en donnent une différente à chaque construction du schéma (cf. `StoreBackup`).
  func testFingerprintIsStable() {
    let a = StoreBackup.fingerprint(of: Schema(versionedSchema: CurrentSchema.self))
    let b = StoreBackup.fingerprint(of: Schema(versionedSchema: CurrentSchema.self))
    XCTAssertEqual(a, b, "l'empreinte doit être déterministe, sinon le cliquet est un bruit")
  }

  /// Deux formes différentes doivent donner deux empreintes différentes — sinon le cliquet
  /// laisserait passer précisément ce qu'il surveille.
  func testDifferentShapesGiveDifferentFingerprints() {
    let current = StoreBackup.fingerprint(of: Schema(versionedSchema: CurrentSchema.self))
    let previous = StoreBackup.fingerprint(of: Schema(versionedSchema: SchemaV3.self))
    XCTAssertNotEqual(
      current, previous,
      "3.0.0 et 4.0.0 diffèrent par les `uuid` : leurs empreintes doivent différer")
  }
}
