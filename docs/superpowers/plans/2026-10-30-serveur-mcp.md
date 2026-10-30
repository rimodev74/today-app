# Serveur MCP de Today — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** Today héberge un serveur MCP local que Claude Code branche en une commande pour lire et
écrire projets, listes, tâches et sous-tâches.

**Architecture :** `MCPServer` (Services) écoute en HTTP sur 127.0.0.1 via `NWListener`, filtre clé
et `Origin`, décode le JSON hors du fil principal en `JSONValue` (Sendable). `MCPRouter` (Models),
sur `MainActor`, répartit le JSON-RPC et exécute les outils sur `container.mainContext`. Les
suppressions passent par `deleteCascadeAndSave` puis `forgetAppleItems` / `ProjectCovers.remove`.

**Tech stack :** Swift 5 mode, SwiftUI, SwiftData, Network.framework. Aucune dépendance ajoutée.

**Spec :** `docs/superpowers/specs/2026-10-30-serveur-mcp-design.md`

## Global Constraints

- Aucun changement de `@Model` ni de `TodaySchema` : identifiants = `uuid` existants.
- macOS 14 minimum : aucune API `@available(macOS 15+)` (vérifier à l'œil, le build ne le fait pas).
- Écoute **127.0.0.1 uniquement** ; clé 32 octets aléatoires, comparaison en temps constant ; 401 sans
  clé valide ; **403 si en-tête `Origin` présent** ; corps > 1 Mo → 413 ; `GET /mcp` → 405.
- Bascule des Réglages **éteinte par défaut**.
- Ports fixes : `Today` = **48631**, `TodayDev` = **48632** (choisi par `Bundle.main.bundleIdentifier`
  ou le nom du process, comme le reste de l'isolation dev).
- Écritures SwiftData uniquement sur `MainActor`, contexte = `TodayApp.container.mainContext`.
- Commentaires en français, identifiants en anglais, commentaires = pourquoi.
- Après chaque tâche : `swift build && swift test` verts. Avant la fin : contrôle complet
  (`find Sources Tests -name '*.swift' -exec touch {} +; swift build -c release && swift test`).
- Commits sans trailer `Co-Authored-By` ni mention d'outil.

## Review Focus

1. **Relancer une synchro** (même titres) → aucun doublon de projet, liste, tâche ou sous-tâche ;
   titres comparés après trim, insensibles à la casse. (Tâche 1)
2. **`id` inconnu ou d'un autre type** (ex. `list_id` qui est une tâche) → résultat `isError: true`
   lisible, jamais de crash. (Tâche 1)
3. **Supprimer la liste ou le projet affiché** → la fenêtre retombe sur « Tâches », pas de page
   fantôme. (Tâche 2, vérif visuelle)
4. **Requête HTTP coupée en plusieurs paquets** ou `Content-Length` absent/menteur → attente du corps
   complet, ou 400 ; jamais d'exécution sur un corps tronqué. (Tâche 3)
5. **Port déjà occupé** (deux Today, ou un autre programme) → la section des Réglages l'affiche,
   l'app ne plante pas. (Tâche 4)

---

### Tâche 1 : routeur JSON-RPC et outils de lecture / création / modification

**Files :**
- Create : `Sources/Today/Models/JSONValue.swift`
- Create : `Sources/Today/Models/MCPRouter.swift`
- Test : `Tests/TodayTests/MCPRouterTests.swift`

**Interfaces :**
- Produces :
  - `enum JSONValue: Codable, Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }` + accès `subscript(key: String) -> JSONValue?`, `var stringValue: String?`, `var boolValue: Bool?`, `var arrayValue: [JSONValue]?`.
  - `struct MCPEffects { let forgetAppleItems: ([String]) -> Void; let removeCover: (UUID) -> Void }` (utilisé en tâche 2 ; ici seulement stocké).
  - `@MainActor struct MCPRouter { init(context: ModelContext, effects: MCPEffects); func handle(_ request: JSONValue) -> JSONValue? }` — `nil` pour une notification (pas d'`id`).
  - Outils (noms exacts) : `list_projects`, `get_project`, `create_project`, `create_list`, `create_task`, `add_subtask`, `update_item`, `delete_item` (ce dernier stubbé en tâche 1 : `isError` « non implémenté »).

- [ ] **Étape 1 : tests qui échouent**, conteneur en mémoire comme `MoveTargetsTests.setUpWithError`, effets no-op :
  - `testInitializeEchoesProtocolVersion` : `initialize` avec `protocolVersion: "2025-06-18"` → `result.protocolVersion == "2025-06-18"`, `result.capabilities.tools` présent, `result.serverInfo.name == "Today"`.
  - `testNotificationReturnsNil` : `{"jsonrpc":"2.0","method":"notifications/initialized"}` → `nil`.
  - `testUnknownMethodIsMinus32601`.
  - `testToolsListNamesAllEight` : les 8 noms ci-dessus ; `delete_item` porte `annotations.destructiveHint == true`.
  - `testCreateProjectIsIdempotentByTitle` : `create_project("Monflix")` puis `create_project("  monflix ")` → même `id`, second `created == false`, 1 projet en base.
  - `testCreateListTaskSubtaskIdempotent` : liste, tâche (avec `subtasks: ["a","b"]`), `add_subtask("A")` rejoués deux fois → comptes inchangés au second passage ; sous-tâches dans l'ordre `a, b`.
  - `testGetProjectTree` : renvoie listes → tâches (`completed`, `notes` texte brut, `is_header`) → sous-tâches (`done`), ordre manuel.
  - `testUpdateItemCompletesTask` : `completed: true` → `isCompleted` et `completedAt != nil` ; `false` → `completedAt == nil`. Sur sous-tâche → `isDone`.
  - `testUpdateItemNotesRoundTrip` : `notes: "x"` → `NotesCodec.plainText(task.notes) == "x"`.
  - `testUnknownIdIsToolError` et `testWrongTypeIdIsToolError` (`list_id` = uuid d'une tâche) → `result.isError == true`, aucune écriture.
  - `testListProjectsIncludesInbox` : la liste `isInbox` apparaît (hors projet).
- [ ] **Étape 2 :** `swift test --filter MCPRouterTests` → échec (types absents).
- [ ] **Étape 3 : implémenter.** Résultat d'outil au format MCP : `{"content":[{"type":"text","text":<JSON compact>}], "isError": bool}`. Résolution d'`id` : `FetchDescriptor` avec `#Predicate { $0.uuid == id }` sur le type attendu. Création via `Project`/`Project.appendList(titled:in:)`/`TaskItem`/`Subtask` en fin (`sortIndex` = max+1), `insertAndSave` puis `saveReportingSuccess`. Notes : `NotesCodec.encode(NSAttributedString(string:))`. Compter `done/total` hors en-têtes, une passe par projet (pas de propriété calculée relue par élément). Les descriptions d'outils portent la convention : phase = liste, ligne = tâche, sous-point = sous-tâche ; appeler `get_project` avant de synchroniser ; garder les `id`. Description de `delete_item` : « Uniquement quand l'utilisateur l'a demandé explicitement dans la conversation. Jamais pour nettoyer, dédoublonner ou réorganiser de ta propre initiative. »
- [ ] **Étape 4 :** `swift test --filter MCPRouterTests` → PASS ; `swift build && swift test` verts.
- [ ] **Étape 5 : commit** `git add Sources/Today/Models/JSONValue.swift Sources/Today/Models/MCPRouter.swift Tests/TodayTests/MCPRouterTests.swift && git commit -m "MCP : routeur JSON-RPC et outils de lecture et d'écriture"`

### Tâche 2 : suppression partagée et garde de sélection

**Files :**
- Modify : `Sources/Today/Models/Project.swift` (ajout de `delete`)
- Modify : `Sources/Today/Views/Sidebar/SidebarView.swift:865-911` (`delete(_ project:)` délègue)
- Modify : `Sources/Today/Models/MCPRouter.swift` (`delete_item`)
- Modify : `Sources/Today/Views/ContentView.swift` (garde de `selection`)
- Test : `Tests/TodayTests/MCPRouterTests.swift`

**Interfaces :**
- Consumes : `MCPEffects`, `MCPRouter` (tâche 1) ; `ModelContext.deleteCascadeAndSave`, `runAfterNextSave`, `RemindersService.appleIdentifiers(of:)`.
- Produces : `extension Project { @discardableResult func delete(in context: ModelContext, forget: @escaping ([String]) -> Void, removeCover: @escaping (UUID) -> Void) -> Bool }` — lit identifiants Apple et `uuid` AVANT, `deleteCascadeAndSave`, puis `forget` + `removeCover` (ou `runAfterNextSave` si échec). La sidebar garde SA gestion de sélection et appelle cette fonction pour le reste.

- [ ] **Étape 1 : tests qui échouent :**
  - `testDeleteTaskCascadesSubtasks` : tâche + 2 sous-tâches jamais lues → `delete_item(task)` → 0 tâche, 0 sous-tâche, `forget` reçu une fois.
  - `testDeleteListCascades`, `testDeleteProjectCascadesAndRemovesCover` : `removeCover` reçu avec l'`uuid` du projet.
  - `testDeleteRefusesInbox` : supprimer la liste `isInbox` → `isError`, rien n'est supprimé.
- [ ] **Étape 2 :** `swift test --filter MCPRouterTests` → échec.
- [ ] **Étape 3 : implémenter** `Project.delete`, la délégation dans `SidebarView.delete(_ project:)` (comportement identique), et `delete_item` : `deleteCascadeAndSave` pour tâche, sous-tâche, liste, projet ; identifiants Apple lus avant. Dans `ContentView`, un `.onChange` sur le signal `ModelContext.didSave` (ou équivalent déjà présent) qui remet `selection = .smartList(.all)` quand l'objet sélectionné a `isDeleted` ou `modelContext == nil`.
- [ ] **Étape 4 :** tests verts ; `swift build && swift test`.
- [ ] **Étape 5 : commit** « MCP : suppression sur demande, projet supprimé par un chemin partagé ».

### Tâche 3 : serveur HTTP local

**Files :**
- Create : `Sources/Today/Models/HTTPRequest.swift` (analyse pure)
- Create : `Sources/Today/Services/MCPServer.swift`
- Test : `Tests/TodayTests/MCPServerTests.swift`

**Interfaces :**
- Consumes : `JSONValue`, `MCPRouter` (tâche 1).
- Produces :
  - `struct HTTPRequest: Sendable { let method: String; let path: String; let headers: [String: String] /* clés en minuscules */; let body: Data }`, `static func parse(_ buffer: Data) -> ParseResult` avec `enum ParseResult { case incomplete, malformed, tooLarge, complete(HTTPRequest) }` ; plafond 1 048 576 octets.
  - `enum MCPGate { static func status(for request: HTTPRequest, key: String) -> Int? }` — `nil` = autorisé ; sinon 403 (Origin), 401 (clé), 405 (méthode ≠ POST), 404 (chemin ≠ `/mcp`). Ordre : Origin, puis clé, puis méthode/chemin.
  - `@MainActor final class MCPServer { enum State: Equatable { case off, listening(port: UInt16), failed(String) }; private(set) var state: State; init(container: ModelContainer, effects: MCPEffects); func start(port: UInt16, key: String); func stop() }` — `@Observable` pour les Réglages.

- [ ] **Étape 1 : tests qui échouent :**
  - `testParseCompleteRequest`, `testParseIncompleteUntilBodyArrives` (en-têtes seuls avec `Content-Length: 10` → `.incomplete` ; corps ajouté → `.complete`), `testParseMissingContentLengthOnPostIsMalformed`, `testParseTooLarge`.
  - `testGateRejectsOrigin` (403 même avec bonne clé), `testGateRejectsBadKey` (401), `testGateRejectsGet` (405), `testGateAcceptsBearer` (`nil`).
- [ ] **Étape 2 :** `swift test --filter MCPServerTests` → échec.
- [ ] **Étape 3 : implémenter.** `NWListener` avec `NWParameters.tcp`, `requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port:)`, file dédiée. Par connexion : accumuler jusqu'à `.complete`, `MCPGate`, décoder `JSONValue` hors fil principal, `await MainActor.run { router.handle(...) }`, encoder, répondre (`200 application/json`, `202` sans corps pour une notification, `Connection: close`). Comparaison de clé en temps constant (XOR sur les octets, longueurs égales). `stop()` annule listener et connexions. Échec du listener (port pris) → `state = .failed(message)`, aucun `fatalError`.
- [ ] **Étape 4 :** tests verts ; `swift build && swift test`.
- [ ] **Étape 5 : commit** « MCP : serveur HTTP local, clé et refus des navigateurs ».

### Tâche 4 : Réglages, branchement dans l'app, vérification de bout en bout

**Files :**
- Create : `Sources/Today/Views/ClaudeCodeSettingsTab.swift`
- Modify : `Sources/Today/Views/SettingsView.swift` (onglet « Claude Code », `systemImage: "terminal"`)
- Modify : `Sources/Today/ThingsCloneApp.swift` (création et injection de `MCPServer`)
- Modify : `CLAUDE.md` (§ État réel : une puce « Serveur MCP »), `PIEGES.md` si un piège est rencontré

**Interfaces :**
- Consumes : `MCPServer`, `MCPEffects(forgetAppleItems: remindersService.forgetAppleItems, removeCover: covers.remove(for:))`.
- Produces : clés `UserDefaults` `mcpEnabled: Bool` (défaut `false`) et `mcpKey: String` (hex, générée par `SecRandomCopyBytes` au premier allumage).

- [ ] **Étape 1 : implémenter.** `TodayApp` possède `@State var mcpServer`, l'injecte en environnement, le démarre au lancement si `mcpEnabled`, l'arrête sur `NSApplication.willTerminateNotification`. L'onglet : `Toggle("Autoriser Claude Code à modifier Today")`, état (`Écoute sur le port 48631` / message d'échec), la commande `claude mcp add --transport http --scope user today http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <clé>"` en `Text` sélectionnable + bouton « Copier » (`NSPasteboard`), bouton « Régénérer la clé » (redémarre le serveur), et la mention : « Ne mets jamais `delete_item` en "toujours autoriser" : chaque suppression doit te demander confirmation. » Basculer = démarrer / arrêter.
- [ ] **Étape 2 :** `swift build && swift test` verts.
- [ ] **Étape 3 : vérif visuelle.** `./run-dev.sh`, ouvrir l'onglet, capture dans les deux thèmes ; lancer une seconde fois sur un port occupé (`nc -l 48632` avant) → message d'échec visible.
- [ ] **Étape 4 : bout en bout sur `TodayDev`.** `claude mcp add --transport http today-dev http://127.0.0.1:48632/mcp --header "Authorization: Bearer <clé>"`, puis dans une session : créer « Test MCP » avec 2 listes, des tâches et sous-tâches ; rejouer → aucun doublon ; cocher une tâche dans l'app → `get_project` la voit cochée ; « supprime le projet Test MCP » → fenêtre de confirmation de Claude Code, projet parti, fenêtre retombée sur « Tâches » s'il était affiché. Puis `curl -H "Origin: http://evil" …` → 403, sans clé → 401.
- [ ] **Étape 5 :** contrôle complet des avertissements (cf. Global Constraints) ; retirer `today-dev` de Claude Code.
- [ ] **Étape 6 : commit** « MCP : réglages et branchement dans l'app ».
