#pragma once
// LP-0026 Forum — domain core (Qt-free, no GUI/network dependencies).
//
// Contracts (docs/CONTRACT.md §1/§2):
//   - Canonical event encoding: deterministic, escaped, sorted-field form.
//     Event ID = SHA-256 hex of the canonical bytes (content-derived).
//     Ed25519 signature covers the same canonical bytes (domain separation via
//     the "forum-v1|" prefix).
//   - Anonymous posting uses a FRESH signing key per identity; no account
//     identifier field exists in the wire form.
//   - Store-before-send: enqueue() commits the post + its privacy requirement
//     durably (SQLite) before any transport call may happen.
//   - Dedup by verified event ID; duplicates are no-ops, invalid events are
//     never partially accepted.
//   - Bounds enforced before allocation-heavy work: body <= 4096, alias <= 64
//     printable ASCII.

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace forum {

constexpr size_t kMaxBody = 4096;
constexpr size_t kMaxAlias = 64;
constexpr size_t kMaxTitle = 128;                 // topic titles
// Received events dated further ahead than this are refused: one event could
// otherwise pin its topic to the top of every reader's list.
constexpr int64_t kMaxFutureSkewMs = 60LL * 60 * 1000;
constexpr const char* kDomainPrefix = "forum-v1|";

struct KeyPair {
    std::string pub_hex;   // 32 bytes, hex
    std::string priv_hex;  // 32 bytes, hex (stays in private storage)
    static KeyPair generate();
};

// Idempotent libsodium init — every crypto entry point calls this first so
// the core is safe in any host process (ui-host never inits sodium itself).
void init_crypto();

// Hex helpers
std::string sha256_hex(const std::string& bytes);
std::string sign(const std::string& priv_hex, const std::string& msg);
bool verify(const std::string& pub_hex, const std::string& msg, const std::string& sig_hex);

bool valid_alias(const std::string& alias);

struct EventDraft {
    std::string forum_id;
    std::string type;          // "post"
    std::string topic_id;
    std::string parent_id;     // empty = topic root
    std::string author_pub_hex;
    std::string alias;         // empty = no alias (anonymous ok)
    int64_t ts_ms = 0;
    std::string body;
};

struct Event {
    std::string id;        // sha256 hex over domain-prefixed canonical bytes
    std::string canonical; // domain-prefixed canonical bytes (signed)
    std::string signature; // hex
};

enum class MergeResult { Accepted, Duplicate, Invalid, StoreError };

struct PostRecord {
    std::string event_id, forum_id, type, topic_id, parent_id;
    std::string author_pub_hex, alias, body, signature;
    int64_t ts_ms = 0;
    std::string state;    // pending | sent | failed | received
    std::string privacy;  // "required"
    std::string last_error;
};

class Store {
public:
    explicit Store(const std::string& path);
    bool ok() const { return m_ok; }

    // Accounts (persistent aliases). Returns false on duplicate alias.
    bool create_account(const std::string& alias, const KeyPair& kp);
    std::optional<KeyPair> account(const std::string& alias) const;
    std::vector<std::string> accounts() const;

    // Identity rotation (privacy across the platform): an alias moves to a
    // fresh key manually, or automatically every N posts and/or every N days.
    // Earlier posts stay verifiable (each carries its own public key); later
    // posts no longer share a key id with them. Times are passed in (ms since
    // the epoch) so the policy is deterministic and testable.
    struct Rotation {
        uint32_t every = 0;         // posts per key; 0 = no post-count rotation
        uint32_t days = 0;          // days per key; 0 = no age rotation
        uint32_t posts_on_key = 0;  // posts signed with the current key
        uint32_t rotations = 0;
        int64_t key_since_ms = 0;   // when the current key's age clock started
    };
    bool rotate_account(const std::string& alias, const KeyPair& fresh, int64_t now_ms = 0);
    bool set_rotate_every(const std::string& alias, uint32_t every);
    // Days per key (0..365). Enabling it starts the current key's clock if
    // it has none yet.
    bool set_rotate_days(const std::string& alias, uint32_t days, int64_t now_ms);
    std::optional<Rotation> rotation(const std::string& alias) const;
    // Count one post signed with the alias's current key. Returns true when
    // the automatic threshold is reached (the caller rotates).
    bool note_signed(const std::string& alias);
    // True when the alias's current key is older than its days-per-key.
    bool key_due_by_age(const std::string& alias, int64_t now_ms) const;

    // Read markers (local only): posts of a topic the user has seen.
    bool mark_seen(const std::string& topic_id, uint32_t count);
    uint32_t seen(const std::string& topic_id) const;

    // Topics + threads (M2 GUI). A topic row is an event of type "topic";
    // replies are "post" events whose parent_id is the topic id (threaded
    // replies target a post id — the UI groups by parent).
    // Returns the topic_id (content-derived) or nullopt on invalid input.
    std::optional<std::string> create_topic(const std::string& forum_id,
                                            const std::string& title,
                                            const std::string& alias,
                                            const KeyPair& signer,
                                            int64_t ts_ms);
    struct TopicInfo {
        std::string topic_id;
        std::string title;
        uint32_t posts = 0;
        int64_t last_ts = 0;
    };
    std::vector<TopicInfo> topics() const;
    // The shared default topic ("General"): a deterministic event signed by a
    // well-known key derived from the forum id (Ed25519 is deterministic), so
    // every instance holds byte-identical bytes and the same topic id with no
    // dispatch. The key is public by construction and confers no authority;
    // it signs only this one event. Stored as received (never in the outbox).
    std::optional<std::string> ensure_default_topic(const std::string& forum_id);
    // Posts of a topic in receive order (state included for the UI).
    std::vector<PostRecord> thread(const std::string& topic_id) const;

    // Event pipeline
    std::optional<Event> make_event(const EventDraft& d, const KeyPair& signer) const;
    // Durable store-before-send. Returns false if the event id already exists.
    bool enqueue(const Event& e, const std::string& privacy);
    // Verify signature + id + bounds, then insert-or-ignore by event id.
    // now_ms is the receiver's clock (the system clock when omitted).
    MergeResult merge_verified(const Event& e);
    MergeResult merge_verified(const Event& e, int64_t now_ms);
    bool mark_state(const std::string& event_id, const std::string& state,
                    const std::string& err = "");
    // Reconstruct the ORIGINAL signed event for a stored row — retry resends
    // the same bytes (same event ID), so receivers dedup it (R05).
    std::optional<Event> stored_event(const std::string& event_id) const;
    std::vector<PostRecord> posts() const;
    std::vector<PostRecord> pending() const;
    int count_posts() const;

private:
    void* m_db = nullptr; // sqlite3* (hidden to keep the header dep-light)
    bool m_ok = false;
};

} // namespace forum
