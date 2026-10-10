# Security and privacy notes — LP-0026 Forum

What the forum does to protect its users, what it deliberately does not do,
and the limits you should know before relying on it. Everything here is
checked by a test or a recorded run unless it says otherwise; the matrix in
`MATRIX.md` links the evidence.

## What is protected

| Property | How |
|---|---|
| Posts cannot be forged or altered | Every event is canonical bytes signed with Ed25519; the event id is the SHA-256 of those bytes. Signature, id and bounds are verified before anything is stored. Invalid events are never partly accepted. |
| Reading a post cannot contact its author | Every peer-supplied string (titles, aliases, bodies, key ids, snapshot notes) is rendered with `Text.PlainText`. No remote images, avatars or link previews are ever loaded. |
| Posting does not reveal your network address to the topic | Sends use Delivery with anonymity `Required` (Mix). If Mix is not ready the post waits in the local store; there is no plain fallback. |
| A hostile clock cannot pin a topic or poison catch-up | Events dated more than one hour ahead of the receiver's clock are refused (`kMaxFutureSkewMs`). |
| A message flood cannot grow your store without bound | Live events are ingested through a token bucket (120 per minute sustained, burst 300). Only events that verify and are new spend the budget, so junk and duplicates cannot starve real posts. Over-budget live events are dropped unstored (and reported); the network's store returns them on the next catch-up. History pages are bounded separately (≤ 10 pages × 50). |
| Sending does not flood the network | A token bucket in front of the transport: a burst of 5, then one send every 2 s, whatever the outbox holds. Automatic retries are capped at 3 per post per session. |
| Alias keys can be sealed at rest | Optional: *Protect keys with password* seals every alias key with Argon2id + XSalsa20-Poly1305. A locked store lists its aliases but cannot sign for them; anonymous posts use one-time keys that are never stored and still work. Locking clears the selected key from the backend. |
| Replaced keys do not linger | `secure_delete` is on and the write-ahead log is checkpointed and truncated after every key rotation and every protection change. Stores created by an earlier release are rewritten once (`VACUUM`) on first open. |
| A pasted snapshot cannot aim your node at your own network | When restoring a snapshot, only public IP addresses (`/ip4`, `/ip6`) from the announcement are dialed, and only with plain transport components after the host (`tcp`/`udp` with a port, `quic-v1`, `ws`, `wss`, `p2p`); relay-circuit or second-host forms are refused. DNS names and loopback, private, link-local, CGNAT, documentation, multicast, mapped and 6to4/Teredo forms are refused. The same filter keeps your LAN addresses out of the announcements you publish. Lab networks can set `FORUM_ALLOW_PRIVATE_PEERS=1`. |
| The backend does not freeze on a stalled node | Delivery sends are asynchronous (35 s timeout). The post is already stored; the reply, or its failure, only updates its state. |

## Identity model, honestly

- **Anonymous posts** use a fresh key per post and carry no alias.
  They are unlinkable to each other *by key*. They still leave from your own
  node, so a peer connected directly to you can tell that node published
  them. Mix hides the network path between you and the relays, not the fact
  that your node is the origin.
- **Alias posts** are signed with the alias's account key. Anyone can link all
  posts of an alias, and "hide alias" only removes the name, not the key id.
  Rotation (manual, every N posts, every N days) limits how much one key
  links; it does not unlink old posts from each other.
- **Rotation cannot hide history**: earlier posts keep their own public key
  and stay verifiable.

## Limits you should know

1. **Keys are unencrypted unless you turn protection on.** By default an alias
   key is a hex string in the local SQLite store. Anyone with your profile
   directory can post as your alias. Protection is opt-in because it adds a
   password to remember.
2. **There is no password reset.** Lose the password and the sealed alias keys
   are gone; earlier posts stay valid. There is no recovery phrase, because
   keys are independent random keys, not derived from one secret.
3. **A locked store protects keys at rest, not a running process.** While
   unlocked, the key is in the backend's memory like any signing key.
4. **Storage snapshots connect directly.** Restoring a snapshot dials the node
   that saved it over Logos Storage, which can see your address. Saving one
   publishes your Storage address in the announcement (signed with a one-time
   key, never your alias). Delivery history queries are a direct request to a
   store node as well: that node learns your node asked for this forum.
   Posting stays on Mix.
5. **Spam resistance is limited.** There is no proof of work or per-author
   quota on received posts. Anyone can post, with fresh keys, as fast as the
   network's own limits allow; the ingest budget bounds what your node does
   with it, not what the network carries, and a flood of validly signed posts
   from throwaway keys can still crowd out live posts until the next catch-up. A future RLN membership would be
   the real answer.
6. **Posts cannot be deleted from the network.** A serverless design has no
   delete button; a post you wrote may live on peers and store nodes.
7. **Blocking calls remain at connect.** Creating, starting and subscribing
   the Delivery node are single synchronous calls made once when you press
   Connect; sends and history queries are asynchronous.
8. **One shared Delivery and Storage per Basecamp.** Other apps use the same
   modules; whichever app initialises Storage first sets its settings.

## Reporting

Please open an issue on the repository with steps to reproduce.
