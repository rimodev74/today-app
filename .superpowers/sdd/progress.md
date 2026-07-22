# Sous-tâches — ledger d'exécution

Plan : docs/superpowers/plans/2026-07-22-sous-taches.md
Branche : sous-taches
Base : 092a7a6 (checkpoint WIP)

- [x] Task 1 : Modèle Subtask + relation + schéma
- [x] Task 2 : TaskCheckbox variante ronde
- [x] Task 3 : SubtaskRowView
- [x] Task 4 : Affichage + ajout clavier
- [x] Task 5 : Suppression + purge des vides

## Journal
Task 1 : complete (commit 5f7fbd7, tests 3/3, revue APPROVED)
Task 2 : complete (commit 486e470, build OK, revue APPROVED). NB : code plan Task 2 utilisait AnyShape — corrigé par helper générique fillAndBorder<S: InsettableShape>.
Task 3 : complete (commit 5579bb8, build OK, revue APPROVED)
Task 4 : complete (commit aa46dc2, build OK, revue APPROVED)
Task 5 : complete (commit c65b976, build OK, 20 tests, revue APPROVED)

== Toutes les tâches complètes. Revue finale de branche en cours. ==
Revue finale (Opus) : FIXES NEEDED → 2 findings (duplication perd sous-tâches ; clé focus persistentModelID instable).
Fix : commit a50ea90 (uuid stable + duplication copie subtasks), build OK, 20 tests. Findings résolus.
Reste : vérification visuelle humaine (./run.sh) + finalisation de branche.
