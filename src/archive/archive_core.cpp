#include "archive_core.h"
#include "forum_core.h"

#include <sstream>

namespace forum {

namespace {
std::string u64(uint64_t v) { return std::to_string(v); }
} // namespace

bool coverage_shape_ok(const InventoryDraft& d)
{
    if (d.segments.empty() || d.segments.size() > kMaxSegments) return false;
    for (const auto& s : d.segments) {
        if (s.cid.empty() || s.cid.size() > kMaxCidLen) return false;
        if (s.sha256.size() != 64) return false;
        if (s.bytes == 0) return false;
        if (s.post_count == 0) return false;
        if (s.first_event_id.size() != 64 || s.last_event_id.size() != 64) return false;
    }
    uint32_t sum = 0;
    for (const auto& s : d.segments) sum += s.post_count;
    if (sum != d.posts_covered) return false;
    return true;
}

std::string inventory_canonical(const InventoryDraft& d)
{
    // Escape is the forum_core field escaper (same wire hygiene).
    auto esc = [](const std::string& in) {
        std::string out;
        for (char c : in) {
            if (c == '\\') out += "\\\\";
            else if (c == '|') out += "\\p";
            else if (c == '\n') out += "\\n";
            else if (c == '\r') out += "\\r";
            else out.push_back(c);
        }
        return out;
    };
    std::ostringstream o;
    o << kInvDomain
      << "archive=" << d.archive_pub_hex << "|"
      << "epoch=" << u64(d.epoch) << "|"
      << "forum=" << esc(d.forum_id) << "|"
      << "predecessor=" << (d.predecessor_inv_id.empty() ? "" : d.predecessor_inv_id) << "|"
      << "posts=" << u64(d.posts_covered) << "|"
      << "created=" << u64(static_cast<uint64_t>(d.created_ms)) << "|"
      << "seg=";
    for (size_t i = 0; i < d.segments.size(); ++i) {
        const auto& s = d.segments[i];
        if (i) o << ";";
        o << s.cid << ":" << s.sha256 << ":" << u64(s.bytes) << ":"
          << u64(s.post_count) << ":" << s.first_event_id << ":" << s.last_event_id;
    }
    return o.str();
}

std::optional<Inventory> sign_inventory(const InventoryDraft& d, const KeyPair& archive_key)
{
    if (d.archive_pub_hex != archive_key.pub_hex) return std::nullopt;
    if (d.forum_id.empty() || d.forum_id.size() > 64) return std::nullopt;
    if (!d.predecessor_inv_id.empty() && d.predecessor_inv_id.size() != 64) return std::nullopt;
    if (!coverage_shape_ok(d)) return std::nullopt;
    Inventory inv;
    inv.canonical = inventory_canonical(d);
    inv.id = sha256_hex(inv.canonical);
    inv.signature = sign(archive_key.priv_hex, inv.canonical);
    if (inv.signature.empty()) return std::nullopt;
    return inv;
}

InvVerify verify_inventory(const Inventory& inv, const std::string& expected_archive_pub_hex)
{
    if (inv.canonical.rfind(kInvDomain, 0) != 0) return InvVerify::BadStructure;
    if (inv.id.size() != 64 || inv.signature.size() != 128) return InvVerify::BadStructure;
    if (sha256_hex(inv.canonical) != inv.id) return InvVerify::BadId;
    // The archive identity is INSIDE the signed canonical; the caller pins the
    // key it trusts and we require an exact match (no key substitution).
    if (inv.canonical.find("archive=" + expected_archive_pub_hex + "|") == std::string::npos) {
        return InvVerify::BadStructure;
    }
    if (!verify(expected_archive_pub_hex, inv.canonical, inv.signature)) {
        return InvVerify::BadSignature;
    }
    // Bounded parse of declared coverage + segments for shape.
    InventoryDraft probe;
    probe.archive_pub_hex = expected_archive_pub_hex;
    const auto postspos = inv.canonical.find("|posts=");
    if (postspos == std::string::npos) return InvVerify::BadStructure;
    probe.posts_covered = static_cast<uint32_t>(
        std::strtoul(inv.canonical.c_str() + postspos + 7, nullptr, 10));
    const auto segpos = inv.canonical.find("|seg=");
    if (segpos == std::string::npos) return InvVerify::BadStructure;
    std::string segs = inv.canonical.substr(segpos + 5);
    size_t start = 0;
    while (start < segs.size()) {
        size_t end = segs.find(';', start);
        if (end == std::string::npos) end = segs.size();
        const std::string one = segs.substr(start, end - start);
        // cid:sha:bytes:count:first:last
        std::vector<std::string> parts;
        size_t p0 = 0;
        for (int k = 0; k < 5; ++k) {
            size_t c = one.find(':', p0);
            if (c == std::string::npos) return InvVerify::BadStructure;
            parts.push_back(one.substr(p0, c - p0));
            p0 = c + 1;
        }
        parts.push_back(one.substr(p0));
        Segment s;
        s.cid = parts[0]; s.sha256 = parts[1];
        s.bytes = std::strtoull(parts[2].c_str(), nullptr, 10);
        s.post_count = static_cast<uint32_t>(std::strtoul(parts[3].c_str(), nullptr, 10));
        s.first_event_id = parts[4]; s.last_event_id = parts[5];
        probe.segments.push_back(s);
        start = end + 1;
    }
    if (!coverage_shape_ok(probe)) return InvVerify::BadStructure;
    return InvVerify::Valid;
}

} // namespace forum
