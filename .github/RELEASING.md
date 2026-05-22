# Releasing Keywordista

How to cut a signed + notarized macOS release. Maintainer-only — contributors don't need any of this to build the project from source.

There are two release streams that ship independently:

| Tag pattern | What gets built | Workflow |
|---|---|---|
| `app-v0.1.0` | `Keywordista-0.1.0.dmg` (the menubar app + bundled service) | [`release-app.yml`](workflows/release-app.yml) |
| `service-v0.1.0` | `keywordista-service-0.1.0.zip` (the Vapor server + SPA) — consumed by the menubar app's in-app updater | [`release-service.yml`](workflows/release-service.yml) |

Both workflows use the same five secrets — set them once and both pipelines work.

## One-time setup

### 1. Export your Developer ID Application certificate

In Keychain Access → your login keychain → Certificates:

1. Right-click **Developer ID Application: Astemir Boziev (KHNA6PF8QV)**
2. Export → save as `cert.p12`
3. Set an export password (you'll need it as `MACOS_CERT_PASSWORD`)

Then base64-encode for the GitHub secret:

```bash
base64 -i cert.p12 | pbcopy
```

### 2. Generate an app-specific password for notarization

At <https://appleid.apple.com/account/manage> → App-Specific Passwords → Generate.

Save it; you can't view it again later.

### 3. Configure GitHub Actions secrets

Repo Settings → Secrets and variables → Actions → New repository secret. Set all five:

| Secret name | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | The base64 blob from step 1 |
| `MACOS_CERT_PASSWORD` | The .p12 export password |
| `APPLE_ID` | The Apple ID email tied to the dev team |
| `APPLE_APP_SPECIFIC_PASSWORD` | The app-specific password from step 2 |
| `APPLE_TEAM_ID` | `KHNA6PF8QV` |

## Releasing the app

Once secrets are in place, releasing is a single tag push:

```bash
# Bump version, tag, push
git tag app-v0.1.0
git push origin app-v0.1.0
```

The workflow:
1. Stamps the version from the tag into `mac/Resources/Info.plist`
2. Imports the cert into a temporary keychain
3. Builds universal arm64+x86_64 binaries
4. Signs everything with hardened runtime + timestamp
5. Builds the DMG, signs it
6. Submits to Apple notarization, stamps the ticket onto the DMG
7. Creates a GitHub Release with the DMG + a SHA-256 sidecar file, auto-generates release notes from commits since the previous tag

Takes ~5–8 minutes end to end.

## Releasing the service

Service releases are the same idea but for the Vapor binary + SPA that the menubar app's in-app updater consumes:

```bash
git tag service-v0.1.0
git push origin service-v0.1.0
```

The workflow:
1. Stamps the version into `Sources/App/Services/Version.swift`
2. Imports the cert (same dance as the app workflow)
3. Builds the universal Vapor binary, signs it
4. Builds the SPA
5. `ditto`-zips `keywordista-server` + `Public/` into `keywordista-service-$VERSION.zip`
6. Submits the .zip to Apple notarization — the **binary's signature** gets notarized; the .zip wrapper is just for transport. No stapling (unsupported on .zip), but the menubar app's `UpdateChecker` does `codesign --verify` after extraction, which is sufficient.
7. Creates a GitHub Release with the .zip + SHA-256 sidecar.

End users don't download these directly — the menubar app polls for `service-v*` releases and applies them in-place via the **Apply Update** menu item.

### When to cut which release

| Change | Tag |
|---|---|
| Backend logic (Vapor server, SPA, scoring heuristic, refresh job) | `service-vN.N.N` |
| Menubar app UI / supervisor / update flow itself | `app-vN.N.N` |
| First-time install needs the bundled fallback updated too | `app-vN.N.N` (re-bundles the latest service) |

The app's bundled fallback service binary is whatever was on `main` at the time the app DMG was built. After install, the menubar app upgrades to whatever `service-v*` is newer than its bundled fallback. So users always get the latest service eventually, even if they only ever download the .dmg once.

## Dry-run testing

The workflow also accepts a manual trigger via `workflow_dispatch` for testing without cutting a real release:

1. Actions → Release App → Run workflow
2. Enter a version (e.g. `0.1.0-dryrun`)
3. The DMG is uploaded as a **workflow artifact** (14-day retention) instead of a Release

This is useful for verifying the signing/notarization pipeline after rotating secrets, before tagging.

## Verifying a release locally

After download:

```bash
shasum -a 256 -c Keywordista-0.1.0.dmg.sha256
codesign --verify --deep --strict --verbose=2 /Volumes/Keywordista/Keywordista.app
spctl --assess --type install --verbose=2 Keywordista-0.1.0.dmg
# Expected: source=Notarized Developer ID
```

## When something goes wrong

- **Cert import fails** — re-export the .p12 with the same password you set as the secret. Keychain Access sometimes saves with a different cipher; export as PKCS#12 explicitly.
- **Notarization rejected** — check the workflow logs for the JSON response. Common causes: hardened runtime not enabled (we always pass `--options runtime`, so this shouldn't trigger), or an embedded binary that wasn't signed (build-dmg.sh signs server + menubar + .app in that order).
- **Wrong cert auto-detected** — pin one explicitly via repository variable `CODESIGN_IDENTITY` and add `CODESIGN_IDENTITY: ${{ vars.CODESIGN_IDENTITY }}` to the build step's env. The script honors that override.

## What about a "release notes" channel?

The workflow uses `gh release create --generate-notes`, which auto-fills release notes from commits + PRs since the last tag. If you want curated notes, prepare a `CHANGELOG.md` section and edit the Release after it's created.
