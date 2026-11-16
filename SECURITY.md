# Security

SimpleWhispr is a local-first dictation app. By design, audio and transcripts
never leave your machine. Please help keep it that way.

## Reporting a vulnerability

Do **not** open a public issue for a security problem. Instead:

1. Prefer the **Security tab** on the repository:
   <https://github.com/okiess/simplewhispr/security/advisories> and click
   "Report a vulnerability". This lets us discuss the issue privately.
2. If you cannot use that, send a private note through the maintainer's contact
   channels and mark the subject `Security:`.

Please include:

- A short description of the issue.
- The affected version or build number.
- Steps to reproduce, or a proof of concept.
- Any known impact.

## What we will not do

- We will not accept changes that add telemetry, cloud calls, or API keys to the
  core transcription path.
- We will not accept changes that weaken the local-first contract.

## Response

We aim to acknowledge a report within a few business days and to fix confirmed
issues in a subsequent release. We will credit reporters unless they ask to stay
anonymous.
