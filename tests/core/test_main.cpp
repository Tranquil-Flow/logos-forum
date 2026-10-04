// LP-0026 Forum — domain core tests (Qt-free contract, no GUI/network).
// Run via: nix build .#core-tests
//
// These tests define the M2 contract before the backend trusts any behavior:
// canonical event encoding, content-derived IDs, Ed25519 sign/verify,
// anonymous posting without stable identity fields, durable store-before-send,
// idempotent dedup, honest outbox states, and input bounds.
#include "forum_core.h"
#include "archive_core.h"

#include <sodium.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond) do { \
    ++g_checks; \
    if (!(cond)) { \
        ++g_failures; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

#define CHECK_EQ(a, b) do { \
    ++g_checks; \
    auto _a = (a); auto _b = (b); \
    if (!(_a == _b)) { \
        ++g_failures; \
        fprintf(stderr, "FAIL %s:%d: %s == %s\n", __FILE__, __LINE__, #a, #b); \
    } \
} while (0)

using namespace forum;

static std::string tmpdir()
{
    // mkdtemp is hidden under the nix clang's strict libc mode; a pid+counter
    // path keeps each test's database isolated within one process.
    static int counter = 0;
    const std::string d = "/tmp/forum-core-test-" + std::to_string(getpid())
                          + "-" + std::to_string(++counter);
    mkdir(d.c_str(), 0700);
    return d;
}

static EventDraft sample_draft(const std::string& pub)
{
    EventDraft d;
    d.forum_id = "general";
    d.type = "post";
    d.topic_id = "topic-1";
    d.parent_id = "";
    d.author_pub_hex = pub;
    d.alias = "alice";
    d.ts_ms = 1727800000000LL;
    d.body = "TECHNICAL TEST DATA: hello forum";
    return d;
}

static void test_canonical_id_stability()
{
    const KeyPair kp = KeyPair::generate();
    Store s(tmpdir() + "/t.db");
    auto e1 = s.make_event(sample_draft(kp.pub_hex), kp);
    CHECK(e1.has_value());
    // Same content, constructed again → identical canonical bytes and ID.
    auto e2 = s.make_event(sample_draft(kp.pub_hex), kp);
    CHECK(e2.has_value());
    CHECK_EQ(e1->id, e2->id);
    CHECK_EQ(e1->canonical, e2->canonical);
    CHECK_EQ(e1->id.size(), size_t(64)); // sha256 hex
}

static void test_sign_verify_and_tamper()
{
    const KeyPair kp = KeyPair::generate();
    Store s(tmpdir() + "/t.db");
    auto e = s.make_event(sample_draft(kp.pub_hex), kp);
    CHECK(e.has_value());
    CHECK(verify(kp.pub_hex, e->canonical, e->signature));

    // Tampered canonical bytes must fail verification.
    std::string tampered = e->canonical;
    const size_t pos = tampered.find("hello forum");
    CHECK(pos != std::string::npos);
    tampered.replace(pos, 5, "heXlo");
    CHECK(!verify(kp.pub_hex, tampered, e->signature));

    // Wrong key must fail.
    const KeyPair other = KeyPair::generate();
    CHECK(!verify(other.pub_hex, e->canonical, e->signature));
}

static void test_anonymous_post_has_no_stable_identity()
{
    const KeyPair anon1 = KeyPair::generate();
    const KeyPair anon2 = KeyPair::generate();
    CHECK(anon1.pub_hex != anon2.pub_hex); // fresh identity per post

    EventDraft d = sample_draft(anon1.pub_hex);
    d.alias = ""; // anonymous: no alias field content
    Store s(tmpdir() + "/t.db");
    auto e = s.make_event(d, anon1);
    CHECK(e.has_value());
    // Wire bytes carry the per-post key, never an account identifier field.
    CHECK(e->canonical.find("account") == std::string::npos);
    CHECK(e->canonical.find("alias=") != std::string::npos);
    const std::string alias_part = e->canonical.substr(e->canonical.find("alias="));
    CHECK(alias_part.rfind("alias=|", 0) == 0 || alias_part.find("|") == 6);
}

static void test_store_before_send_durability()
{
    const std::string dir = tmpdir();
    const KeyPair kp = KeyPair::generate();
    std::string db = dir + "/t.db";
    std::string event_id;
    {
        Store s(db);
        CHECK(s.ok());
        auto e = s.make_event(sample_draft(kp.pub_hex), kp);
        CHECK(e.has_value());
        CHECK(s.enqueue(*e, "required")); // durable commit happens here
        event_id = e->id;
    }
    // Reopen with a FRESH connection — the row must already exist as pending.
    Store s2(db);
    auto pending = s2.pending();
    CHECK_EQ(pending.size(), size_t(1));
    if (!pending.empty()) {
        CHECK_EQ(pending[0].event_id, event_id);
        CHECK_EQ(pending[0].state, std::string("pending"));
        CHECK_EQ(pending[0].privacy, std::string("required"));
        CHECK_EQ(pending[0].body, std::string("TECHNICAL TEST DATA: hello forum"));
    }
}

static void test_dedup_idempotent_merge()
{
    const KeyPair kp = KeyPair::generate();
    Store s(tmpdir() + "/t.db");
    auto e = s.make_event(sample_draft(kp.pub_hex), kp);
    CHECK(e.has_value());
    CHECK(s.merge_verified(*e) == MergeResult::Accepted);
    CHECK(s.merge_verified(*e) == MergeResult::Duplicate); // live+retry duplicate
    CHECK_EQ(s.count_posts(), 1);

    // Invalid events are rejected, never partially accepted.
    Event forged = *e;
    forged.signature[0] = forged.signature[0] == 'a' ? 'b' : 'a';
    CHECK(s.merge_verified(forged) == MergeResult::Invalid);
    CHECK_EQ(s.count_posts(), 1);

    // ID mismatch (swapped id from another event) is invalid.
    Event swapped = *e;
    swapped.id = std::string(64, '0');
    CHECK(s.merge_verified(swapped) == MergeResult::Invalid);
}

static void test_outbox_states()
{
    const KeyPair kp = KeyPair::generate();
    Store s(tmpdir() + "/t.db");
    auto e = s.make_event(sample_draft(kp.pub_hex), kp);
    CHECK(e.has_value());
    CHECK(s.enqueue(*e, "required"));
    CHECK(!s.enqueue(*e, "required")); // duplicate enqueue refused

    CHECK(s.mark_state(e->id, "failed", "Required send FAILED: mix unavailable"));
    auto all = s.posts();
    CHECK_EQ(all.size(), size_t(1));
    if (!all.empty()) {
        CHECK_EQ(all[0].state, std::string("failed"));
        CHECK(all[0].last_error.find("mix unavailable") != std::string::npos);
    }
    // Retry: back to pending with cleared error; then sent; idempotent.
    CHECK(s.mark_state(e->id, "pending", ""));
    CHECK(s.mark_state(e->id, "sent", ""));
    CHECK(s.mark_state(e->id, "sent", "")); // duplicate terminal mark is a no-op success
    auto sent = s.pending();
    CHECK_EQ(sent.size(), size_t(0));
}

static void test_bounds_and_validation()
{
    const KeyPair kp = KeyPair::generate();
    Store s(tmpdir() + "/t.db");

    EventDraft d = sample_draft(kp.pub_hex);
    d.body = std::string(kMaxBody + 1, 'x');
    CHECK(!s.make_event(d, kp).has_value()); // oversize body rejected

    d = sample_draft(kp.pub_hex);
    d.alias = std::string(kMaxAlias + 1, 'a');
    CHECK(!s.make_event(d, kp).has_value()); // oversize alias rejected

    d = sample_draft(kp.pub_hex);
    d.alias = "bad\nalias";
    CHECK(!valid_alias(d.alias)); // control chars rejected

    d = sample_draft(kp.pub_hex);
    d.body = "ok";
    auto e = s.make_event(d, kp);
    CHECK(e.has_value());
    if (e.has_value()) {
        Event corrupt;
        corrupt.canonical = "not|a|valid|canonical|form";
        corrupt.id = sha256_hex(corrupt.canonical);
        corrupt.signature = e->signature;
        CHECK(s.merge_verified(corrupt) == MergeResult::Invalid);
    }
}

static void test_stored_event_retry_identity()
{
    const KeyPair kp = KeyPair::generate();
    Store s(tmpdir() + "/t.db");
    auto e = s.make_event(sample_draft(kp.pub_hex), kp);
    CHECK(e.has_value());
    CHECK(s.enqueue(*e, "required"));
    CHECK(s.mark_state(e->id, "failed", "mix unavailable"));
    // Retry material: the ORIGINAL signed event, byte-identical → same id.
    auto again = s.stored_event(e->id);
    CHECK(again.has_value());
    if (again.has_value()) {
        CHECK_EQ(again->id, e->id);
        CHECK_EQ(again->canonical, e->canonical);
        CHECK_EQ(again->signature, e->signature);
        CHECK(verify(kp.pub_hex, again->canonical, again->signature));
    }
    // Unknown id reconstructs nothing.
    CHECK(!s.stored_event(std::string(64, 'f')).has_value());
}

static forum::Segment seg(const std::string& cid, uint32_t n,
                          const std::string& first, const std::string& last)
{
    forum::Segment s;
    s.cid = cid;
    s.sha256 = std::string(64, 'a');
    s.bytes = 1024;
    s.post_count = n;
    s.first_event_id = first;
    s.last_event_id = last;
    return s;
}

static void test_inventory_sign_verify_roundtrip()
{
    using namespace forum;
    const KeyPair archive = KeyPair::generate();   // the ARCHIVE's own key
    const KeyPair author = KeyPair::generate();    // unrelated post author
    (void)author;

    InventoryDraft d;
    d.archive_pub_hex = archive.pub_hex;
    d.epoch = 1;
    d.forum_id = "general";
    d.predecessor_inv_id = "";
    d.segments = { seg(std::string(64, 'c') + "cid", 2, std::string(64, '1'),
                       std::string(64, '2')) };
    d.posts_covered = 2;
    d.created_ms = 1727880000000LL;

    auto inv = sign_inventory(d, archive);
    CHECK(inv.has_value());
    if (!inv.has_value()) return;
    CHECK(inv->id == sha256_hex(inv->canonical));
    CHECK(verify_inventory(*inv, archive.pub_hex) == InvVerify::Valid);

    // Wrong archive key pinned by the reader -> rejected.
    const KeyPair other = KeyPair::generate();
    CHECK(verify_inventory(*inv, other.pub_hex) == InvVerify::BadStructure);

    // Tampered segment bytes -> id mismatch or signature failure.
    Inventory forged = *inv;
    const size_t pos = forged.canonical.find(":1024:");
    CHECK(pos != std::string::npos);
    forged.canonical.replace(pos + 1, 4, "9999");
    CHECK(verify_inventory(forged, archive.pub_hex) != InvVerify::Valid);
}

static void test_inventory_rejects_bad_shapes()
{
    using namespace forum;
    const KeyPair archive = KeyPair::generate();
    InventoryDraft d;
    d.archive_pub_hex = archive.pub_hex;
    d.epoch = 3;
    d.forum_id = "general";
    d.segments = { seg(std::string(64, 'c') + "cid", 5, std::string(64, '1'),
                       std::string(64, '2')) };
    d.posts_covered = 7; // disagrees with segment sum -> refused
    d.created_ms = 1;
    CHECK(!sign_inventory(d, archive).has_value());

    // Key substitution: draft signed by a DIFFERENT key than declared.
    const KeyPair attacker = KeyPair::generate();
    d.posts_covered = 5;
    CHECK(!sign_inventory(d, attacker).has_value());

    // Empty segments refused.
    d.segments.clear();
    CHECK(!sign_inventory(d, archive).has_value());
}

static void test_inventory_epoch_lineage_shape()
{
    // Lineage: successor inventory must be verifiable and carry predecessor
    // id; the reader keeps per-issuer watermarks (epoch monotonicity) — that
    // policy lives in the reader (m3 harness); here we only prove the wire
    // carries lineage and verifies.
    using namespace forum;
    const KeyPair archive = KeyPair::generate();
    InventoryDraft d1;
    d1.archive_pub_hex = archive.pub_hex; d1.epoch = 1; d1.forum_id = "general";
    d1.segments = { seg(std::string(64, 'a') + "s1", 1, std::string(64, '9'),
                        std::string(64, '9')) };
    d1.posts_covered = 1; d1.created_ms = 100;
    auto inv1 = sign_inventory(d1, archive);
    CHECK(inv1.has_value());

    InventoryDraft d2 = d1;
    d2.epoch = 2;
    d2.predecessor_inv_id = inv1->id;
    d2.segments = { seg(std::string(64, 'b') + "s2", 3, std::string(64, '1'),
                        std::string(64, '3')) };
    d2.posts_covered = 3; d2.created_ms = 200;
    auto inv2 = sign_inventory(d2, archive);
    CHECK(inv2.has_value());
    if (inv1.has_value() && inv2.has_value()) {
        CHECK(verify_inventory(*inv2, archive.pub_hex) == InvVerify::Valid);
        CHECK(inv2->canonical.find("predecessor=" + inv1->id) != std::string::npos);
    }
}

static void test_topics_replies_threads()
{
    using namespace forum;
    const KeyPair alice = KeyPair::generate();
    const KeyPair bob = KeyPair::generate();
    Store s(tmpdir() + "/t.db");
    CHECK(s.create_account("alice", alice));
    CHECK(s.create_account("bob", bob));

    // Topic creation returns a content-derived id; listed with title.
    auto tid = s.create_topic("general", "Welcome thread", "alice", alice, 1000);
    CHECK(tid.has_value());
    auto tops = s.topics();
    CHECK_EQ(tops.size(), size_t(1));
    if (tops.size() == 1) {
        CHECK_EQ(tops[0].title, std::string("Welcome thread"));
        CHECK_EQ(tops[0].posts, uint32_t(0));
    }

    // Alice posts in her topic; Bob replies (parent = topic id).
    EventDraft d1;
    d1.forum_id = "general"; d1.type = "post"; d1.topic_id = *tid;
    d1.parent_id = *tid; d1.author_pub_hex = alice.pub_hex;
    d1.alias = "alice"; d1.ts_ms = 2000; d1.body = "first post";
    auto e1 = s.make_event(d1, alice);
    CHECK(e1.has_value());
    CHECK(s.enqueue(*e1, "required"));
    // Local events are stored by enqueue; merging the SAME event again is
    // correctly Duplicate (merge's job is REMOTE ingest — dedup by id).
    CHECK(s.merge_verified(*e1) == MergeResult::Duplicate);

    EventDraft d2;
    d2.forum_id = "general"; d2.type = "post"; d2.topic_id = *tid;
    d2.parent_id = *tid; d2.author_pub_hex = bob.pub_hex;
    d2.alias = "bob"; d2.ts_ms = 3000; d2.body = "a reply";
    auto e2 = s.make_event(d2, bob);
    CHECK(e2.has_value());
    CHECK(s.enqueue(*e2, "required"));

    // Thread shows both posts with alias + state; duplicate merge collapses.
    CHECK(s.merge_verified(*e2) == MergeResult::Duplicate);
    auto th = s.thread(*tid);
    CHECK_EQ(th.size(), size_t(2));
    if (th.size() == 2) {
        CHECK_EQ(th[0].body, std::string("first post"));
        CHECK_EQ(th[1].body, std::string("a reply"));
        CHECK_EQ(th[1].alias, std::string("bob"));
        CHECK_EQ(th[1].parent_id, *tid);
    }

    // Topic post count reflects the thread.
    tops = s.topics();
    if (tops.size() == 1) CHECK_EQ(tops[0].posts, uint32_t(2));

    // Anonymous posting: no alias, fresh key — still lands in the topic.
    const KeyPair anon = KeyPair::generate();
    EventDraft d3;
    d3.forum_id = "general"; d3.type = "post"; d3.topic_id = *tid;
    d3.parent_id = *tid; d3.author_pub_hex = anon.pub_hex;
    d3.alias = ""; d3.ts_ms = 4000; d3.body = "anonymous reply";
    auto e3 = s.make_event(d3, anon);
    CHECK(e3.has_value());
    CHECK(s.merge_verified(*e3) == MergeResult::Accepted);
    CHECK_EQ(s.thread(*tid).size(), size_t(3));

    // Invalid topic creation refused.
    CHECK(!s.create_topic("general", "", "alice", alice, 1000).has_value());
    CHECK(!s.create_topic("general", "t", "bad\nalias", alice, 1000).has_value());

    // accounts() lists both.
    auto accts = s.accounts();
    CHECK_EQ(accts.size(), size_t(2));
}

static void test_accounts_and_aliasing()
{
    const std::string dir = tmpdir();
    Store s(dir + "/t.db");
    const KeyPair kp = KeyPair::generate();
    CHECK(s.create_account("alice", kp));
    CHECK(!s.create_account("alice", KeyPair::generate())); // no alias overwrite
    auto acc = s.account("alice");
    CHECK(acc.has_value());
    if (acc.has_value()) CHECK_EQ(acc->pub_hex, kp.pub_hex);
    CHECK(!s.account("nobody").has_value());

    CHECK(valid_alias("alice"));
    CHECK(valid_alias(""));
    CHECK(!valid_alias(std::string(kMaxAlias + 1, 'a')));
}


static void test_default_topic_shared_across_instances()
{
    using namespace forum;
    // Two independent instances (separate stores, no communication) must
    // derive the SAME default topic event, so posts to "General" land in the
    // same thread everywhere without anyone dispatching a topic event.
    Store a(tmpdir() + "/default-a.db");
    Store b(tmpdir() + "/default-b.db");
    auto ta = a.ensure_default_topic("general");
    auto tb = b.ensure_default_topic("general");
    CHECK(ta.has_value());
    CHECK(tb.has_value());
    if (!ta || !tb) return;
    CHECK_EQ(*ta, *tb);
    // Idempotent; listed once as "General"; never queued for sending.
    CHECK_EQ(*a.ensure_default_topic("general"), *ta);
    auto tops = a.topics();
    CHECK_EQ(tops.size(), size_t(1));
    if (tops.size() == 1) CHECK_EQ(tops[0].title, std::string("General"));
    CHECK_EQ(a.pending().size(), size_t(0));
    // The well-known key signs ONLY the topic event and confers no authority:
    // the event verifies like any other (and a different forum differs).
    auto ev = a.stored_event(*ta);
    CHECK(ev.has_value());
    auto other = a.ensure_default_topic("another-forum");
    CHECK(other.has_value() && *other != *ta);

    // A post made on instance A, merged on instance B, shows in B's thread.
    const KeyPair anon = KeyPair::generate();
    EventDraft d;
    d.forum_id = "general"; d.type = "post"; d.topic_id = *ta;
    d.parent_id = *ta; d.author_pub_hex = anon.pub_hex;
    d.alias = ""; d.ts_ms = 5000; d.body = "hello across instances";
    auto e = a.make_event(d, anon);
    CHECK(e.has_value());
    if (!e) return;
    CHECK(a.enqueue(*e, "required"));
    CHECK(b.merge_verified(*e) == MergeResult::Accepted);
    auto th = b.thread(*tb);
    CHECK_EQ(th.size(), size_t(1));
    if (th.size() == 1) {
        CHECK_EQ(th[0].body, std::string("hello across instances"));
        CHECK_EQ(th[0].state, std::string("received"));
        CHECK_EQ(th[0].ts_ms, int64_t(5000)); // signed authored time, not 0
    }
}

static void test_thread_order_follows_signed_time()
{
    using namespace forum;
    // History can arrive after newer live posts; the thread must still read
    // in the authors' signed time order, identically on every reader.
    Store a(tmpdir() + "/order-a.db");
    auto t = a.ensure_default_topic("general");
    CHECK(t.has_value());
    if (!t) return;
    const KeyPair k = KeyPair::generate();
    auto mk = [&](int64_t ts, const char* body) {
        EventDraft d;
        d.forum_id = "general"; d.type = "post"; d.topic_id = *t; d.parent_id = *t;
        d.author_pub_hex = k.pub_hex; d.alias = ""; d.ts_ms = ts; d.body = body;
        return a.make_event(d, k);
    };
    auto newer = mk(3000, "third");
    auto oldest = mk(1000, "first");
    auto middle = mk(2000, "second");
    CHECK(newer && oldest && middle);
    if (!newer || !oldest || !middle) return;
    // Arrival order: newest first, then older history.
    CHECK(a.merge_verified(*newer) == MergeResult::Accepted);
    CHECK(a.merge_verified(*oldest) == MergeResult::Accepted);
    CHECK(a.merge_verified(*middle) == MergeResult::Accepted);
    // A LOCAL post (enqueued, not merged) keeps its signed time too, so it
    // sorts among received ones (regression: enqueue once stored ts 0).
    auto local = mk(2500, "local");
    CHECK(local.has_value());
    if (!local) return;
    CHECK(a.enqueue(*local, "required"));
    auto th = a.thread(*t);
    CHECK_EQ(th.size(), size_t(4));
    if (th.size() == 4) {
        CHECK_EQ(th[0].body, std::string("first"));
        CHECK_EQ(th[1].body, std::string("second"));
        CHECK_EQ(th[2].body, std::string("local"));
        CHECK_EQ(th[2].ts_ms, int64_t(2500));
        CHECK_EQ(th[3].body, std::string("third"));
    }
}

static void test_alias_rotation_and_read_markers()
{
    using namespace forum;
    const std::string db = tmpdir() + "/rotate-a.db";
    Store a(db);
    CHECK(a.ok());
    const KeyPair k1 = KeyPair::generate();
    CHECK(a.create_account("carol", k1));
    auto r0 = a.rotation("carol");
    CHECK(r0.has_value() && r0->every == 0 && r0->rotations == 0);
    // Manual rotation: a fresh key replaces the old one; the alias stays.
    const KeyPair k2 = KeyPair::generate();
    CHECK(a.rotate_account("carol", k2));
    auto cur = a.account("carol");
    CHECK(cur.has_value() && cur->pub_hex == k2.pub_hex && cur->pub_hex != k1.pub_hex);
    CHECK(!a.rotate_account("nobody", KeyPair::generate()));
    CHECK(!a.rotate_account("carol", KeyPair{}));  // malformed key refused
    // Automatic rotation every 2 posts: the second signed post hits it.
    CHECK(a.set_rotate_every("carol", 2));
    CHECK(!a.set_rotate_every("carol", 5000));      // bounded
    CHECK(!a.note_signed("carol"));
    CHECK(a.note_signed("carol"));
    CHECK(a.rotate_account("carol", KeyPair::generate()));
    auto r1 = a.rotation("carol");
    CHECK(r1.has_value() && r1->rotations == 2 && r1->posts_on_key == 0 && r1->every == 2);
    // Read markers: absent = 0; upsert keeps the latest count.
    CHECK_EQ(a.seen("t1"), uint32_t(0));
    CHECK(a.mark_seen("t1", 3));
    CHECK(a.mark_seen("t1", 5));
    CHECK_EQ(a.seen("t1"), uint32_t(5));
    CHECK(!a.mark_seen("", 1));
    // Rotation by age: enabling it starts the current key's clock; the key
    // is due once it is N days old; rotating restarts the clock.
    const int64_t day = 86400000LL, t0 = 1700000000000LL;
    CHECK(!a.key_due_by_age("carol", t0));          // off by default
    CHECK(a.set_rotate_days("carol", 7, t0));
    CHECK(!a.set_rotate_days("carol", 400, t0));    // bounded
    CHECK(a.set_rotate_days("carol", 7, t0 + day)); // keeps the running clock
    auto r3 = a.rotation("carol");
    CHECK(r3.has_value() && r3->days == 7 && r3->key_since_ms == t0);
    CHECK(!a.key_due_by_age("carol", t0 + 7 * day - 1));
    CHECK(a.key_due_by_age("carol", t0 + 7 * day));
    CHECK(a.rotate_account("carol", KeyPair::generate(), t0 + 7 * day));
    CHECK(!a.key_due_by_age("carol", t0 + 7 * day + 1));
    CHECK(!a.key_due_by_age("nobody", t0 + 100 * day));
    // Rotation state survives reopening (it lives in the profile store).
    Store b(db);
    auto r2 = b.rotation("carol");
    CHECK(r2.has_value() && r2->every == 2 && r2->rotations == 3 && r2->days == 7 &&
          r2->key_since_ms == t0 + 7 * day);
    CHECK_EQ(b.seen("t1"), uint32_t(5));
}

static void test_fields_unescaped_and_canonical_strict()
{
    using namespace forum;
    // Bodies with newlines, pipes and backslashes are stored and shown as
    // written (regression: stored fields kept the wire escapes, so a
    // multi-line post read "a\nb" and a snapshot announcement did not parse).
    Store a(tmpdir() + "/fields-a.db");
    Store b(tmpdir() + "/fields-b.db");
    auto t = a.ensure_default_topic("general");
    auto tb = b.ensure_default_topic("general");
    CHECK(t.has_value() && tb.has_value() && *t == *tb);
    if (!t) return;
    const KeyPair k = KeyPair::generate();
    const std::string body = "line one\ncid: abc|def\\ghi\r\nend";
    EventDraft d;
    d.forum_id = "general"; d.type = "post"; d.topic_id = *t; d.parent_id = *t;
    d.author_pub_hex = k.pub_hex; d.alias = "dora"; d.ts_ms = 1234; d.body = body;
    auto ev = a.make_event(d, k);
    CHECK(ev.has_value());
    if (!ev) return;
    CHECK(a.enqueue(*ev, "required"));
    CHECK(b.merge_verified(*ev) == MergeResult::Accepted);
    for (Store* s : {&a, &b}) {
        bool found = false;
        for (const auto& p : s->thread(*t)) {
            if (p.event_id != ev->id) continue;
            found = true;
            CHECK_EQ(p.body, body);
            CHECK_EQ(p.alias, std::string("dora"));
            CHECK_EQ(p.ts_ms, int64_t(1234));
        }
        CHECK(found);
    }
    // Validly signed but non-canonical events are refused: fields reordered,
    // an extra field, a duplicated key, an unknown escape.
    auto signed_ev = [&](const std::string& canon) {
        Event e;
        e.canonical = canon;
        e.id = sha256_hex(canon);
        e.signature = sign(k.priv_hex, canon);
        return e;
    };
    const std::string pre = kDomainPrefix;
    const std::string head = "forum=general|type=post|topic=" + *t + "|parent=" + *t +
                             "|author=" + k.pub_hex + "|alias=|ts=5|";
    CHECK(b.merge_verified(signed_ev(pre + head + "body=ok")) == MergeResult::Accepted);
    CHECK(b.merge_verified(signed_ev(pre + "type=post|forum=general|topic=" + *t + "|parent=" +
                                     *t + "|author=" + k.pub_hex + "|alias=|ts=5|body=x")) ==
          MergeResult::Invalid);
    CHECK(b.merge_verified(signed_ev(pre + head + "extra=1|body=y")) == MergeResult::Invalid);
    CHECK(b.merge_verified(signed_ev(pre + head + "body=z|body=w")) == MergeResult::Invalid);
    CHECK(b.merge_verified(signed_ev(pre + head + "body=bad\\x")) == MergeResult::Invalid);
    CHECK(b.merge_verified(signed_ev(pre + head + "body=trailing\\")) == MergeResult::Invalid);
}

int main()
{
    if (sodium_init() < 0) {
        fprintf(stderr, "sodium_init failed\n");
        return 2;
    }
    test_canonical_id_stability();
    test_sign_verify_and_tamper();
    test_anonymous_post_has_no_stable_identity();
    test_store_before_send_durability();
    test_dedup_idempotent_merge();
    test_outbox_states();
    test_bounds_and_validation();
    test_accounts_and_aliasing();
    test_stored_event_retry_identity();
    test_inventory_sign_verify_roundtrip();
    test_inventory_rejects_bad_shapes();
    test_inventory_epoch_lineage_shape();
    test_topics_replies_threads();
    test_default_topic_shared_across_instances();
    test_thread_order_follows_signed_time();
    test_alias_rotation_and_read_markers();
    test_fields_unescaped_and_canonical_strict();

    printf("core tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
