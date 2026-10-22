# Security Policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub's private vulnerability reporting:

<https://github.com/ddol/canopy-ios/security/advisories/new>

Do not open a public issue for a security problem. Include what you found, how to reproduce it, and the
impact you expect. We will acknowledge the report, keep you updated while we fix it, and credit you in the
advisory if you would like.

## Supported versions

Canopy is pre-release. Only the latest commit on `main` is supported.

## Scope

Things we especially want to hear about:

- Any way the app could store or upload a camera image, or any identity beyond the Game Center player id
  and alias (see [PRIVACY.md](PRIVACY.md)).
- Ways to forge or replay observations, evidence or changesets, or to get a change onto the shared map
  without two players agreeing and one of them being trusted.
- Corruption of the local database or blob store through crafted input (for example fixture or GLB files).
