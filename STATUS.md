# LP-0026 Forum

One `STATUS.md` is the single progress ledger. Gate labels:
`LOCAL_CANDIDATE_VERIFIED` → `NETWORK_QUALIFIED` → `SUBMISSION_READY` →
`PUBLISHED` — each only with its receipts.

## CURRENT STATE — 2026-10-03 closeout (supersedes every OPEN BLOCKER below)

**Gate: LOCAL_CANDIDATE_VERIFIED** (held). Matrix: **13 PASS, 2 PARTIAL,
0 BLOCKED, 1 NOT RUN** (`docs/MATRIX.md`; R14/R15 PARTIAL on owner-gated
publication/CI/video, R16 the external organic-use gate).

**Update — source review fixes, 2026-10-06 afternoon**
(`evidence/m5-package/bugfix-20261006/NOTE.txt`): a send that fails while
connected is kept and retried automatically, and the composer is cleared (no
duplicate post); posts waiting their paced turn are sent after a reconnect;
the post limit is counted in UTF-8 bytes; topics follow alias key rotation;
snapshot downloads must hold their size for 3 s before they are merged.
Core 177/0, UI 14/14, live logos.dev round trip, store probe and clean
install PASS on this tree. `tools/windows_smoke.sh` now also saves and
restores a snapshot, loads history and restarts the app on Windows — not
yet run in CI (no receipt; README limitation 7 unchanged until it is).

**Update — Windows in CI, offline posts, 2026-10-06** (details in the last
section): CI job `windows-basecamp` runs the Windows package in the official
Basecamp 0.3.1 app on a Windows runner: it loads, opens its store, keeps a
post written offline and sends it through Mix on logos.dev after Connect
(screenshots uploaded); that post was then received on macOS from the
network's store. The Windows run showed two UX faults, now fixed: an offline
post was stored as *not sent* while its text also stayed in the composer
(a second Send would duplicate it) — it is now *waiting to send* and the
composer is cleared; and the "Connecting…" hint outlived the connection.
**Retry stored** shows only when connected. Core 177/0, UI 13/13, store
probe, clean install and both UI tours on the final tree.

**Update — release app, Windows, polish, 2026-10-04 night** (details in the
last section): the release package loads in the **release Basecamp 0.3.1
app** on a fresh profile and now opens its store on its own, so saved topics
show without a click (found in the release app; `m5-package/release-app-*`).
Status lines in plain words (no "post(s)"); transport diagnostics behind
**Network details**. **Windows**: `packages.x86_64-windows.lgx-portable`
added to CI plus an `all-platforms` job merging darwin-arm64 / linux /
windows-x86_64 into one `.lgx`; building it locally under x86 emulation on
Apple silicon fails (eval stack overflow, then Qt `repc` SIGSEGV — three
receipts kept), so the Windows package comes from CI. macOS core 177/0,
UI 13/13 on the final tree.

**Update — rotation, Storage in the app, Linux, 2026-10-04 evening**
(details in the last section): key rotation for aliases (manual, every N
posts, every N days); topics by activity with unread counts; local search;
paced sending; narrow-window layout; **topic snapshots on Logos Storage in
the app** (save + announce through Mix live on logos.dev; a reader that never
joined Delivery restored and verified them — `m7-storage/snapshot-*`); a
strict canonical parser (fixes stored escapes). **Linux closed**: core
177/0, UI suite 13/13 and the portable `.lgx` (`linux-arm64`) on
aarch64-linux (`linux-20261004-191439`). macOS: core 177/0, UI 13/13.
Matrix 14 PASS / 2 PARTIAL / 0 BLOCKED / 1 NOT RUN.

**Update — live network + history + UI, 2026-10-04** (details in a later
section): owner authorised live logos.dev testing, feature work and a Linux
Docker build. **Live on public logos.dev**: in-app Connect → Required send
propagated via Mix → `[received]` at a second instance (`m6-live/live-*`);
offline reader gets past posts in the app (`m6-live/history-*`, matrix
R17). New: connection lifecycle (connected only when Delivery says so),
queue-while-connecting, bounded auto-retry, store catch-up accounting,
"Load older posts", signed-time thread order, redesigned light UI. Matrix
**14 PASS / 2 PARTIAL / 0 BLOCKED / 1 NOT RUN** (R01–R17).

**Update — submission prep, 2026-10-03 night** (details in the last section):
three identity options (alias + id, id only, anonymous); explicit
"Connect to Logos network (logos.dev · Mix required)" action, nothing
connects automatically, not yet exercised live (public network is
owner-gated); integration **10/10**; final-UI receipts store-probe
`-223325`, cleaninstall `-223452`, smoke `-223623` all PASS. Known gap: no
in-app history fetch (Store query / archives are harness-layer only,
labelled in the matrix).

**M2-GUI blocker: RESOLVED — root cause found, fixed, receipted.** The
"3-layer QtRO source-replica wedge" was a dead backend, not a QtRO defect:
logos-module-builder 0.3.2 links macOS plugins with `-undefined
dynamic_lookup` and does not forward `metadata.json`
`extra_link_libraries`, so the plugin linked with libsodium/sqlite
*unresolved*; the first `KeyPair::generate()` called a null `sodium_init`
and the ui-host SIGSEGV'd. Everything after that looked "wedged" (no slot
return, stale PROPs, no dispatch) because the source process was gone.
Fix: `LINK_LIBRARIES sqlite3 sodium` in `CMakeLists.txt`. Proof chain in
`evidence/m5-package/linkfix/` (lldb backtrace on the ui-host
`lldb-uihost-root-cause.txt`; `otool -L` before/after
`plugin-linkage-{before,after}.txt`; before/after drives). The bisect-rung-4
claim below ("statically linked") was WRONG — the symbols were undefined,
resolved at runtime to nothing. Kept verbatim for audit.

**Measured on the final tree (all 2026-10-03):**
- core-tests **116/0** (`evidence/m5-package/linkfix/core-tests-final.txt`).
- CI integration **8/8**, store-backed (`linkfix/integration-final.log`):
  alias create/select/list, topic create/list, topic browse switch, refused
  post stored + shown failed. Negative control without the link fix:
  2 passed / 6 failed (`linkfix/integration-negative-control-no-link.log`).
- Dev launcher store probe **M2-GUI PASS** (`store-probe-20261003-214233`;
  first PASS `-205535`). FAIL gates `-205003`/`-205428` preserved (probe
  harness defects: substring click, stale outcome text).
- Real Basecamp clean install **PASS** with `store_flow_in_real_host: true`
  (`cleaninstall-20261003-212919`, per-profile store at
  `<profile>/module_data/forum_module/forum.db`; `-212727` is the
  pre-per-profile run, store under the shared `ui-host` AppData path).
- Two-instance in-app Required smoke **PASS ×3** (`smoke-20261003-211102`,
  `-211209`, `-214415`): "Message propagated via Mix" in sender log, the
  post rendered `[received]` in the receiver's General thread, re-check
  confirms the app-owned node. `smoke-20261003-210837` FAIL preserved
  (harness: stale driver ids + stale `relays.pids`).
- R05 m2b-cli **PASS ×2 consecutive** (`m2b-cli-20261003-211708`,
  `-212136`). Earlier FAILs (`-105639`, `-110729`, `-194612`, `-211358`)
  preserved; the last two are traced to harness defects (doubled module arg
  made the readiness gate unpassable; stale `relays.pids`). The two
  morning FAILs predate those fixes and are not re-attributed.
- Negatives **PASS** (`negatives-20261003-214548`; N1/N2/N4 measured, N3
  by-construction and labelled so). `-213717` FAIL preserved (N3 policy).

**Product changes this closeout:** link fix; per-profile store path
(`dladdr` → `<user-dir>/module_data/forum_module/forum.db`, then
AppDataLocation fallback; `FORUM_DB_PATH` override); deterministic shared
"General" topic (`ensure_default_topic`, public derivable key — confers no
authority, stored as received) so posts thread across instances;
`merge_verified` keeps the signed `ts`; app-owned-node confirmation on
re-check; outbox count in transport status; identity box follows the
backend selection.

**Not attributed without A/B:** the 2026-10-02 in-app smoke regression
(OPEN BLOCKER below) no longer reproduces; posting signs via libsodium, so
the missing link is the likely cause, but no pre-fix run with the corrected
harness was made. The Delivery 0.3.0 trampoline SIGSEGV (Upstream findings)
is in `logos_host`, a different process, and has not been re-evaluated.

**Owner-gated, not executed:** A1–A7 (owner approval list, kept outside the repo)
(commit/push, remote CI, catalog, video, public testnet, organic use).

## RESOLVED 2026-10-03 (see CURRENT STATE) — was OPEN BLOCKER (recorded 2026-10-02, extended 2026-10-03): in-app slot-serving dies under transport mesh

The M1-era tree ran the two-instance Required smoke PASS twice (preserved:
smoke-20261001-221949, -222502). The CURRENT tree reproduces the same smoke
FAIL: transportState props sync ("transport ready" readable) but slot calls
(postMessage/echo) never dispatch once a gossipsub mesh peer exists.

### Bisect: 8 controlled rungs — ALL NEGATIVE (failure unchanged)
1. sync send restored (was async) — not it
2. M1-era 4-subscription set restored — not it
3. watchdog pings disabled + alive pinned — not it
4. dynamic libsodium interposition — ruled out (statically linked; `nm -gU`
   shows ZERO exported sodium/sqlite symbols — no interposition vector)
5. full process-clean slate — not it
6. post-start getNodeInfo removed — not it
7. **cross-thread callbacks → Qt::QueuedConnection marshalling** (the review's
   P0-1 hypothesis: delivery emits on its worker thread; store/QtRO from
   there destabilises the bridge) — compiles, CI 4/4, smoke still fails
8. **.rep glue regeneration delta** (retryPending SLOT removed, glue
   regenerated) — not it

CI integration stays 4/4 on this tree throughout (integ9–12) because the
sandboxed CI host runs WITHOUT a transport mesh — the defect needs a live
Delivery node + mesh peer. Conclusion: not any single controllable delta; the
failure tracks the compiled plugin's interaction with live Delivery event
emission in the two-instance shape. Next moves (review plan branches):
sidecar Delivery via logosctl, or defer/poll design, or ship with the in-app
transport explicitly regression-blocked while the forum GUI + CLI-protocol
legs carry the functional claims.

### Review-response ledger (2026-10-03, independent review findings)
- ev->id read before has_value (UB) — **FIXED** (check-first ordering)
- single m_lastSendRequest retry slot — **FIXED** (m_requestToEvent hash map)
- cross-thread callbacks — **FIXED** (QueuedConnection marshalling) — does
  not resolve the regression alone (rung 7)
- honest liveness — **RESTORED** (watchdog re-enabled post-handshake; CI 4/4)
- PINS.json digests — **FIXED** (all recomputed from local artifacts)
- STATUS/README drift — **FIXED** (76 checks, matrix counts, path)
- unlabelled reviewer reruns — **LABELLED** (evidence/m2-core/REVIEW-RERUNS.md;
  the two m2b-cli FAILs documented as a real reproducibility defect)
- OPEN from review: m2b-cli reproducibility (mesh-ready gating + rerun),
  N3/N4 measured-vs-by-construction, R08 clean retained-path rerun, the
  forum GUI (accounts/aliases/topics/replies — the biggest lever), organic use

## RESOLVED 2026-10-03 — older OPEN BLOCKER wording (superseded, kept for audit)

The M1-era tree ran the two-instance Required smoke PASS twice (preserved:
smoke-20261001-221949, smoke-20261001-222502 incl. recheck-own-node). The
CURRENT tree reproduces the same smoke FAIL: transportState props sync
("transport ready" readable) but slot calls (postMessage/echo) never dispatch
once a gossipsub mesh peer exists; the ui-host's slot-serving side dies
(logs end with `qt.remoteobjects: connectionToSource is null`; crash reports
show the upstream Delivery 0.3.0 trampoline SIGSEGV chain).

Six controlled A/B rungs on the current tree — ALL NEGATIVE (failure unchanged):
1. sync send restored (was async) — not it
2. M1-era 4-subscription set restored (had trimmed to 3) — not it
3. watchdog pings disabled + alive pinned true — not it
4. dynamic libsodium interposition — ruled out by otool (sodium/sqlite are
   STATICALLY linked into the plugin)
5. full process-clean slate (0 logos_host remainders) — not it
6. post-start getNodeInfo removed from configure — not it

Remaining untested delta: the .rep gained retryPending (glue regeneration) —
low mechanical plausibility (echo's signature is unchanged) but unproven either
way. CI integration stays 4/4 green on this tree (integ9/10/11) because the
sandboxed CI host runs WITHOUT a transport mesh — the regression needs live
Delivery node + mesh peer.

NEXT EXECUTABLE ACTION (M2b completion without the in-app slot path):
CLI-protocol durability leg — the harness signs posts with the same Ed25519
algorithm (python cryptography, cross-checked against core-tests), sends via
`logosctl call delivery_module send` on a CLI sender session, receives via
`logosctl watch` on the CLI receiver, verifies signature + content-derived ID +
exactly-once on retry (resending the ORIGINAL signed bytes from the durable
row). Combined with core-tests 63/0 (store-before-send reopen proof,
stored_event retry identity) and CI 4/4, this closes the durability/dedup
claims at the protocol layer while the in-app slot regression stays an open,
receipted blocker pending either the .rep A/B or an upstream fix.

## Historical slice — M2-GUI diagnosis (SUPERSEDED 2026-10-03: root cause
was the missing libsodium/sqlite link; see CURRENT STATE)

**M2-GUI — QtRO source-replica connection wedge (historical label; 3 LAYERS
DIAGNOSED 2026-10-03, misdiagnosis).** The earliest m5b framing as a "store-open wedge"
is wrong. The store is healthy. What fails in the dev launcher
(`logos-standalone-app 1.0.0`) is a 3-layer QtRO wedge:

- **L1 slot-return channel** — `capability_module` cannot bind its
  `eventResponse(QString,QVariantList)` signal
  (`Warning: QObject::connect: No such signal ::eventResponse(...)`), so
  any slot return value is computed on the source but never delivered to
  the QML replica.
- **L2 PROP-sync channel** — `set*` PROP updates on the source (e.g.
  `setAccounts` after a successful `createAccount`) do not propagate
  to the QML's `root.accounts` PROP. The QML's `root.status` PROP does
  reflect the initial `setStatus("Ready")` in `onContextReady`, so this
  is a post-initialization failure, not a complete PROP failure.
- **L3 QML→source slot dispatch** — even the trivial `echo("liveness")`
  and `createAccount("demo")` slots do not invoke on the source after
  the first slot call. The QML button click reports `"clicked": true`
  and the direct `evaluate(logos.watch(root.backend.createAccount(...)))`
  returns a `WatchHandle` JSON, but the source-side slot is never
  executed (host log shows zero invocations; SQLite `accounts` table
  stays empty). The wedge exists from the FIRST slot call (confirmed
  with `FORUM_SKIP_STAGE1=1` — skipping the slot-return wedge test
  doesn't unblock subsequent slots). The `qt.remoteobjects:
  connectionToSource is null` warning fires on the second inspector
  connect, which is the smoking gun for the dropped source-replica link.

This affects the dev launcher (`logos-standalone-app 1.0.0`) only; the
nix-sandboxed integration-test host (`run-standalone`) does NOT exhibit
the wedge — integration-25 passed 4/4 because the CI never relies on a
post-initialization slot call (it checks QML-local text + a post path
that uses `setStatus` PROP at the time of the initial handshake). The
fix is NOT a QML refactor (PROP-sync is also wedged) — it requires either
an upstream `capability_module` eventResponse/source-link fix, or a
substantial refactor of the source to dispatch all slots on a worker
thread with marshalled PROP updates through a different QtRO channel
that doesn't use `eventResponse`. Neither was in the 2026-10-03 session's
scope.

**Receipts — 2026-10-03 store_probe runs (`tools/store_probe.sh`,
`evidence/m5-package/store-probe-*`):**
- run 2026-10-03-193410 (`open` bisect, **pre-fix driver** —
  QML_INSPECTOR_PORT not yet exported; node client connected to the
  wrong port, host disconnected before any slot triggered — preserved
  for the driver-fix audit trail; wedge evidence is in the three
  later runs).
- run 2026-10-03-193834 (`precreated` bisect — precreate the db with
  `schema_version=1` + `General` topic row so the slot does NOT have to
  enqueue): SAME wedge. Rules out schema migration as a cause.
  `eventResponse_warnings: 2`, `getAvailableConfigs_calls: 1`.
- run 2026-10-03-193917 (`nowal` bisect — precreate + `journal_mode=MEMORY`
  + `synchronous=OFF`): SAME wedge. Rules out WAL/journal as a cause.
  `eventResponse_warnings: 2`, `getAvailableConfigs_calls: 1`.
- run 2026-10-03-194029 (final `open` baseline): SAME wedge. `result.json`
  carries `eventResponse_warnings: 2`, `getAvailableConfigs_calls: 1`, and
  the honest `gate_label: M2-GUI BLOCKED-with-receipts (QtRO back-channel
  wedge in dev launcher; store is healthy; CI integration-25 4/4 holds)`.
- run 2026-10-03-200529 (`FORUM_SKIP_STAGE1=1`): skipping stage 1 doesn't
  unblock stage 2 — the L3 wedge exists from the FIRST slot call.
- run 2026-10-03-200641 (`FORUM_SKIP_STAGE1=1`, repeat): same finding;
  stage 2 click reports `clicked: true`, slot never invokes, accounts
  table empty.
- run 2026-10-03-200826 (canonical `open` baseline with the
  3-stage probe): all three layers wedged. `wedge_layers_identified`
  carries L1/L2/L3 in the `result.json`.
- run 2026-10-03-202243 (latest canonical `open` baseline after probe
  doc/hygiene hardening): same L1/L2/L3 wedge, `layer:
  qtro-dev-launcher-wedge-probe`, `processes_remaining: none`,
  `port_freed: true`. This is the newest receipt and the matrix hash target.
- m5b run-10 (legacy framing, preserved): same wedge but the legacy
  `m5b_realhost_gui.sh` driver returns the WATCH HANDLE synchronously
  (`logos.watch(...)` returns a `WatchHandle` whose `.result` is undefined
  initially), so it never observed the slot's return even if the back-channel
  was working. The new `store_probe.sh` uses `findAndClick` + QML id globals
  + the actual `outcome.text` Text — the right pattern, and the wedge is
  the same there.

**Gate label: M2-GUI BLOCKED-with-receipts (store healthy, 3-layer QtRO
source-replica wedge in dev launcher; CI 4/4 holds; nix-sandboxed prod build
is unaffected).** CI suite stays store-optional green (4/4 battery13) + core
100/0 until an upstream source-link/eventResponse fix or a substantial
source-side refactor unblocks the dev-launcher path.

### P0-B / P0-C — 2026-10-03 (R08 + R05 reproducibility receipts)

**P0-B (R08) — clean retained-path rerun: PASS.** `evidence/m3-archive/
discovery-20261003-194327/result.json` — `status: "PASS"`, `discovery_path:
"store-query"` (the requested retained path), 4 claims met, 3 verified
posts, `oracle_match_current_run: true`. The live-propagation path stays
primary (2026-10-02 run 7); the retained-path leg now has a reproducible
quiet-host receipt, with the 2026-10-02 run-2 receipt preserved alongside.
Mismatch guard stayed failing closed throughout. Matrix regenerated
(R08 PASS, 4 receipts).

**P0-C (R05 reproducibility) — quiet-host attempt: FAIL (characterized).**
`evidence/m2-core/m2b-cli-20261003-194612` — `RuntimeError: sender node
never came up (no multiaddrs)`. Same load-sensitivity as the prior reviewer
reruns (REVIEW-RERUNS.md): Delivery 0.3.0 node formation is timing-sensitive
under any concurrent host activity; the loud gate refuses by construction
rather than emit an untrustworthy receipt. Per the plan: "Two consecutive
PASSes make R05 reproducible; otherwise keep the loud-gate characterization
and the preserved run-2 PASS" — the 2026-10-02-115420 PASS stands as the
sole reproducible protocol receipt; the 2026-10-03 FAIL is one more data
point on the OPEN reproducibility characterization, not a regression.
Matrix R05 demoted PASS → PARTIAL on this honest count; the durable outbox
claim still rests on the preserved 2026-10-02 PASS + core 76/0 (store-
before-send reopen proof, stored_event retry identity).

### M2b/GUI evidence chain 2026-10-03 (m5b runs 1-10 + store_probe runs, all diagnosed)
- run1-2: Basecamp inspector context has NO logos/root evaluate globals
  (property-based interaction only there — cleaninstall shape).
- run3: property-based on Basecamp — tile/view/Connected ✓; store-backed
  texts absent (store wedge, unknown then).
- run4-5: dev-launcher switch; run5 exposed `\\` env-continuation bug +
  port phantom; run6-7: port hygiene + ui-host sweep (inspector lives in
  the ui-host child, cmdline carries OUR plugin dir — never sweep
  logos_host broadly); run7 proved evaluate WORKS on the dev launcher
  (accounts: [] read returned); run8-9: FORUM_DB_PATH wiring + continuation
  fix; run10: props readable, store-touching slots wedge — the blocker
  above. Receipts: evidence/m5-package/realhost-gui-*/ .
- store_probe runs (corrected framing — see "Current slice" above): the
  m5b driver's `logos.watch(slotCall, ...)` idiom returns the WATCH HANDLE
  synchronously, not the slot result; the new `tools/store_probe.sh` uses
  QML id globals + actual QML-side observables (`outcome.text`, `root.accounts`,
  `root.threadPosts`) and now probes all three layers: slot return, PROP sync,
  and QML→source dispatch. It surfaces the SAME user-visible wedge with a
  precise 3-layer smoking gun (`eventResponse` missing, PROP updates absent,
  and `qt.remoteobjects: connectionToSource is null` with zero source-side
  `createAccount`/`echo` invocations). Bisect rungs `precreated` and `nowal`
  both show the same wedge, ruling out the planned WAL/migration/sodium
  hypotheses. Receipts: evidence/m5-package/store-probe-*/ .

**Sandbox CI GREEN**: integration-25 — 4/4 (UI loads, backend connects,
post-path honest refusal + composer retention, honest transport status) on
the PINNED closure. **Core: 100/0.** M0–M5 + M6-prep remain CLOSED; matrix
**10/5/0/1** (regenerated 2026-10-03 — R05 PARTIAL on reproducibility, R08
PASS with new retained-path receipt, R02/R03 wording tightened to reflect
the corrected M2-GUI diagnosis).
**M5 CLOSED** (clean-install PASS + evaluator materials, receipts below).
**M0–M5 CLOSED** — 11/12 milestones.
**Gate label: LOCAL_CANDIDATE_VERIFIED** — locally installed app (fresh
profile, both dependency packages) + all required local flows pass with
receipts. NOT SUBMISSION_READY: R15 catalog/video publication and R16 organic
use remain owner-approval/external gates.
**M0, M1-local, M2 core+integration+M2b CLOSED** (receipts below).
**M2b CLOSED via the CLI-protocol leg** (receipt below); the in-app QtRO
slot regression stays open as a UI-path item (blocker section) — M4 owns the
foreign-node fixture and full failure matrix.
**M0, M1 local, M2 core+integration CLOSED** (receipts below).

## Closed slices — receipts

### M0 (module loads through the real host) — CLOSED
- Hermetic UI suite **4/4** (integration-6): load, connect, post-path honest
  refusal + text retention, honest presence reporting.
- `.lgx` installed via real logosctl 0.3.1 (`status ok`); cleanup verified.
- Native Basecamp proves the module on BOTH flavors:
  - release dmg (isolated profile, pinned commits);
  - inspector nix host: tile `sidebar.app.forum_module`, view mounted,
    vision-verified screenshot, `Module loaded: delivery_module` on demand.
- Variant truth: release wants `darwin-arm64`, nix-dev wants `-dev`; both built.

### M1 (Required transport + usable post path, local) — CLOSED
- Typed dep gate: LIDL-derived wrappers compile; Storage privacy surface
  (`isPrivate`+`advertise`+`getAdvertise`) verified at type level.
- **Smoke PASS ×2** (`smoke-20261001-221949`, `smoke-20261001-222502`):
  4 loopback Mix relays + 2 app instances; sender Required send →
  `Message propagated via Mix` in the sender's OWN log (source-defined trace,
  not a config flag) → receiver rendered the post; re-probe confirms the
  app-owned node (coexistence guard honest branch); cleanup verified.
- Refusal negatives: no transport → visible refusal + composer text retained
  (hermetic + native Basecamp). Never a silent fallback.

### M2 (core + backend integration) — GREEN
- `nix build .#core-tests`: **76 checks, 0 failures** (evidence/m2-core/ + m3-archive/; 63 was the pre-archive-core count).
  Covers canonical IDs, Ed25519 sign/verify + tamper rejection, anonymous
  per-post identities, durable store-before-send (fresh-connection reopen),
  idempotent dedup, honest outbox states, bounds, accounts, and
  retry-preserves-identity (stored_event → same signed bytes → same ID).
  RED receipts preserved: missing includes; seed-vs-64-byte-secretkey bug.
- Integration suite **4/4** on the core-wired backend: durable enqueue runs
  before any send; refusal keeps composer text AND stores the row; honest
  presence/status reporting.
- Wire format frozen: `canonical-bytes ++ "\n" ++ signature-hex`; receivers
  re-verify via the core and dedup by verified event ID.

### M2b (durability) — CLOSED via CLI-protocol leg, 2026-10-02
`tools/m2b_cli.py` run 2 — **PASS**, evidence/m2-core/m2b-cli-20261002-115420:
- p1-wire-verified-independently: harness-signed canonical wire (RFC 8032
  Ed25519, encoding identical to src/core/forum_core.cpp) delivered over the
  real Delivery Required path (4 loopback Mix relays, validated topology),
  verified independently at the receiver (signature + content-derived ID,
  deliveries_seen=1).
- p2-required-failed-honestly-relays-down: messageError receipt with relays
  gone — no silent fallback at the protocol layer.
- p2-signed-wire-durably-retained: signed wire file re-verified after outage.
- p2-exactly-once-distinct-event-id + p2-original-signed-bytes-resent: after
  relays returned, sessions restarted (fresh locators — matches the upstream
  no-auto-redial finding) and the ORIGINAL bytes were resent; the delivered
  event id EQUALS sha256(original canonical) — asserted, deliveries_seen=1.
Composite with core-tests 63/0 (store-before-send reopen proof, retry identity)
and CI 4/4 (UI logic incl. honest refusals): the M2 acceptance claims are
receipted at every layer that could be exercised honestly.
M1-era in-app receipts (2 PASS smokes) remain valid for their tree.

### M3 storage lifecycle — CLOSED (runtime leg), 2026-10-02
Archive core: `nix build .#core-tests` → **76 checks, 0 failures** (inventory
sign/verify roundtrip, wrong-key + tamper rejection, coverage-shape refusal,
epoch+predecessor lineage). RED receipts preserved (missing include; probe
posts= parse bug).
`tools/m3_storage.py` run 11 — **PASS**, evidence/m3-archive/storage-20261002-163203
on the predecessor-qualified logosctl **0.3.0** (commit d9eb3ba, copied to our
state root; labelled honestly):
- two-archives-hold-verifiable-bytes + byte-exact-readback-both-archives (R07)
- non-author-inventories-signed-and-verified + archive-keys-distinct-from-author-key
  (R06/R07 — per-archive inventories, own Ed25519 keys, independently verified)
- private-upload-not-advertised-local-read-ok (R10 — getAdvertise()==false,
  local read still works)
- finite-ttl-expiry-positive-control + finite-ttl-refresh-restores-bytes (R11 —
  zero-TTL-not-permanent re-proven on v3.0.0; "1h" TTL is rejected by the
  v3.0.0 parser while 24h/30m/5m/2m/1m pass — probed)
- second-archive-verifies-after-one-loss (R09/R07 — archive A data dir wiped;
  B's inventory + readback still verify the corpus)

### M3 config pitfalls discovered (probed, recorded)
- logosctl **0.3.1**: storage module init fails cross-session (single storage
  instance per user at a time; second session's init → False, persists after
  the first stops). **Upstream finding** — M3 runs on 0.3.0.
- Storage module auto-inits from persisted `~/.logos_storage` — per-session
  HOME isolation is MANDATORY (predecessor runtime.py lesson).
- `logosctl watch storage_module` BEFORE init makes init return False — watch
  must start after init+start (A/B proven, config-probe5).
- `log-level` must be lowercase; `block-ttl: "1h"` specifically rejected.

### M3b discovery — CLOSED, 2026-10-02 (run 7 PASS + run 2 store-query PASS)
Run 7 (discovery-20261002-193242): **discovery_path=live-propagation** — the
fresh reader (ordinary relays only, nothing injected) received the signed
announce through the mesh, accepted the newest self-consistent chain, and
verified the full announce→CID→bytes→posts path (3/3 posts Ed25519-verified);
oracle_match_current_run=true. Claims: fresh-reader-discovered-cid-from-
signed-announce, runner-injected-no-cid-to-reader, reader-paged-retained-
announces, self-consistent-chain-announce-cid-bytes-posts.
Run 2 (discovery-20261002-171721) had already proven the RETAINED path:
bounded Store query retrieved the signed announce with no injected CID.
Both discovery paths now receipted. (Parser fix chain preserved: wire-pair
regex replaces naive newline splitting.)

### M3b discovery — earlier partial, 2026-10-02
PROVEN (discovery-run2, evidence/m3-archive/discovery-20261002-171721):
- fresh-reader-discovered-cid-from-signed-announce: the reader, bootstrapped
  ONLY on the ordinary relays (no CID/inventory/archive address injected),
  issued a bounded Delivery Store query to the archive peer and retrieved the
  retained SIGNED announce; signature verified, CID/inv_id matched the
  archive's records exactly.
- runner-injected-no-cid-to-reader (by construction + receipt).
Anomaly (runs 3-4, fail-closed): a fresh archive session's messaging.db
served PRIOR-RUN announces — delivery store retention/replay across sessions
on this release (upstream finding #3: per-session data isolation for
delivery store is broken; localStoragePath is per-run yet stale messages are
replayed to new subscribers). The mismatch oracle correctly REFUSED stale
content as this-run's result. Live-propagation window not yet observed.
NEXT M3B ACTION: accept any VALID epoch-N signed announce as a fresh reader
would (oldest-lineage acceptance is honest product behavior), verify the
discovered CID's bytes + posts end-to-end (self-consistent chain), and rerun
on a clean slate for the live-path receipt.

### M4 — CLOSED, 2026-10-02 (regenerated 2026-10-03)
- `docs/MATRIX.md` + evidence/m4-matrix/matrix.json: R01–R16 crosswalk with
  sha256-bound receipts. Summary regenerated 2026-10-03:
  **10 PASS, 5 PARTIAL, 0 BLOCKED, 1 NOT RUN** (R16 is the sole external
  gate; R15 PARTIAL — local clean-install + demo script done, publication/
  recording pending approval; R05 PARTIAL — protocol-layer reproducibility
  on 0.3.0 OPEN, preserved 2026-10-02 PASS still stands; R02/R03 PARTIAL
  wording tightened to reflect the corrected M2-GUI diagnosis). PARTIAL
  rows name the same cause: the open dev-launcher 3-layer QtRO source-replica
  wedge + pending publication.
- `tools/m4_negatives.py` run 2 — **PASS** (negatives-20261002-201355):
  N1 quota-pressure honest (dispatched but never verifiable bytes);
  N2 double-createNode — the coexistence-guard trigger VERIFIED at protocol
  layer (node exists after first create; second refused — exactly the state
  the in-app guard detects before visible refusal);
  N3 oversize transport vs app bound (4 KiB enforced at merge, 76/0);
  N4 replay collapse (distinct verified event IDs == 1; full proof in
  m2b-cli exactly-once receipt).

### M5 — CLOSED, 2026-10-02
- `tools/m5_cleaninstall.sh` run 3 — **PASS**: fresh .lgx build → fresh
  isolated profile → module + delivery/storage deps seeded in the real
  install layout → isolated Basecamp host (inspector) → tile clicked →
  module view rendered with honest states (Connected / Backend Ready /
  transport refusal visible) → zero processes remaining, port freed.
- Evaluator materials: README.md (exact build/install/use commands, honest
  labels, known limitations), docs/FURPS.md (FURPS lens over the matrix),
  tools/demo_walkthrough.sh (recording-ready 10-scene walkthrough over the
  REAL harnesses; recording itself needs owner consent).
- Matrix regenerated: **11 PASS, 4 PARTIAL, 0 BLOCKED, 1 NOT RUN** (R16 the
  sole external gate; R15 PARTIAL — local clean-install + demo script done,
  publication/recording pending approval).

### M6 — recheck + bundle, 2026-10-02
- Live authority recheck (read-only, gh api): master **7a52d8f0… unchanged**;
  LP-0026.md blob cdc419ae… unchanged; PR #168 open/unmerged (6c0e9ecc…);
  PR #173 merged at the pin; Basecamp 0.3.1 / module-builder 0.3.2 /
  logosctl 0.3.1 still current. Prize OPEN — investment direction stands.
- Owner approval list (kept outside the repo): A0 (done) → A7, each with exposure/budget/stop
  conditions; sequencing recommended; nothing executed.
- .github/workflows/ci.yml prepared (core on ubuntu, UI+package on macOS) —
  activates only on push (A2/A3 approval).
- Honest closure state: LOCAL_CANDIDATE_VERIFIED held with receipts; the
  build program (M0–M5 + M6 preparation) is complete. Remaining execution is
  owner-gated: commits/push/CI/catalog/video/public-testnet/organic-use.

## Remaining

See CURRENT STATE at the top. The pre-M2 "Remaining / Processes / Next"
lists that stood here were stale and are replaced, not extended.

## Upstream findings (recorded, NOT published — contact needs owner approval)

- **Delivery 0.3.0 generated event trampoline SIGSEGV**: faulting chain
  `DeliveryModuleImpl::connectionStateChanged` → `event_callback` →
  `ffi_events::notifyListeners` → `lidlEnsureEmitWiring` →
  `DeliveryModuleCdylibProvider::emitTrampoline` → `ModuleProxy` ctor →
  `QObject::thread()` null deref (EXC_BAD_ACCESS @0x77). Correlates with
  multi-node connection churn killing a consumer ui-host MID-SESSION; crash
  reports also cluster at teardown. Consumers see a zombie UI: property reads
  answer from stale replica state while slot calls vanish. Our mitigations:
  minimal subscription set (dropped onMessageSent), QML liveness watchdog with
  honest "Backend unresponsive" surfacing, restart-resilient durability flow.
  Evidence: ~/Library/Logs/DiagnosticReports/logos_host-*.ips +
  evidence/m2-core/outbox-*/ sender logs + probe3/probe4 receipts.

## Exposures (disclosed, bounded)

- Stock hosts auto-bootstrap storage onto public logos.test (no data written
  by us; NAT failed, nothing announced). Our app: explicit local config only.
- nix-built storage fails init ("Should create metadata store!") — upstream
  packaging finding; dmg storage works; M3 pins a working path.
- Public-network qualification (real testnet Required send, independent hosts)
  = external approval gate, not started.

## Processes

None owned by this project running at closeout (see the closeout entry
below for the check).

## Session closure — 2026-10-03 (afternoon)

**Built:** `tools/store_probe.sh` (proper bounded 3-layer QtRO wedge probe —
port hygiene, ui-host sweep, no inline `&`, three bisect rungs,
`FORUM_SKIP_STAGE1=1` contamination check, exports `QML_INSPECTOR_PORT`
for the MCP framework, QML id globals and QML-side observables instead of
`logos.watch` WATCH HANDLE). `tools/m4_matrix.py` extended to pick up
newest PASS m2b-cli and m3-discovery receipts, dynamically count
store_probe receipts, and demote R05 to PARTIAL on honest reproducibility
failure. README + `tools/verify.sh` now expose `store-probe` as a named
local verifier whose process PASS is separate from the product gate.

**Continuation hardening 2026-10-03 20:22:** cleaned stale "QML refactor /
back-channel only" wording across README, STATUS, internal notes,
`tools/demo_walkthrough.sh`, `tools/verify.sh`, and
`tools/store_probe.sh`; reran `./tools/verify.sh store-probe` and generated
`evidence/m5-package/store-probe-20261003-202243/result.json` (PASS as a
clean evidence run, `gate_label: M2-GUI BLOCKED-with-receipts`, `layer:
qtro-dev-launcher-wedge-probe`, `processes_remaining: none`, `port_freed:
true`). Regenerated `docs/MATRIX.md` / `evidence/m4-matrix/matrix.json` —
still **10 PASS, 5 PARTIAL, 0 BLOCKED, 1 NOT RUN**, now with **8**
store_probe receipts and the latest result hash bound.

**Measured:** P0-B PASS (`discovery-20261003-194327` retained-path
quiet-host rerun, `discovery_path: "store-query"`, 3 verified posts,
`oracle_match_current_run: true`). P0-C FAIL (`m2b-cli-20261003-194612`
`RuntimeError: sender node never came up (no multiaddrs)` — same
load-sensitivity as the prior reviewer reruns; loud gate refused by
construction). P0-A M2-GUI: store proven healthy via three bisect
rungs (open / precreated / nowal) all showing the SAME wedge with the
SAME smoking gun (`QObject::connect: No such signal ::eventResponse(...)`
in capability_module; slot ran but return never delivered). Diagnosis
then **deepened to 3 layers** (L1 slot-return, L2 PROP-sync, L3
QML→source slot dispatch — even trivial `echo` never invokes on the
source, confirmed by `FORUM_SKIP_STAGE1=1` runs that skip the slot-return
wedge test and STILL see no slot dispatch). Smoking gun for L3:
`qt.remoteobjects: connectionToSource is null` on the second inspector
connect + zero source-side invocations for `createAccount`/`echo` even
when the QML click reports `"clicked": true`.

**Remaining / blocked:**
- M2-GUI dev-launcher 3-layer QtRO source-replica wedge — requires
  either an upstream `capability_module` eventResponse/source-link
  fix, or a substantial refactor of the source to dispatch all slots
  on a worker thread with marshalled PROP updates through a different
  QtRO channel that doesn't use `eventResponse`. Not in this session's
  scope. 8 receipts in `evidence/m5-package/store-probe-*/` (3 bisect
  rungs + 2 SKIP_STAGE1 confirmations + 3 canonical baselines) +
  `evidence/m2-core/REVIEW-RERUNS.md`. CI integration-25 4/4 holds;
  nix-sandboxed prod build is unaffected.
- P1 mesh-churn branch (b) — defer createNode/subscribe to first
  post/recheck. Per the plan: "only after P0s land." P0-A did not
  land a fix (the cause is not branch-(b)'s hypothesis; branch-(b) is
  about avoiding the wedge, but the wedge is deeper than the original
  framing). P1 stays queued. Skipped by design.
- R05 reproducibility (M2b CLI on 0.3.0) — third independent data
  point in the same direction; preserved 2026-10-02-115420 PASS
  stands; matrix demoted PASS → PARTIAL on this honest count.
- A1–A7 owner-gated (commits / push / CI / catalog / video /
  public-testnet / organic use) — unchanged, no execution.

**Honest gate label: LOCAL_CANDIDATE_VERIFIED** held; the M2-GUI
corrected diagnosis makes the receipt chain more honest, not less.
The build program (M0–M5 + M6 preparation) remains complete; remaining
execution is owner-gated.

## Closeout — 2026-10-03 evening (M2-GUI root cause + final-tree receipts)

**Built:** `CMakeLists.txt` (`LINK_LIBRARIES sqlite3 sodium`), `flake.nix`
(store-backed `integration-test` via `FORUM_DB_PATH`), `src/core/forum_core.{h,cpp}`
(`ensure_default_topic`; `merge_verified` keeps the signed ts),
`src/forum_module_backend.{h,cpp}` (per-profile store, shared General,
outbox count, app-owned-node confirmation), `src/qml/Main.qml` (ids,
identity box follows backend), `tests/core/test_main.cpp` (shared default
topic test), `tests/ui-tests.mjs` (4 → 8 tests), harness fixes in
`tools/{store_probe.sh,m1_ui_driver.mjs,m1_run.sh,m1_topology.py,m2b_cli.py,m4_negatives.py,m4_matrix.py,m5_cleaninstall.sh}`.

**Final-tree receipts:** core-tests 116/0 (`linkfix/core-tests-final.txt`);
integration 8/8 (`linkfix/integration-final.log`); store-probe
`20261003-214233` M2-GUI PASS; smoke `20261003-214415` PASS; negatives
`20261003-214548` PASS; cleaninstall `20261003-212919` PASS
(store_flow_in_real_host); m2b-cli `-211708`/`-212136` PASS ×2; portable
`.lgx` bundles libsodium/libsqlite via `@loader_path`
(`linkfix/plugin-linkage-portable-final.txt`). Failures kept and labelled
in `evidence/m2-core/REVIEW-RERUNS.md` (closeout section).

**Cleanliness at closeout:** ports 3768/3769/3770/3771/3789 free; no
lp0026-forum-dev / standalone-ui / logos_host / ui-host / logosctl
processes. `result*` symlinks are build outputs (gitignored).

**Gate:** LOCAL_CANDIDATE_VERIFIED. Not NETWORK_QUALIFIED (no public
testnet or independent host); A1–A7 owner-gated, none executed.

## Submission prep — 2026-10-03 night

**Built:** identity options in the `.rep`/backend/QML (`hideAlias`,
`selectedUid`, `aliasHidden`; thread rows render `alias · id <16hex>` or
`id <16hex>`; the identity line states linkability before posting);
`connectNetwork()` + "Connect to Logos network" button (logos.dev preset,
anonymity Required; a `FORUM_TRANSPORT_CONFIG` file still takes precedence);
thread header shows the topic title; `tests/ui-tests.mjs` 8 → 10 tests
(identity modes; network join offered, not automatic); harness Python
defaults to `python3`/`sys.executable` with a `cryptography` preflight, plus
`.#harness-python` in the flake; hard-coded home paths removed from
`tools/m1_topology.py` and `tools/store_probe.sh`; CI installs Nix with the
Logos binary cache and runs a harness syntax step; matrix rows R06–R11/R13
labelled "harness layer, not in-app"; `docs/CONTRACT.md` frozen for v0.1.0
(view + event contract); README install/connect/identity/limitations.

**Receipts:** integration 10/10 (`linkfix/integration-connect-2.log`;
`integration-connect.log` 9/1 FAIL preserved — the connect button hid after
a refused post changed the status text; fixed by showing it whenever the
transport is not ready); store-probe `20261003-223325` PASS; cleaninstall
`20261003-223452` PASS; smoke `20261003-223623` PASS; `.lgx-portable`
rebuilt rc 0. Linux `lgx-portable`/`core-tests`/`integration-test`
derivations evaluate for x86_64/aarch64 but are unbuilt (no Linux builder).

**Open (owner decisions):** live logos.dev test of the connect action
(public network); catalog fork + publication, remote CI, video (A1–A5);
in-app history via `delivery_module.storeQuery` not implemented; 14 raw
logs contain an absolute local tool path and are left unedited
(preserve-evidence rule).

**Gate:** LOCAL_CANDIDATE_VERIFIED (unchanged).

## 2026-10-04 — live network, history, redesigned UI, Linux

**Built:** the app waits for Delivery's connection status before sending
(posts written earlier are stored as *waiting to send* and go out on
connect; failed sends retry automatically at most 3 times, 15/30/60 s);
"Load older posts" queries a logos.dev store node for the forum's last 7
days (paged, at most 10 pages of 50, every event verified before storing);
the view was redesigned for Basecamp's light panel (connection chip, post
cards with author, state and time, composer with character count).

**Live receipts (public logos.dev, Mix required):** `m6-live/live-20261004-141425`
PASS (post written before the connection was ready, sent automatically,
received by the second instance, 0 manual retries); `m6-live/history-20261004-141441`
PASS (reader started after the author quit: 1 post via catch-up, "Load older
posts" loaded 9 messages, 8 posts in total). Earlier PASS runs kept:
live-122221 (needed 1 manual retry — the reason the connection wait was
built), live-124131, live-131857, history-122454, -124153, -132033.

**Regression on the final tree:** core 129/0 (`linkfix/core-tests-tsfix.txt`);
integration 10/10 (`linkfix/integration-tsfix.log`); store-probe
`20261004-141055`, cleaninstall `20261004-141106`, smoke `20261004-141232`
all PASS; `.lgx-portable` rc 0.

**Bug found by the Linux build:** locally written posts were stored with
time 0 (enqueue bound 0 instead of the signed time), so on Linux they sorted
first — `linux-20261004-133301` core 3 failures, preserved. Fixed in
`forum_core.cpp` (bind the signed time; repair old rows on open) with a
regression test; macOS and Linux both 129/0 since.

**Linux (aarch64-linux, nixos/nix container):** core-tests 129/0 and
`lgx-portable` build (`linux-20261004-140311`). The UI integration build
was killed (exit 137) in all five runs (`linux-20261004-122008`, `-133301`,
`-140311`, `-141049`, `-141420`): first at 2 jobs × 12 cores, then at
2 × 4, 1 × 2, 1 × 2 with 2 downloads, 1 × 1. `-141420/container-memory.log`
shows the container passing 5 GB at the first Qt compile, with ~5.3 GB free
in the 8 GB Docker VM (another long-running container holds the rest).
Not resolved; needs a larger Docker VM or a Linux host.

**Docs:** README, CONTRACT, FURPS, MATRIX (R01–R17: 14 PASS / 2 PARTIAL /
0 BLOCKED / 1 NOT RUN) updated. Publication copy is produced by a staging
step that normalises local paths in evidence text into `<repo>`/`~` and
lists every change in `evidence/REDACTIONS.md`; raw files here stay
unedited.

**Open (owner decisions):** publish repo, catalog entry, remote CI, video,
organic use (R16); Docker VM memory for the Linux UI build.

**Gate:** LOCAL_CANDIDATE_VERIFIED (unchanged; nothing published).

## 2026-10-04 evening — rotation, search, Storage snapshots, Linux

**Built:** alias key rotation — **New key now**, every 5/10/25/100 posts,
and/or daily/weekly/monthly (an over-age key is replaced before it signs the
next post; state persists per profile); topics ordered by latest activity
with unread counts (local read markers); local search over titles, post
text and authors; paced sending (burst 5, then one per 2 s, including the
outbox flush on reconnect); stacked layout below 760 px; **Save snapshot /
Restore these posts** on Logos Storage (the snapshot holds the same signed
wire events; announcement signed with a one-time key and sent through Mix;
every restored event re-verified; ≤1000 events / 4 MiB).

**Bugs found and fixed while testing (receipts kept, each with NOTE.txt):**
- `m7-storage/snapshot-20261004-174350` FAIL: stored post fields kept the
  canonical escapes (a multi-line post was stored with a literal `\n`), so
  the snapshot announcement could not be parsed. Fixed with a strict
  canonical parser (exact fields in order, unescaped; reordered/extra/
  duplicate fields, unknown escapes and raw `|` are invalid even with a
  valid signature) + regression test.
- `-175512` FAIL: test driver picked an earlier run's announcement that the
  fresh profile had received from the network's store; driver fixed.
- `-180425` FAIL: `storage_module.downloadToUrl` blocks while it fetches the
  manifest (up to 30 s + 30 s in the module source) and the default module
  call times out at 20 s; now called asynchronously with a 75 s timeout.
- `-183428` FAIL: Storage `connect()` only starts a dial; the download could
  start before the dial completed ("Key doesn't exist" after 10 manifest
  attempts). The app now waits for the `storageConnect` outcome and re-dials
  up to 3 times.
- UI test race (offline snapshot test re-sent a call between polls) fixed;
  `integration-features-2.log` (12/1) preserved.

**Storage receipts on the final tree:** `snapshot-20261004-184209` PASS
(5 new, 0 rejected) and `-185554` PASS (2 new, 0 rejected); reader stayed
offline from Delivery in both. Earlier PASS `-180949` (before the dial fix).
`-184509` FAIL: the announcement stayed pending — public logos.dev Mix sends
were failing in that window (Delivery "Failed to send message", posts took
332 s); not an app defect. Storage nodes run on loopback on one machine;
cross-machine fetch through NAT is not receipted (README limitation 4).

**Regression on the final tree:** core 177/0 (`linkfix/core-tests-age-1.log`),
UI 13/13 (`linkfix/integration-final-tree-2.log`), store-probe
`20261004-190334`, cleaninstall `-190345`, smoke `-190445` PASS; live
`-182756` PASS; history `-185910` PASS (`-182833` FAIL: public Mix sends
failing for the whole retry budget; the app stopped after 3 automatic
retries and kept the post, as designed).

**Linux:** `linux-20261004-191439` — aarch64-linux, core 177/0, UI suite
13/13, `lgx-portable` adds the `linux-arm64` variant. The earlier exit-137
kills were the `nix` process holding the evaluation heap while building;
`tools/linux_build.sh` now evaluates to a `.drv` and realises it in a fresh
process. `linux-20261004-144950` (GitHub unreachable during evaluation) and
`-145929` (stopped by operator during a stalled download) are kept.

**Tooling:** `tools/m7_storage.sh` (+ `verify.sh storage`); `tools/ui_tour.mjs
--features` (screens in `m5-package/ui-tour-20261004-191248`); CI workflow
now runs core + UI + package on Linux and uploads the `.lgx` files.

**Gate:** LOCAL_CANDIDATE_VERIFIED (unchanged; nothing published).

## 2026-10-04 night — release app, Windows packaging, polish

**Release app.** `tools/demo_profiles.sh` unpacks the pinned Basecamp 0.3.1
dmg and makes fresh profiles with the release Forum package plus the pinned
dependency packages, laid out as Package Manager installs them. In the
release app the module loads (`m5-package/release-app-20261004/before-R2`),
but the store only opened on the first user action, so a reopened profile
showed no saved topics until a click. Fixed: the view asks the backend once,
300 ms after it reports ready (outside the handshake window). After the fix
the store is created ~10 s after launch with no interaction (`after-R3`).

**Polish.** Status lines say "1 post" / "3 posts", "rotated 2 times" (no
"(s)"); rotation menus read *Rotate every 5 posts* / *Rotate weekly*; the
transport line and Check/Re-check buttons are behind **Network details**.
UI test adjustments and their failures are kept in `polish-20261004/`
(`integration-toggle-1..5-FAIL`: a visibility race, a substring match
"Check transport" ⊂ "Re-check transport", and a headless window that never
lays out newly shown items, so a synthesised click hit the wrong button —
the test now emits the button's `clicked()`); final `integration-toggle-6`
13/13 and `integration-storeopen-7` 13/13; core 177/0.

**Windows.** CI job `windows` builds `packages.x86_64-windows.lgx-portable`
(mingw cross build on x86_64 Linux); job `all-platforms` merges the macOS,
Linux and Windows packages with the official `lgx` tool and checks all
variants are present. Local attempts under x86 emulation on Apple silicon
all failed, receipts kept: `linux-amd64-20261004-202135` (evaluation stack
overflow), `-204935` (same with unlimited stack), `-205124` (host-side
evaluation worked; Qt `repc` SIGSEGV under emulation). A local merge of the
macOS and Linux packages verifies (darwin-arm64 + linux-arm64).

**Linux on the final tree:** `linux-20261004-211318` — aarch64-linux, core
177/0, UI 13/13, `lgx-portable` (`linux-arm64`).

**Final-tree macOS receipts (tools changed for the Network details toggle):**
store-probe `20261004-212309` (M2-GUI PASS), cleaninstall `-212332` PASS
(`details_opened: true`), smoke `-212552` PASS (Required send propagated,
rendered at the receiver, re-check confirmed own node). Local merge of the
macOS + Linux packages: `merge-20261004` (verifies, both variants).

**Gate:** LOCAL_CANDIDATE_VERIFIED (unchanged; nothing public).

**Windows fix (found by CI).** The first private CI run (Linux and macOS
green) failed the Windows cross build: the per-profile store lookup used
POSIX `dladdr` (`<dlfcn.h>`). It now uses `GetModuleHandleExW` +
`GetModuleFileNameW` on Windows; the next CI run builds windows-x86_64.
Re-verified after the fix: macOS UI 13/13 (`integration-win32fix-9`),
release app (`release-app-20261004/after-R5-win32fix`), Linux
`linux-20261004-214743` (core 177/0, UI 13/13, lgx). Package metadata now
names the author and has a plain description. `linux-20261004-214036` was
stopped by the operator (started before the fix; kept).

**CI (private repo):** run 37229652457 on `fd8b57d` — linux, macos, windows
and all-platforms all green. The Windows package and the merged package
(darwin-arm64 + linux-amd64 + windows-x86_64) verify with the lgx tool;
the Windows plugin imports the same host runtime DLLs as the official
delivery_module (`m5-package/ci-windows-20261004`). Not yet run on Windows.

## 2026-10-06 — Windows in CI, offline posts wait, README images

**Windows (CI job `windows-basecamp`, `tools/windows_smoke.sh`).** On a
`windows-latest` runner (a real desktop session), the official Basecamp 0.3.1
Windows installer (NSIS, sha256 `fd4488e8…`) is unpacked, a fresh
`--user-dir` is seeded with the Forum package and the pinned
delivery_module 0.3.0 / storage_module 3.0.0 packages, and Forum is opened
with `--uri`. The script then drives the window with clicks and keystrokes:
writes a labelled test post while offline, connects to logos.dev and waits
for the store to mark the post sent (Mix only). Trial runs on a scratch
branch: 37442253129 (artifact permission), 37442347321 (Git Bash hash
prefix), 37442435495 (Windows path given to tar) failed on harness bugs;
37442559967 PASS (store opens after 9 s; screenshot); 37442786178 the store
check passed but the click on Send missed (the button moves when text is
entered) — its screenshots showed the two UX faults below; 37443584000
PASS: post written offline, sent through Mix 5 s after Connect. Receipts:
`evidence/m8-windows/`.

**Offline posts wait instead of failing** (`src/forum_module_backend.cpp`):
before the user connects, a post is signed, stored as pending (*waiting to
send*) and `postMessage` returns `queued`; the UI says "Saved — it will be
sent through Mix as soon as you are connected." and clears the composer.
Previously it was stored as failed and its text also kept in the composer,
so a second Send would have posted it twice. A local store error still
refuses and keeps the text. The "Connecting…" hint is replaced once
connected, and **Retry stored** appears only when connected
(`src/qml/Main.qml`). Tests and harnesses updated (`tests/ui-tests.mjs`,
`tools/m5_cleaninstall.sh`, `store_probe.sh`, `m5b_realhost_gui.sh`).
`store_probe.sh` now rebuilds `#ui-dev` first: one run used a launcher built
on 2026-10-04 and probed old code (`store-probe-20261006-114102`, NOTE).

**Receipts (final tree):** `m5-package/polish-20261006/` (core 177/0; UI
13/13 in `integration-retry-visible-3.log`; an earlier 12/13 was a test
assertion bug, kept), `store-probe-20261006-*` PASS, `cleaninstall-20261006-115418`
PASS, `ui-tour-20261006/` (offline + live tours; README images come from
here; the live tour on macOS received the Windows CI test post).

**CI (main, c6c04df): run 37446511273 green** — linux, macos, windows,
windows-basecamp, all-platforms (`evidence/m8-windows/ci-main-37446511273/`:
the fixed Windows package, sha256 `b8fe2c06…`, shows *waiting to send* with
an empty composer, then *sent* through Mix 6 s after Connect).

**Install wording corrected:** Basecamp 0.3.1 adds repositories under
Settings → Package Repositories (*Add a repository*; Package Manager links
there with **Manage Repositories**) and installs files with **Install Local
Package** — checked against the app's own QML.

**Gate:** LOCAL_CANDIDATE_VERIFIED (repos going public; no submission yet).
