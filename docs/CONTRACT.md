# Contracts — LP-0026 Forum

Status: **frozen for v0.1.0** — §1 view, §2 event/identity, §3 archive
inventory and §4 transport policy describe the shipped code.

## 0. Non-negotiable product rules

1. **No silent privacy fallback.** Posting policy defaults to `Required`.
   A requested policy is not verified protection; if the transport cannot
   provide it, the post stays queued/refused visibly — never silently downgraded.
2. **Store before send.** Post text + intended privacy requirement are
   persisted atomically before any network call. Settings changes never
   retroactively downgrade queued posts.
3. **Plain text rendering.** Posts/aliases render as plain text. No automatic
   remote images, avatars, previews or resource loads. External links require
   explicit user action.
4. **Honest states.** The stored states pending / sent / failed / received
   derive from real module events, never from the caller's expectation or the
   test runner's knowledge.
5. **No central authority.** No mandatory server/index/founder signer. Any
   archive role can issue signed inventories from verified posts.
6. **Finite retention.** Storage retention is finite + refreshed + readback-
   verified; zero TTL is NOT treated as permanent pin on Storage 3.0.0.

## 1. View contract (`src/forum_module.rep`)

The QML view reaches the backend only via `logos.module("forum_module")`;
no transport API is reachable from QML. Slots return plain strings.

| Member | Kind | Semantics |
|---|---|---|
| `status`, `transportState` | PROP | lifecycle / transport state, plain text, from real module events |
| `connection` | PROP | `offline` (no network chosen) / `connecting` / `connected` — `connected` only once Delivery reports `Connected`/`PartiallyConnected` (for Required this includes a ready Mix pool) |
| `historyState` | PROP | what the network delivered: posts recovered from history (store catch-up, `Load older posts`) vs received live |
| `accounts`, `selectedAlias`, `selectedUid`, `aliasHidden` | PROP | local accounts; current signer; its 16-hex key id; id-only mode |
| `rotationInfo`, `rotateEvery`, `rotateDays` | PROP | selected alias's key rotation: posts on the current key, rotations so far, posts-per-key and days-per-key (0 = off) |
| `topics`, `currentTopicId`, `currentTopicTitle`, `threadPosts`, `threadTimes` | PROP | `id\|title (N)\|unread` rows, most recent activity first; open topic; `<author> [state]: body` rows in signed-time order (newest 200); each row's signed time |
| `searchText` | PROP | active local filter (`""` = none) |
| `archiveState` | PROP | what the last Storage snapshot save/restore did, with counts |
| `createAccount(alias)`, `selectIdentity(alias)`, `hideAlias(bool)` | SLOT | `ok` / `error: …` (`""` = anonymous) |
| `rotateKey()`, `setAutoRotate(n)`, `setAutoRotateDays(d)` | SLOT | move the selected alias to a fresh key now / every `n` stored posts (0–1000) / once its key is `d` days old (0–365, checked before each post); `ok` / `error: …` |
| `createTopic(title)`, `openTopic(id)` | SLOT | topic id / `ok` / `error: …` |
| `setSearch(text)` | SLOT | filters topics (title, post text, author) and the open thread; local only |
| `postMessage(text)` | SLOT | event id; `queued` while offline or connecting (stored as pending, sent through Mix automatically once connected); `retrying` when connected but the send failed (stored as failed, retried automatically) — in both cases the composer is cleared; or `unavailable` (local store error) / `failed` (local validation) / `empty` / `too long` (over 4096 UTF-8 bytes) — text kept |
| `retryPending()` | SLOT | resends stored rows' ORIGINAL signed bytes; count. Also automatic: on every transition to `connected`, and up to 3 times per post (15/30/60 s) after a send error |
| `connectNetwork()` | SLOT | user-initiated join of logos.dev with anonymity `Required`; never automatic |
| `loadHistory()` | SLOT | asks a logos.dev store node for this forum's last 7 days (≤ 10 pages × 50); results verified, merged, reported in `historyState` |
| `archiveTopic()` | SLOT | saves the open topic's published posts as a snapshot on Logos Storage and announces the CID in the topic; `saving` / `error: …` |
| `restoreSnapshot(text)` | SLOT | fetches a snapshot (announcement text or bare CID), verifies and merges every event; `restoring` / `error: …` |
| `recheckTransport()`, `transportStatus()`, `echo(text)` | SLOT | diagnostics / liveness |

Thread author rendering: `alias · id <16 hex>` when an alias is present,
otherwise `id <16 hex>` (anonymous posts carry a one-time key).

## 2. Event / identity contract

Canonical bytes (UTF-8, fields escaped, fixed order), signed with Ed25519:

```
forum-v1|forum=<f>|type=<topic|post>|topic=<t>|parent=<p>|author=<pub hex>|alias=<a>|ts=<ms>|body=<b>
```

- Escapes inside field values: `\\` for `\`, `\p` for `|`, `\n` and `\r`
  for line breaks. A reader accepts exactly these eight fields in this
  order, each value unescaped; anything else (reordered, extra or repeated
  fields, unknown escapes, a raw `|` in a value) is invalid even when the
  signature checks out.
- Event ID = SHA-256 hex of the canonical bytes (content-derived); the
  `forum-v1|` prefix is the signature domain.
- Wire payload on content topic `/lp0026forum/1/general/text`:
  `<canonical>\n<signature hex>`.
- Bounds, checked before verification work: body 1–4096 bytes, alias ≤ 64
  printable ASCII, topic title ≤ 128 bytes, canonical ≤ 8192 bytes, signed
  time at most one hour ahead of the receiver's clock. Invalid events are never
  partially accepted; duplicates (same ID) are no-ops.
- Identity: an account is a persistent key + alias in the local store.
  Posting modes: alias + key; key only (alias field empty); anonymous (fresh
  key per post, alias empty). No account identifier exists on the wire
  beyond the signing key.
- Default topic: "General" is a `type=topic` event signed with a key derived
  from `sha256("lp0026-forum/default-topic/v1|" + forum_id)` and `ts=0`, so
  every instance derives the same topic ID. The key is public by design and
  confers no authority.
- Outbox: the post row and its privacy requirement are committed to SQLite
  before any send; states `pending → sent | failed`, received rows
  `received`. Retry resends the stored canonical bytes, so the ID is stable.
- Rotation: an alias can move to a fresh key (manually, or automatically
  after N stored posts and/or once the key is N days old — an over-age key
  is replaced before it signs the next post). Earlier posts keep their own key and stay
  verifiable; later posts carry the new key id. The alias text itself is
  self-asserted, so rotation unlinks key ids, not a visible alias — hide the
  alias for unlinkable batches.
- Snapshot (Logos Storage): a text file, first line
  `logos-forum-snapshot v1 topic=<id> posts=<n>`, then one line per event:
  base64 of the exact wire payload. ≤ 1000 events, ≤ 4 MiB. Restoring runs
  the same verification as a received message (ID = hash, signature,
  bounds); a snapshot can add posts but never alter or forge one. Only rows
  already published through Mix (`sent`/`received`) are included.
- Snapshot announcement: an ordinary signed post in the topic whose body is
  `Snapshot of this topic on Logos Storage: <n> post(s).`, then `cid: <cid>`,
  and when known `peer: <storage peer id>` and `addrs: <multiaddrs>` (where to
  fetch it). It is signed with a one-time key, never the user's alias.

## 3. Archive inventory contract

Per-archive signed inventories (version/epoch, archive identity, exact CIDs,
byte hashes/lengths, declared coverage, predecessor lineage). Any archive can
build one from verified posts without founder keys. Readers merge by event ID,
bound downloads before fetching, and keep per-issuer watermarks.

## 4. Transport policy contract

- Default `Required` posting policy; unavailable Mix ⇒ visible refusal/queue.
- Joining is explicit (`connectNetwork`, preset `logos.dev`, ports chosen by
  the OS). Posts are sent only once Delivery reports a connection; posts
  written before that are stored and flushed on the transition.
- Pacing: at most 5 sends at once, then one every 2 s (≤ 30 posts/min),
  however many stored posts are waiting after a reconnect.
- Storage is not anonymous: whoever saves a snapshot serves it from their
  own Storage node, and the announcement names that node's address;
  restoring is a direct download from it. Only already-published posts go
  into snapshots, and announcements never carry the saver's alias or key.
- Reading is not anonymous: live receive is relay gossip, and history (the
  node's automatic store catch-up and `loadHistory`) is a direct request to
  a logos.dev store node, which learns that this peer asked for the forum's
  content topic. Mix protects the *sender* of a post, not the reader.
- Private-required reads use private routing AND `advertise=false`, no direct
  fallback; provider hosting is explicit opt-in, consentful, capacity-bounded.
