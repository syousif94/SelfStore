# SelfStore

Host ad hoc signed iOS apps on your Mac, including multiple versions of each, and install them on iPhone/iPad over the air.

**[Download for Mac](https://github.com/syousif94/SelfStore/releases/latest/download/SelfStore.dmg)** · [Website](https://syousif94.github.io/SelfStore/)

- **Mac app** (`Mac/`): a menu bar app (the icon can be hidden) that runs an HTTP server on port **8765**, advertises itself over
  Bonjour (`_selfstore._tcp`) and shares itself on the tailnet with `tailscale serve` at **https://<mac>.<tailnet>.ts.net:8767**.
- **iOS app** (`iOS/`): finds Macs over Bonjour, by Tailscale address, or from the "Add this Mac to the SelfStore app" link
  (`selfstore://add?url=…`) on the Safari page. It lists every app with its icon, name and version, and installs any version.
- **Projects**: add an `.xcodeproj`/`.xcworkspace` in the Library (or `POST /api/projects`) and build it on demand from the
  iPhone, the menu bar, or the API. SelfStore builds unsigned, keeps entitlements, re-signs and publishes the result.
- **Signing**: with an App Store Connect API key (Settings ▸ Signing), SelfStore registers iPhones from Safari
  (`/register`), creates ad hoc profiles and re-signs every build for all registered devices.
- **TestFlight**: with the same API key, upload the latest (or any) build to TestFlight from the Library window, the
  iOS app, or `POST /api/apps/<bundleId>/latest/testflight`. SelfStore re-signs it for the App Store and uploads it with
  `altool`. The app must already exist in App Store Connect.
- **Mac apps**: projects with a macOS scheme build a `.dmg` and `.zip`. With a Developer ID certificate (Settings ▸
  Signing can create one with the API key, or import a .p12), they're signed with hardened runtime, notarized and stapled. Apps with iCloud, push or other entitlements that
  need a profile get a Developer ID provisioning profile embedded.
- **Git repos**: add a public repo with a [`selfstore.yml`](#selfstoreyml) from the Library, the iPhone or the API. It can list
  prebuilt `.ipa` files (imported and re-signed) and Xcode projects (built on the Mac), on any number of branches.
  Pull, or Pull & Build, from the iPhone, the menu bar or the Library.
- **Uploads from anywhere**: drop an `.ipa` on the Library window, pick one in the iOS app (or share it to SelfStore from
  Files/Safari), or `POST /api/apps`.
- **Bundle ID prefix**: set your prefix in Settings ▸ Bundle IDs and SelfStore moves other developers' apps to it when it
  re-signs them (`com.someone.Notes` → `com.you.Notes`), so they sign with your team. Only `.ipa` files are renamed;
  apps built from Xcode projects keep their own bundle ID.
- **Multiple Macs**: the iOS app shows apps and projects from every Mac you add, side by side.
- **Safari**: open the Tailscale URL on the phone to get the same list with Install buttons, no app needed.

Installs always go through the Tailscale HTTPS address, because iOS only accepts `itms-services` manifests over HTTPS with a
trusted certificate. Bonjour is used only to find the Mac.

## selfstore.yml

Put a `selfstore.yml` at the root of a repo to publish its apps to any SelfStore:

```yaml
version: 1
branches: [main]                 # default for every app; globs like "release/*" work
apps:
  - name: Notes
    ipa: selfstore/Notes.ipa     # a prebuilt .ipa in the repo (re-imported when it changes)
  - name: Widgets
    project: Widgets/Widgets.xcodeproj   # or .xcworkspace; SelfStore builds it
    scheme: Widgets              # or schemes: [Widgets, WidgetsMac]
    configuration: Release       # optional
    platform: ios                # optional: ios | macos (detected when omitted)
    branches: [main, beta]       # optional, overrides the default
    notes: Shown with every build  # optional
```

- Apps on branches other than the default get the branch name added to their bundle ID, so they install side by side.
- For a project SelfStore already builds, turn on **Export the .ipa to the repo after each build** in its Library page:
  SelfStore writes `selfstore/<Scheme>.ipa` and the matching `selfstore.yml` entry. Commit them and anyone can add the repo
  without building.
- Building a repo runs its build scripts on your Mac. Only add repos you trust.

## For agents

See [AGENTS.md](AGENTS.md) (also served live at `GET http://localhost:8765/api/docs`). In short:

```bash
curl --fail-with-body --data-binary @App.ipa "http://localhost:8765/api/apps?notes=What%20changed"
```

## Build

### Releasing

```bash
scripts/deploy.sh "What changed"
```

The script has the SelfStore running on this Mac build, sign, notarize and package `SelfStoreMac` (set up Developer ID
signing first). It then publishes `SelfStore.dmg` and `SelfStore.zip` as a GitHub release with `gh`, writes
`docs/latest.json` and pushes it, which redeploys the website in `docs/` (GitHub Pages, `main` branch, `/docs`).
The site's download button always points at the newest release. `DRY_RUN=1` builds and downloads only.

### Building by hand

```bash
xcodegen generate
xcodebuild -project SelfStore.xcodeproj -scheme SelfStoreMac -configuration Release -derivedDataPath build/dd build
cp -R build/dd/Build/Products/Release/SelfStore.app /Applications/
```

`scripts/publish-ios.sh "notes"` archives the iOS app ad hoc and uploads it to the local SelfStore. It needs an Apple account in Xcode.

Data lives in `~/Library/Application Support/SelfStore/apps/<bundleId>/<version>-<build>/`.
Settings (menu bar ▸ Settings, or open the app again while it's running): show/hide menu bar icon, launch at login,
Tailscale sharing, API token for uploads from other machines.
