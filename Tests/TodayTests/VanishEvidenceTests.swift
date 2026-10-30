import XCTest

@testable import Today

/// Les preuves qu'exige la synchro avant d'effacer une tâche ou de retirer une durée. C'est le seul
/// endroit de l'app qui détruit des données sans qu'on le lui demande : chaque règle a ici le test
/// qui la tient, seconde par seconde — l'horloge est un paramètre.
final class VanishEvidenceTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  /// Vu vivant à `t0 - 10`, pour que l'absence qui suit soit celle d'un élément CONNU.
  private func evidence(alive ids: [String]) -> VanishEvidence {
    var evidence = VanishEvidence()
    _ = evidence.assess(
      Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }), containerPresent: true,
      at: at(-10))
    return evidence
  }

  // MARK: Vu vivant

  /// La base restaurée du 5 août 2026 : un identifiant jamais vu vivant n'est pas orphelin, il
  /// est périmé. Aucune durée d'absence n'en fait une suppression.
  func testJamaisVuVivantNeDevientJamaisUneSuppression() {
    var evidence = VanishEvidence()
    for second in stride(from: 0.0, through: 600, by: 60) {
      let verdict = evidence.assess(["R": false], containerPresent: true, at: at(second))
      XCTAssertEqual(verdict["R"], .unknownIdentifier)
    }
    XCTAssertNil(evidence.nextCheck, "rien à attendre pour un identifiant inconnu")
  }

  // MARK: La durée ET le nombre de passes

  /// Le défaut corrigé : « deux passes de suite » tombaient à une seconde d'écart, soit 2 à 3 s
  /// d'absence — la durée d'une resynchro iCloud. Trois passes rapprochées ne prouvent rien.
  func testDesPassesRapprocheesNeSuffisentPas() {
    var evidence = evidence(alive: ["R"])
    for second in [0.0, 1, 2, 3, 10] {
      XCTAssertEqual(
        evidence.assess(["R": false], containerPresent: true, at: at(second))["R"], .missing)
    }
  }

  /// Deux minutes ne suffisent pas non plus si elles ne sont couvertes que par deux passes.
  func testLaDureeSansLeNombreDePassesNeSuffitPas() {
    var evidence = evidence(alive: ["R"])
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(0))["R"], .missing)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(500))["R"], .missing)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(501))["R"], .vanished,
      "la troisième passe, au-delà de la durée, tranche")
  }

  func testTroisPassesSurDeuxMinutesTranchent() {
    var evidence = evidence(alive: ["R"])
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(0))["R"], .missing)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(60))["R"], .missing)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(119))["R"], .missing,
      "trois passes, mais 119 s : pas encore")
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(120))["R"], .vanished)
  }

  /// Un retour, même bref, remet tout à zéro : c'est le hoquet iCloud qu'on refuse de prendre
  /// pour une suppression.
  func testUnRetourRemetLesPreuvesAZero() {
    var evidence = evidence(alive: ["R"])
    _ = evidence.assess(["R": false], containerPresent: true, at: at(0))
    _ = evidence.assess(["R": false], containerPresent: true, at: at(60))
    XCTAssertEqual(evidence.assess(["R": true], containerPresent: true, at: at(90))["R"], .alive)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(130))["R"], .missing)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(140))["R"], .missing,
      "la nouvelle absence repart de 130 s")
  }

  /// Verdict rendu, dossier clos : l'élément n'est plus « vu vivant ». S'il manque encore, c'est un
  /// identifiant inconnu — jamais une seconde suppression.
  func testUnVerdictRenduFermeLeDossier() {
    var evidence = evidence(alive: ["R"])
    for second in [0.0, 60, 120] {
      _ = evidence.assess(["R": false], containerPresent: true, at: at(second))
    }
    XCTAssertFalse(evidence.wasSeenAlive("R"))
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(200))["R"], .unknownIdentifier)
    XCTAssertNil(evidence.nextCheck)
  }

  // MARK: Le garde-fou de masse

  /// Plus du quart des éléments vivants qui manquent d'un coup (et trois au moins) : c'est le compte
  /// qui se resynchronise. Rien n'est compté, aussi longtemps que ça dure.
  func testUneDisparitionEnMasseNeCompteJamais() {
    var evidence = evidence(alive: ["A", "B", "C", "D"])
    for second in stride(from: 0.0, through: 600, by: 30) {
      let verdicts = evidence.assess(
        ["A": false, "B": false, "C": false, "D": true], containerPresent: true, at: at(second))
      XCTAssertFalse(verdicts.values.contains(.vanished), "à \(second) s : \(verdicts)")
    }
    XCTAssertTrue(evidence.isHeld)
    XCTAssertNil(evidence.nextCheck, "pas de réarmement sur une panne")
  }

  /// Le seuil est une PART et un minimum : 5 sur 20 (25 %, pas plus) n'est pas une masse, 2 sur 2
  /// non plus (moins de trois) — ce sont des suppressions ordinaires.
  func testLeSeuilDeMasse() {
    let twenty = (0..<20).map { "R\($0)" }
    var ordinary = evidence(alive: twenty)
    var present = Dictionary(uniqueKeysWithValues: twenty.map { ($0, true) })
    for id in twenty.prefix(5) { present[id] = false }
    _ = ordinary.assess(present, containerPresent: true, at: at(0))
    XCTAssertFalse(ordinary.isHeld, "5 sur 20")

    var pair = evidence(alive: ["A", "B"])
    _ = pair.assess(["A": false, "B": false], containerPresent: true, at: at(0))
    XCTAssertFalse(pair.isHeld, "2 sur 2 : moins de trois")

    var twelve = evidence(alive: (0..<12).map { "R\($0)" })
    var four = Dictionary(uniqueKeysWithValues: (0..<12).map { ("R\($0)", true) })
    for i in 0..<4 { four["R\(i)"] = false }
    _ = twelve.assess(four, containerPresent: true, at: at(0))
    XCTAssertTrue(twelve.isHeld, "4 sur 12, plus du quart")
  }

  /// Le conteneur (liste-pont, calendrier) absent de la passe : rien n'est compté. Les passes
  /// retenues ne s'ajoutent pas, même si elles couvrent la durée.
  func testUnConteneurAbsentRetientLaPasse() {
    var evidence = evidence(alive: ["R"])
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(0))["R"], .missing)
    for second in [30.0, 60, 90, 150] {
      XCTAssertEqual(
        evidence.assess(["R": false], containerPresent: false, at: at(second))["R"], .missing)
      XCTAssertTrue(evidence.isHeld)
    }
    // Deux passes comptées seulement (0 s et celle-ci) : pas encore.
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(160))["R"], .missing)
    XCTAssertEqual(
      evidence.assess(["R": false], containerPresent: true, at: at(161))["R"], .vanished,
      "l'absence ouverte à 0 s garde son départ : trois passes comptées, 161 s")
  }

  // MARK: Le réarmement

  /// Les passes s'étalent sur la durée exigée — mi-parcours, puis l'échéance — au lieu de tourner
  /// à 1 Hz.
  func testLaProchaineVerificationSuitLEcheance() {
    var evidence = evidence(alive: ["R"])
    XCTAssertNil(evidence.nextCheck)
    _ = evidence.assess(["R": false], containerPresent: true, at: at(0))
    XCTAssertEqual(evidence.nextCheck, at(60))
    _ = evidence.assess(["R": false], containerPresent: true, at: at(5))
    XCTAssertEqual(evidence.nextCheck, at(120))
    _ = evidence.assess(["R": false], containerPresent: true, at: at(10))
    XCTAssertEqual(evidence.nextCheck, at(120), "trois passes : il ne manque que la durée")
  }

  /// Le réarmement sans fin : un identifiant que plus aucune tâche ne porte n'était plus jamais
  /// tranché, et son absence en attente réarmait la synchro à 1 Hz pour toujours.
  func testUnIdentifiantQuiNestPlusSuiviEstOublie() {
    var evidence = evidence(alive: ["R", "S"])
    _ = evidence.assess(["R": false, "S": true], containerPresent: true, at: at(0))
    XCTAssertNotNil(evidence.nextCheck)
    _ = evidence.assess(["S": true], containerPresent: true, at: at(1))
    XCTAssertNil(evidence.nextCheck)
    XCTAssertFalse(evidence.wasSeenAlive("R"))
  }

  /// Ce que l'app efface elle-même n'a plus rien à prouver.
  func testOublierRetireLesPreuves() {
    var evidence = evidence(alive: ["R"])
    _ = evidence.assess(["R": false], containerPresent: true, at: at(0))
    evidence.forget(["R"])
    XCTAssertNil(evidence.nextCheck)
    XCTAssertFalse(evidence.wasSeenAlive("R"))
  }
}
