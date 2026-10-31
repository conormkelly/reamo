# Security policy

## Supported versions

- **0.8.x (latest release):** supported. Fixes ship in the next release; there are no backports.
- **Release candidates of the next version:** best effort until it ships.
- **0.7.x and older:** not supported. Update to the latest release.

## Reporting a vulnerability

- Don't open a public issue, discussion or pull request.
- Report privately: [github.com/conormkelly/reamo/security/advisories/new](https://github.com/conormkelly/reamo/security/advisories/new).
- Include the REAmo, REAPER and OS versions, what an attacker needs (same network? the user visiting a web page?), steps to reproduce, and what they gain.

## What to expect

- REAmo has one maintainer. I'll acknowledge your report within about a week, then fix accepted issues in a release as soon as I can.
- You'll be credited if you want to be. Please wait for the fix before disclosing. There is no bug bounty.

## Scope

- **In:** the extension's HTTP/WebSocket server (`extension/`), the web app (`frontend/`), the installer and uninstaller (`installer/`), the release workflow and its artifacts (`.github/workflows/`).
- **In, and most valuable:** any way to reach REAmo without being on its network (from a web page, DNS rebinding, through the browser).
- **Out:** control by anyone on the same network. There is no password by design.
- **Out:** reading plain-HTTP traffic on the network. TLS isn't offered.
- **Out:** exposure from forwarding REAmo's port to the internet.
- **Out:** bugs in REAPER, other extensions or browsers; DoS that needs sustained flooding from the LAN.

## Verifying a download

- Each release zip has a `.sha256` file beside it.
- From v0.8.1 on, each zip has a signed build provenance attestation: `gh attestation verify REAmo-v<version>-<platform>.zip -R conormkelly/reamo`
- The binaries are not Apple or Microsoft code-signed or notarized.

Threats, measures and known gaps: [docs/architecture/SECURITY.md](docs/architecture/SECURITY.md).
