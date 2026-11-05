# Vibe Cleaner

A cleaning and maintenance utility for macOS, in native SwiftUI: cleanup, protection, performance, app uninstaller, clutter, disk map and a menu bar monitor. Local use only: no account, no license key, no analytics. The only network access is the app update check, which can be turned off (see Applications).

> **Warning: a vibe coded app, use it at your own risk.**
> Vibe Cleaner was vibe coded end to end with AI agents. It has had no independent security audit and no external review, yet it deletes files, uninstalls apps and runs commands with the administrator password. Keep an up-to-date backup (Time Machine), start in simulation mode and read every selection before cleaning. The software is provided as is, without any warranty (see [LICENSE](LICENSE)).

> **Language: the app is in French for now.**
> The whole interface (menus, results, alerts) is in French. If you would like an English version, open an [issue](https://github.com/GuigsEvt/vibe-cleaner/issues) or send a pull request, and I will take the time to add it. In this README, French labels from the app are quoted in parentheses, e.g. Cleanup (« Nettoyage »).

## Quick start

```bash
git clone https://github.com/GuigsEvt/vibe-cleaner.git && cd vibe-cleaner
make test     # 500+ tests, on temporary folders only
make run      # builds dist/Vibe Cleaner.app and opens it
```

On first launch:

1. Open Settings (⌘,) > General (« Général ») and tick **Simulation mode** (« Mode simulation »). While it is on, nothing is changed: not by the modules, the menu bar, notifications or Shortcuts.
2. Settings > Permissions (« Autorisations ») > **Open privacy settings**, then add Vibe Cleaner to Full Disk Access (see below).
3. Pick a module in the sidebar and click **Scan** (« Analyser »).
4. Browse the results, adjust the selection, then click the action button.
5. Once you are confident, untick simulation mode to clean for real.

## Features

| Module | What it does |
|---|---|
| **Vibe Check** | Scans Cleanup, Protection, Performance, Applications and Clutter in parallel (modules configurable in Settings > Scan), shows one card per module with a recommended selection, then runs the ticked cards one after the other. From Performance it only takes maintenance scripts and login items, with nothing ticked. From Clutter it takes duplicates in Downloads and large files. It remembers what you untick from one scan to the next. |
| **Cleanup** (« Nettoyage ») | User and system caches, logs, temporary files, broken preferences, document versions, Xcode and developer tool junk, old iOS backups, Mail attachments, trashes. Also: Dropbox caches, broken startup items (including /Library, as admin; user agents go to the Trash without being unloaded) and broken login items, downloaded simulator runtimes (removed with `simctl runtime delete`), apps' iCloud trashes, local copies of deleted messages from IMAP and iCloud accounts (never ticked). Attachments are only ticked for IMAP and iCloud accounts, when Full Disk Access allows reading `Accounts4.sqlite`. Homebrew is never ticked: `brew cleanup` also removes older installed versions. Mail, Xcode and Simulator must be quit before their files are cleaned. |
| **Protection** | Launch agents and daemons that start an unsigned, badly signed or suspiciously located program; apps with a badly signed executable; files matched by Apple's XProtect YARA rules if `yara` is installed. Also detects suspicious cron jobs, unsigned processes launched from hidden or temporary folders, Chrome extensions installed outside the Web Store, Safari extensions from badly signed apps, a hijacked Safari home page and configuration profiles. Threats are classified by type (Adware, Trojan, Stealer…) and go to a restorable quarantine, system items included (administrator password asked on restore). The program launched by a suspicious agent goes there too. Hash list: add your own SHA-256 fingerprints to `~/Library/Application Support/VibeCleaner/hashes.txt` (one per line, optionally followed by a name); Vibe Cleaner ships none. Custom scan: "Scan a folder…" button on the Protection screen, or drag and drop. Monitoring while the app is open: new launch agents and, with Full Disk Access, new downloads; quick daily scan in the background. Nothing runs once the app is quit. Privacy: browser data (Safari; Chrome, including Beta, Dev and Canary, Opera and Chromium derivatives; Firefox from `profiles.ini`: history, cookies, downloads, autofill, passwords, sessions), erased only with the browser closed, with a copy of the database moved to the Trash first; permissions granted to apps (camera, microphone, folders…, removed with `tccutil reset`, with a dedicated Camera and microphone tile), recent items lists of the Apple menu (moved to the Trash), known Wi-Fi networks (link to System Settings). On the privacy side nothing is ticked by default, and erasing is done by whole category (not item by item). |
| **Performance** | Maintenance tasks (free up RAM, flush the DNS cache, reindex Spotlight, repair home folder permissions, thin Time Machine snapshots, speed up Mail), login items, launch agents (including broken ones). Tasks are recommended based on their last run (7 or 30 days). Speed up Mail first moves a copy of the Envelope Index to the Trash. Agents show their launchd state and can be disabled or re-enabled; so can login items ("Open at Login" list). |
| **Applications** | Complete uninstall (bundle and related files, including plug-ins, installers, CLI links and login items; the Dock icon is reported, to be removed by hand; a pkg receipt is found only if its identifier derives from the app's). The app's daemons are stopped before the app goes to the Trash; if that is not possible, the app stays in place. Apple's App Store apps (Pages, Keynote, Xcode…) can be uninstalled. App reset (right click), leftovers of already deleted apps, unused apps. Also finds 32-bit or Intel-only apps, apps without a valid signature, forgotten DMG and PKG installers (Spotlight), plug-ins (audio, Quick Look, screen savers, preference panes, system extensions), Steam games, leftovers of apps moved to the Trash and pending macOS updates. App updates: the App Store and the vendors' Sparkle feeds are queried during the scan (can be turned off in Settings > Scan); nothing is installed, a button opens the App Store or the app. "All applications" can be filtered by source (App Store, Internet…) and by vendor, and is only ticked app by app. Desktop, Documents and Downloads are only read with Full Disk Access. |
| **Clutter** (« Fouillis ») | Four cards, nothing ticked in advance: duplicates, similar images, large and old files, downloads. In "Review", filters narrow the list (recent, Desktop or Documents, type, size, last opened, source app or site); a set of duplicates or images is ticked in one click while keeping the best copy, and "Compare" opens its images in Quick Look. Also compares apps and packages as a whole, suggests the best image of each group of similar ones (sharpness, noise, contrast), groups downloads by app and by site, and can scan external disks (option in Settings > Scan). The copy kept is the one on the Mac rather than on an external disk, and a hard link is never ticked. |
| **Radar** | Interactive bubble map of disk usage, with a volume gauge (used, selected, purgeable, free). "Cloud storage" button: map of iCloud Drive and `~/Library/CloudStorage`, without ever downloading files still in the cloud (they count as 0 bytes). |
| **Cloud cleanup** (« Nettoyage cloud ») | Frees the local space of iCloud Drive, Dropbox, Google Drive and OneDrive files without deleting them from the cloud. Files over 50 MB, nothing ticked. Filters: rarely used (over 30 days), last opened, size, type. |
| **Menu bar** | Icon with a severity badge. Widgets for Storage (categories with Full Disk Access, purgeable, SMART status), Memory (pressure), CPU (macOS thermal state), Battery, Network (type, Wi-Fi security, `networkQuality` speed test on click), Protection, accessories (battery read from the IORegistry), external disks (eject). A click opens the details. Hungry processes with "Quit", health score and recommendation of the day. The Trash size requires Full Disk Access. |
| **The Guide** (« Le Guide ») | Health score, sorted recommendations with an action, "Ignore" and "Learn more". Holding Option while opening it shows a panel that simulates the factors (display only). |
| **Shortcuts and Siri** | Uninstall an application, Run Vibe Check, Mac health, Storage status, Empty the Trash, Free up RAM. Actions that change the Mac always ask for confirmation and respect simulation mode. Uninstalling says it will quit the app if it is open. App names are passed to Siri when Vibe Cleaner launches. |

## Safety

Vibe Cleaner deletes files, hence several guard rails:

- **Trash by default.** Items owned by root do not go to your Trash. They are set aside in `/Library/Application Support/VibeCleaner/Corbeille` (a root folder), which can be emptied from Cleanup › Trashes.
- **Permanent deletions.** Regenerable caches and emptying the trashes are permanent. So are, never ticked by default: the archives and ASL of `/private/var/log`, downloaded media of Telegram, Tencent and QQ, and `brew cleanup`. The review marks these items "Permanent" (« Définitif »).
- **Quarantine.** Threats go to quarantine (`~/Library/Application Support/VibeCleaner/Quarantine`, or `/Library/Application Support/VibeCleaner/Quarantine` for system items). Settings > Quarantine lets you restore them to their original location or delete them. Restoring into other apps' data folders (Mail, Safari, Containers, Keychains…) is refused.
- **Protected paths.** Every deletion goes through `SafeRemover`, which refuses system roots (`/System`, `/usr`, `/bin`, `/Library/Apple`…) and top-level folders (`~`, `~/Library`, `~/Documents`, `/Applications`…). The content of these folders may be deleted, never the folders themselves. Keychains, Messages, Mail's database, Photos libraries, SSH, GPG and cloud credentials, the privacy database (TCC), Calendar, Contacts, Notes and Reminders data, and Time Machine backups and volume metadata on any disk are never touched.
- **Exclusion list.** Nothing under an excluded path is touched, neither by the app nor by the CLI. It is managed in Settings or by right-clicking an item, with "Add to exclusion list".
- **Simulation mode.** An option in Settings: shows what would be done without changing anything, including from the menu bar, notifications, Shortcuts and the quarantine. The CLI runs in simulation by default.
- **Confirmation** before each cleanup (can be turned off) and before the menu bar's quick actions. The review lists the items and the operations that will ask for the password; it is always shown if every copy of a duplicate is ticked.
- **One password per batch.** There is no resident privileged helper. A module's root operations (system caches, `/Library/LaunchDaemons`, maintenance tasks) are grouped behind a single macOS authorization prompt. In Vibe Check, Cleanup, Performance and Clutter share one prompt; Applications and Protection each keep their own. See "Next steps" for the password window.
- **Scans never write.** A scan never modifies the disk. The only exceptions, in the temporary folder: read-only copies of the databases being read, and archives if the option is on (see "Limits").

## Using the app

- **Sidebar**: Vibe Check, then the modules (Cleanup, Protection, Performance, Applications, Clutter) and the tools (Radar, Cloud cleanup), with the Guide at the bottom. Shortcuts ⌘1 to ⌘8, ⌘0 for the Guide. Deep links `vibecleaner://module/<id>` and `vibecleaner://settings`.
- **A module's cycle**: home screen, then **Scan** (round button at the bottom); the scan touches nothing. Then come the results as tiles, one per category (one per module in Vibe Check), each with its checkbox and a "Review" (« Revoir ») button that opens the list: categories on the left, details on the right. Three-state checkboxes let you choose category by category or item by item; you can sort by size, name or date, search, and use the "Selection" menu (smart, all, none). Each tile also has its own action button. In the list: sort by size, name, date or item count; quick selection (largest, smallest, newest, oldest: a quarter of the items); "Show" filter. The action button ("Clean", "Delete", "Run"…, ⌘↩) opens a review, then execution starts; "Stop" interrupts it between two items. Only one scan and one execution at a time, whatever the starting point (button, ⌘R, Scan a folder, Shortcuts); Radar is separate. If open apps block some items (an app to uninstall, a browser, Mail), a window offers to quit them, force quit them or skip those items. A final summary shows the space freed, any errors and the detailed log, which "Copy" puts on the clipboard; each execution is also saved as JSON in `~/Library/Application Support/VibeCleaner/Logs`.
- **Right click on an item**: Quick Look, Show in Finder, Open, Get Info, Copy path, Add to exclusion list. The exclusion is undone with "Put back" in the banner that follows.
- **Radar**: choose a volume, the home folder or a folder. Click a bubble to enter it; go back up through the breadcrumb, a double click on the background or Back / Forward (⌘[ ⌘]). The list follows the bubbles, with small items grouped and expandable; the tooltip gives the size, modification date and selection. Right click offers Quick Look and "Move to Trash". For an item in iCloud Drive or `~/Library/CloudStorage`, Vibe Cleaner warns that deleting it also deletes it from the cloud. After a deletion, parent folder sizes update without a new scan, and a log is saved.
- **Menu bar**: the ✦ icon shows the Mac's state live, with quick actions: free up RAM (administrator password), empty the Trash, open Vibe Cleaner. Emptying only touches the home folder's Trash and requires Full Disk Access; trashes on external disks stay in place. Each action shows its result. The ⋯ menu gives Settings, About and Quit.
- **Settings**: Menu tab (menu bar, open at login, recommendations, external disks); when opened at login, the app starts without a window, with only the menu bar and alerts. Protection tab (monitoring, daily scan, unpacking PKG and ZIP, off by default, attachments, external disks). Notifications tab, including "external disk almost full". Exclusions by path, by app (bundle id) and by developer (Team ID). Detailed logs in `~/Library/Logs/VibeCleaner/`: start and end of scans and executions, and every failure.
- **Password**: asked only if the selection contains system items, once per module (once for Cleanup, Performance and Clutter together in Vibe Check). "Free up RAM" and "Flush DNS cache" need it: Performance ticks them when they have not run for 7 days, Vibe Check does not take them. Untick them for a run without a password.

## Requirements

- macOS 15 or later (developed on macOS 27, Apple Silicon)
- Xcode 16 or later (Swift 6), or the Command Line Tools
- Optional: `brew install yara` to enable the XProtect scan of the Protection module

## Build and run

```bash
make test      # unit tests (temporary folders only)
make app       # builds dist/Vibe Cleaner.app
make run       # builds then opens the app
make install   # copies the app to /Applications
make clean
```

The project is a plain SwiftPM package, with no Xcode project. `scripts/bundle.sh` assembles the `.app` (binary, `Info.plist`), generates the App Intents metadata (`Contents/Resources/Metadata.appintents`, with Xcode's `appintentsmetadataprocessor`) and signs locally. Without that tool the app is still built, but Shortcuts does not see its actions; `swift run` does not expose them either.

### Full Disk Access

Several categories (Mail attachments, some app data, TCC, Trash size and emptying, Desktop, Documents and Downloads in Applications) require Full Disk Access: System Settings > Privacy & Security > Full Disk Access > add `Vibe Cleaner`. The shortcut is in the app's Settings > Permissions.

macOS ties this permission to the app's signature. With the default ad hoc signature, it is lost on every rebuild. To keep it, create a local code signing certificate once (Keychain Access > Certificate Assistant > Create a Certificate, type "Code Signing", name "Vibe Cleaner Local"), then:

```bash
SIGN_IDENTITY="Vibe Cleaner Local" make app
```

## CLI

`vibeclean` runs the same engines without an interface, with the app's exclusion list and Protection settings. Without Full Disk Access, protected folders are not read. It is built by `make build` in `.build/debug/`, and copied into the app by `make app`. Module ids: `junk`, `protection`, `performance`, `applications`, `clutter`, `cloud`. Vibe Check, Radar, the Guide and Shortcuts only exist in the app.

```bash
make build

.build/debug/vibeclean list                     # available modules
.build/debug/vibeclean scan junk --all          # scan and detailed list (read only)
.build/debug/vibeclean clean junk               # simulation of the recommended selection
.build/debug/vibeclean clean junk --apply       # real execution
.build/debug/vibeclean quarantine list          # quarantined threats (restore <id> | purge <id>)
```

## Architecture

```
Sources/
  VibeCleanerCore/          logic, testable, no UI
    Foundation/             FileSizer, Shell, SafeRemover, SQLite, Log
    Model/                  ResultGroup/ResultItem, ItemAction, ActionExecutor (including the admin batch), ScanModule protocol
    Modules/<Name>/         one folder per module (Cleanup, Protection, Performance, Applications,
                            Clutter, Cloud, Radar, Monitor) + Catalog.swift (sidebar order)
  VibeCleaner/              SwiftUI app: sidebar, generic module screens, Radar, menu bar
  vibeclean/                CLI
Tests/VibeCleanerCoreTests/
```

Each module implements `ScanModule`:

```swift
public protocol ScanModule: Sendable {
    var id: String { get }; var title: String { get }; var subtitle: String { get }
    var symbol: String { get }; var actionTitle: String { get }
    func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup]
    func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport
}
```

A scan returns a tree of groups and items. Each item carries its action (`delete`, `command`, `custom`) and a default selection flag. The interface is the same for every module: home, scan, results (categories, details, three-state selection, sorting, search), confirmation, execution, summary with log. Vibe Check chains several modules through this same cycle.

## Developing with an AI agent

[`CLAUDE.md`](CLAUDE.md) sets the rule: an agent writes, builds and tests the code, but **never** applies a cleanup on the machine. It deletes nothing, does not run `vibeclean clean`, and uses neither the admin password nor any system command that changes something. Only the user, using the app, acts on their Mac.

## Design choices

| Choice | Why |
|---|---|
| Trash by default; root items set aside in a root area | Reversibility |
| No installed root helper: one administrator password per batch | Nothing runs as root permanently (see "Next steps") |
| Signature and persistence heuristics, plus Apple's XProtect rules | No proprietary malware database: open sources or provided by the system |
| Threats moved to a restorable quarantine, never deleted outright | Reversibility |
| "Free up RAM" through `purge`, with the administrator password | Simple and documented |
| Cloud cleanup limited to synced local copies: "Free up" never deletes a file from the cloud | No credentials or private database of a cloud client is read |
| Disk images never mounted (read as raw files), background items (BTM) not read | No side effect during a scan; the BTM database requires root |
| No temperature reading, no freeing of purgeable space | No public API |
| No account, license, purchase, analytics or online assistant | Personal use |
| App lists, duplicates and large files ticked one by one, never in bulk | A mass uninstall or deletion is too serious for a single click |

## Next steps

### Signed privileged helper

**Today.** Operations that require root are grouped and run at once through AppleScript, with `do shell script … with administrator privileges` (`ActionExecutor.adminAppleScript`). This covers moving an app installed by a `.pkg` to the Trash (its bundle is owned by root, like DaVinci Resolve), `pkgutil --forget`, stopping daemons and system caches. The Finder would also ask for the password for these items.

**The problem.** macOS 27 shows a generic window for this mechanism: "Allow administrator access for a script started by "Vibe Cleaner"? … Apple could not verify this script is free of malware". The explanation provided by the app is no longer shown. The request is legitimate, but the window is worrying.

**The goal.** A small signed privileged helper, like most system utilities:
- an executable embedded in the bundle (`Contents/Library/LaunchDaemons`), registered once with `SMAppService.daemon(plistName:)`;
- the user authorizes it once in System Settings > General > Login Items & Extensions; macOS shows it there with Vibe Cleaner's name and icon;
- the app talks to it over XPC (`NSXPCConnection` with a Mach service), with a closed list of operations: root move to Trash, stopping a daemon, `pkgutil --forget`. Never an arbitrary shell;
- the helper checks the caller's signature (same Team ID, through `setCodeSigningRequirement`) before accepting a request;
- it runs every path through `SafeRemover` again (protected paths, exclusions, simulation), as today;
- it chains an uninstall in the safe order: stop the daemon, check that it stopped, and only then move the app to the Trash. Today the batch's commands are independent: if stopping fails, the app is removed anyway and the daemon runs until the next restart. Fixing it in the AppleScript batch would need a second password.

**What it takes.**
- A **Developer ID Application** certificate (Apple Developer Program, paid). The current ad hoc signature is not enough: `SMAppService` refuses a daemon that macOS cannot tie to an identified developer.
- **Notarization** of the app and the helper (`notarytool`), without which Gatekeeper blocks the daemon.
- A fallback: without an authorized helper, keep the current AppleScript batch.

Steps for the certificate and notarization (in French): [docs/CERTIFICAT-APPLE.md](docs/CERTIFICAT-APPLE.md).

**What it changes for the user.** No more "unverified script" window on each uninstall: a single, identified authorization, then no more prompts for the planned operations. The helper only runs when the app calls it and is uninstalled with it.

Nothing will be installed on a Mac without explicit consent: the helper only registers at the first root operation, after an explanation in the app.

### Notarized release and badge

Once the app is signed with a Developer ID and notarized, a DMG will be published in the GitHub releases, with a badge at the top of this README.

## Status and known limits

Not implemented yet:
- a **background daemon**: threat monitoring, the daily scan and alerts (disk, external disk almost full, Trash, memory, apps in the Trash, accessories) only run while the app is open. Only the Vibe Check reminder is scheduled as a local notification and also arrives with the app closed;
- **similar images in the Photos library**;
- **cleaning external disks** (on eject, disks over 128 GB);
- **AirPods battery** (the `system_profiler` fallback is not written).

Awaiting a decision:
- **frozen apps**: detecting them would need the Accessibility permission, which the app does not ask for today.

Notifications are only requested during onboarding; if refused, nothing is shown.

Limits:
- Exclusion rules are written by hand: they may be incomplete, or more cautious than needed.
- Clutter ignores any folder containing a `.git`: a "duplicate" inside a project is often part of it.
- Login items added by apps through SMAppService have no public API. Only those in the "Open at Login" list are listed.
- Several system formats are read from their assumed structure, without checking against a real database: Mail accounts (`Accounts4.sqlite`), TCC databases, App Store downloads.
- ZIP archives and PKG installers are only unpacked (in the temporary folder, with limits on size, file count and duration) if the option is on. The SQLite databases being read (TCC, browser history and cookies, Chrome's encrypted passwords, Mail accounts) are copied read-only into the temporary folder, then deleted.

## License

[MIT](LICENSE). Not affiliated with Apple.
