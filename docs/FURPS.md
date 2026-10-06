# FURPS view — LP-0026 Forum

Grouping of `docs/MATRIX.md`'s R01–R17 rows by the prize's Supportability
lenses. Every cell points at hash-bound receipts in the matrix; nothing here
adds claims beyond it.

## Functional
| Capability | Rows | Receipt highlights |
|---|---|---|
| Accounts / aliases / anonymous posting | R02 | core-tests 177/0 (accounts, per-post fresh Ed25519 identities, no stable id on the wire); three identity options — alias + key id, key id only, anonymous one-time key — in CI 13/13; alias + key-id row on real Basecamp clean install |
| Identity rotation (one alias, many keys) | R02 | an alias moves to a fresh key on demand (**New key now**), every N posts (5/10/25/100) and/or once the key is a day/week/month old; earlier posts stay verifiable, later ones no longer share their key id; rotation state persists in the profile (core-tests; CI 'alias key rotation — manual, by posts and by age') |
| Topics + replies over real transport | R03 | two-instance in-app smokes (Required path, post shown `[received]` in the shared General thread); topic create/browse in CI 13/13; topics ordered by latest activity with unread counts; local search over titles, text and authors (CI 'search filters topics and posts'); replies are flat within a topic |
| Privacy-required sending, no silent fallback | R04 | **live on public logos.dev**: two instances join via the in-app Connect action, post sent through Mix (`Message propagated via Mix`), rendered `[received]` at the other; local Required round trips + `messageError` refusal receipts; coexistence guard trigger (N2) |
| Past messages after being offline | R17 | **live on public logos.dev**: author posts and quits; a reader started later with an empty store gets the post via store catch-up and "Load older posts" (7 days, paged) |
| History on Logos Storage, in the app | R17 | **Save snapshot** puts a topic's signed posts on Logos Storage and announces the CID through Mix (live on logos.dev); **Restore these posts** fetches it and re-verifies every post — a reader that never joined Delivery restored 5 posts, 0 rejected (`tools/m7_storage.sh`; Storage nodes on loopback, the author's node serving) |
| Offline durability + duplicate-free retry | R05 | store-before-send reopen proof, `stored_event` identity, protocol exactly-once (original bytes); posts written while connecting are sent automatically on connection (live receipt, zero manual retries) |
| No central server / founder signer | R06 | non-author inventories + fresh-reader discovery with nothing injected |
| Verifiable retained history | R07/R08 | two archives byte-verified; live + retained discovery paths |

## Usability
| Aspect | Evidence |
|---|---|
| Non-expert local install | README quick start (5 steps, no build) and install section; real lgpm install receipt (`status: ok`); the release package loads in the release Basecamp 0.3.1 app on a fresh profile and shows the saved topics on open, no click needed (`evidence/m5-package/release-app-20261004/`); isolated `--user-dir` instances (`tools/demo_profiles.sh`) |
| Honest pending/privacy/degraded states | network chip (offline / connecting / connected) driven by Delivery's connection status; per-post states from module events; CI asserts an offline post is saved as *waiting to send* (composer cleared, no duplicate) and a store failure keeps the text; watchdog surfacing for backend death; matrix R04/R05 |
| Joining the network | one explicit button; no configuration; nothing connects automatically (CI test "network join is offered, not automatic"); transport diagnostics folded behind **Network details**; status lines in plain words ("1 post", "rotated 2 times") |
| Privacy stated where it matters | identity line states linkability before posting; rotation line shows posts on the current key; "Load older posts" and snapshot fetches state that reading is a direct request |
| Small windows | layout stacks topics above the thread below 760 px; controls carry accessible names |
| Plain-text safety | UI renders text only; no automatic remote resource loads (CONTRACT §0.3, enforced in QML) |

## Reliability
| Aspect | Rows |
|---|---|
| Loss/repair/restart/churn truthfulness | R09 (archive loss + restart survival + honest failures) |
| Finite retention with refresh | R11 (expiry positive control, refresh restoration; zero-TTL not permanent) |
| Input hostility | R12 (bounds/tamper/forgery/replay matrix + fail-closed stale-announce refusal) |
| Named upstream finding | STATUS: Delivery 0.3.0 trampoline SIGSEGV in `logos_host` — recorded, not re-evaluated after the 2026-10-03 link fix |

## Performance
| Aspect | Rows |
|---|---|
| No network flooding | R13 (bounded harness budgets: ≤50 posts/5 MiB, 4 relays, paged queries with caps); in the app: every send paced (burst 5, then one per 2 s — also when a reconnect flushes the outbox), ≤3 automatic retries per post (15/30/60 s), history ≤10 pages × 50, snapshots ≤1000 events / 4 MiB, 200 rendered rows |

## Supportability
| Aspect | Rows |
|---|---|
| Reusable design + docs | R14 (CONTRACT.md, LICENSES.md, flake pins, local CI green on macOS and aarch64-linux; prepared workflow runs core + UI + package on Linux and macOS; remote CI run not yet receipted) |
| Reproducible verification surface | `tools/verify.sh` (non-execution propagates), matrix generator with sha256 receipts |
| Packaging | release variants darwin-arm64, linux-arm64/linux-amd64 and windows-x86_64 (mingw cross build, CI job `windows`), merged by CI into one multi-platform `.lgx` (job `all-platforms`); the Windows package runs in the release Basecamp 0.3.1 app on a Windows CI runner and sends a post written offline through Mix after Connect (job `windows-basecamp`, `evidence/m8-windows/`); a Windows cross build under emulation on Apple silicon fails in Qt's `repc` (receipts kept); both `.lgx` flavours build; variant truth documented (release=`darwin-arm64`, dev=`-dev`); Linux (aarch64, `nixos/nix` container via `tools/linux_build.sh`): core tests 177/0, hermetic UI suite 13/13 and the portable `.lgx` with a `linux-arm64` variant (`linux-20261004-214743`, final tree); five earlier UI builds were killed for memory (exit 137, receipts kept) until evaluation and build were split into separate processes |
