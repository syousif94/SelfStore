# SelfStore agent API

SelfStore hosts ad hoc signed iOS apps (.ipa) on this Mac and serves them to iPhones/iPads for
over-the-air install. Add builds by calling the HTTP API. Do not copy files into SelfStore's folders.

Base URL on this Mac: http://localhost:8765
Base URL from other tailnet machines: https://<this-mac>.<tailnet>.ts.net:8767 (needs `Authorization: Bearer <token>`, see SelfStore Settings)

Requests from this Mac (localhost) need no token.

## Upload a build

```bash
curl --fail-with-body --data-binary @path/to/App.ipa "http://localhost:8765/api/apps?notes=Fixes%20login"
```

- The body is the raw .ipa. `multipart/form-data` also works: `curl -F ipa=@App.ipa -F notes="Fixes login" http://localhost:8765/api/apps`
- Bundle id, name, version, build and icon are read from the .ipa. Many versions of the same app are kept.
- Query options: `notes=<text>`, `replace=false` (409 instead of overwriting the same version+build), `keep=<n>` (prune to the newest n versions after upload), `resign=true|false` (override the re-sign setting), `rename=true|false` (override moving the bundle ID to the preferred prefix, see Bundle IDs).
- Returns 201 with the version JSON, including `installURL` (itms-services link) when Tailscale is serving.

## Signing

Check `GET /api/signing`. When `"ready": true`, SelfStore re-signs every upload with its Apple Distribution
certificate and a fresh ad hoc profile containing every registered device. Upload any build: development-signed,
ad hoc, or unsigned/locally signed. No Apple account in Xcode is needed. The easiest way to build is:

```bash
xcodebuild -project App.xcodeproj -scheme App -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
rm -rf Payload && mkdir Payload && cp -R build/Build/Products/Release-iphoneos/App.app Payload/
# Sign locally so the app's entitlements travel with it (omit --entitlements if the app has none):
codesign -f -s - --entitlements App/App.entitlements Payload/App.app
zip -qry App.ipa Payload
curl --fail-with-body --data-binary @App.ipa "http://localhost:8765/api/apps?notes=…"
```

App extensions (.appex) need the same `codesign -s - --entitlements …` before the app itself.
SelfStore keeps the entitlements that the App ID allows.
SelfStore turns on the App ID capabilities those entitlements need (App Groups, iCloud,
push…) and remakes a cached profile that doesn't allow them. App groups and iCloud containers can't be attached
through the API: attach them once in the developer portal, then build again. Entitlements it drops, and what to do,
are listed in the version's `signingWarnings` and in a project's `warnings`. Each bundle ID (including extensions) is
created on the developer account automatically if it doesn't exist. Apps containing a Watch app can't be re-signed yet.

When `"ready": false`, the .ipa must already be ad hoc signed with the target devices in its profile.

- `GET /api/signing`: status, certificate, registered devices
- `GET /api/devices`: registered devices
- `POST /api/devices` with JSON `{"udid": "…", "name": "…"}`: register a device (new devices trigger a re-sign of every app's latest version)
- `POST /api/apps/<bundleId>/<versionId|latest>/resign`: re-sign one version now
- `POST /api/resign-all`: re-sign the latest version of every app in the background
- `POST /api/signing/refresh`: re-read devices/certificate from App Store Connect
- `POST /api/signing/developer-id` (this Mac only): create a Developer ID Application certificate for Mac builds
- Phones register themselves by opening `https://<this-mac>.<tailnet>.ts.net:8767/register` in Safari

## Bundle IDs

Apps from other developers carry bundle IDs registered to their team, which can't be signed with this one.
With a prefix set in Settings ▸ Bundle IDs (`GET /api/info` → `bundlePrefix`), SelfStore keeps the last component of
the app's ID and replaces the rest: `com.someone.Notes` → `<prefix>.Notes`. Extensions nested under the app's ID keep
their tail (`com.someone.Notes.Share` → `<prefix>.Notes.Share`); app groups, iCloud containers and keychain groups
follow. It happens while re-signing, so the original upload is kept and re-signs/TestFlight uploads repeat it.
Only .ipa files (uploads and repo `ipa:` entries) are renamed; apps SelfStore builds from Xcode projects keep
their project's bundle ID.
Versions record `originalBundleId`. Renaming needs signing to be set up; IDs already on the prefix are left alone.

## TestFlight

With an App Store Connect API key set up (`GET /api/signing` shows `"configured": true`), SelfStore can upload
any stored build to TestFlight. It re-signs the original upload with an App Store profile (entitlements kept,
`beta-reports-active` added) and uploads it with `xcrun altool`.

- `POST /api/apps/<bundleId>/<versionId|latest>/testflight`: queue an upload (202). Allowed from any tailnet device, like builds.
- Poll `GET /api/apps/<bundleId>/<versionId>`: `testFlight.state` is queued, signing, uploading, succeeded or failed, with `step` and `error`.
- The app must already exist in App Store Connect (Apps ▸ New App); the API can't create it.
- Each upload needs a version + build number App Store Connect hasn't seen. Project builds use a timestamp build number, so they always qualify.
- Apple processes the build for a few minutes after `succeeded`. Builds without `ITSAppUsesNonExemptEncryption` in Info.plist wait for an export compliance answer in App Store Connect.

## Projects (build on demand)

Register an Xcode project once; then it can be built from the iOS app, the menu bar, or the API.
SelfStore builds with `CODE_SIGNING_ALLOWED=NO`, carries each target's entitlements over, re-signs for
registered devices and publishes it (keeping the newest 5 builds). Build numbers default to a UTC timestamp.

- `POST /api/projects` with JSON `{"path": "/abs/App.xcodeproj", "scheme": "App", "build": true}`: add (scheme optional)
- `GET /api/projects`, `GET /api/projects/<id>`: status (`state`: queued, building, signing, succeeded, failed, cancelled; `step`; `error`; `logTail`)
- `POST /api/projects/<id>/build`, `POST /api/projects/<id>/cancel`
- `GET /api/projects/<id>/log`: full xcodebuild log
- `DELETE /api/projects/<id>`: remove (doesn't touch the source or published builds)
- `GET /api/settings/builds-folder`, `PUT /api/settings/builds-folder` with `{"path": "/Volumes/Drive/SelfStore"}` (this Mac only; empty for the default): where builds (DerivedData, logs, Mac files) are kept. Changing it moves existing builds; refused (409) while builds run

### Mac app projects

Projects whose scheme builds a Mac app (`"platform": "macos"`, detected automatically; pass `"platform"` to
`POST /api/projects` to override) produce a `.dmg` and a `.zip` instead of a library entry. With a Developer ID
Application certificate (`GET /api/signing` → `developerIDCertificate`), SelfStore signs with hardened runtime,
notarizes with the App Store Connect key and staples the ticket. Without one, builds are signed ad hoc and not notarized.
Entitlements that need a provisioning profile (`com.apple.developer.*`, keychain groups) are dropped and listed in `warnings`.

- `GET /api/projects/<id>`: `artifacts` (`name`, `path`, `size`), `notarized`, `version`, `warnings`
- `GET /api/projects/<id>/files/<name>`: download the `.dmg` or `.zip`

## Git repos (selfstore.yml)

Add a public git repo with a `selfstore.yml` at its root. Each app is either a prebuilt `.ipa` in the repo,
which SelfStore imports and re-signs, or an Xcode project + scheme, which it builds like any project.

```yaml
version: 1
branches: [main]               # default for every app; globs like "release/*" work
apps:
  - name: Notes
    ipa: selfstore/Notes.ipa     # prebuilt; re-imported whenever the file changes
  - name: Widgets
    project: Widgets/Widgets.xcodeproj   # or .xcworkspace
    scheme: Widgets              # or schemes: [Widgets, WidgetsMac]
    configuration: Release       # optional
    platform: ios                # optional (ios | macos), detected when omitted
    branches: [main, beta]       # optional, overrides the default
    notes: Shown with every build  # optional
```

- Branches other than the repo's default get the branch name appended to the app's bundle ID
  (`com.you.Widgets.beta`), so they install side by side. Each branch can carry its own selfstore.yml.
- `POST /api/repos` with JSON `{"url": "https://github.com/owner/repo", "build": true}`: add, clone and pull
  (from this Mac, with the token, or from a tailnet device). `owner/repo` is shorthand for GitHub.
- `GET /api/repos`, `GET /api/repos/<id>`: `state` (idle, pulling, failed), `step`, `error`, `branches` (name, commit,
  subject), `targets` (`kind` ipa or project, `projectId` to build, `bundleId` it publishes to, `error`)
- `POST /api/repos/<id>/pull`: fetch, import changed .ipa files, update build targets. `?build=changed` then builds
  projects with new commits (or never built); `?build=all` builds every project. Allowed from any tailnet device.
- `POST /api/repos/<id>/build` (`?all=true`): build without pulling
- `DELETE /api/repos/<id>`: remove the repo, its checkout and build targets (published apps stay)
- Repo projects also appear in `GET /api/projects` with `repoId`, `branch` and `commit`.
- Git LFS files need `git-lfs` installed on this Mac. Submodules are checked out.

### Export a project's builds to its repo

`PATCH /api/projects/<id>` with `{"exportToRepo": true}`: after each iOS build, SelfStore copies the .ipa to
`<git root>/selfstore/<Scheme>.ipa` and adds it to `<git root>/selfstore.yml`, so the repo can be added to any
SelfStore without building. Nothing is committed or pushed. The project's `lastBuild.exportedTo` has the path.

## Read

- `GET /api/info` — server name, LAN and Tailscale URLs, whether installs are available
- `GET /api/apps` — every app with versions, newest first
- `GET /api/apps/<bundleId>` — one app
- `GET /api/apps/<bundleId>/<versionId|latest>` — one version

## Change

- `PATCH /api/apps/<bundleId>/<versionId>` with JSON `{"notes": "…"}` — edit release notes
- `DELETE /api/apps/<bundleId>/<versionId>` — remove one version
- `DELETE /api/apps/<bundleId>` — remove the app and all versions
- `POST /api/apps/<bundleId>/prune?keep=3` — keep only the newest 3 versions

## Files (used by iOS)

- `/apps/<bundleId>/<versionId|latest>/manifest.plist`, `/app.ipa`, `/icon.png`
- `/apps/<bundleId>/icon.png` — latest icon

Version ids look like `1.2.0-45` (`<CFBundleShortVersionString>-<CFBundleVersion>`).
Errors are JSON: `{"error": "…"}` with 400/401/404/409/422/500.

## Install on a device

Open https://<this-mac>.<tailnet>.ts.net:8767 in Safari on the iPhone (on Tailscale), or use the SelfStore iOS app, which finds this Mac over Bonjour.