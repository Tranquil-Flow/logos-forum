# Licence inventory — LP-0026 Forum

Original code in this repository is dual-licensed **MIT + Apache-2.0**
(see `LICENSE-MIT`, `LICENSE-APACHE-2.0`), per prize eligibility terms.

## Direct build/runtime dependencies (pinned tuple)

| Component | Version pin | Licence | Notes |
|---|---|---|---|
| logos-module-builder | 0.3.2 (`4b799827…`) | MIT + Apache-2.0 | verified `LICENSE-MIT`/`LICENSE-APACHE-v2` in pinned source |
| logos-delivery-module | v0.3.0 (`bec85943…`) | MIT + Apache-2.0 | verified licence files in pinned source |
| logos-storage-module | v3.0.0 (`a9c14b8c…`) | MIT + Apache-2.0 | verified licence files in pinned source |
| logos-basecamp (host) | 0.3.1 (`aeb8192…`) | MIT + Apache-2.0 | verified licence files in pinned source |
| logos-logoscore-cli | 0.3.1 | MIT + Apache-2.0 (Logos stack convention) | verify at release repo before publication |
| logos-qt-mcp (test framework) | pin in builder flake.lock | MIT + Apache-2.0 | test-only dependency |

## Transitive runtime libraries (bundled in packages / host)

| Library | Licence | Why present |
|---|---|---|
| Qt 6.9.2 (QtQuick, QtRemoteObjects, …) | LGPL-3.0 (dynamic linking) | host + module runtime; dynamically linked, no Qt static linking into our code |
| SQLite | Public domain | M2 core persistence |
| libsodium | ISC | crypto used by Logos stack binaries |
| OpenSSL / LibreSSL | Apache-2.0 / dual OpenSSL+SSLeay | TLS/crypto in stack binaries |
| Boost (subset: system, etc.) | BSL-1.0 | stack binaries |
| ICU, libxml2, curl, zlib, etc. | MIT/BSD/Zlib (upstream) | transitive, shipped inside Logos runtime bundles |

## Rules observed

- No AGPL/copyleft code was copied into this repository; no competitor code
  was used as implementation source.
- Licence texts for original code shipped in the repository root; third-party
  notices for bundled binaries belong with each package (module-builder lgx
  bundling carries upstream notices inside payloads).
- Before any publication (M6), re-verify the logos-logoscore-cli release
  licence files at the pinned tag and refresh this table from primary sources.
