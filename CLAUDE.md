# CLAUDE.md — Vibe Cleaner

## Règle absolue : l'agent construit le programme, il ne l'applique jamais

Vibe Cleaner est un nettoyeur de Mac. Son rôle est de supprimer, déplacer et modifier des choses sur l'ordinateur, mais **uniquement quand l'utilisateur se sert lui-même de l'application déployée** (ou de la CLI dans son propre terminal).

Depuis une session agentique (Claude Code ou tout autre agent), on écrit, compile et teste le code. On ne nettoie **jamais** la machine. Aucune décision ni action sur l'ordinateur réel, même si le code est prêt, même si un scan montre « beaucoup de place à libérer », même pour « vérifier que ça marche ».

### Interdit depuis l'agent, sans exception

- Toute suppression, mise à la corbeille, mise en quarantaine ou déplacement de fichiers hors du dépôt et des dossiers de build (`.build*/`, `dist/`) ou du scratchpad de la session.
- `vibeclean clean …` (avec ou sans `--apply`), et tout appel à `execute(...)` d'un module, à `ActionExecutor.run`, `SafeRemover.remove` ou `Quarantine` sur des chemins réels.
- Cliquer ou automatiser les actions de l'app (Nettoyer, Supprimer, Lancer, Libérer, Mettre en quarantaine, Libérer la RAM, Vider la corbeille…), y compris par AppleScript, `osascript`, l'accessibilité ou des tests UI.
- Toute modification du système, de la mémoire ou des applications : `purge`, `launchctl bootout|unload|load|remove`, `tmutil thinlocalsnapshots|deletelocalsnapshots`, `mdutil -E`, `diskutil resetUserPermissions`, `dscacheutil`, `killall`, `kill`, `tccutil`, `pkgutil --forget`, `brew cleanup`, `xcrun simctl delete|erase`, `sqlite3` en écriture (ex. `VACUUM`), `defaults write|delete` sur d'autres domaines que celui de l'app en développement, `sfltool`, `profiles`, `evictUbiquitousItem`, fermeture d'apps (`terminate`), vidage de corbeille.
- Toute commande avec `sudo` ou `with administrator privileges`, et toute action qui ferait apparaître une demande de mot de passe administrateur.
- Toute commande qui déclenche un installeur ou une demande d'autorisation macOS (ex. `xcrun simctl` peut lancer l'installeur des composants Xcode).

### Autorisé

- Lire et modifier le code du dépôt ; `swift build`, `swift test`, `make build`, `make test`, `make app`.
- Les tests unitaires, à condition qu'ils ne touchent **que des dossiers temporaires** créés par le test (`FileManager.default.temporaryDirectory/...`), jamais le vrai dossier personnel, `/Library`, `/Applications` ni le système. Un test qui supprime, déplace ou exécute une commande système sur un chemin réel est interdit.
- Lire des fichiers système pour comprendre leur format (`ls`, `plutil -p`, `cat`…), sans les modifier.
- `vibeclean scan <module>` (lecture seule) **seulement si l'utilisateur le demande explicitement** dans la conversation en cours. Un scan ne doit jamais écrire sur le disque ni déclencher de demande d'autorisation ; si ça arrive, c'est un bug à corriger dans le code, pas à contourner.
- Lancer l'app (`make run`) seulement si l'utilisateur le demande, sans jamais déclencher ses actions.

### En cas de doute

On ne fait pas, on demande. Si une tâche semble exiger d'agir sur la machine (tester un nettoyage réel, vérifier une suppression), on écrit un test sur un dossier temporaire ou on décrit à l'utilisateur la manipulation à faire lui-même dans l'app.

## Règles de code

- Toute suppression dans le code passe par `SafeRemover` (chemins protégés, exclusions, mode simulation). Corbeille par défaut, sauf caches régénérables.
- Un scan ne modifie jamais le disque et ne lance que des outils en lecture seule. Seule exception : des copies temporaires (bases SQLite lues, archives si l'option est activée) dans le dossier temporaire, supprimées en fin d'appel.
- Les actions root sont des `ItemAction` marquées `admin: true`, regroupées par `ActionExecutor` derrière une seule demande d'autorisation, jamais exécutées depuis l'agent.
- Code original, écrit à partir des API publiques d'Apple ; aucun code, aucune image ni aucune base de règles reprise d'un autre produit.
- Interface et textes en français. Swift 6, API publiques uniquement, pas de dépendance externe.

## Repères

- Lancer et comprendre le projet : `README.md`
- Mesures de performance : `docs/PERF.md`
- Certificat Apple et notarisation : `docs/CERTIFICAT-APPLE.md`
