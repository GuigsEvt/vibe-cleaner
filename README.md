# Vibe Cleaner

Utilitaire de nettoyage et de maintenance pour macOS, en SwiftUI natif : nettoyage, protection, performance, désinstallation d'apps, encombrement, carte du disque et barre des menus. Usage local uniquement : pas de compte, pas de licence, pas d'analytics. Le seul accès réseau est la recherche de mises à jour d'apps, désactivable (voir Applications).

> **Avertissement : app « vibe codée », à utiliser à vos propres risques.**
> Vibe Cleaner a été codée de bout en bout avec l'IA (vibe coding), par des agents de programmation. Elle n'a fait l'objet d'aucun audit de sécurité indépendant ni d'aucune revue externe. Or elle supprime des fichiers, désinstalle des apps et lance des commandes avec le mot de passe administrateur. Gardez une sauvegarde (Time Machine) à jour, commencez en mode simulation et relisez chaque sélection avant de lancer un nettoyage. Le logiciel est fourni tel quel, sans aucune garantie (voir [LICENSE](LICENSE)).
>
> *English: Vibe Cleaner was vibe coded end to end with AI agents. It has had no security audit and no external review, yet it deletes files, uninstalls apps and runs commands with the administrator password. Keep a backup, start in simulation mode, and use it at your own risk. Provided as is, without warranty (MIT).*

## Démarrage rapide

```bash
git clone https://github.com/GuigsEvt/vibe-cleaner.git && cd vibe-cleaner
make test     # plus de 500 tests, sur des dossiers temporaires uniquement
make run      # construit dist/Vibe Cleaner.app et l'ouvre
```

Au premier lancement :

1. Ouvrez les Réglages (⌘,) > Général et cochez **Mode simulation**. Tant qu'il est actif, rien n'est modifié : ni par les modules, ni par la barre des menus, ni par les notifications, ni par les Raccourcis.
2. Réglages > Autorisations > **Ouvrir les réglages de confidentialité**, puis ajoutez Vibe Cleaner à l'accès complet au disque (voir plus bas).
3. Choisissez un module dans la barre latérale et cliquez **Analyser**.
4. Parcourez les résultats, ajustez la sélection, puis cliquez le bouton d'action.
5. Une fois rassuré, décochez le mode simulation pour nettoyer réellement.

## Fonctionnalités

| Module | Ce qu'il fait |
|---|---|
| **Vibe Check** | Analyse en parallèle Nettoyage, Protection, Performance, Applications et Fouillis (modules réglables dans Réglages > Analyse), présente une carte par module avec une sélection recommandée, puis exécute les cartes cochées l'une après l'autre. De Performance, il ne reprend que les scripts de maintenance et les éléments de connexion, sans rien cocher. Du Fouillis, il reprend les doublons de Téléchargements et les gros fichiers. Il mémorise ce que vous décochez d'une analyse à l'autre. |
| **Nettoyage** | Caches utilisateur et système, journaux, fichiers temporaires, préférences cassées, versions de documents, déchets Xcode et outils de développement, sauvegardes iOS anciennes, pièces jointes Mail, corbeilles. Aussi : caches Dropbox, éléments de démarrage cassés (y compris /Library, en admin ; les agents utilisateur partent à la Corbeille sans être déchargés) et éléments de connexion cassés, runtimes de simulateurs téléchargés (supprimés par `simctl runtime delete`), corbeilles iCloud des apps, copies locales des messages supprimés des comptes IMAP et iCloud (jamais cochées). Les pièces jointes ne sont cochées que pour les comptes IMAP et iCloud, quand l'accès complet au disque permet de lire `Accounts4.sqlite`. Homebrew n'est jamais coché : `brew cleanup` retire aussi les anciennes versions installées. Mail, Xcode et Simulator doivent être quittés avant de nettoyer leurs fichiers. |
| **Protection** | Agents et démons de démarrage qui lancent un programme non signé, mal signé ou placé dans un emplacement suspect ; apps à l'exécutable mal signé ; fichiers reconnus par les règles YARA d'XProtect (Apple) si `yara` est installé. Détecte aussi les tâches cron suspectes, les processus non signés lancés depuis des dossiers cachés ou temporaires, les extensions Chrome installées hors Web Store, les extensions Safari d'apps mal signées, une page d'accueil Safari détournée et les profils de configuration. Les menaces sont classées par type (Adware, Cheval de Troie, Voleur de données…) et vont dans une quarantaine restaurable, éléments système compris (mot de passe administrateur demandé à la restauration). Le programme lancé par un agent suspect y part aussi. Liste de hash : ajoutez vos empreintes SHA-256 dans `~/Library/Application Support/VibeCleaner/hashes.txt` (une par ligne, suivie d'un nom si besoin) ; Vibe Cleaner n'en fournit aucune. Analyse personnalisée : bouton « Analyser un dossier… » sur l'écran Protection, ou glisser-déposer. Surveillance quand l'app est ouverte : nouveaux agents de lancement et, avec l'accès complet au disque, nouveaux téléchargements ; analyse rapide quotidienne en arrière-plan. Rien ne tourne une fois l'app quittée. Vie privée : données des navigateurs (Safari ; Chrome, y compris Beta, Dev et Canary, Opera et dérivés de Chromium ; Firefox d'après `profiles.ini` : historique, cookies, téléchargements, saisie automatique, mots de passe, sessions), effacées seulement navigateur fermé, avec une copie de la base mise à la Corbeille avant ; autorisations accordées aux apps (caméra, micro, dossiers… retirées par `tccutil reset`, avec une tuile dédiée Caméra et micro), listes d'éléments récents du menu Pomme (mises à la Corbeille), réseaux Wi-Fi connus (renvoi vers les Réglages). Côté vie privée, rien n'est coché par défaut, et l'effacement se fait par catégorie entière (pas élément par élément). |
| **Performance** | Tâches de maintenance (libérer la RAM, vider le cache DNS, réindexer Spotlight, réparer les permissions du dossier personnel, alléger les snapshots Time Machine, accélérer Mail), éléments de connexion, agents de lancement (dont les éléments cassés). Les tâches sont recommandées selon leur dernière exécution (7 ou 30 jours). Accélérer Mail met d'abord une copie de l'Envelope Index à la Corbeille. Les agents affichent leur état launchd et peuvent être désactivés ou réactivés ; les éléments de connexion aussi (liste « Ouvrir à la connexion »). |
| **Applications** | Désinstallation complète (bundle et fichiers associés, y compris plug-ins, installeurs, liens CLI et éléments de connexion ; l'icône du Dock est signalée, à retirer à la main ; un reçu pkg n'est trouvé que si son identifiant dérive de celui de l'app). Les démons de l'app sont arrêtés avant que l'app parte à la Corbeille ; si ce n'est pas possible, l'app reste en place. Les apps Apple de l'App Store (Pages, Keynote, Xcode…) sont désinstallables. Réinitialisation d'une app (clic droit), restes d'apps déjà supprimées, apps inutilisées. Repère aussi les apps 32 bits ou Intel uniquement, les apps sans signature valide, les installeurs DMG et PKG oubliés (Spotlight), les plug-ins (audio, Quick Look, économiseurs, panneaux, extensions système), les jeux Steam, les restes des apps mises à la Corbeille et les mises à jour macOS en attente. Mises à jour d'apps : l'App Store et les flux Sparkle des éditeurs sont interrogés pendant l'analyse (désactivable dans Réglages > Analyse) ; rien n'est installé, un bouton ouvre l'App Store ou l'app. « Toutes les applications » se filtre par source (App Store, Internet…) et par éditeur, et ne se coche qu'app par app. Bureau, Documents et Téléchargements ne sont lus qu'avec l'accès complet au disque. |
| **Fouillis** | Quatre cartes, sans rien de coché d'avance : doublons, images similaires, gros et vieux fichiers, téléchargements. Dans « Voir », des filtres affinent la liste (récents, Bureau ou Documents, type, taille, dernière ouverture, app ou site d'origine) ; une série de doublons ou d'images se coche d'un clic en gardant le meilleur exemplaire, et « Comparer » ouvre ses images dans Coup d'œil. Compare aussi les apps et paquets comme un tout, propose la meilleure image de chaque groupe de similaires (netteté, bruit, contraste), regroupe les téléchargements par app et par site, et peut analyser les disques externes (option de Réglages > Analyse). La copie gardée est celle du Mac plutôt que celle d'un disque externe, et un lien physique n'est jamais coché. |
| **Radar** | Carte interactive de l'occupation du disque, en bulles, avec indicateur du volume (utilisé, sélectionné, purgeable, libre). Bouton « Stockage cloud » : carte d'iCloud Drive et de `~/Library/CloudStorage`, sans jamais télécharger les fichiers restés dans le cloud (ils comptent pour 0 octet). |
| **Nettoyage cloud** | Libère l'espace local des fichiers iCloud Drive, Dropbox, Google Drive et OneDrive sans les supprimer du cloud. Fichiers de plus de 50 Mo, rien n'est coché. Filtres : rarement utilisés (plus de 30 jours), dernière ouverture, taille, type. |
| **Barre des menus** | Icône avec badge de sévérité. Widgets Stockage (catégories avec l'accès complet au disque, purgeable, état SMART), Mémoire (pression), Processeur (état thermique de macOS), Batterie, Réseau (type, sécurité Wi-Fi, test de débit `networkQuality` au clic), Protection, accessoires (batterie lue dans l'IORegistry), disques externes (éjecter). Un clic ouvre le détail. Processus gourmands avec « Quitter », score de santé et recommandation du jour. La taille de la corbeille exige l'accès complet au disque. |
| **Le Guide** | Score de santé, recommandations triées avec action, « Ignorer » et « En savoir plus ». Option enfoncée à l'ouverture affiche un panneau de simulation des facteurs (affichage seul). |
| **Raccourcis et Siri** | Désinstaller une application, Lancer Vibe Check, Santé du Mac, État du stockage, Vider la corbeille, Libérer la RAM. Les actions qui modifient le Mac demandent toujours une confirmation et respectent le mode simulation. La désinstallation annonce qu'elle quittera l'app si elle est ouverte. Les noms des apps sont transmis à Siri au lancement de Vibe Cleaner. |

## Sécurité

Vibe Cleaner efface des fichiers, d'où plusieurs garde-fous :

- **Corbeille par défaut.** Les éléments appartenant à root ne vont pas dans votre Corbeille. Ils sont mis de côté dans `/Library/Application Support/VibeCleaner/Corbeille` (dossier root), vidable depuis Nettoyage › Corbeilles.
- **Suppressions définitives.** Les caches régénérables et le vidage des corbeilles sont définitifs. Le sont aussi, jamais cochés par défaut : les archives et ASL de `/private/var/log`, les médias téléchargés de Telegram, Tencent et QQ, et `brew cleanup`. La revue marque ces éléments « Définitif ».
- **Quarantaine.** Les menaces partent en quarantaine (`~/Library/Application Support/VibeCleaner/Quarantine`, ou `/Library/Application Support/VibeCleaner/Quarantine` pour les éléments système). Réglages > Quarantaine permet de les restaurer à leur emplacement d'origine ou de les supprimer. La restauration est refusée vers les dossiers de données d'autres apps (Mail, Safari, Containers, Trousseaux…).
- **Chemins protégés.** Toute suppression passe par `SafeRemover`, qui refuse les racines système (`/System`, `/usr`, `/bin`, `/Library/Apple`…) et les dossiers de premier niveau (`~`, `~/Library`, `~/Documents`, `/Applications`…). Le contenu de ces dossiers peut être supprimé, jamais les dossiers eux-mêmes.
- **Liste d'exclusion.** Rien sous un chemin exclu n'est touché, ni par l'app ni par la CLI. Elle se gère dans les Réglages ou via le clic droit sur un élément, avec « Ajouter à la liste d'exclusion ».
- **Mode simulation.** Option dans les Réglages : affiche ce qui serait fait sans rien modifier, y compris depuis la barre des menus, les notifications, les Raccourcis et la quarantaine. La CLI fonctionne en simulation par défaut.
- **Confirmation** avant chaque nettoyage (désactivable) et avant les actions rapides de la barre des menus. La revue liste les éléments et les opérations qui demanderont le mot de passe ; elle s'affiche toujours si toutes les copies d'un doublon sont cochées.
- **Un mot de passe par lot.** Il n'y a pas de helper privilégié résident. Les opérations root d'un module (caches système, `/Library/LaunchDaemons`, tâches de maintenance) sont regroupées derrière une seule demande d'autorisation macOS. Dans Vibe Check, Nettoyage, Performance et Fouillis partagent une demande ; Applications et Protection gardent chacun la leur. Voir « Prochaines étapes » pour la fenêtre de mot de passe.
- **Scan sans écriture.** L'analyse ne modifie jamais le disque. Seules exceptions, dans le dossier temporaire : les copies en lecture seule des bases lues, et les archives si l'option est activée (voir « Limites »).

## Utiliser l'app

- **Barre latérale** : Vibe Check, puis les modules (Nettoyage, Protection, Performance, Applications, Fouillis) et les outils (Radar, Nettoyage cloud), avec le Guide en pied. Raccourcis ⌘1 à ⌘8, ⌘0 pour le Guide. Liens profonds `vibecleaner://module/<id>` et `vibecleaner://settings`.
- **Cycle d'un module** : accueil, puis **Analyser** (bouton rond en bas) ; l'analyse ne touche à rien. Viennent ensuite les résultats en tuiles, une par catégorie (une par module dans Vibe Check), chacune avec sa case et un bouton « Revoir » qui ouvre la liste : catégories à gauche, détail à droite. Les cases à trois états permettent de choisir catégorie par catégorie ou élément par élément ; on peut trier par taille, nom ou date, rechercher, et utiliser le menu « Sélection » (intelligente, tout, rien). Chaque tuile a aussi son propre bouton d'action. Dans la liste : tri par taille, nom, date ou nombre d'éléments ; sélection rapide (plus gros, plus petits, plus récents, plus anciens : le quart des éléments) ; filtre « Afficher ». Le bouton d'action (« Nettoyer », « Supprimer », « Lancer »…, ⌘↩) ouvre une revue, puis l'exécution démarre ; « Arrêter » l'interrompt entre deux éléments. Une seule analyse et une seule exécution à la fois, quel que soit le point de départ (bouton, ⌘R, Analyser un dossier, Raccourcis) ; le Radar est à part. Si des apps ouvertes bloquent certains éléments (app à désinstaller, navigateur, Mail), une fenêtre propose de les quitter, de forcer la fermeture ou de sauter ces éléments. Un récapitulatif final indique l'espace libéré, les erreurs éventuelles et le journal détaillé, que « Copier » met dans le presse-papiers ; chaque exécution est aussi enregistrée en JSON dans `~/Library/Application Support/VibeCleaner/Logs`.
- **Clic droit sur un élément** : Coup d'œil, Afficher dans le Finder, Ouvrir, Infos, Copier le chemin, Ajouter à la liste d'exclusion. L'exclusion s'annule avec « Remettre » dans le bandeau qui suit.
- **Radar** : choisissez un volume, le dossier personnel ou un dossier. Cliquez une bulle pour y entrer ; remontez par le fil d'Ariane, un double-clic sur le fond ou Précédent / Suivant (⌘[ ⌘]). La liste suit les bulles, petits éléments regroupés et dépliables ; l'infobulle donne la taille, la date de modification et la sélection. Le clic droit propose Coup d'œil et « Mettre à la Corbeille ». Pour un élément d'iCloud Drive ou de `~/Library/CloudStorage`, Vibe Cleaner prévient que la suppression vaut aussi pour le cloud. Après une suppression, les tailles des dossiers parents se mettent à jour sans nouvelle analyse, et un journal est enregistré.
- **Barre des menus** : l'icône ✦ affiche l'état du Mac en direct, avec des actions rapides : libérer la RAM (mot de passe administrateur), vider la corbeille, ouvrir Vibe Cleaner. Le vidage ne touche que la corbeille du dossier personnel et exige l'accès complet au disque ; les corbeilles des disques externes restent en place. Chaque action affiche son résultat. Le menu ⋯ donne Réglages, À propos et Quitter.
- **Réglages** : onglet Menu (barre des menus, ouverture à la connexion, recommandations, disques externes) ; ouverte à la connexion, l'app démarre sans fenêtre, avec la barre des menus et les alertes seulement. Onglet Protection (surveillance, analyse quotidienne, décompression des PKG et ZIP, désactivée par défaut, pièces jointes, disques externes). Onglet Notifications, dont « disque externe presque plein ». Exclusions par chemin, par app (bundle id) et par développeur (Team ID). Journaux détaillés dans `~/Library/Logs/VibeCleaner/` : début et fin des analyses et des exécutions, et chaque échec.
- **Mot de passe** : demandé seulement si la sélection contient des éléments système, une fois par module (une seule fois pour Nettoyage, Performance et Fouillis réunis dans Vibe Check). « Libérer la RAM » et « Vider le cache DNS » en ont besoin : Performance les coche quand ils n'ont pas tourné depuis 7 jours, Vibe Check ne les reprend pas. Décochez-les pour une exécution sans mot de passe.

## Prérequis

- macOS 15 ou plus récent (développé sur macOS 27, Apple Silicon)
- Xcode 16 ou plus récent (Swift 6), ou les Command Line Tools
- Optionnel : `brew install yara` pour activer le scan XProtect du module Protection

## Compiler et lancer

```bash
make test      # tests unitaires (dossiers temporaires uniquement)
make app       # construit dist/Vibe Cleaner.app
make run       # construit puis ouvre l'app
make install   # copie l'app dans /Applications
make clean
```

Le projet est un simple paquet SwiftPM, sans projet Xcode. `scripts/bundle.sh` assemble le `.app` (binaire, `Info.plist`), génère les métadonnées App Intents (`Contents/Resources/Metadata.appintents`, avec `appintentsmetadataprocessor` de Xcode) et signe localement. Sans cet outil, l'app est construite quand même, mais Raccourcis ne voit pas ses actions ; `swift run` ne les expose pas non plus.

### Accès complet au disque

Plusieurs catégories (pièces jointes Mail, certaines données d'apps, TCC, taille et vidage de la corbeille, Bureau, Documents et Téléchargements dans Applications) exigent l'accès complet au disque : Réglages Système > Confidentialité et sécurité > Accès complet au disque > ajouter `Vibe Cleaner`. Le raccourci est dans Réglages de l'app > Autorisations.

macOS rattache cette autorisation à la signature de l'app. Avec la signature ad hoc par défaut, elle est perdue à chaque recompilation. Pour qu'elle tienne, créez une fois un certificat de signature de code local (Trousseau d'accès > Assistant de certification > Créer un certificat, type « Signature de code », nom « Vibe Cleaner Local »), puis :

```bash
SIGN_IDENTITY="Vibe Cleaner Local" make app
```

## CLI

`vibeclean` lance les mêmes moteurs sans interface, avec la liste d'exclusion et les réglages Protection de l'app. Sans accès complet au disque, les dossiers protégés ne sont pas lus. Il est construit par `make build` dans `.build/debug/`, et copié dans l'app par `make app`. Identifiants des modules : `junk`, `protection`, `performance`, `applications`, `clutter`, `cloud`. Vibe Check, Radar, le Guide et les raccourcis n'existent que dans l'app.

```bash
make build

.build/debug/vibeclean list                     # modules disponibles
.build/debug/vibeclean scan junk --all          # analyse et liste détaillée (lecture seule)
.build/debug/vibeclean clean junk               # simulation de la sélection recommandée
.build/debug/vibeclean clean junk --apply       # exécution réelle
.build/debug/vibeclean quarantine list          # menaces en quarantaine (restore <id> | purge <id>)
```

## Architecture

```
Sources/
  VibeCleanerCore/          logique, testable, sans UI
    Foundation/             FileSizer, Shell, SafeRemover, SQLite, Log
    Model/                  ResultGroup/ResultItem, ItemAction, ActionExecutor (dont lot admin), protocole ScanModule
    Modules/<Nom>/          un dossier par module (Cleanup, Protection, Performance, Applications,
                            Clutter, Cloud, Radar, Monitor) + Catalog.swift (ordre de la sidebar)
  VibeCleaner/              app SwiftUI : sidebar, écrans génériques de module, Radar, barre des menus
  vibeclean/                CLI
Tests/VibeCleanerCoreTests/
```

Chaque module implémente `ScanModule` :

```swift
public protocol ScanModule: Sendable {
    var id: String { get }; var title: String { get }; var subtitle: String { get }
    var symbol: String { get }; var actionTitle: String { get }
    func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup]
    func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport
}
```

Le scan renvoie un arbre de groupes et d'éléments. Chaque élément porte son action (`delete`, `command`, `custom`) et un drapeau de sélection par défaut. L'interface est la même pour tous les modules : accueil, scan, résultats (catégories, détail, sélection à trois états, tri, recherche), confirmation, exécution, récapitulatif avec journal. Vibe Check enchaîne plusieurs modules dans ce même cycle.

## Développement avec un agent IA

[`CLAUDE.md`](CLAUDE.md) fixe la règle : un agent écrit, compile et teste le code, mais n'applique **jamais** le nettoyage sur la machine. Il ne supprime rien, ne lance pas `vibeclean clean`, n'utilise ni mot de passe admin ni commande système qui modifie quelque chose. Seul l'utilisateur, en utilisant l'app, agit sur son Mac.

## Choix de conception

| Choix | Pourquoi |
|---|---|
| Corbeille par défaut ; éléments root mis de côté dans une zone root | Réversibilité |
| Pas de helper root installé : un mot de passe administrateur par lot | Rien ne tourne en root en permanence (voir « Prochaines étapes ») |
| Heuristiques de signature et de persistance, plus les règles XProtect d'Apple | Pas de base anti-malware propriétaire : sources ouvertes ou fournies par le système |
| Menaces mises en quarantaine restaurable, jamais supprimées d'emblée | Réversibilité |
| « Libérer la RAM » par `purge`, avec mot de passe administrateur | Simple et documenté |
| Nettoyage cloud limité aux copies locales synchronisées : « Libérer » ne supprime jamais un fichier du cloud | Aucun identifiant ni base privée de client cloud n'est lu |
| Images disque jamais montées (lues comme fichiers bruts), éléments d'arrière-plan (BTM) non lus | Pas d'effet de bord pendant l'analyse ; la base BTM exige root |
| Pas de température ni de libération de l'espace purgeable | Pas d'API publique |
| Pas de compte, de licence, d'achat, d'analytics ni d'assistant en ligne | Usage personnel |
| Listes d'apps, doublons et gros fichiers cochés un par un, jamais en bloc | Une désinstallation ou une suppression de masse est trop grave pour un seul clic |

## Prochaines étapes

### Helper privilégié signé

**Aujourd'hui.** Les opérations qui exigent root sont regroupées et lancées en une fois par AppleScript, avec `do shell script … with administrator privileges` (`ActionExecutor.adminAppleScript`). C'est le cas de la mise à la Corbeille d'une app installée par un `.pkg` (son bundle appartient à root, comme DaVinci Resolve), de `pkgutil --forget`, de l'arrêt des démons et des caches système. Le Finder demanderait lui aussi le mot de passe pour ces éléments.

**Le problème.** macOS 27 affiche pour ce mécanisme une fenêtre générique : « Allow administrator access for a script started by "Vibe Cleaner"? … Apple could not verify this script is free of malware ». Le message explicatif fourni par l'app n'est plus montré. La demande est légitime, mais la fenêtre inquiète.

**La cible.** Un petit helper privilégié signé, comme la plupart des utilitaires système :
- un exécutable embarqué dans le bundle (`Contents/Library/LaunchDaemons`), enregistré une fois avec `SMAppService.daemon(plistName:)` ;
- l'utilisateur l'autorise une seule fois dans Réglages Système > Général > Ouverture et extensions ; macOS l'y présente sous le nom et l'icône de Vibe Cleaner ;
- l'app lui parle par XPC (`NSXPCConnection` avec un service Mach), avec une liste fermée d'opérations : mise à la Corbeille root, arrêt d'un démon, `pkgutil --forget`. Jamais de shell arbitraire ;
- le helper vérifie la signature de l'appelant (même Team ID, via `setCodeSigningRequirement`) avant d'accepter une requête ;
- il repasse chaque chemin par `SafeRemover` (chemins protégés, exclusions, simulation), comme aujourd'hui.
- il enchaîne une désinstallation dans l'ordre sûr : arrêter le démon, vérifier qu'il est arrêté, puis seulement mettre l'app à la corbeille. Aujourd'hui, les commandes du lot sont indépendantes : si l'arrêt échoue, l'app part quand même et le démon tourne jusqu'au redémarrage suivant. Le corriger dans le lot AppleScript demanderait un second mot de passe.

**Ce qu'il faut.**
- Un certificat **Developer ID Application** (programme Apple Developer, payant). La signature ad hoc actuelle ne suffit pas : `SMAppService` refuse un démon que macOS ne peut pas rattacher à un développeur identifié.
- La **notarisation** de l'app et du helper (`notarytool`), sans quoi Gatekeeper bloque le démon.
- Un chemin de repli : sans helper autorisé, garder le lot AppleScript actuel.

Marche à suivre pour le certificat et la notarisation : [docs/CERTIFICAT-APPLE.md](docs/CERTIFICAT-APPLE.md).

**Ce que ça change pour l'utilisateur.** Plus de fenêtre « script non vérifié » à chaque désinstallation : une autorisation unique et identifiée, puis plus aucune demande pour les opérations prévues. Le helper ne tourne que lorsque l'app l'appelle et se désinstalle avec elle.

Rien ne sera installé sur un Mac sans accord explicite : le helper ne s'enregistre qu'à la première opération root, après une explication dans l'app.

## État et limites connues

Pas encore implémenté :
- un **démon en arrière-plan** : surveillance des menaces, analyse quotidienne et alertes (disque, disque externe presque plein, corbeille, mémoire, apps à la corbeille, accessoires) ne tournent que lorsque l'app est ouverte. Seul le rappel Vibe Check est programmé comme notification locale et arrive aussi app fermée ;
- les **images similaires de la bibliothèque Photos** ;
- le **nettoyage des disques externes** (à l'éjection, disques de plus de 128 Go) ;
- la **batterie des AirPods** (le repli `system_profiler` n'est pas codé).

En attente d'une décision :
- les **apps figées** : leur détection passerait par l'autorisation Accessibilité, que l'app ne demande pas aujourd'hui.

Les notifications ne sont demandées qu'à l'onboarding ; refusées, rien n'est affiché.

Limites :
- Les règles d'exclusion sont écrites à la main : elles peuvent être incomplètes, ou plus prudentes que nécessaire.
- Fouillis ignore tout dossier contenant un `.git` : un « doublon » dans un projet en fait souvent partie.
- Les éléments de connexion ajoutés par des apps via SMAppService n'ont pas d'API publique. Seuls ceux de la liste « Ouvrir à la connexion » sont listés.
- Plusieurs formats système sont lus d'après leur structure supposée, sans vérification sur une vraie base : comptes Mail (`Accounts4.sqlite`), bases TCC, téléchargements App Store.
- Les archives ZIP et les installeurs PKG ne sont décompressés (dans le dossier temporaire, avec limites de taille, de nombre de fichiers et de durée) que si l'option est activée. Les bases SQLite lues (TCC, historiques et cookies des navigateurs, mots de passe Chrome chiffrés, comptes Mail) sont copiées en lecture seule dans le dossier temporaire puis supprimées.
- Le scan lance aussi des outils en lecture seule : `mdfind`, `systemextensionsctl list`, `launchctl print`, `tmutil listlocalsnapshots`, `pgrep`, `crontab -l`, `profiles list`.
- La protection n'est pas un antivirus. Elle repère des signaux faibles (signature, persistance, emplacement) et ce que reconnaissent les règles XProtect.
