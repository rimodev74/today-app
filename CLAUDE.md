# ThingsClone

Clone natif macOS de Things (Cultured Code). Scope, décisions et découpage : `ROADMAP.md`.
SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData, ~2000 lignes dans `Sources/ThingsClone/`.

## Lancer

```bash
./run.sh          # build → bundle .app → open. Le seul moyen correct de lancer l'app.
swift build       # compilation seule (~0,2 s incrémental)
```

**Jamais `swift run`.** L'exécutable nu n'est pas un bundle : macOS ne lui applique pas la
chrome de fenêtre native (coins arrondis, barre de titre) et l'app ne ressemble à rien.
`Scripts/make-app.sh` fabrique le bundle + Info.plist + signature ad-hoc.

## Pièges de ce projet

- **Le minimum macOS n'est pas vérifié par le build.** `Package.swift` déclare `.macOS(.v14)`
  mais `swift build` compile pour l'hôte (macOS 26). Une API `@available(macOS 15+)` compile
  sans broncher et casserait sur une vraie cible 14. À vérifier à l'œil.
- **Changer un `@Model` efface la base.** `ThingsCloneApp.container` supprime le store quand le
  schéma ne charge pas (pas de plan de migration à ce stade). Normal aujourd'hui, à signaler
  quand même si des données de test comptent.
- **`swift build` qui passe ne veut pas dire que ça marche.** L'essentiel des bugs ici sont des
  bugs de layout et d'interaction, invisibles au compilateur. Un changement d'UI se vérifie en
  lançant `./run.sh` et en regardant.

## Conventions

- **Natif d'abord, toujours.** `List` + `.onMove` plutôt qu'un drag & drop maison, `List` +
  sélection native plutôt qu'un `ScrollView`. Les régressions de ce projet viennent toutes de
  réimplémentations de ce que macOS fait déjà. Si l'API native ne convient pas, dire pourquoi
  en commentaire avant d'écrire du custom (cf. `TaskCheckbox` dans `TaskRowView.swift`).
- **Les commentaires disent *pourquoi*, jamais *quoi*.** Ce code documente des pièges macOS non
  évidents (le header dans la `List` à cause de `fullSizeContentView`, le focus posé au
  `.onAppear` du champ, l'image tabulaire du `MenuBarExtra`). C'est le standard : le tenir.
- **En français**, comme le reste du code.
- `// ponytail:` marque une simplification délibérée et son plafond.

## Outils

- **sourcekit-lsp est installé** et couvre les `.swift`. Utiliser les outils `lsp_*`
  (`lsp_diagnostics`, `lsp_goto_definition`, `lsp_find_references`, `lsp_hover`) plutôt que de
  deviner un type ou de grep des références à la main.
- Formatage : `xcrun swift-format -i -r Sources` (pas de config, valeurs par défaut).

## État réel

Beaucoup d'UI est du décor non branché — le vérifier avant de le présenter comme fini :
recherche, vues intelligentes (Aujourd'hui, À venir…) sont des stubs `comingSoon`, et la rangée
d'icônes de la carte d'édition (date, tags, checklist, priorité) ne fait rien. Ce qui marche
vraiment : listes, tâches, en-têtes, réordonnancement, renommage, complétion, projets, pomodoro.
