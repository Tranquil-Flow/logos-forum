#pragma once
// LP-0026 Forum — archive inventory core (Qt-free).
//
// Contract (docs/CONTRACT.md §3, frozen for M3): a PER-ARCHIVE signed
// inventory asserts what THAT archive retained — never global completeness.
// Any consenting archive can build one from verified posts with its OWN key;
// no founder secret is involved. Readers verify independently:
//   - inventory signature over the canonical form (archive's Ed25519 key),
//   - each segment's CID + sha256 + byte length (bound before download),
//   - declared post coverage (event IDs) against locally verified posts.
// Epoch + predecessor hash give per-issuer lineage for watermark/equivocation
// checks (a lower epoch or a non-descendant predecessor for a known issuer is
// a locally-known rollback/regression signal, surfaced honestly).

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "forum_core.h"  // KeyPair, sha256/sign/verify primitives

namespace forum {

constexpr const char* kInvDomain = "archive-v1|";

struct Segment {
    std::string cid;       // storage dataset/segment CID (opaque, bounded)
    std::string sha256;    // hex, over the segment bytes
    uint64_t bytes = 0;
    uint32_t post_count = 0;
    std::string first_event_id; // hex (64) — coverage bounds
    std::string last_event_id;  // hex (64)
};

struct InventoryDraft {
    std::string archive_pub_hex; // the ARCHIVE's own key — not the author's
    uint64_t epoch = 0;
    std::string forum_id;
    std::string predecessor_inv_id; // sha256 hex of predecessor inventory, or ""
    std::vector<Segment> segments;  // 1..kMaxSegments
    uint32_t posts_covered = 0;
    int64_t created_ms = 0;
};

constexpr size_t kMaxSegments = 64;
constexpr size_t kMaxCidLen = 128;

struct Inventory {
    std::string id;        // sha256 hex over canonical bytes
    std::string canonical; // domain-prefixed canonical bytes (signed)
    std::string signature; // hex
};

enum class InvVerify { Valid, BadSignature, BadStructure, BadId };

// Canonical form: fixed field order, escaped text fields, segments in order.
std::string inventory_canonical(const InventoryDraft& d);
std::optional<Inventory> sign_inventory(const InventoryDraft& d, const KeyPair& archive_key);
InvVerify verify_inventory(const Inventory& inv, const std::string& expected_archive_pub_hex);

// Coverage check: every declared first/last bound must be well-formed; the
// caller cross-references event IDs against its verified local set.
bool coverage_shape_ok(const InventoryDraft& d);

} // namespace forum
