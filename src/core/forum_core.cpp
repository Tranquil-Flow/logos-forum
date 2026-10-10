#include "forum_core.h"

#include <algorithm>
#include <cctype>
#include <functional>
#include <vector>
#include <chrono>
#include <map>

#include <sodium.h>
#include <cstdlib>
#include <sqlite3.h>

#include <cstdio>
#include <cstring>

namespace forum {

namespace {

std::string to_hex(const unsigned char* p, size_t n)
{
    static const char* hexd = "0123456789abcdef";
    std::string out;
    out.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) {
        out.push_back(hexd[p[i] >> 4]);
        out.push_back(hexd[p[i] & 0x0f]);
    }
    return out;
}

bool from_hex(const std::string& h, std::vector<unsigned char>& out)
{
    if (h.size() % 2 != 0) return false;
    out.clear();
    out.reserve(h.size() / 2);
    auto val = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return -1;
    };
    for (size_t i = 0; i < h.size(); i += 2) {
        int a = val(h[i]), b = val(h[i + 1]);
        if (a < 0 || b < 0) return false;
        out.push_back(static_cast<unsigned char>((a << 4) | b));
    }
    return true;
}

std::string escape_field(const std::string& s)
{
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c == '\\') out += "\\\\";
        else if (c == '|') out += "\\p";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else out.push_back(c);
    }
    return out;
}

// Parse a canonical event back into its fields. Exact keys in the fixed
// order make_event writes them, each value unescaped; anything else (missing,
// extra, reordered or duplicate fields, bad escapes) is not a forum event.
constexpr const char* kCanonKeys[] = {"forum", "type", "topic", "parent",
                                      "author", "alias", "ts", "body"};

bool unescape_field(const std::string& s, std::string& out)
{
    out.clear();
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '\\') { out.push_back(s[i]); continue; }
        if (++i >= s.size()) return false;
        switch (s[i]) {
        case '\\': out.push_back('\\'); break;
        case 'p': out.push_back('|'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        default: return false;
        }
    }
    return true;
}

bool parse_canonical(const std::string& canon, std::map<std::string, std::string>& fields)
{
    fields.clear();
    const std::string prefix = kDomainPrefix;
    if (canon.rfind(prefix, 0) != 0) return false;
    size_t pos = prefix.size();
    for (const char* key : kCanonKeys) {
        const std::string k = std::string(key) + "=";
        if (canon.compare(pos, k.size(), k) != 0) return false;
        pos += k.size();
        const bool last = std::string(key) == "body";
        size_t end = canon.find('|', pos);
        if (last ? end != std::string::npos : end == std::string::npos) return false;
        if (last) end = canon.size();
        std::string value;
        if (!unescape_field(canon.substr(pos, end - pos), value)) return false;
        fields[key] = value;
        pos = last ? end : end + 1;
    }
    return pos == canon.size();
}


constexpr const char* kSealPrefix = "enc1:";
constexpr const char* kVaultCheck = "forum-vault-ok";

bool derive_vault_key(const std::string& password, const unsigned char* salt,
                      std::vector<unsigned char>& key)
{
    key.assign(crypto_secretbox_KEYBYTES, 0);
    return crypto_pwhash(key.data(), key.size(), password.data(), password.size(), salt,
                         crypto_pwhash_OPSLIMIT_INTERACTIVE, crypto_pwhash_MEMLIMIT_INTERACTIVE,
                         crypto_pwhash_ALG_ARGON2ID13) == 0;
}

std::string seal_with(const std::vector<unsigned char>& key, const std::string& plain)
{
    unsigned char nonce[crypto_secretbox_NONCEBYTES];
    randombytes_buf(nonce, sizeof(nonce));
    std::vector<unsigned char> all(nonce, nonce + sizeof(nonce));
    all.resize(sizeof(nonce) + plain.size() + crypto_secretbox_MACBYTES);
    crypto_secretbox_easy(all.data() + sizeof(nonce),
                          reinterpret_cast<const unsigned char*>(plain.data()), plain.size(),
                          nonce, key.data());
    return std::string(kSealPrefix) + to_hex(all.data(), all.size());
}

bool is_sealed(const std::string& s) { return s.rfind(kSealPrefix, 0) == 0; }

bool open_with(const std::vector<unsigned char>& key, const std::string& sealed, std::string& out)
{
    if (!is_sealed(sealed) || key.size() != crypto_secretbox_KEYBYTES) return false;
    std::vector<unsigned char> all;
    if (!from_hex(sealed.substr(std::strlen(kSealPrefix)), all)) return false;
    if (all.size() < crypto_secretbox_NONCEBYTES + crypto_secretbox_MACBYTES) return false;
    const size_t clen = all.size() - crypto_secretbox_NONCEBYTES;
    std::vector<unsigned char> plain(clen - crypto_secretbox_MACBYTES);
    if (crypto_secretbox_open_easy(plain.data(), all.data() + crypto_secretbox_NONCEBYTES, clen,
                                   all.data(), key.data()) != 0) {
        return false;
    }
    out.assign(plain.begin(), plain.end());
    sodium_memzero(plain.data(), plain.size());
    return true;
}

bool parse_ipv4(const std::string& s, unsigned char out[4])
{
    int part = 0, digits = 0, value = 0;
    for (size_t i = 0; i <= s.size(); ++i) {
        const char c = i < s.size() ? s[i] : '.';
        if (c >= '0' && c <= '9') {
            if (digits == 1 && value == 0) return false;  // leading zero
            value = value * 10 + (c - '0');
            if (++digits > 3 || value > 255) return false;
        } else if (c == '.') {
            if (digits == 0 || part > 3) return false;
            out[part++] = static_cast<unsigned char>(value);
            digits = 0; value = 0;
            if (i == s.size()) break;
        } else {
            return false;
        }
    }
    return part == 4;
}

bool public_ipv4(const unsigned char a[4])
{
    const unsigned x = a[0], y = a[1], z = a[2];
    if (x == 0 || x == 10 || x == 127 || x >= 224) return false;
    if (x == 100 && y >= 64 && y <= 127) return false;       // CGNAT
    if (x == 169 && y == 254) return false;                  // link-local
    if (x == 172 && y >= 16 && y <= 31) return false;
    if (x == 192 && y == 168) return false;
    if (x == 192 && y == 0 && (z == 0 || z == 2)) return false;
    if (x == 198 && (y == 18 || y == 19)) return false;      // benchmarking
    if (x == 198 && y == 51 && z == 100) return false;       // documentation
    if (x == 203 && y == 0 && z == 113) return false;
    return true;
}

// Only global-unicast 2000::/3 qualifies; documentation, Teredo and 6to4
// ranges and any embedded-IPv4 notation are refused.
bool public_ipv6(const std::string& s)
{
    if (s.empty() || s.find('.') != std::string::npos || s.find('%') != std::string::npos) {
        return false;
    }
    std::vector<unsigned> groups;
    int gap = -1;
    size_t i = 0;
    if (s.rfind("::", 0) == 0) { gap = 0; i = 2; }
    else if (s[0] == ':') return false;
    while (i < s.size()) {
        size_t j = i;
        unsigned v = 0;
        while (j < s.size() && s[j] != ':') {
            const char c = s[j];
            int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = 10 + c - 'a';
            else if (c >= 'A' && c <= 'F') d = 10 + c - 'A';
            else return false;
            v = v * 16 + d;
            if (++j - i > 4) return false;
        }
        if (j == i) return false;
        groups.push_back(v);
        if (j >= s.size()) break;
        if (j + 1 < s.size() && s[j + 1] == ':') {
            if (gap >= 0) return false;
            gap = static_cast<int>(groups.size());
            j += 2;
            if (j >= s.size()) break;
        } else {
            ++j;
            if (j >= s.size()) return false;
        }
        i = j;
    }
    if (groups.size() > 8 || (gap < 0 && groups.size() != 8) || groups.empty()) return false;
    const unsigned g0 = groups[0];
    const unsigned g1 = groups.size() > 1 ? groups[1] : 0;
    if (g0 < 0x2000 || g0 > 0x3fff) return false;
    if (g0 == 0x2001 && (g1 == 0x0000 || g1 == 0x0db8)) return false;
    if (g0 == 0x2002) return false;
    return true;
}

sqlite3* db_of(void* m) { return static_cast<sqlite3*>(m); }

bool exec_sql(sqlite3* db, const char* sql)
{
    char* err = nullptr;
    const int rc = sqlite3_exec(db, sql, nullptr, nullptr, &err);
    if (rc != SQLITE_OK) {
        if (err) sqlite3_free(err);
        return false;
    }
    return true;
}

} // namespace

void init_crypto()
{
    static const bool ready = []() { return sodium_init() >= 0; }();
    (void)ready;
}

std::string sha256_hex(const std::string& bytes)
{
    unsigned char out[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(out, reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size());
    return to_hex(out, sizeof(out));
}

std::string sign(const std::string& priv_hex, const std::string& msg)
{
    init_crypto();
    std::vector<unsigned char> seed;
    // The persisted private half is the 32-byte Ed25519 seed; the 64-byte
    // secret key is derived at signing time.
    if (!from_hex(priv_hex, seed) || seed.size() != crypto_sign_SEEDBYTES) {
        // caller-visible failure: empty signature
        return "";
    }
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk64[crypto_sign_SECRETKEYBYTES];
    crypto_sign_seed_keypair(pk, sk64, seed.data());
    unsigned char sig[crypto_sign_BYTES];
    crypto_sign_detached(sig, nullptr,
                         reinterpret_cast<const unsigned char*>(msg.data()), msg.size(),
                         sk64);
    sodium_memzero(sk64, sizeof(sk64));
    return to_hex(sig, sizeof(sig));
}

bool verify(const std::string& pub_hex, const std::string& msg, const std::string& sig_hex)
{
    init_crypto();
    std::vector<unsigned char> pk, sig;
    if (!from_hex(pub_hex, pk) || pk.size() != crypto_sign_PUBLICKEYBYTES) return false;
    if (!from_hex(sig_hex, sig) || sig.size() != crypto_sign_BYTES) return false;
    return crypto_sign_verify_detached(
               sig.data(), reinterpret_cast<const unsigned char*>(msg.data()), msg.size(),
               pk.data()) == 0;
}

bool valid_alias(const std::string& alias)
{
    if (alias.size() > kMaxAlias) return false;
    // Printable ASCII only: an alias sits next to the key id that tells
    // authors apart, and Unicode look-alikes (dots, brackets, direction
    // overrides, invisible characters) could imitate one.
    for (unsigned char c : alias) {
        if (c < 0x20 || c > 0x7e) return false;
    }
    return true;
}

KeyPair KeyPair::generate()
{
    init_crypto();
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_SECRETKEYBYTES];
    unsigned char seed[crypto_sign_SEEDBYTES];
    randombytes_buf(seed, sizeof(seed));
    crypto_sign_seed_keypair(pk, sk, seed);
    KeyPair kp;
    kp.pub_hex = to_hex(pk, sizeof(pk));
    kp.priv_hex = to_hex(seed, sizeof(seed)); // 32-byte seed is the private half we persist
    sodium_memzero(sk, sizeof(sk));
    return kp;
}

Store::Store(const std::string& path)
{
    sqlite3* db = nullptr;
    if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        m_ok = false;
        return;
    }
    m_db = db;
    m_ok = exec_sql(db,
        "PRAGMA journal_mode=WAL;"
        "PRAGMA secure_delete=ON;"
        "CREATE TABLE IF NOT EXISTS vault("
        " id INTEGER PRIMARY KEY CHECK(id=1),"
        " salt TEXT NOT NULL,"
        " check_ct TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS accounts("
        " alias TEXT PRIMARY KEY,"
        " pub_hex TEXT NOT NULL,"
        " priv_hex TEXT NOT NULL,"
        " created_ms INTEGER NOT NULL);"
        "CREATE TABLE IF NOT EXISTS posts("
        " event_id TEXT PRIMARY KEY,"
        " forum_id TEXT NOT NULL,"
        " type TEXT NOT NULL,"
        " topic_id TEXT NOT NULL,"
        " parent_id TEXT NOT NULL,"
        " author_pub_hex TEXT NOT NULL,"
        " alias TEXT NOT NULL,"
        " ts_ms INTEGER NOT NULL,"
        " body TEXT NOT NULL,"
        " signature TEXT NOT NULL,"
        " state TEXT NOT NULL,"
        " privacy TEXT NOT NULL,"
        " last_error TEXT NOT NULL,"
        " canonical TEXT NOT NULL,"
        " created_ms INTEGER NOT NULL);");
    // Additive migrations (idempotent: "duplicate column" errors are ignored).
    exec_sql(db, "ALTER TABLE accounts ADD COLUMN rotate_every INTEGER NOT NULL DEFAULT 0;");
    exec_sql(db, "ALTER TABLE accounts ADD COLUMN posts_on_key INTEGER NOT NULL DEFAULT 0;");
    exec_sql(db, "ALTER TABLE accounts ADD COLUMN rotations INTEGER NOT NULL DEFAULT 0;");
    exec_sql(db, "ALTER TABLE accounts ADD COLUMN rotate_days INTEGER NOT NULL DEFAULT 0;");
    exec_sql(db, "ALTER TABLE accounts ADD COLUMN key_since_ms INTEGER NOT NULL DEFAULT 0;");
    if (m_ok) {
        m_ok = exec_sql(db,
            "CREATE TABLE IF NOT EXISTS topic_seen("
            " topic_id TEXT PRIMARY KEY,"
            " seen INTEGER NOT NULL);");
    }
    // One-time rewrite so a store created before secure_delete was on holds no
    // superseded key bytes in free pages (user_version 0 -> 1).
    if (m_ok) {
        sqlite3_stmt* uv = nullptr;
        int version = 1;
        if (sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &uv, nullptr) == SQLITE_OK) {
            if (sqlite3_step(uv) == SQLITE_ROW) version = sqlite3_column_int(uv, 0);
            sqlite3_finalize(uv);
        }
        if (version < 1) {
            exec_sql(db, "VACUUM;");
            exec_sql(db, "PRAGMA user_version=1;");
        }
    }
    // Repair: before v0.1.0 final, enqueue() stored local rows with ts_ms 0.
    // The signed time is in the canonical bytes; restore it (idempotent).
    exec_sql(db,
        "UPDATE posts SET ts_ms = CAST(substr(canonical, instr(canonical,'|ts=')+4,"
        " instr(substr(canonical, instr(canonical,'|ts=')+4), '|')-1) AS INTEGER)"
        " WHERE ts_ms = 0 AND instr(canonical,'|ts=') > 0;");
}


bool public_multiaddr(const std::string& multiaddr)
{
    // /ip4/<addr>/... or /ip6/<addr>/...
    if (multiaddr.size() > 256) return false;
    std::string rest;
    bool v6;
    if (multiaddr.rfind("/ip4/", 0) == 0) { v6 = false; rest = multiaddr.substr(5); }
    else if (multiaddr.rfind("/ip6/", 0) == 0) { v6 = true; rest = multiaddr.substr(5); }
    else return false;
    const size_t slash = rest.find('/');
    const std::string host = slash == std::string::npos ? rest : rest.substr(0, slash);
    for (char c : multiaddr) {
        if (static_cast<unsigned char>(c) < 0x21 || static_cast<unsigned char>(c) > 0x7e) return false;
    }
    // Everything after the host must be plain transport components: a second
    // host-bearing protocol (dns, ip4, p2p-circuit, unix, ...) would let the
    // dialer reach somewhere this check never looked at.
    if (slash != std::string::npos) {
        std::vector<std::string> parts;
        size_t pos = slash + 1;
        while (pos <= rest.size()) {
            const size_t nx = rest.find('/', pos);
            parts.push_back(rest.substr(pos, nx == std::string::npos ? std::string::npos : nx - pos));
            if (nx == std::string::npos) break;
            pos = nx + 1;
        }
        for (size_t i = 0; i < parts.size(); ++i) {
            const std::string& p = parts[i];
            if (p.empty()) { if (i + 1 == parts.size()) break; return false; }  // one trailing '/'
            if (p == "tcp" || p == "udp") {
                if (i + 1 >= parts.size()) return false;
                const std::string& port = parts[++i];
                if (port.empty() || port.size() > 5 || port[0] == '0') return false;
                for (char c : port) if (c < '0' || c > '9') return false;
                if (std::stoi(port) > 65535) return false;
            } else if (p == "quic" || p == "quic-v1" || p == "ws" || p == "wss" || p == "tls") {
                continue;
            } else if (p == "p2p" || p == "ipfs") {
                if (i + 1 >= parts.size()) return false;
                const std::string& id = parts[++i];
                if (id.size() < 20 || id.size() > 128) return false;
                for (char c : id) {
                    if (!std::isalnum(static_cast<unsigned char>(c))) return false;
                }
            } else {
                return false;
            }
        }
    }
    if (v6) return public_ipv6(host);
    unsigned char a[4];
    return parse_ipv4(host, a) && public_ipv4(a);
}

bool RateBudget::allow(int64_t now_ms)
{
    if (m_last != 0 && now_ms > m_last) {
        m_tokens = std::min(m_burst, m_tokens + double(now_ms - m_last) * m_rate);
    }
    m_last = now_ms;
    if (m_tokens < 1.0) return false;
    m_tokens -= 1.0;
    return true;
}

std::string event_author(const std::string& canonical)
{
    std::map<std::string, std::string> f;
    if (!parse_canonical(canonical, f)) return "";
    const auto it = f.find("author");
    return it == f.end() ? std::string() : it->second;
}

bool Store::create_account(const std::string& alias, const KeyPair& kp)
{
    if (!m_ok || !valid_alias(alias) || alias.empty()) return false;
    std::string stored_priv = kp.priv_hex;
    if (keys_protected()) {
        if (m_vault_key.empty()) return false;  // locked: no new keys until unlocked
        stored_priv = seal_with(m_vault_key, kp.priv_hex);
    }
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO accounts(alias,pub_hex,priv_hex,created_ms) VALUES(?,?,?,?)",
            -1, &st, nullptr) != SQLITE_OK) {
        return false;
    }
    sqlite3_bind_text(st, 1, alias.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, kp.pub_hex.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, stored_priv.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 4, 0);
    const int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE;
}

std::optional<KeyPair> Store::account(const std::string& alias) const
{
    if (!m_ok) return std::nullopt;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
            "SELECT pub_hex,priv_hex FROM accounts WHERE alias=?", -1, &st, nullptr)
        != SQLITE_OK) {
        return std::nullopt;
    }
    sqlite3_bind_text(st, 1, alias.c_str(), -1, SQLITE_TRANSIENT);
    std::optional<KeyPair> out;
    if (sqlite3_step(st) == SQLITE_ROW) {
        KeyPair kp;
        kp.pub_hex = reinterpret_cast<const char*>(sqlite3_column_text(st, 0));
        const std::string stored = reinterpret_cast<const char*>(sqlite3_column_text(st, 1));
        if (!is_sealed(stored)) {
            kp.priv_hex = stored;
        } else if (!open_with(m_vault_key, stored, kp.priv_hex)) {
            kp.priv_hex.clear();  // locked: the account exists but cannot sign
        }
        out = kp;
    }
    sqlite3_finalize(st);
    return out;
}

std::optional<Event> Store::make_event(const EventDraft& d, const KeyPair& signer) const
{
    if (d.body.size() > kMaxBody) return std::nullopt;
    if (d.body.empty()) return std::nullopt;
    if (!valid_alias(d.alias)) return std::nullopt;
    if (d.forum_id.empty() || d.type.empty()) return std::nullopt;
    // A topic's own id IS its event id — only posts must reference a topic.
    if (d.type != "topic" && d.topic_id.empty()) return std::nullopt;
    if (d.author_pub_hex.empty()) return std::nullopt;

    // Canonical form: domain prefix + escaped fields in fixed order.
    // The domain prefix is the signature-domain separation (CONTRACT §2).
    std::string canon;
    canon += kDomainPrefix;
    canon += "forum=" + escape_field(d.forum_id) + "|";
    canon += "type=" + escape_field(d.type) + "|";
    canon += "topic=" + escape_field(d.topic_id) + "|";
    canon += "parent=" + escape_field(d.parent_id) + "|";
    canon += "author=" + d.author_pub_hex + "|";
    canon += "alias=" + escape_field(d.alias) + "|";
    canon += "ts=" + std::to_string(d.ts_ms) + "|";
    canon += "body=" + escape_field(d.body);

    Event e;
    e.canonical = canon;
    e.id = sha256_hex(canon);
    e.signature = sign(signer.priv_hex, canon);
    if (e.signature.empty()) return std::nullopt;
    return e;
}

bool Store::enqueue(const Event& e, const std::string& privacy)
{
    if (!m_ok) return false;
    sqlite3* db = db_of(m_db);
    // Parse minimal fields back out of the canonical form for storage.
    // (The event id is the dedup key; canonical+sig are the verification material.)
    exec_sql(db, "BEGIN IMMEDIATE;");
    sqlite3_stmt* st = nullptr;
    bool inserted = false;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO posts(event_id,forum_id,type,topic_id,parent_id,author_pub_hex,"
            "alias,ts_ms,body,signature,state,privacy,last_error,canonical,created_ms)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &st, nullptr) == SQLITE_OK) {
        // Fields are re-derived (unescaped) from the canonical string.
        std::map<std::string, std::string> fields;
        parse_canonical(e.canonical, fields);
        auto field = [&fields](const char* key) -> std::string {
            const auto it = fields.find(key);
            return it == fields.end() ? std::string() : it->second;
        };
        sqlite3_bind_text(st, 1, e.id.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, field("forum").c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, field("type").c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 4, field("topic").c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 5, field("parent").c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 6, field("author").c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 7, field("alias").c_str(), -1, SQLITE_TRANSIENT);
        // The signed (authored) time, exactly as merge_verified stores it.
        const std::string ts_field = field("ts");
        char* ts_end = nullptr;
        long long ts = std::strtoll(ts_field.c_str(), &ts_end, 10);
        if (ts_field.empty() || ts_end == nullptr || *ts_end != '\0' || ts < 0) ts = 0;
        sqlite3_bind_int64(st, 8, ts);
        sqlite3_bind_text(st, 9, field("body").c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 10, e.signature.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 11, "pending", -1, SQLITE_STATIC);
        sqlite3_bind_text(st, 12, privacy.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 13, "", -1, SQLITE_STATIC);
        sqlite3_bind_text(st, 14, e.canonical.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 15, 0);
        inserted = sqlite3_step(st) == SQLITE_DONE;
        sqlite3_finalize(st);
    }
    exec_sql(db, inserted ? "COMMIT;" : "ROLLBACK;");
    return inserted;
}

MergeResult Store::merge_verified(const Event& e)
{
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return merge_verified(e, std::chrono::duration_cast<std::chrono::milliseconds>(now).count());
}

MergeResult Store::merge_verified(const Event& e, int64_t now_ms)
{
    return merge_verified(e, now_ms, std::function<bool()>());
}

MergeResult Store::merge_verified(const Event& e, int64_t now_ms,
                                  const std::function<bool()>& admit)
{
    if (!m_ok) return MergeResult::Invalid;
    if (e.id.size() != 64 || e.signature.size() != 128) return MergeResult::Invalid;
    if (e.canonical.rfind(kDomainPrefix, 0) != 0) return MergeResult::Invalid;
    if (e.canonical.size() > 8192) return MergeResult::Invalid; // hard wire bound
    // ID must match content.
    if (sha256_hex(e.canonical) != e.id) return MergeResult::Invalid;
    // Extract author + body bounds before any allocation-heavy work.
    std::map<std::string, std::string> fields;
    if (!parse_canonical(e.canonical, fields)) return MergeResult::Invalid;
    auto field = [&fields](const char* key) -> std::string {
        const auto it = fields.find(key);
        return it == fields.end() ? std::string() : it->second;
    };
    const std::string author = field("author");
    if (author.size() != 64) return MergeResult::Invalid;
    const std::string body = field("body");
    if (body.empty() || body.size() > kMaxBody) return MergeResult::Invalid;
    const std::string alias = field("alias");
    if (!valid_alias(alias)) return MergeResult::Invalid;
    if (field("type") == "topic" && body.size() > kMaxTitle) return MergeResult::Invalid;
    // The signed timestamp (authored time) — not 0, so received rows sort
    // with local ones. Non-numeric/absent ts degrades to 0, never rejects;
    // a time too far in the future is refused (see kMaxFutureSkewMs).
    const std::string ts_field = field("ts");
    char* ts_end = nullptr;
    long long ts = std::strtoll(ts_field.c_str(), &ts_end, 10);
    if (ts_field.empty() || ts_end == nullptr || *ts_end != '\0' || ts < 0) ts = 0;
    if (ts > now_ms + kMaxFutureSkewMs) return MergeResult::Invalid;
    // Signature check (domain-separated canonical bytes).
    if (!verify(author, e.canonical, e.signature)) return MergeResult::Invalid;

    sqlite3* db = db_of(m_db);
    if (admit) {
        bool have = false;
        sqlite3_stmt* q = nullptr;
        if (sqlite3_prepare_v2(db, "SELECT 1 FROM posts WHERE event_id=?", -1, &q, nullptr)
            == SQLITE_OK) {
            sqlite3_bind_text(q, 1, e.id.c_str(), -1, SQLITE_TRANSIENT);
            have = sqlite3_step(q) == SQLITE_ROW;
            sqlite3_finalize(q);
        }
        if (have) return MergeResult::Duplicate;
        if (!admit()) return MergeResult::Throttled;
    }

    // Insert-or-ignore: duplicates are no-ops.
    exec_sql(db, "BEGIN IMMEDIATE;");
    bool accepted = false;
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
            "INSERT OR IGNORE INTO posts(event_id,forum_id,type,topic_id,parent_id,"
            "author_pub_hex,alias,ts_ms,body,signature,state,privacy,last_error,canonical,"
            "created_ms)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,'received','required','',?,0)", -1, &st, nullptr)
        == SQLITE_OK) {
        const std::string forum = field("forum");
        const std::string type = field("type");
        const std::string topic = field("topic");
        const std::string parent = field("parent");
        sqlite3_bind_text(st, 1, e.id.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, forum.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, type.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 4, topic.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 5, parent.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 6, author.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 7, alias.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 8, static_cast<sqlite3_int64>(ts));
        sqlite3_bind_text(st, 9, body.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 10, e.signature.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 11, e.canonical.c_str(), -1, SQLITE_TRANSIENT);
        accepted = sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) > 0;
        sqlite3_finalize(st);
    }
    exec_sql(db, accepted ? "COMMIT;" : "ROLLBACK;");
    if (accepted) return MergeResult::Accepted;
    // Verified but not inserted: a duplicate only if the row is really there
    // (a busy or full database is an error, not "already here").
    bool present = false;
    sqlite3_stmt* q = nullptr;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM posts WHERE event_id=?", -1, &q, nullptr)
        == SQLITE_OK) {
        sqlite3_bind_text(q, 1, e.id.c_str(), -1, SQLITE_TRANSIENT);
        present = sqlite3_step(q) == SQLITE_ROW;
        sqlite3_finalize(q);
    }
    return present ? MergeResult::Duplicate : MergeResult::StoreError;
}

bool Store::mark_state(const std::string& event_id, const std::string& state,
                       const std::string& err)
{
    if (!m_ok) return false;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
            "UPDATE posts SET state=?, last_error=? WHERE event_id=?", -1, &st, nullptr)
        != SQLITE_OK) {
        return false;
    }
    sqlite3_bind_text(st, 1, state.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, err.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, event_id.c_str(), -1, SQLITE_TRANSIENT);
    const int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE;
}

std::vector<PostRecord> Store::posts() const
{
    std::vector<PostRecord> out;
    if (!m_ok) return out;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
            "SELECT event_id,forum_id,type,topic_id,parent_id,author_pub_hex,alias,ts_ms,"
            "body,signature,state,privacy,last_error FROM posts ORDER BY rowid", -1, &st,
            nullptr) != SQLITE_OK) {
        return out;
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
        PostRecord r;
        auto s = [&](int i) { return reinterpret_cast<const char*>(sqlite3_column_text(st, i)); };
        r.event_id = s(0); r.forum_id = s(1); r.type = s(2); r.topic_id = s(3);
        r.parent_id = s(4); r.author_pub_hex = s(5); r.alias = s(6);
        r.ts_ms = sqlite3_column_int64(st, 7);
        r.body = s(8); r.signature = s(9); r.state = s(10); r.privacy = s(11);
        r.last_error = s(12);
        out.push_back(r);
    }
    sqlite3_finalize(st);
    return out;
}

std::vector<PostRecord> Store::pending() const
{
    std::vector<PostRecord> out;
    for (const auto& r : posts()) {
        if (r.state == "pending") out.push_back(r);
    }
    return out;
}

std::vector<std::string> Store::accounts() const
{
    std::vector<std::string> out;
    if (!m_ok) return out;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db, "SELECT alias FROM accounts ORDER BY alias", -1, &st,
                           nullptr) != SQLITE_OK) {
        return out;
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
        out.emplace_back(reinterpret_cast<const char*>(sqlite3_column_text(st, 0)));
    }
    sqlite3_finalize(st);
    return out;
}

namespace {
// One-statement helper for the small account/marker updates below.
bool exec_bound(sqlite3* db, const char* sql, const std::vector<std::string>& text,
                const std::vector<int64_t>& ints)
{
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK) return false;
    int i = 1;
    for (const auto& v : ints) sqlite3_bind_int64(st, i++, v);
    for (const auto& t : text) sqlite3_bind_text(st, i++, t.c_str(), -1, SQLITE_TRANSIENT);
    const int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE && sqlite3_changes(db) > 0;
}
} // namespace

bool Store::rotate_account(const std::string& alias, const KeyPair& fresh, int64_t now_ms)
{
    if (!m_ok || fresh.pub_hex.size() != 64 || fresh.priv_hex.size() != 64) return false;
    std::string stored_priv = fresh.priv_hex;
    if (keys_protected()) {
        if (m_vault_key.empty()) return false;
        stored_priv = seal_with(m_vault_key, fresh.priv_hex);
    }
    const bool ok = exec_bound(db_of(m_db),
        "UPDATE accounts SET key_since_ms=?, pub_hex=?, priv_hex=?, posts_on_key=0,"
        " rotations=rotations+1 WHERE alias=?",
        {fresh.pub_hex, stored_priv, alias}, {std::max<int64_t>(now_ms, 0)});
    // The replaced key must not outlive the rotation in the write-ahead log.
    if (ok) scrub();
    return ok;
}

namespace {
// Seals (or opens) every stored private key with the given transforms. All
// rows are read first, then rewritten in one transaction.
bool rewrite_all_keys(sqlite3* db,
                      const std::function<bool(const std::string&, std::string&)>& fn)
{
    std::vector<std::pair<std::string, std::string>> rows;
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db, "SELECT alias,priv_hex FROM accounts", -1, &st, nullptr)
        != SQLITE_OK) {
        return false;
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
        rows.emplace_back(reinterpret_cast<const char*>(sqlite3_column_text(st, 0)),
                          reinterpret_cast<const char*>(sqlite3_column_text(st, 1)));
    }
    sqlite3_finalize(st);
    for (auto& r : rows) {
        std::string next;
        if (!fn(r.second, next)) return false;
        r.second = std::move(next);
    }
    for (const auto& r : rows) {
        if (!exec_bound(db, "UPDATE accounts SET priv_hex=? WHERE alias=?",
                        {r.second, r.first}, {})) {
            return false;
        }
    }
    return true;
}

bool read_vault(sqlite3* db, std::vector<unsigned char>& salt, std::string& check)
{
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db, "SELECT salt,check_ct FROM vault WHERE id=1", -1, &st, nullptr)
        != SQLITE_OK) {
        return false;
    }
    bool ok = false;
    if (sqlite3_step(st) == SQLITE_ROW) {
        ok = from_hex(reinterpret_cast<const char*>(sqlite3_column_text(st, 0)), salt)
             && salt.size() == crypto_pwhash_SALTBYTES;
        check = reinterpret_cast<const char*>(sqlite3_column_text(st, 1));
    }
    sqlite3_finalize(st);
    return ok;
}

// Derives the key for `password` and verifies it against the vault check.
bool verify_password(sqlite3* db, const std::string& password, std::vector<unsigned char>& key)
{
    std::vector<unsigned char> salt;
    std::string check, plain;
    if (!read_vault(db, salt, check)) return false;
    if (!derive_vault_key(password, salt.data(), key)) return false;
    if (!open_with(key, check, plain) || plain != kVaultCheck) {
        sodium_memzero(key.data(), key.size());
        key.clear();
        return false;
    }
    return true;
}
} // namespace

bool Store::keys_protected() const
{
    if (!m_ok) return false;
    std::vector<unsigned char> salt;
    std::string check;
    return read_vault(db_of(m_db), salt, check);
}

bool Store::keys_locked() const { return keys_protected() && m_vault_key.empty(); }

bool Store::protect_keys(const std::string& password)
{
    if (!m_ok || password.size() < 8 || keys_protected()) return false;
    init_crypto();
    unsigned char salt[crypto_pwhash_SALTBYTES];
    randombytes_buf(salt, sizeof(salt));
    std::vector<unsigned char> key;
    if (!derive_vault_key(password, salt, key)) return false;
    sqlite3* db = db_of(m_db);
    exec_sql(db, "BEGIN IMMEDIATE;");
    bool ok = rewrite_all_keys(db, [&](const std::string& in, std::string& out) {
        out = is_sealed(in) ? in : seal_with(key, in);
        return true;
    });
    ok = ok && exec_bound(db, "INSERT INTO vault(id,salt,check_ct) VALUES(1,?,?)",
                          {to_hex(salt, sizeof(salt)), seal_with(key, kVaultCheck)}, {});
    exec_sql(db, ok ? "COMMIT;" : "ROLLBACK;");
    if (!ok) { sodium_memzero(key.data(), key.size()); return false; }
    m_vault_key = key;
    // Overwrite the plaintext keys the rewrite superseded.
    exec_sql(db, "PRAGMA wal_checkpoint(TRUNCATE);");
    exec_sql(db, "VACUUM;");
    exec_sql(db, "PRAGMA wal_checkpoint(TRUNCATE);");
    return true;
}

bool Store::unlock_keys(const std::string& password)
{
    if (!m_ok || !keys_protected()) return false;
    init_crypto();
    std::vector<unsigned char> key;
    if (!verify_password(db_of(m_db), password, key)) return false;
    m_vault_key = key;
    return true;
}

void Store::lock_keys()
{
    if (!m_vault_key.empty()) sodium_memzero(m_vault_key.data(), m_vault_key.size());
    m_vault_key.clear();
}

bool Store::unprotect_keys(const std::string& password)
{
    if (!m_ok || !keys_protected()) return false;
    init_crypto();
    std::vector<unsigned char> key;
    sqlite3* db = db_of(m_db);
    if (!verify_password(db, password, key)) return false;
    exec_sql(db, "BEGIN IMMEDIATE;");
    bool ok = rewrite_all_keys(db, [&](const std::string& in, std::string& out) {
        if (!is_sealed(in)) { out = in; return true; }
        return open_with(key, in, out);
    });
    ok = ok && exec_sql(db, "DELETE FROM vault WHERE id=1;");
    exec_sql(db, ok ? "COMMIT;" : "ROLLBACK;");
    sodium_memzero(key.data(), key.size());
    if (!ok) return false;
    lock_keys();
    scrub();
    return true;
}

bool Store::change_key_password(const std::string& old_password, const std::string& new_password)
{
    if (!m_ok || new_password.size() < 8 || !keys_protected()) return false;
    init_crypto();
    sqlite3* db = db_of(m_db);
    std::vector<unsigned char> old_key, new_key;
    if (!verify_password(db, old_password, old_key)) return false;
    unsigned char salt[crypto_pwhash_SALTBYTES];
    randombytes_buf(salt, sizeof(salt));
    if (!derive_vault_key(new_password, salt, new_key)) return false;
    exec_sql(db, "BEGIN IMMEDIATE;");
    bool ok = rewrite_all_keys(db, [&](const std::string& in, std::string& out) {
        std::string plain;
        if (!open_with(old_key, in, plain)) return false;
        out = seal_with(new_key, plain);
        sodium_memzero(plain.data(), plain.size());
        return true;
    });
    ok = ok && exec_bound(db, "UPDATE vault SET salt=?, check_ct=? WHERE id=1",
                          {to_hex(salt, sizeof(salt)), seal_with(new_key, kVaultCheck)}, {});
    exec_sql(db, ok ? "COMMIT;" : "ROLLBACK;");
    sodium_memzero(old_key.data(), old_key.size());
    if (!ok) { sodium_memzero(new_key.data(), new_key.size()); return false; }
    m_vault_key = new_key;
    scrub();
    return true;
}

void Store::scrub()
{
    if (m_ok) exec_sql(db_of(m_db), "PRAGMA wal_checkpoint(TRUNCATE);");
}

bool Store::set_rotate_days(const std::string& alias, uint32_t days, int64_t now_ms)
{
    if (!m_ok || days > 365 || now_ms < 0) return false;
    return exec_bound(db_of(m_db),
        "UPDATE accounts SET rotate_days=?,"
        " key_since_ms=CASE WHEN key_since_ms=0 THEN ? ELSE key_since_ms END WHERE alias=?",
        {alias}, {static_cast<int64_t>(days), now_ms});
}

bool Store::key_due_by_age(const std::string& alias, int64_t now_ms) const
{
    const auto r = rotation(alias);
    if (!r || r->days == 0 || r->key_since_ms <= 0) return false;
    return now_ms - r->key_since_ms >= int64_t(r->days) * 86400000LL;
}

bool Store::set_rotate_every(const std::string& alias, uint32_t every)
{
    if (!m_ok || every > 1000) return false;
    return exec_bound(db_of(m_db), "UPDATE accounts SET rotate_every=? WHERE alias=?",
                      {alias}, {static_cast<int64_t>(every)});
}

std::optional<Store::Rotation> Store::rotation(const std::string& alias) const
{
    if (!m_ok) return std::nullopt;
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db_of(m_db),
            "SELECT rotate_every, posts_on_key, rotations, rotate_days, key_since_ms"
            " FROM accounts WHERE alias=?",
            -1, &st, nullptr) != SQLITE_OK) {
        return std::nullopt;
    }
    sqlite3_bind_text(st, 1, alias.c_str(), -1, SQLITE_TRANSIENT);
    std::optional<Rotation> out;
    if (sqlite3_step(st) == SQLITE_ROW) {
        Rotation r;
        r.every = static_cast<uint32_t>(sqlite3_column_int(st, 0));
        r.posts_on_key = static_cast<uint32_t>(sqlite3_column_int(st, 1));
        r.rotations = static_cast<uint32_t>(sqlite3_column_int(st, 2));
        r.days = static_cast<uint32_t>(sqlite3_column_int(st, 3));
        r.key_since_ms = sqlite3_column_int64(st, 4);
        out = r;
    }
    sqlite3_finalize(st);
    return out;
}

bool Store::note_signed(const std::string& alias)
{
    if (!m_ok) return false;
    exec_bound(db_of(m_db), "UPDATE accounts SET posts_on_key=posts_on_key+1 WHERE alias=?",
               {alias}, {});
    const auto r = rotation(alias);
    return r.has_value() && r->every > 0 && r->posts_on_key >= r->every;
}

bool Store::mark_seen(const std::string& topic_id, uint32_t count)
{
    if (!m_ok || topic_id.empty()) return false;
    return exec_bound(db_of(m_db),
        "INSERT INTO topic_seen(seen, topic_id) VALUES(?,?)"
        " ON CONFLICT(topic_id) DO UPDATE SET seen=excluded.seen",
        {topic_id}, {static_cast<int64_t>(count)});
}

uint32_t Store::seen(const std::string& topic_id) const
{
    if (!m_ok) return 0;
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db_of(m_db), "SELECT seen FROM topic_seen WHERE topic_id=?",
                           -1, &st, nullptr) != SQLITE_OK) {
        return 0;
    }
    sqlite3_bind_text(st, 1, topic_id.c_str(), -1, SQLITE_TRANSIENT);
    uint32_t n = 0;
    if (sqlite3_step(st) == SQLITE_ROW) n = static_cast<uint32_t>(sqlite3_column_int(st, 0));
    sqlite3_finalize(st);
    return n;
}

std::optional<std::string> Store::create_topic(const std::string& forum_id,
                                                const std::string& title,
                                                const std::string& alias,
                                                const KeyPair& signer,
                                                int64_t ts_ms)
{
    if (title.empty() || title.size() > kMaxTitle || !valid_alias(alias)) return std::nullopt;
    EventDraft d;
    d.forum_id = forum_id;
    d.type = "topic";
    d.topic_id = "";  // topic id is derived from the event itself
    d.parent_id = "";
    d.author_pub_hex = signer.pub_hex;
    d.alias = alias;
    d.ts_ms = ts_ms;
    d.body = title;
    auto ev = make_event(d, signer);
    if (!ev.has_value()) return std::nullopt;
    if (!enqueue(*ev, "required")) return std::nullopt;
    return ev->id;
}

std::optional<std::string> Store::ensure_default_topic(const std::string& forum_id,
                                                       const std::string& title)
{
    if (!m_ok || forum_id.empty() || title.empty() || title.size() > kMaxTitle) return std::nullopt;
    init_crypto();
    // Well-known seed: public by construction (see header).
    const std::string tag = title == "General" ? std::string() : "|" + title;
    std::vector<unsigned char> seed;
    if (!from_hex(sha256_hex("lp0026-forum/default-topic/v1|" + forum_id + tag), seed) ||
        seed.size() != crypto_sign_SEEDBYTES) {
        return std::nullopt;
    }
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk64[crypto_sign_SECRETKEYBYTES];
    crypto_sign_seed_keypair(pk, sk64, seed.data());
    sodium_memzero(sk64, sizeof(sk64));
    KeyPair kp;
    kp.pub_hex = to_hex(pk, sizeof(pk));
    kp.priv_hex = to_hex(seed.data(), seed.size());

    EventDraft d;
    d.forum_id = forum_id;
    d.type = "topic";
    d.author_pub_hex = kp.pub_hex;
    d.alias = "";
    d.ts_ms = 0;
    d.body = title;
    auto ev = make_event(d, kp);
    if (!ev.has_value()) return std::nullopt;
    if (merge_verified(*ev) == MergeResult::Invalid) return std::nullopt;
    return ev->id;
}

std::vector<Store::TopicInfo> Store::topics() const
{
    std::vector<TopicInfo> out;
    if (!m_ok) return out;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    // A topic is its own event (type=topic, id=topic_id); posts reference it.
    if (sqlite3_prepare_v2(db,
            "SELECT p.event_id, p.body, "
            "(SELECT COUNT(*) FROM posts q WHERE q.type='post' AND "
            " (q.topic_id=p.event_id OR q.parent_id=p.event_id)), "
            " COALESCE((SELECT MAX(t.ts_ms) FROM posts t WHERE "
            "  (t.topic_id=p.event_id OR t.parent_id=p.event_id)), p.ts_ms) "
            "FROM posts p WHERE p.type='topic' ORDER BY p.ts_ms", -1, &st, nullptr)
        != SQLITE_OK) {
        return out;
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
        TopicInfo t;
        t.topic_id = reinterpret_cast<const char*>(sqlite3_column_text(st, 0));
        t.title = reinterpret_cast<const char*>(sqlite3_column_text(st, 1));
        t.posts = static_cast<uint32_t>(sqlite3_column_int(st, 2));
        t.last_ts = sqlite3_column_int64(st, 3);
        out.push_back(t);
    }
    sqlite3_finalize(st);
    return out;
}

std::vector<PostRecord> Store::thread(const std::string& topic_id) const
{
    std::vector<PostRecord> out;
    for (const auto& r : posts()) {
        if (r.type == "post" &&
            (r.topic_id == topic_id || r.parent_id == topic_id)) {
            out.push_back(r);
        }
    }
    // Conversation order = the authors' signed timestamps, not arrival order
    // (history can arrive after newer live posts). Event id breaks ties so
    // every reader shows the same order.
    std::stable_sort(out.begin(), out.end(), [](const PostRecord& x, const PostRecord& y) {
        return x.ts_ms != y.ts_ms ? x.ts_ms < y.ts_ms : x.event_id < y.event_id;
    });
    return out;
}

std::optional<Event> Store::stored_event(const std::string& event_id) const
{
    if (!m_ok) return std::nullopt;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
            "SELECT canonical, signature FROM posts WHERE event_id=?", -1, &st, nullptr)
        != SQLITE_OK) {
        return std::nullopt;
    }
    sqlite3_bind_text(st, 1, event_id.c_str(), -1, SQLITE_TRANSIENT);
    std::optional<Event> out;
    if (sqlite3_step(st) == SQLITE_ROW) {
        Event e;
        e.canonical = reinterpret_cast<const char*>(sqlite3_column_text(st, 0));
        e.signature = reinterpret_cast<const char*>(sqlite3_column_text(st, 1));
        e.id = sha256_hex(e.canonical);
        if (e.id == event_id) out = e;
    }
    sqlite3_finalize(st);
    return out;
}

int Store::count_posts() const
{
    if (!m_ok) return -1;
    sqlite3* db = db_of(m_db);
    sqlite3_stmt* st = nullptr;
    int n = -1;
    if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM posts", -1, &st, nullptr) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
    }
    return n;
}

} // namespace forum
