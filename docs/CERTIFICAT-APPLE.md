# Obtenir un certificat Apple et notariser Vibe Cleaner

Marche à suivre pour passer de la signature locale actuelle (Apple Development ou ad hoc) à une app signée **Developer ID** et **notarisée** par Apple. C'est le prérequis du helper privilégié décrit dans le README (« Prochaines étapes »).

Toutes les commandes ci-dessous se lancent à la main, dans votre propre terminal.

## Ce que ça apporte

- **Gatekeeper.** L'app s'ouvre sur n'importe quel Mac sans l'alerte « développeur non identifié » ni le passage par Réglages Système > Confidentialité et sécurité > « Ouvrir quand même ».
- **Helper privilégié.** `SMAppService` n'enregistre un démon que si l'app est signée Developer ID et notarisée. C'est ce qui permettra de remplacer la fenêtre « script non vérifié » par une autorisation unique au nom de Vibe Cleaner.
- **Accès complet au disque stable.** L'autorisation reste attachée au Team ID, et ne se perd pas entre deux versions.

## 1. S'inscrire au programme Apple Developer

- **Coût** : 99 € par an environ (99 USD), renouvelable. Sans renouvellement, les apps déjà notarisées continuent de s'ouvrir, mais on ne peut plus en signer de nouvelles.
- **Compte** : un identifiant Apple avec l'authentification à deux facteurs activée.
- **Où** : l'app Apple Developer (Mac ou iPhone), qui vérifie l'identité avec une pièce d'identité, ou le site [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/).
- **Particulier ou organisation** :
  - *Particulier* : l'app apparaît sous votre nom (« Developer ID Application: Guillaume Evrat »). Le plus rapide, souvent validé en 24 à 48 h.
  - *Organisation* : l'app apparaît sous le nom de la société. Il faut un numéro **D-U-N-S** (gratuit, demandé à Dun & Bradstreet via le lien d'Apple, plusieurs jours de délai), une entité juridique et un site web au nom de la société.
- Une fois accepté, notez le **Team ID** (10 caractères) : developer.apple.com/account > Membership details.

## 2. Créer le certificat Developer ID Application

Seul le titulaire du compte (« Account Holder ») peut créer ce type de certificat.

**Le plus simple, avec Xcode :**
1. Xcode > Réglages > Comptes, ajouter l'identifiant Apple du programme.
2. Sélectionner l'équipe > « Gérer les certificats… » > `+` > **Developer ID Application**.

**Sans Xcode, par le site :**
1. Trousseau d'accès > Assistant de certification > « Demander un certificat à une autorité de certification… », enregistrer la demande (`.certSigningRequest`) sur le disque.
2. developer.apple.com/account > Certificates > `+` > Developer ID > **Developer ID Application**, envoyer la demande.
3. Télécharger le `.cer` et l'ouvrir : il rejoint le trousseau avec sa clé privée.

**Vérifier :**

```bash
security find-identity -v -p codesigning
# … "Developer ID Application: Guillaume Evrat (ABCDE12345)"
```

**Sauvegarder la clé privée.** Dans Trousseau d'accès, exporter le certificat avec sa clé en `.p12` protégé par un mot de passe, et le ranger hors du dépôt (gestionnaire de mots de passe, disque chiffré). Clé perdue : il faut révoquer et recréer le certificat. Clé volée : quelqu'un peut signer des apps à votre nom, révoquez immédiatement. Le `.gitignore` refuse déjà les `.p12`, `.cer` et `.certSigningRequest`.

Le certificat *Developer ID Installer* n'est utile que pour distribuer un `.pkg`. Il n'est pas nécessaire ici.

## 3. Préparer la notarisation

`notarytool` a besoin d'un accès au compte. Deux options :

**Mot de passe pour app (le plus simple) :**
1. [account.apple.com](https://account.apple.com) > Connexion et sécurité > Mots de passe pour app > en créer un, nommé « notarytool ».
2. Le ranger une fois dans le trousseau, sous un nom de profil :

```bash
xcrun notarytool store-credentials vibecleaner \
  --apple-id "vous@exemple.com" --team-id ABCDE12345 --password "xxxx-xxxx-xxxx-xxxx"
```

**Clé API App Store Connect** (utile plus tard pour une CI) : App Store Connect > Utilisateurs et accès > Intégrations > clés API, puis `store-credentials` avec `--key`, `--key-id` et `--issuer`. Le fichier `.p8` ne se télécharge qu'une fois et ne va jamais dans le dépôt.

## 4. Signer, notariser, agrafer

`scripts/bundle.sh` signe déjà avec le runtime renforcé, exigé par la notarisation. Il ajoute l'horodatage sécurisé (`--timestamp`, également exigé) dès que l'identité est un Developer ID.

```bash
# 1. Construire et signer
SIGN_IDENTITY="Developer ID Application: Guillaume Evrat (ABCDE12345)" make app

# 2. Contrôler la signature avant l'envoi
codesign --verify --strict --deep --verbose=2 "dist/Vibe Cleaner.app"
codesign -dv --verbose=4 "dist/Vibe Cleaner.app" 2>&1 | grep -E "Authority|Timestamp|flags"
# attendu : Authority=Developer ID Application…, un Timestamp, flags=0x10000(runtime)

# 3. Envoyer à Apple (quelques minutes en général)
ditto -c -k --keepParent "dist/Vibe Cleaner.app" dist/VibeCleaner.zip
xcrun notarytool submit dist/VibeCleaner.zip --keychain-profile vibecleaner --wait

# 4. En cas de refus, lire le rapport
xcrun notarytool log <submission-id> --keychain-profile vibecleaner

# 5. Agrafer le ticket à l'app : Gatekeeper le vérifie même hors ligne
xcrun stapler staple "dist/Vibe Cleaner.app"

# 6. Vérifier comme le ferait un autre Mac
spctl -a -vvv -t exec "dist/Vibe Cleaner.app"
# attendu : accepted, source=Notarized Developer ID
```

Le zip ne sert qu'à l'envoi : après l'agrafage, c'est l'app elle-même qu'on distribue (dans un nouveau zip ou un DMG).

**Refus fréquents :**
- *The signature does not include a secure timestamp* : `--timestamp` manquant, ou signé avec une identité Apple Development.
- *The executable does not have the hardened runtime enabled* : un binaire signé sans `--options runtime`. Ici, l'app et `vibeclean` le sont déjà.
- *The binary is not signed with a valid Developer ID certificate* : un des deux binaires a gardé l'ancienne signature. Refaire `make app` avec `SIGN_IDENTITY`.

## 5. Distribuer en DMG (optionnel)

```bash
hdiutil create -volname "Vibe Cleaner" -srcfolder "dist/Vibe Cleaner.app" -ov -format UDZO "dist/Vibe Cleaner.dmg"
codesign --sign "Developer ID Application: Guillaume Evrat (ABCDE12345)" --timestamp "dist/Vibe Cleaner.dmg"
xcrun notarytool submit "dist/Vibe Cleaner.dmg" --keychain-profile vibecleaner --wait
xcrun stapler staple "dist/Vibe Cleaner.dmg"
```

Un DMG notarisé et agrafé couvre l'app qu'il contient. Il se publie ensuite comme fichier d'une *release* GitHub.

## 6. Après le passage au Developer ID

- **Accès complet au disque** : la signature change d'identité (Apple Development vers Developer ID), donc macOS redemande l'autorisation une fois. Elle tient ensuite pour toutes les versions signées avec le même Team ID.
- **Badge du README** : une fois la première version notarisée publiée, on peut ajouter en tête du README un badge, par exemple `![Notarisée par Apple](https://img.shields.io/badge/macOS-notaris%C3%A9e-success)`, avec un lien vers la release.
- **Helper privilégié** : c'est l'étape suivante, décrite dans le README (« Prochaines étapes »). Le helper doit être signé avec le même certificat et notarisé avec l'app.

## Ce qui ne va jamais dans le dépôt

Le `.p12` et son mot de passe, le `.p8` d'une clé API, le mot de passe pour app, et tout fichier `.env` qui les contiendrait. Le Team ID et le nom du certificat ne sont pas secrets : ils figurent dans toute app signée.
