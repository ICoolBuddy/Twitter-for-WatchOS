# Perch

A personal, non-commercial X client for Apple Watch (with a small iPhone companion for login).
Built entirely on GitHub Actions. No Mac needed. Not for the App Store.

- **Install:** see [docs/SIDELOADING.md](docs/SIDELOADING.md)
- **Design, research notes, milestones:** see [docs/PLAN.md](docs/PLAN.md)

## How it works

Perch talks to the same internal endpoints x.com's web app uses, authenticated with your own
browser session cookies (`auth_token`, `ct0`). Those are stored only in the Keychain on your
iPhone and Watch. The iPhone logs in through a normal X login page, then sends the session, the
current GraphQL query IDs and the request-signing key to the Watch over WatchConnectivity. After
that, the Watch works on its own over Wi-Fi/LTE.

When X changes its web app, query IDs go stale (HTTP 404). Perch fixes itself by re-reading x.com's
JavaScript (*Refresh endpoints*), or from a remote override URL, e.g.:

```
https://raw.githubusercontent.com/<you>/<repo>/main/endpoints.json
```

`scripts/update_endpoints.py` regenerates `endpoints.json` (stdlib Python, no account needed).

## Layout

```
Packages/XKit/   networking, parsing, transaction-id, endpoints (Swift package; tests run in CI)
Perch/           iOS app
PerchWatch/      watchOS app
Shared/          SwiftUI/view-model code compiled into both apps
project.yml      XcodeGen spec (the .xcodeproj is generated on CI)
```

## Development without a Mac

- Push → CI generates the project, runs XKit tests, archives unsigned, uploads `Perch-unsigned-ipa`.
- The same tests run in CI on the macOS runner; the package is Foundation-only, so
  `cd Packages/XKit && swift test` also works on Linux (Swift 6.x toolchain).

## Account safety

Perch behaves like a light human user: ≥350 ms between requests, exponential backoff on 429,
background refresh at most every 15 minutes, no promoted content, no automation.
Using unofficial endpoints is against X's terms. Use at your own risk, on your own account.
