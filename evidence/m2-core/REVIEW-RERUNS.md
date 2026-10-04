# Review reruns — independent reviewer, 2026-10-02 (labelled after the fact)

An independent review pass reran
harnesses against this tree on 2026-10-02 ~23:00-23:45. Their runs produced
evidence directories that were initially unlabelled. Labels:

## m2b-cli-20261002-233952 and -234241 — reviewer reruns, **FAIL**
- Error: `P1 not verified on the wire: {'verified': False, 'reason':
  'deadline', 'deliveries_seen': 0}` — the Required send/receive leg did not
  deliver within the window on their reruns (their report also cites an
  "Unable to send within retry time window" send response).
- Interpretation: the 2026-10-02-115420 PASS is NOT reliably reproducible as
  written — a genuine reproducibility defect. Candidate causes: mesh-ready
  gating absent before send (the same readiness race fixed in m2b v2), relay
  timing, or session-state sensitivity on 0.3.0.
- Status: OPEN — the durability claim rests on (a) this non-reproducible
  protocol run, (b) the deterministic core receipts (store-before-send
  reopen proof, stored_event retry identity — 76/0), and (c) CI 4/4. The
  protocol leg must be hardened (mesh-ready gate + longer bounded waits) and
  re-run to a reproducible PASS before R05's protocol column is claimed as
  reproducible.

## m4-matrix/negatives-20261002-234524 — reviewer rerun, **PASS**
- Independent reproduction of the N1–N4 negatives (quota honest-failure,
  coexistence trigger, oversize bound, replay). Corroborates
  negatives-20261002-201355.
- Caveat carried from the original finding: N3/N4 verdicts contained
  hard-coded literals (m4_negatives.py) and N4 observed 0 deliveries — those
  cases are "by construction"/unit-backed, not fully measured at the
  transport layer. Fix tracked in the review response.

## m5-package/cleaninstall-20261002-205210 — reviewer rerun, PASS
- Independent reproduction of the clean-install flow.

## Hardening reruns — 2026-10-03 (author, review response)
- `m2b-cli-20261003-105639` / `-110729` — **FAIL, loudly**: mesh-ready gates
  added (node-up via supported getNodeInfo keys + warm-up + one bounded
  original-bytes resend). Both refused explicitly: first on a wrong-key query
  (PubsubPeers does not exist in Delivery 0.3.0 — supported keys are
  Version/Metrics/MyMultiaddresses/MyENR/MyPeerId), then on "sender node
  never came up (no multiaddrs)". Characterization: 0.3.0 session node
  formation is timing-sensitive under concurrent heavy builds; sends into an
  unformed mesh are now IMPOSSIBLE by construction — the harness refuses
  rather than emits a receipt that can't be trusted. The 2026-10-02-115420
  PASS stands as a preserved receipt; reproducibility on 0.3.0 remains OPEN
  pending calmer-host reruns or a supported peers key.
- `negatives-20261003-110052` / `-111034` — **PASS** with honest relabelling:
  N3 = BY-CONSTRUCTION (unit-backed bounds receipt, not a transport
  measurement); N4 wired session-to-session for measurement, but 0.3.0
  createNode with staticnodes returned None under load → N4 verdict degrades
  to BY-CONSTRUCTION unless deliveries are actually observed.

Author's note: this file exists because unlabelled evidence is a hazard.
Every run in this tree carries status + interpretation or it does not ship.

## M2-GUI store_probe runs — 2026-10-03 (author)

The earliest m5b framing as a "store-open wedge" is wrong. The store is
healthy. What wedges in the dev launcher (`logos-standalone-app 1.0.0`)
is a **3-layer QtRO source-replica connection wedge** — receipted across
8 probe runs in `evidence/m5-package/store-probe-*`:

- **L1 slot-return channel** — `capability_module` cannot bind its
  `eventResponse(QString,QVariantList)` signal, so any slot return value
  is computed on the source but never delivered to the QML replica.
- **L2 PROP-sync channel** — `set*` PROP updates (e.g. `setAccounts`) do
  not propagate to the QML's `root.accounts` PROP after the initial
  handshake. The QML's `root.status` PROP does reflect the initial
  `setStatus("Ready")`, so this is a post-initialization failure.
- **L3 QML→source slot dispatch** — even trivial `echo`/`createAccount`
  slots do not invoke on the source after the first slot call. The QML
  button click reports `"clicked": true` and the direct
  `evaluate(logos.watch(slotCall))` returns a `WatchHandle`, but the
  source-side slot is never executed (host log shows zero invocations;
  SQLite `accounts` table stays empty). Confirmed by
  `FORUM_SKIP_STAGE1=1` runs — the wedge exists from the FIRST slot
  call, not caused by stage 1 contamination.

**Run-by-run receipts:**

- **store-probe-20261003-193410** — `open` bisect (baseline). **Pre-fix
  driver run:** QML_INSPECTOR_PORT env was not yet exported, so the
  inspector client connected to the wrong port and the host disconnected
  before any slot was triggered. Preserved for the driver-fix audit
  trail only; the wedge evidence is in the three later runs.
- **store-probe-20261003-193834** — `precreated` bisect (precreated
  empty db with `schema_version=1` + `General` row, so the slot does
  NOT have to enqueue). **Same wedge.** Rules out schema migration.
  `host_smoking_gun.eventResponse_warnings: 2`,
  `getAvailableConfigs_calls: 1`.
- **store-probe-20261003-193917** — `nowal` bisect (precreated +
  `journal_mode=MEMORY` + `synchronous=OFF`). **Same wedge.** Rules
  out WAL/journal.
- **store-probe-20261003-194029** — final `open` baseline. **Same
  wedge.** `result.json` carries the honest gate label `M2-GUI
  BLOCKED-with-receipts (QtRO back-channel wedge in dev launcher; store
  is healthy; CI integration-25 4/4 holds)`.
- **store-probe-20261003-200529** — `FORUM_SKIP_STAGE1=1` (skip the
  slot-return wedge test; go straight to PROP-sync test on a fresh
  source). **STILL wedges** — stage 2 click reports `clicked: true`,
  slot never invokes, accounts table empty. This is the L3 finding:
  the wedge exists from the FIRST slot call.
- **store-probe-20261003-200641** — `FORUM_SKIP_STAGE1=1` repeat.
  Same finding; stage 2 click reports `clicked: true`, button
  `enabled: true`, textfield `text: "demo"` set successfully via
  `setProperty`, but slot never invokes, accounts table empty.
  `eventResponse_warnings: 0` (the slot didn't even reach the
  capability_module — it's a QML→source dispatch issue, not a
  cross-module issue).
- **store-probe-20261003-200826** — canonical `open` baseline with the
  3-stage probe. All three layers wedged. `wedge_layers_identified`
  carries L1/L2/L3 in the `result.json`.
- **store-probe-20261003-202243** — latest canonical `open` baseline after
  probe doc/hygiene hardening. Same L1/L2/L3 wedge; `layer:
  qtro-dev-launcher-wedge-probe`, `processes_remaining: none`,
  `port_freed: true`. This is the newest matrix/hash target.

The legacy `m5b_realhost_gui.sh` driver returns the WATCH HANDLE
synchronously (`logos.watch(slotCall, ...)` returns a `WatchHandle`
whose `.result` is undefined initially), so it never observed the slot's
return even if the back-channel was working. The new `store_probe.sh`
uses QML id globals + the actual `outcome.text` Text — the same path
the user clicks — and surfaces the wedge with a precise smoking gun.

**Fix requires** either an upstream `capability_module`
eventResponse/source-link fix, or a substantial refactor of the source
to dispatch all slots on a worker thread with marshalled PROP updates
through a different QtRO channel that doesn't use `eventResponse`.
Neither was in that session's scope. CI integration-25 4/4
holds; the nix-sandboxed prod build is unaffected. The probe script is
reusable for any future re-attempt:
`FORUM_BISECT=open|precreated|nowal bash tools/store_probe.sh`.

## m3-discovery retained-path rerun — 2026-10-03 (author)

- **discovery-20261003-194327** — quiet-host rerun, **PASS**.
  `discovery_path: "store-query"`, 4 claims met, 3 verified posts,
  `oracle_match_current_run: true`. Run 7 (live propagation) stays the
  primary receipt; the retained-path leg now has a reproducible
  quiet-host receipt with the 2026-10-02 run-2 receipt preserved
  alongside. Mismatch guard stayed failing closed throughout.

## m2b-cli quiet-host attempt — 2026-10-03 (author)

- **m2b-cli-20261003-194612** — quiet-host attempt after the
  m3-discovery run completed (no concurrent nix builds; host was
  actually quiet). **FAIL** with `RuntimeError: sender node never came
  up (no multiaddrs)`. Same load-sensitivity characterization as the
  2026-10-03-105639 / -110729 hardening reruns: Delivery 0.3.0 session
  node formation is timing-sensitive; the loud gate refuses by
  construction rather than emit an untrustworthy receipt. The
  2026-10-02-115420 PASS stands as the sole reproducible protocol
  receipt; reproducibility on 0.3.0 remains **OPEN** with this third
  independent data point.

## Closeout reruns + corrections — 2026-10-03 evening (author)

**Correction to the M2-GUI section above (kept verbatim for audit):** the
"3-layer QtRO source-replica wedge" was a misdiagnosis. lldb on the ui-host
(`evidence/m5-package/linkfix/lldb-uihost-root-cause.txt`) shows a SIGSEGV
in the first `KeyPair::generate()` → null `sodium_init`: the builder links
plugins with `-undefined dynamic_lookup` and does not forward
`extra_link_libraries`, so libsodium/sqlite were never linked
(`plugin-linkage-before.txt` vs `-after.txt`). L1/L2/L3 were all symptoms
of a dead source process. Fix: `LINK_LIBRARIES sqlite3 sodium` in
`CMakeLists.txt`. Negative control: the store-backed suite without the fix
is 2 passed / 6 failed (`linkfix/integration-negative-control-no-link.log`).

Labelled runs:

- **store-probe-20261003-205003, -205428** — gate `M2-GUI FAIL`, evidence
  run clean. Probe harness defects, not product: stage-3 substring click
  hit "Alias created" instead of the topic button; stale "alias already
  exists" outcome text read as the stage result. Fixed (id click, outcome
  cleared first).
- **store-probe-20261003-205535, -214233** — gate `M2-GUI PASS` (slot
  return + PROP sync + post path). `-214233` is on the final tree.
- **smoke-20261003-210837** — FAIL, harness: driver used a stale QML id
  (`postButton`) and the topology reused a stale `relays.pids` (dead ports
  → no peers; Delivery 0.3.0 Required does not redial). Fixed: driver ids,
  `relays.pids` unlinked before start and written only after all relay
  ports accept.
- **smoke-20261003-211102, -211209, -214415** — PASS (sender "Message
  propagated via Mix"; receiver thread shows `[received]`; re-check confirms
  the app-owned node). `-214415` is on the final tree.
- **m2b-cli-20261003-211358** — FAIL `sender node never came up (no
  multiaddrs)`. Harness defect: the readiness gate passed the module
  name `delivery_module` twice (the session wrapper already prepends it), so
  the `getNodeInfo` call could never return multiaddrs. Fixed.
- **m2b-cli-20261003-211708, -212136** — PASS, two consecutive on the fixed
  harness → R05 PASS in the matrix.
- **m2b-cli-20261003-110729, -194612** — same error string as the gate
  defect, so consistent with it; not re-run on the old harness, so not
  formally re-attributed. **-105639** (mesh never formed) is a different
  failure and stays unexplained.
- **negatives-20261003-213717** — FAIL: N3 was counted against the status
  although it is by-construction. Policy fixed (BY-CONSTRUCTION cases are
  listed separately, not counted as PASS or FAIL). **-213832** PASS but its
  N3 receipt text overclaimed ("wire<=8192"); superseded by
  **-214548** PASS (N1/N2/N4 measured, N3 by-construction, accurate text).
  Earlier harness defect also fixed: a crashed run could be labelled PASS
  (initial status is now RUNNING, exceptions set FAIL).
