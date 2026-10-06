#include "forum_module_backend.h"

// Generated umbrella: typed dependency wrappers (delivery/storage).
#include "logos_sdk.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThread>

#include <algorithm>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
// "1 post", "3 posts": status lines are read by people, not parsed.
QString count(qint64 n, const char *one, const char *many)
{
    return QStringLiteral("%1 %2").arg(n).arg(QLatin1String(n == 1 ? one : many));
}
const QString kForumTopic = QStringLiteral("/lp0026forum/1/general/text");
const int kMaxPosts = 200;
// Bounds free-form slot input; post bodies are checked in UTF-8 bytes against
// forum::kMaxBody.
const int kMaxInputChars = 4096;
const int kMaxAutoRetries = 3;           // per post per session (no flooding)
const int kAutoRetryBaseMs = 15000;      // 15 s, 30 s, 60 s
const int kConnPollMs = 3000;
const int kHistoryDays = 7;
const int kHistoryPageLimit = 50;
const int kHistoryMaxPages = 10;         // ≤ 500 messages per request (bounded)
const qlonglong kHistoryTimeoutMs = 15000;
// Pacing (no flooding): up to kSendBurst sends at once, then one per interval
// (sustained <= 30 posts/min, whatever the outbox holds after a reconnect).
const int kSendBurst = 5;
const int kSendIntervalMs = 2000;
// Snapshots on Logos Storage: bounded both ways.
const int kMaxSnapshotEvents = 1000;
const qint64 kMaxSnapshotBytes = 4 * 1024 * 1024;
const int kUploadWaitS = 60;
const int kDownloadWaitS = 90;
const int kDownloadSettleS = 3;          // unchanged size for 3 s = complete
const int kDialWaitMs = 15000;              // wait for Storage's connect outcome
const int kDialRetryMs = 3000;
const int kMaxDials = 3;                    // dials (and downloads) per restore
const int kDownloadStartTimeoutMs = 75000; // manifest (30 s) + download start (30 s)
const QString kSnapshotMagic = QStringLiteral("logos-forum-snapshot v1");
// Also matched by Main.qml (root.snapshotTitle) and tools/windows_smoke.sh.
const QString kSnapshotTitle = QStringLiteral("Snapshot of this topic on Logos Storage");
// Entry nodes of the logos.dev preset shipped in Delivery 0.3.0
// (networks_config.nim). The node's automatic store catch-up already covers
// short gaps; these are asked explicitly, in order, for older history.
const char *const kHistoryPeers[] = {
    "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby",
    "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmMK7PYygBtKUQ8EHp7EfaD3bCEsJrkFooK8RQ2PVpJprH",
    "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397",
    "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8Y9kgBNtjxvCnf1X6gnZJW5EGE4UwwCL3CCm55TwqBiH",
    "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8YokiNun9BkeA1ZRmhLbtNUvcwRr64F69tYj9fkGyuEP",
    "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAkvwhGHKNry6LACrB8TmEFoCJKEX29XR5dDUzk3UT3UNSE",
};
const int kHistoryPeerCount = int(sizeof(kHistoryPeers) / sizeof(kHistoryPeers[0]));

// Collect every "cid" value in a Storage result (list of manifests, an
// object wrapping one, or JSON text of either).
void collectCids(const QJsonValue &v, QStringList &out)
{
    if (v.isArray()) {
        for (const auto &e : v.toArray()) collectCids(e, out);
    } else if (v.isObject()) {
        const QJsonObject o = v.toObject();
        const QString cid = o.value(QStringLiteral("cid")).toString();
        if (!cid.isEmpty()) out << cid;
        for (auto it = o.begin(); it != o.end(); ++it) {
            if (it.value().isArray() || it.value().isObject()) collectCids(it.value(), out);
        }
    }
}

QJsonValue resultJson(const QVariant &v)
{
    if (v.typeId() == QMetaType::QString || v.typeId() == QMetaType::QByteArray) {
        const QJsonDocument d = QJsonDocument::fromJson(v.toByteArray());
        if (d.isArray()) return d.array();
        if (d.isObject()) return d.object();
        return QJsonValue(v.toString());
    }
    return QJsonValue::fromVariant(v);
}

bool isConnected(const QString &status)
{
    return status == QLatin1String("Connected") ||
           status == QLatin1String("PartiallyConnected");
}
} // namespace

// Per-profile store: Basecamp installs the plugin at
// <user-dir>/plugins/forum_module/, so keep the data beside the host's own
// per-profile module data (<user-dir>/module_data/forum_module/). Without this
// every profile on a machine (QStandardPaths ignores --user-dir) would share
// one store — two "users" would see each other's accounts and posts locally.
// Returns "" when the plugin is not in that layout (e.g. read-only nix store).
QString ForumModuleBackend::profileStorePath()
{
#ifdef _WIN32
    HMODULE module = nullptr;
    wchar_t file[MAX_PATH];
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&ForumModuleBackend::profileStorePath),
                            &module)) {
        return QString();
    }
    const DWORD n = GetModuleFileNameW(module, file, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        return QString();
    }
    const QString pluginFile = QString::fromWCharArray(file, int(n));
#else
    Dl_info info;
    if (dladdr(reinterpret_cast<const void *>(&ForumModuleBackend::profileStorePath),
               &info) == 0 || info.dli_fname == nullptr) {
        return QString();
    }
    const QString pluginFile = QString::fromLocal8Bit(info.dli_fname);
#endif
    const QDir pluginDir = QFileInfo(pluginFile).absoluteDir();
    QDir userDir = pluginDir;
    if (!userDir.cdUp() || userDir.dirName() != QStringLiteral("plugins") || !userDir.cdUp()) {
        return QString();
    }
    const QString dataDir = userDir.absoluteFilePath(QStringLiteral("module_data/forum_module"));
    if (!QDir().mkpath(dataDir) || !QFileInfo(dataDir).isWritable()) {
        return QString();
    }
    return dataDir + QStringLiteral("/forum.db");
}

ForumModuleBackend::ForumModuleBackend()
{
    setStatus(QStringLiteral("Starting"));
    m_sendTokens = kSendBurst;
    m_tokensAt = QDateTime::currentMSecsSinceEpoch();
    m_paceTimer.setInterval(kSendIntervalMs);
    QObject::connect(&m_paceTimer, &QTimer::timeout, [this]() { drainSendQueue(); });
    // Fallback for the connection event: poll while connecting.
    m_connPoll.setInterval(kConnPollMs);
    QObject::connect(&m_connPoll, &QTimer::timeout, [this]() {
        if (!m_nodeStarted) { m_connPoll.stop(); return; }
        const LogosResult r = modules().delivery_module.getConnectionStatus();
        if (r.success) onConnectionStatus(r.getString());
    });
}

forum::Store *ForumModuleBackend::store()
{
    if (!m_store) {
        QString path = qEnvironmentVariable("FORUM_DB_PATH");
        if (path.isEmpty()) {
            path = profileStorePath();
        }
        if (path.isEmpty()) {
            const QString dir =
                QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
            QDir().mkpath(dir);
            path = dir + QStringLiteral("/forum.db");
        }
        m_store = std::make_unique<forum::Store>(path.toStdString());
        if (!m_store->ok()) {
            // Unwritable host (nix-sandboxed CI: /var/empty/...) — fail FAST
            // and honestly: the UI degrades to store-less refusals, and the
            // store-dependent flows run on the real-host drive instead.
            m_store.reset();
            return nullptr;
        }
        ensureTopic();
        refreshIdentityProps();
        refreshTopics();
        refreshThread();
    }
    return m_store.get();
}

bool ForumModuleBackend::ensureTopic()
{
    forum::Store *st = store();
    if (!st) return false;
    // The shared "General" topic is deterministic (same id on every instance),
    // so the composer always has a destination that other instances also show.
    auto tid = st->ensure_default_topic("general");
    if (!tid.has_value()) return false;
    if (m_currentTopicId.isEmpty()) {
        m_currentTopicId = QString::fromStdString(*tid);
    }
    return true;
}

QString ForumModuleBackend::echo(QString text)
{
    // Liveness probe: no side effects (it runs every few seconds).
    return text.left(kMaxInputChars);
}

QString ForumModuleBackend::transportStatus()
{
    if (!m_contextReady) {
        return QStringLiteral("backend context not ready — transport unverified");
    }
    QStringList parts;
    const LogosResult delivery = modules().delivery_module.getAvailableConfigs();
    if (delivery.success) {
        parts << QStringLiteral("delivery: present");
    } else {
        const QString err = delivery.getError<QString>();
        parts << (err.contains(QStringLiteral("not initialized"), Qt::CaseInsensitive)
                    ? QStringLiteral("delivery: present (loaded; node not created yet)")
                    : QStringLiteral("delivery: absent or unresponsive"));
    }
    const QString sv = modules().storage_module.version();
    parts << (sv.isEmpty() ? QStringLiteral("storage: absent or version unknown")
                           : QStringLiteral("storage: present (v%1)").arg(sv));
    if (forum::Store *st = store()) {
        int waiting = 0;
        for (const auto &r : st->posts()) {
            if (r.state == "pending" || r.state == "failed") ++waiting;
        }
        parts << QStringLiteral("outbox: %1 waiting to send").arg(count(waiting, "post", "posts"));
    } else {
        parts << QStringLiteral("outbox: unavailable (store error)");
    }
    parts << QStringLiteral("privacy: unverified until a Required send completes");
    return parts.join(QStringLiteral("; "));
}

QString ForumModuleBackend::createAccount(QString alias)
{
    const std::string a = alias.trimmed().toStdString();
    if (!forum::valid_alias(a) || a.empty()) {
        return QStringLiteral("error: alias must be 1-64 printable ASCII characters");
    }
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    const forum::KeyPair kp = forum::KeyPair::generate();
    if (!st->create_account(a, kp)) {
        return QStringLiteral("error: alias already exists");
    }
    // Select it immediately (accounts are for posting).
    m_selectedAlias = QString::fromStdString(a);
    m_selectedKey = kp;
    m_hasSelectedKey = true;
    refreshIdentityProps();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::selectIdentity(QString alias)
{
    const std::string a = alias.trimmed().toStdString();
    if (a.empty()) {
        m_selectedAlias.clear();
        m_hasSelectedKey = false;
        refreshIdentityProps();
        return QStringLiteral("ok");  // anonymous: fresh key per post
    }
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    auto kp = st->account(a);
    if (!kp.has_value()) return QStringLiteral("error: no such alias");
    m_selectedAlias = QString::fromStdString(a);
    m_selectedKey = *kp;
    m_hasSelectedKey = true;
    refreshIdentityProps();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::hideAlias(bool hide)
{
    m_aliasHidden = hide;
    refreshIdentityProps();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::rotateKey()
{
    if (!m_hasSelectedKey || m_selectedAlias.isEmpty()) {
        return QStringLiteral("error: choose an alias first — anonymous posts already use "
                              "a new key every time");
    }
    if (!store()) return QStringLiteral("error: local store unavailable");
    if (!rotateSelectedKey(QDateTime::currentMSecsSinceEpoch())) {
        return QStringLiteral("error: rotation failed");
    }
    refreshIdentityProps();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::setAutoRotate(int everyPosts)
{
    if (!m_hasSelectedKey || m_selectedAlias.isEmpty()) {
        return QStringLiteral("error: choose an alias first");
    }
    if (everyPosts < 0 || everyPosts > 1000) {
        return QStringLiteral("error: choose 0 (manual) to 1000 posts");
    }
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    if (!st->set_rotate_every(m_selectedAlias.toStdString(), uint32_t(everyPosts))) {
        return QStringLiteral("error: could not save the setting");
    }
    refreshIdentityProps();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::setAutoRotateDays(int days)
{
    if (!m_hasSelectedKey || m_selectedAlias.isEmpty()) {
        return QStringLiteral("error: choose an alias first");
    }
    if (days < 0 || days > 365) {
        return QStringLiteral("error: choose 0 (off) to 365 days");
    }
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    if (!st->set_rotate_days(m_selectedAlias.toStdString(), uint32_t(days),
                             QDateTime::currentMSecsSinceEpoch())) {
        return QStringLiteral("error: could not save the setting");
    }
    refreshIdentityProps();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::setSearch(QString text)
{
    m_search = text.trimmed().left(100).toLower();
    setSearchText(m_search);
    refreshTopics();
    refreshThread();
    return QStringLiteral("ok");
}

QString ForumModuleBackend::createTopic(QString title)
{
    const std::string t = title.trimmed().toStdString();
    if (t.empty() || t.size() > 128) {
        return QStringLiteral("error: title must be 1-128 characters");
    }
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    rotateIfDueByAge();
    forum::KeyPair k = m_hasSelectedKey ? m_selectedKey : forum::KeyPair::generate();
    auto tid = st->create_topic("general", t, currentSignerAlias().toStdString(), k,
                                QDateTime::currentMSecsSinceEpoch());
    if (!tid.has_value()) return QStringLiteral("error: topic rejected by validation");
    noteSigned();
    m_currentTopicId = QString::fromStdString(*tid);
    if (m_transportReady) {
        if (auto ev = st->stored_event(*tid)) {
            sendPaced(*ev);
        }
    }
    refreshTopics();
    refreshThread();
    return QString::fromStdString(*tid);
}

QString ForumModuleBackend::openTopic(QString topicId)
{
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    for (const auto &t : st->topics()) {
        if (QString::fromStdString(t.topic_id) == topicId) {
            m_currentTopicId = topicId;
            refreshThread();
            refreshTopics();
            return QStringLiteral("ok");
        }
    }
    return QStringLiteral("error: no such topic");
}

QString ForumModuleBackend::postMessage(QString text)
{
    if (text.trimmed().isEmpty()) return QStringLiteral("empty");
    // The signed body is bounded in UTF-8 bytes; never cut a post silently.
    if (text.toUtf8().size() > int(forum::kMaxBody)) return QStringLiteral("too long");
    rotateIfDueByAge();
    // Anonymous: a fresh key per post. Alias (shown or hidden): its key.
    const forum::KeyPair signer = m_hasSelectedKey ? m_selectedKey : forum::KeyPair::generate();
    m_lastSigned = false;
    const QString result = submitPost(text, signer, currentSignerAlias());
    // Every stored post counts, sent or not: a stored post goes out later
    // with the same signature (and so the same key id).
    if (m_lastSigned) noteSigned();
    return result;
}

bool ForumModuleBackend::rotateSelectedKey(int64_t nowMs)
{
    forum::Store *st = store();
    const forum::KeyPair fresh = forum::KeyPair::generate();
    if (!st || !st->rotate_account(m_selectedAlias.toStdString(), fresh, nowMs)) return false;
    m_selectedKey = fresh;
    return true;
}

void ForumModuleBackend::rotateIfDueByAge()
{
    // An alias key past its days-per-key never signs again: rotate first, so
    // the next post or topic already uses the fresh key.
    if (!m_hasSelectedKey || m_selectedAlias.isEmpty()) return;
    forum::Store *st = store();
    const int64_t now = QDateTime::currentMSecsSinceEpoch();
    if (st && st->key_due_by_age(m_selectedAlias.toStdString(), now)) rotateSelectedKey(now);
}

void ForumModuleBackend::noteSigned()
{
    // Automatic rotation: the NEXT post uses a fresh key once the alias's
    // threshold is reached.
    if (!m_hasSelectedKey || m_selectedAlias.isEmpty()) return;
    forum::Store *st = store();
    if (st && st->note_signed(m_selectedAlias.toStdString())) {
        rotateSelectedKey(QDateTime::currentMSecsSinceEpoch());
    }
    refreshIdentityProps();
}

QString ForumModuleBackend::submitPost(const QString &bounded, const forum::KeyPair &signer,
                                       const QString &alias)
{
    forum::Store *st = store();
    if (!st) {
        setStatus(QStringLiteral("posting unavailable: local store error — text kept"));
        return QStringLiteral("unavailable");
    }
    if (!ensureTopic()) {
        return QStringLiteral("failed");
    }

    forum::EventDraft draft;
    draft.forum_id = "general";
    draft.type = "post";
    draft.topic_id = m_currentTopicId.toStdString();
    draft.parent_id = m_currentTopicId.toStdString();
    draft.author_pub_hex = signer.pub_hex;
    draft.alias = alias.toStdString();
    draft.ts_ms = QDateTime::currentMSecsSinceEpoch();
    draft.body = bounded.toStdString();

    auto ev = st->make_event(draft, signer);
    if (!ev.has_value()) {
        setStatus(QStringLiteral("post rejected by local validation — text kept"));
        return QStringLiteral("failed");
    }
    if (!st->enqueue(*ev, "required")) {
        setStatus(QStringLiteral("post already stored locally"));
        return QString::fromStdString(ev->id).left(12);
    }
    const std::string eventId = ev->id;
    m_lastSigned = true;

    if (!m_transportReady && m_nodeStarted) {
        // Joined but not connected yet: keep it stored; it is sent through
        // Mix automatically once Delivery reports the connection.
        st->mark_state(eventId, "pending", "queued: waiting for the network connection");
        setTransportStateFromEvent(
            QStringLiteral("connecting to the Logos network — post queued; it will be "
                           "sent through Mix once connected (Required policy, no fallback)"));
        refreshTopics();
        refreshThread();
        return QStringLiteral("queued");
    }
    if (!m_transportReady) {
        // Not connected: the signed post is stored and waits; it goes out
        // through Mix only after the user connects (Required, no fallback).
        // The composer is cleared — the text lives in the store now, and
        // keeping it there too would invite a duplicate post.
        st->mark_state(eventId, "pending", "offline: waiting until you connect");
        setTransportStateFromEvent(
            QStringLiteral("offline — post stored; it is sent through Mix after you "
                           "connect (Required policy, no fallback)"));
        refreshTopics();
        refreshThread();
        return QStringLiteral("queued");
    }
    if (!sendPaced(*ev)) {
        // Stored as failed with an automatic retry scheduled: the post is not
        // lost, and re-sending the text would sign a second, different post.
        refreshTopics();
        refreshThread();
        return QStringLiteral("retrying");
    }
    refreshTopics();
    refreshThread();
    return QString::fromStdString(eventId).left(12);
}

bool ForumModuleBackend::sendPaced(const forum::Event &ev)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    m_sendTokens = std::min<double>(kSendBurst,
                                    m_sendTokens + double(now - m_tokensAt) / kSendIntervalMs);
    m_tokensAt = now;
    if (m_sendQueue.isEmpty() && m_sendTokens >= 1.0) {
        m_sendTokens -= 1.0;
        return dispatchWire(ev);
    }
    const QString id = QString::fromStdString(ev.id);
    if (!m_sendQueue.contains(id)) m_sendQueue << id;
    if (forum::Store *st = store()) {
        st->mark_state(ev.id, "pending", "queued: paced send (no flooding)");
    }
    if (!m_paceTimer.isActive()) m_paceTimer.start();
    setTransportStateFromEvent(
        QStringLiteral("%1 waiting their turn — up to %2 sends at once, then one "
                       "every %3 s (no flooding)")
            .arg(count(m_sendQueue.size(), "post", "posts")).arg(kSendBurst).arg(kSendIntervalMs / 1000));
    return true;
}

void ForumModuleBackend::drainSendQueue()
{
    forum::Store *st = store();
    if (!st || !m_transportReady || m_sendQueue.isEmpty()) {
        // Offline: the queue stays; becomeReady() flushes the outbox again.
        m_paceTimer.stop();
        return;
    }
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    m_sendTokens = std::min<double>(kSendBurst,
                                    m_sendTokens + double(now - m_tokensAt) / kSendIntervalMs);
    m_tokensAt = now;
    while (!m_sendQueue.isEmpty() && m_sendTokens >= 1.0) {
        const std::string id = m_sendQueue.takeFirst().toStdString();
        const auto ev = st->stored_event(id);
        if (!ev.has_value()) continue;
        m_sendTokens -= 1.0;
        dispatchWire(*ev);
    }
    if (m_sendQueue.isEmpty()) m_paceTimer.stop();
    refreshThread();
}

int ForumModuleBackend::retryPending()
{
    forum::Store *st = store();
    if (!st) return 0;
    if (!m_transportReady) {
        setTransportStateFromEvent(
            QStringLiteral("retry unavailable: transport not ready (posts stay stored)"));
        return 0;
    }
    return flushStored(QStringLiteral("retrying"));
}

int ForumModuleBackend::flushStored(const QString &why)
{
    forum::Store *st = store();
    if (!st || !m_transportReady) return 0;
    int resent = 0;
    for (const auto &r : st->posts()) {
        if (r.state != "failed" && r.state != "pending") continue;
        // In flight already (awaiting its propagation event): do not resend.
        if (m_requestToEvent.key(QString::fromStdString(r.event_id)).size() > 0) continue;
        const auto ev = st->stored_event(r.event_id);
        if (!ev.has_value()) continue;
        if (m_sendQueue.contains(QString::fromStdString(r.event_id))) continue;  // queued
        st->mark_state(r.event_id, "pending", "");
        if (sendPaced(*ev)) ++resent;
    }
    setTransportStateFromEvent(
        resent > 0
            ? QStringLiteral("%1 %2 with original signed "
                             "bytes (same event IDs — receivers dedup)")
                  .arg(why).arg(count(resent, "stored post", "stored posts"))
            : QStringLiteral("retry found nothing to resend"));
    refreshTopics();
    refreshThread();
    return resent;
}

void ForumModuleBackend::scheduleAutoRetry(const QString &eventId, const QString &error)
{
    const int used = m_autoRetries.value(eventId, 0);
    if (used >= kMaxAutoRetries) {
        setTransportStateFromEvent(
            QStringLiteral("Required send failed: %1 — the post is stored; automatic "
                           "retries used up, use Retry stored").arg(error));
        return;
    }
    m_autoRetries.insert(eventId, used + 1);
    const int delayMs = kAutoRetryBaseMs << used;
    setTransportStateFromEvent(
        QStringLiteral("Required send failed: %1 — the post is stored; automatic "
                       "retry %2/%3 in %4 s")
            .arg(error).arg(used + 1).arg(kMaxAutoRetries).arg(delayMs / 1000));
    QTimer::singleShot(delayMs, this, [this, eventId]() {
        forum::Store *st = store();
        if (!st || !m_transportReady) return;  // flushed on reconnect instead
        for (const auto &r : st->posts()) {
            if (QString::fromStdString(r.event_id) != eventId) continue;
            if (r.state != "failed") return;   // sent meanwhile
            if (const auto ev = st->stored_event(r.event_id)) {
                st->mark_state(r.event_id, "pending", "");
                sendPaced(*ev);
                refreshThread();
            }
            return;
        }
    });
}

void ForumModuleBackend::onConnectionStatus(const QString &status)
{
    m_connStatus = status;
    if (!m_nodeStarted) return;
    if (isConnected(status)) {
        if (!m_transportReady) becomeReady(status);
        return;
    }
    if (m_transportReady) {
        // Lost the network: stop sending; new posts queue until it returns.
        m_transportReady = false;
        m_requestToEvent.clear();
        setConnection(QStringLiteral("connecting"));
        setTransportStateFromEvent(
            QStringLiteral("connection lost (%1) — reconnecting; posts are stored and "
                           "sent once connected").arg(status));
        if (!m_connPoll.isActive()) m_connPoll.start();
    }
}

void ForumModuleBackend::becomeReady(const QString &status)
{
    m_transportReady = true;
    m_connPoll.stop();
    setConnection(QStringLiteral("connected"));
    setTransportStateFromEvent(
        QStringLiteral("transport ready: connected (%1) with Required policy on an "
                       "app-owned node — privacy verified per send via propagation "
                       "events").arg(status));
    refreshHistoryState();
    // Anything written while offline or connecting goes out now, once.
    forum::Store *st = store();
    bool any = false;
    if (st) {
        for (const auto &r : st->posts()) {
            if (r.state == "failed" || r.state == "pending") { any = true; break; }
        }
    }
    if (any) flushStored(QStringLiteral("connected — sending"));
    // Posts still waiting their paced turn when the connection dropped.
    if (!m_sendQueue.isEmpty() && !m_paceTimer.isActive()) m_paceTimer.start();
}

int ForumModuleBackend::mergeWirePayload(const QByteArray &payload, bool fromHistory)
{
    forum::Store *st = store();
    if (!st) return 0;
    const int nl = payload.indexOf('\n');
    if (nl <= 0) return 0;
    forum::Event ev;
    ev.canonical = std::string(payload.constData(), static_cast<size_t>(nl));
    ev.signature = std::string(payload.constData() + nl + 1,
                               static_cast<size_t>(payload.size() - nl - 1));
    ev.id = forum::sha256_hex(ev.canonical);
    // Everything is verified (id = hash, signature, bounds) before storing.
    if (st->merge_verified(ev) != forum::MergeResult::Accepted) return 0;
    if (fromHistory) ++m_historyAccepted; else ++m_liveAccepted;
    return 1;
}

QString ForumModuleBackend::loadHistory()
{
    if (!m_transportReady) {
        return QStringLiteral("not connected — connect to the Logos network first");
    }
    if (m_historyBusy) return QStringLiteral("already loading history");
    m_historyBusy = true;
    m_historyFetched = 0;
    setHistoryState(QStringLiteral("loading the last %1 days from a network store node…")
                        .arg(kHistoryDays));
    queryHistoryPage(0, 0, QString());
    return QStringLiteral("loading");
}

void ForumModuleBackend::queryHistoryPage(int peerIndex, int page, const QString &cursor)
{
    if (peerIndex >= kHistoryPeerCount) {
        m_historyBusy = false;
        setHistoryState(QStringLiteral("could not reach a store node for older history — "
                                       "posts made while you were away are still fetched "
                                       "automatically on connect"));
        return;
    }
    QJsonObject q;
    q.insert(QStringLiteral("requestId"),
             QStringLiteral("forum-history-%1-%2").arg(QDateTime::currentMSecsSinceEpoch()).arg(page));
    q.insert(QStringLiteral("includeData"), true);
    q.insert(QStringLiteral("paginationForward"), true);
    q.insert(QStringLiteral("paginationLimit"), kHistoryPageLimit);
    q.insert(QStringLiteral("contentTopics"), QJsonArray{kForumTopic});
    const qlonglong nowMs = QDateTime::currentMSecsSinceEpoch();
    q.insert(QStringLiteral("timeStart"),
             QString::number((nowMs - qlonglong(kHistoryDays) * 86400000LL) * 1000000LL).toLongLong());
    if (!cursor.isEmpty()) q.insert(QStringLiteral("paginationCursor"), cursor);
    const QString query = QString::fromUtf8(QJsonDocument(q).toJson(QJsonDocument::Compact));
    const QString peer = QString::fromLatin1(kHistoryPeers[peerIndex]);

    modules().delivery_module.storeQueryAsync(
        query, peer, kHistoryTimeoutMs,
        [this, peerIndex, page](LogosResult r) {
            QMetaObject::invokeMethod(this, [this, peerIndex, page, r]() {
                const QJsonObject resp = r.success ? resultJson(r.value).toObject() : QJsonObject();
                const int code = resp.value(QStringLiteral("statusCode")).toInt();
                if (!r.success || code != 200) {
                    // This node did not answer as a store: try the next one
                    // (only before any page was read, so results never mix).
                    if (page == 0) { queryHistoryPage(peerIndex + 1, 0, QString()); return; }
                    m_historyBusy = false;
                    setHistoryState(QStringLiteral("stopped after page %1 (%2); loaded %3, "
                                                   "%4 recovered in total")
                                        .arg(page)
                                        .arg(r.success ? QStringLiteral("status %1").arg(code)
                                                       : r.getError<QString>())
                                        .arg(count(m_historyFetched, "message", "messages"))
                                        .arg(count(m_historyAccepted, "post", "posts")));
                    return;
                }
                int added = 0;
                for (const auto &m : resp.value(QStringLiteral("messages")).toArray()) {
                    const QJsonObject msg = m.toObject().value(QStringLiteral("message")).toObject();
                    if (msg.value(QStringLiteral("contentTopic")).toString() != kForumTopic) continue;
                    const QByteArray b64 = msg.value(QStringLiteral("payload")).toString().toLatin1();
                    QByteArray raw = QByteArray::fromBase64(
                        b64, QByteArray::Base64Encoding | QByteArray::AbortOnBase64DecodingErrors);
                    if (raw.isEmpty()) {
                        raw = QByteArray::fromBase64(b64, QByteArray::Base64UrlEncoding);
                    }
                    ++m_historyFetched;
                    added += mergeWirePayload(raw, true);
                }
                if (added > 0) { refreshTopics(); refreshThread(); }
                const QString next = resp.value(QStringLiteral("paginationCursor")).toString();
                if (!next.isEmpty() && page + 1 < kHistoryMaxPages) {
                    queryHistoryPage(peerIndex, page + 1, next);
                    return;
                }
                m_historyBusy = false;
                setHistoryState(QStringLiteral("loaded %1 from the last %2 days "
                                               "on the network store; %3 recovered in total")
                                    .arg(count(m_historyFetched, "message", "messages"))
                                    .arg(kHistoryDays)
                                    .arg(count(m_historyAccepted, "post", "posts")));
            }, Qt::QueuedConnection);
        },
        Timeout(int(kHistoryTimeoutMs) + 5000));
}

void ForumModuleBackend::refreshHistoryState()
{
    if (!m_nodeStarted) { setHistoryState(QString()); return; }
    QString h;
    if (m_historyAccepted > 0) {
        h = QStringLiteral("%1 recovered from the network's history")
                .arg(count(m_historyAccepted, "post", "posts"));
    } else {
        h = m_transportReady ? QStringLiteral("no new posts in the network's history yet")
                             : QStringLiteral("history is fetched after connecting");
    }
    if (m_liveAccepted > 0) {
        h += QStringLiteral(" · %1 received live").arg(m_liveAccepted);
    }
    setHistoryState(h);
}

QString ForumModuleBackend::connectNetwork()
{
    if (!m_contextReady) {
        return QStringLiteral("backend context not ready — transport unverified");
    }
    // Documented Delivery 0.3.0 app form. logos.dev ships Mix nodes and needs
    // no RLN membership (logos.test requires a funded one).
    m_networkCfg = QStringLiteral(
        R"({"mode":"Core","preset":"logos.dev","messagingOverrides":{"anonymityLevel":"Required"}})");
    setConnection(QStringLiteral("connecting"));
    return recheckTransport();
}

QString ForumModuleBackend::recheckTransport()
{
    if (!m_contextReady) {
        return QStringLiteral("backend context not ready — transport unverified");
    }
    m_transportAttempted = false;
    m_transportReady = false;
    tryConfigureTransport();
    return transportState();
}

void ForumModuleBackend::onContextReady()
{
    m_contextReady = true;
    setStatus(QStringLiteral("Ready"));
    // NOTE: the store is opened LAZILY on first use (post/topic/status), not
    // here — the eager open inside the handshake window wedged the ui-host
    // before READY in sandboxed CI shapes (battery evidence: integration-21
    // vs -22/-23). First user action pays the open cost; the handshake stays
    // clean.

    // Event callbacks hop onto this thread before touching store/QtRO.
    modules().delivery_module.onMessagePropagated(
        [this](const QString &requestId, const QString &, qlonglong) {
            QMetaObject::invokeMethod(this, [this, requestId]() {
                markSent(requestId, QStringLiteral("Required send propagated"));
            }, Qt::QueuedConnection);
        });
    modules().delivery_module.onMessageSent(
        [this](const QString &requestId, const QString &, qlonglong) {
            QMetaObject::invokeMethod(this, [this, requestId]() {
                markSent(requestId, QStringLiteral("Required send validated by network"));
            }, Qt::QueuedConnection);
        });
    modules().delivery_module.onMessageError(
        [this](const QString &requestId, const QString &, const QString &error,
               qlonglong) {
            QMetaObject::invokeMethod(this, [this, requestId, error]() {
                const QString evId = m_requestToEvent.value(requestId);
                if (evId.isEmpty()) return;
                if (forum::Store *st = store()) {
                    st->mark_state(evId.toStdString(), "failed", error.toStdString());
                }
                m_requestToEvent.remove(requestId);
                scheduleAutoRetry(evId, error);
                refreshThread();
            }, Qt::QueuedConnection);
        });
    modules().delivery_module.onMessageReceived(
        [this](const QString &, const QString &contentTopic, QByteArray payload,
               const QString &source, qlonglong) {
            QMetaObject::invokeMethod(this, [this, contentTopic, payload, source]() {
                if (contentTopic != kForumTopic) return;
                // "history" = Delivery's store catch-up after start or a
                // connectivity gap: posts made while this reader was away.
                if (mergeWirePayload(payload, source == QLatin1String("history")) > 0) {
                    refreshHistoryState();
                    refreshTopics();
                    refreshThread();
                }
            }, Qt::QueuedConnection);
        });
    modules().delivery_module.onConnectionStateChanged(
        [this](const QString &status, qlonglong) {
            QMetaObject::invokeMethod(this, [this, status]() {
                onConnectionStatus(status);
            }, Qt::QueuedConnection);
        });

    tryConfigureTransport();
}

void ForumModuleBackend::markSent(const QString &requestId, const QString &what)
{
    const QString evId = m_requestToEvent.take(requestId);
    if (evId.isEmpty()) return;
    if (forum::Store *st = store()) st->mark_state(evId.toStdString(), "sent", "");
    setTransportStateFromEvent(QStringLiteral("%1 (request %2)").arg(what, requestId));
    refreshThread();
}

bool ForumModuleBackend::dispatchWire(const forum::Event &ev)
{
    const std::string wire = ev.canonical + "\n" + ev.signature;
    const QByteArray payload(wire.data(), static_cast<int>(wire.size()));
    const LogosResult sent = modules().delivery_module.send(kForumTopic, payload);
    if (!sent.success) {
        if (forum::Store *st = store()) {
            st->mark_state(ev.id, "failed",
                           sent.getError<QString>().toStdString());
        }
        scheduleAutoRetry(QString::fromStdString(ev.id), sent.getError<QString>());
        return false;
    }
    const QString requestId = sent.getString();
    m_requestToEvent.insert(requestId, QString::fromStdString(ev.id));
    setTransportStateFromEvent(
        QStringLiteral("sending via Required policy (request %1) — awaiting propagation")
            .arg(requestId));
    return true;
}

void ForumModuleBackend::refreshIdentityProps()
{
    QStringList names;
    QString rotation;
    int every = 0, days = 0;
    if (forum::Store *st = store()) {
        for (const auto &a : st->accounts()) {
            names << QString::fromStdString(a);
        }
        if (m_hasSelectedKey && !m_selectedAlias.isEmpty()) {
            if (const auto r = st->rotation(m_selectedAlias.toStdString())) {
                every = int(r->every);
                days = int(r->days);
                QStringList policy;
                if (r->every > 0) policy << count(r->every, "post", "posts");
                if (r->days > 0) policy << count(r->days, "day", "days");
                rotation = QStringLiteral("%1 on this key · %2 · %3")
                               .arg(count(r->posts_on_key, "post", "posts"))
                               .arg(r->rotations == 0 ? QStringLiteral("never rotated")
                                    : QStringLiteral("rotated ") + count(r->rotations, "time", "times"))
                               .arg(policy.isEmpty()
                                        ? QStringLiteral("rotation: manual")
                                        : QStringLiteral("new key every ") +
                                              policy.join(QStringLiteral(" or ")));
            }
        }
    }
    setAccounts(names);
    setSelectedAlias(m_selectedAlias);
    setSelectedUid(m_hasSelectedKey ? shortId(m_selectedKey.pub_hex) : QString());
    setAliasHidden(m_aliasHidden);
    setRotationInfo(rotation);
    setRotateEvery(every);
    setRotateDays(days);
}

namespace {
bool rowMatches(const forum::PostRecord &r, const QString &q)
{
    return QString::fromStdString(r.body).toLower().contains(q) ||
           QString::fromStdString(r.alias).toLower().contains(q) ||
           QString::fromStdString(r.author_pub_hex).left(16).contains(q);
}

// Author-chosen text as it may be shown: no line breaks, invisible or
// direction-changing characters (they could hide or reorder what is shown).
// Aliases are held to printable ASCII here too (forum::valid_alias), so rows
// stored before that rule can't imitate " · id "; their brackets are shown
// as parentheses so "[state]" stays the row's only bracketed part.
QString displaySafe(const QString &in, bool alias)
{
    QString out;
    out.reserve(in.size());
    for (const QChar c : in) {
        const QChar::Category cat = c.category();
        if ((alias && (c.unicode() < 0x20 || c.unicode() > 0x7e))
            || cat == QChar::Other_Control || cat == QChar::Other_Format
            || cat == QChar::Separator_Line || cat == QChar::Separator_Paragraph) {
            out += QChar(0xFFFD);
        } else if (alias && c == QLatin1Char('[')) {
            out += QLatin1Char('(');
        } else if (alias && c == QLatin1Char(']')) {
            out += QLatin1Char(')');
        } else {
            out += c;
        }
    }
    return out;
}
} // namespace

void ForumModuleBackend::refreshTopics()
{
    struct Row { QString line; int64_t last; };
    std::vector<Row> rows;
    if (forum::Store *st = store()) {
        std::vector<forum::PostRecord> all;
        if (!m_search.isEmpty()) all = st->posts();
        for (const auto &t : st->topics()) {
            const QString id = QString::fromStdString(t.topic_id);
            const QString title = displaySafe(QString::fromStdString(t.title), false);
            if (!m_search.isEmpty() && !title.toLower().contains(m_search)) {
                const bool hit = std::any_of(all.begin(), all.end(), [&](const forum::PostRecord &r) {
                    return r.type == "post" &&
                           (r.topic_id == t.topic_id || r.parent_id == t.topic_id) &&
                           rowMatches(r, m_search);
                });
                if (!hit) continue;
            }
            // Unread = posts that arrived since the topic was last shown.
            const uint32_t seen = st->seen(t.topic_id);
            const int unread = (id == m_currentTopicId || t.posts <= seen)
                                   ? 0 : int(t.posts - seen);
            rows.push_back({QStringLiteral("%1|%2 (%3)|%4")
                                .arg(id, title, QString::number(t.posts),
                                     QString::number(unread)),
                            t.last_ts});
        }
    }
    // Most recent activity first (stable: equal times keep creation order).
    std::stable_sort(rows.begin(), rows.end(),
                     [](const Row &a, const Row &b) { return a.last > b.last; });
    QStringList lines;
    for (const auto &r : rows) lines << r.line;
    setTopics(lines);
}

void ForumModuleBackend::refreshThread()
{
    QStringList lines;
    QStringList times;
    QString title;
    forum::Store *st = store();
    if (st && !m_currentTopicId.isEmpty()) {
        for (const auto &t : st->topics()) {
            if (QString::fromStdString(t.topic_id) == m_currentTopicId) {
                title = displaySafe(QString::fromStdString(t.title), false);
            }
        }
        const auto thread = st->thread(m_currentTopicId.toStdString());
        // Shown now = read now (local marker; never sent anywhere).
        st->mark_seen(m_currentTopicId.toStdString(), uint32_t(thread.size()));
        for (const auto &r : thread) {
            if (!m_search.isEmpty() && !rowMatches(r, m_search)) continue;
            // Aliases are self-asserted; the key id is what tells two "alice"s
            // apart. No alias = id only (an anonymous post's key is one-time).
            const QString id = QStringLiteral("id ") + shortId(r.author_pub_hex);
            // "[state]" and " · id " must be the row's only ones (displaySafe).
            const QString alias = displaySafe(QString::fromStdString(r.alias), true);
            const QString author = alias.isEmpty() ? id : alias + QStringLiteral(" · ") + id;
            lines << QStringLiteral("%1 [%2]: %3")
                          .arg(author, QString::fromStdString(r.state),
                               QString::fromStdString(r.body));
            // Author-asserted (signed) time, shown as written.
            times << QDateTime::fromMSecsSinceEpoch(r.ts_ms)
                         .toString(QStringLiteral("d MMM yyyy, HH:mm"));
        }
    }
    // Bounded rendering: keep the newest kMaxPosts rows.
    while (lines.size() > kMaxPosts) { lines.removeFirst(); times.removeFirst(); }
    setThreadPosts(lines);
    setThreadTimes(times);
    setCurrentTopicTitle(title);
    setCurrentTopicId(m_currentTopicId);
}

QString ForumModuleBackend::currentSignerAlias() const
{
    // empty = anonymous (fresh key per post) or alias hidden (account key, id only)
    return m_aliasHidden ? QString() : m_selectedAlias;
}

QString ForumModuleBackend::shortId(const std::string &pubHex)
{
    // 64 bits of the Ed25519 public key: short enough to read, long enough
    // that grinding a look-alike key is impractical for casual impersonation.
    return QString::fromStdString(pubHex.substr(0, 16));
}

void ForumModuleBackend::tryConfigureTransport()
{
    if (m_transportAttempted) return;
    m_transportAttempted = true;

    // An explicit config file (harnesses, local networks) wins; otherwise the
    // user's own "Connect to Logos network" choice; otherwise nothing.
    QString cfg;
    const QString cfgPath = qEnvironmentVariable("FORUM_TRANSPORT_CONFIG");
    if (!cfgPath.isEmpty()) {
        QFile f(cfgPath);
        if (!f.open(QIODevice::ReadOnly)) {
            setTransportStateFromEvent(
                QStringLiteral("transport config unreadable — posting unavailable"));
            return;
        }
        cfg = QString::fromUtf8(f.readAll());
        f.close();
    } else if (!m_networkCfg.isEmpty()) {
        cfg = m_networkCfg;
    } else {
        setTransportStateFromEvent(
            QStringLiteral("no transport configured — posting unavailable (Required policy)"));
        return;
    }

    const LogosResult nodeInfo =
        modules().delivery_module.getNodeInfo(QStringLiteral("MyPeerId"));
    if (nodeInfo.success) {
        const QString peer = nodeInfo.getString();
        if (!m_ownPeerId.isEmpty() && peer == m_ownPeerId) {
            // Re-check on our OWN node: still the Required node we configured.
            m_nodeStarted = true;
            const LogosResult cs = modules().delivery_module.getConnectionStatus();
            m_connStatus = cs.success ? cs.getString() : QStringLiteral("unknown");
            if (isConnected(m_connStatus)) {
                m_transportReady = true;
                setConnection(QStringLiteral("connected"));
                setTransportStateFromEvent(
                    QStringLiteral("transport ready: app-owned node confirmed (peer %1, %2) — "
                                   "Required policy unchanged").arg(peer.left(16), m_connStatus));
            } else {
                setConnection(QStringLiteral("connecting"));
                setTransportStateFromEvent(
                    QStringLiteral("connecting: app-owned node confirmed (peer %1, %2) — "
                                   "waiting for the network; posts are queued")
                        .arg(peer.left(16), m_connStatus));
                if (!m_connPoll.isActive()) m_connPoll.start();
            }
            return;
        }
        setTransportStateFromEvent(
            QStringLiteral("coexistence: a delivery node owned by another context "
                           "exists in this host (peer %1) — the forum will not "
                           "reconfigure it; posting unavailable until that node "
                           "provides the Required policy").arg(peer.left(16)));
        return;
    }
    const LogosResult created = modules().delivery_module.createNode(cfg);
    if (!created.success) {
        setTransportStateFromEvent(
            QStringLiteral("transport setup refused: %1 — posting unavailable")
                .arg(created.getError<QString>()));
        return;
    }
    const LogosResult started = modules().delivery_module.start();
    if (!started.success) {
        setTransportStateFromEvent(
            QStringLiteral("transport start failed: %1 — posting unavailable")
                .arg(started.getError<QString>()));
        return;
    }
    const LogosResult peerInfo =
        modules().delivery_module.getNodeInfo(QStringLiteral("MyPeerId"));
    if (peerInfo.success) m_ownPeerId = peerInfo.getString();

    const LogosResult sub = modules().delivery_module.subscribe(kForumTopic);
    if (!sub.success) {
        setTransportStateFromEvent(
            QStringLiteral("forum topic subscription failed: %1 — posting unavailable")
                .arg(sub.getError<QString>()));
        return;
    }
    m_nodeStarted = true;
    const LogosResult cs = modules().delivery_module.getConnectionStatus();
    m_connStatus = cs.success ? cs.getString() : QStringLiteral("unknown");
    if (isConnected(m_connStatus)) {
        becomeReady(m_connStatus);
        return;
    }
    setConnection(QStringLiteral("connecting"));
    setTransportStateFromEvent(
        QStringLiteral("connecting to the Logos network (%1) — waiting for peers and "
                       "the Mix pool; posts are stored and sent once connected")
            .arg(m_connStatus));
    refreshHistoryState();
    m_connPoll.start();
}

// ---- Logos Storage snapshots -------------------------------------------
//
// A snapshot is a text file: one header line, then one line per signed event
// (base64 of the exact wire form "canonical\nsignature"). Restoring verifies
// every event exactly like a received message, so a snapshot can add posts
// but never forge or alter one. Only posts already published through Mix
// (sent/received) are included: Storage is not anonymous, so nothing leaves
// this device through it that the network has not already seen.

QString ForumModuleBackend::snapshotDir()
{
    QString base = qEnvironmentVariable("FORUM_DB_PATH");
    if (base.isEmpty()) base = profileStorePath();
    // Beside the profile's store, named after it (forum.db -> forum-snapshots).
    const QString dir =
        base.isEmpty()
            ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                  + QStringLiteral("/forum-snapshots")
            : QFileInfo(base).absolutePath() + QLatin1Char('/')
                  + QFileInfo(base).completeBaseName() + QStringLiteral("-snapshots");
    QDir().mkpath(dir);
    return dir;
}

bool ForumModuleBackend::ensureStorage(QString *why)
{
    if (modules().storage_module.isRunning()) {
        m_storageStarted = true;
        wireStorageEvents();
        return true;
    }
    // An explicit config file (harnesses, local networks) wins; otherwise the
    // module's own default network, with its data kept in this profile.
    QString cfg;
    const QString cfgPath = qEnvironmentVariable("FORUM_STORAGE_CONFIG");
    if (!cfgPath.isEmpty()) {
        QFile f(cfgPath);
        if (!f.open(QIODevice::ReadOnly)) {
            *why = QStringLiteral("Logos Storage config unreadable");
            return false;
        }
        cfg = QString::fromUtf8(f.readAll());
    } else {
        const LogosResult def = modules().storage_module.loadConfigOrDefault();
        QJsonObject o = def.success ? resultJson(def.value).toObject() : QJsonObject();
        o.insert(QStringLiteral("data-dir"), snapshotDir() + QStringLiteral("/storage-data"));
        cfg = QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
    }
    // init() refuses when the host already initialised Storage; start() is
    // still worth trying in that case.
    const bool inited = modules().storage_module.init(cfg);
    bool started = false;
    // On Windows the first start() right after init() is often refused while
    // a second one succeeds (CI runs 37462255837, 37464920456, 37467422347):
    // try twice before reporting.
    for (int attempt = 0; attempt < 2 && !modules().storage_module.isRunning(); ++attempt) {
        started = modules().storage_module.start();
        for (int i = 0; i < 20 && !modules().storage_module.isRunning(); ++i) {
            QThread::msleep(250);
        }
    }
    if (!modules().storage_module.isRunning()) {
        *why = QStringLiteral("Logos Storage did not start (init %1, start %2)")
                   .arg(inited ? QStringLiteral("ok") : QStringLiteral("refused"),
                        started ? QStringLiteral("ok") : QStringLiteral("refused"));
        return false;
    }
    m_storageStarted = true;
    wireStorageEvents();
    return true;
}

void ForumModuleBackend::wireStorageEvents()
{
    // Subscribed only once the node runs (subscribing before init broke init).
    // Storage connect() just starts a dial; its outcome arrives here.
    if (m_storageEventsWired) return;
    m_storageEventsWired = true;
    modules().storage_module.onStorageConnect([this](const QString &payload) {
        QMetaObject::invokeMethod(this, [this, payload]() {
            const QJsonObject o = QJsonDocument::fromJson(payload.toUtf8()).object();
            onSnapshotPeerDialed(o.value(QStringLiteral("success")).toBool(),
                                 o.value(QStringLiteral("message")).toString());
        }, Qt::QueuedConnection);
    });
}

QStringList ForumModuleBackend::storageCids()
{
    QStringList out;
    const LogosResult m = modules().storage_module.manifests();
    if (m.success) collectCids(resultJson(m.value), out);
    return out;
}

QString ForumModuleBackend::archiveTopic()
{
    if (m_archiveBusy) return QStringLiteral("error: a snapshot is already being saved or restored");
    forum::Store *st = store();
    if (!st) return QStringLiteral("error: local store unavailable");
    if (m_currentTopicId.isEmpty()) return QStringLiteral("error: open a topic first");
    const std::string topic = m_currentTopicId.toStdString();

    QStringList lines;
    int posts = 0;
    auto add = [&](const std::string &id) {
        const auto ev = st->stored_event(id);
        if (!ev.has_value()) return;
        const std::string wire = ev->canonical + "\n" + ev->signature;
        lines << QString::fromLatin1(QByteArray(wire.data(), int(wire.size())).toBase64());
    };
    for (const auto &r : st->posts()) {
        if (r.event_id == topic && (r.state == "sent" || r.state == "received")) add(r.event_id);
    }
    for (const auto &r : st->thread(topic)) {
        if (r.state != "sent" && r.state != "received") continue;  // published only
        if (posts >= kMaxSnapshotEvents) break;
        add(r.event_id);
        ++posts;
    }
    if (posts == 0) {
        return QStringLiteral("error: nothing published in this topic yet — only posts "
                              "already sent through Mix go into a snapshot");
    }
    QString why;
    if (!ensureStorage(&why)) {
        setArchiveState(why);
        return QStringLiteral("error: ") + why;
    }
    const QString file = snapshotDir() + QStringLiteral("/topic-%1-%2.txt")
                                             .arg(m_currentTopicId.left(12))
                                             .arg(QDateTime::currentMSecsSinceEpoch());
    QFile f(file);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return QStringLiteral("error: could not write the snapshot file");
    }
    f.write((kSnapshotMagic + QStringLiteral(" topic=%1 posts=%2\n")
                                  .arg(m_currentTopicId).arg(posts)).toUtf8());
    f.write(lines.join(QLatin1Char('\n')).toLatin1());
    f.write("\n");
    f.close();

    const QStringList before = storageCids();
    const LogosResult up = modules().storage_module.uploadUrl(file, 65536, true);
    if (!up.success) {
        setArchiveState(QStringLiteral("Logos Storage refused the upload: %1")
                            .arg(up.getError<QString>()));
        return QStringLiteral("error: upload refused");
    }
    m_archiveBusy = true;
    setArchiveState(QStringLiteral("saving %1 to Logos Storage…").arg(count(posts, "post", "posts")));
    QTimer::singleShot(1000, this, [this, file, before, posts]() {
        pollUploadedCid(file, before, posts, 0);
    });
    return QStringLiteral("saving");
}

void ForumModuleBackend::pollUploadedCid(const QString &file, const QStringList &before,
                                         int posts, int attempt)
{
    QString cid;
    for (const QString &c : storageCids()) {
        if (!before.contains(c)) { cid = c; break; }
    }
    if (cid.isEmpty()) {
        if (attempt + 1 < kUploadWaitS) {
            QTimer::singleShot(1000, this, [this, file, before, posts, attempt]() {
                pollUploadedCid(file, before, posts, attempt + 1);
            });
            return;
        }
        m_archiveBusy = false;
        setArchiveState(QStringLiteral("the upload did not finish within %1 s — nothing was "
                                       "announced").arg(kUploadWaitS));
        return;
    }
    m_archiveBusy = false;
    announceSnapshot(cid, posts);
}

QString ForumModuleBackend::storagePeerId()
{
    const LogosResult pid = modules().storage_module.peerId();
    if (!pid.success) return QString();
    const QJsonValue v = resultJson(pid.value);
    return v.isObject() ? v.toObject().value(QStringLiteral("peerId")).toString() : v.toString();
}

void ForumModuleBackend::announceSnapshot(const QString &cid, int posts)
{
    // Where to fetch it from: this node's Storage peer id and addresses, so a
    // reader can connect directly even when the content DHT cannot find it.
    const QString peer = storagePeerId();
    QStringList addrs;
    const LogosResult dbg = modules().storage_module.debug();
    if (dbg.success) {
        const QJsonObject o = resultJson(dbg.value).toObject();
        QJsonArray a = o.value(QStringLiteral("announceAddresses")).toArray();
        if (a.isEmpty()) a = o.value(QStringLiteral("addrs")).toArray();
        for (const auto &x : a) {
            if (addrs.size() < 4) addrs << x.toString();
        }
    }
    QString body = kSnapshotTitle + QStringLiteral(": %1 post(s).\ncid: %2").arg(posts).arg(cid);
    if (!peer.isEmpty()) body += QStringLiteral("\npeer: ") + peer;
    if (!addrs.isEmpty()) body += QStringLiteral("\naddrs: ") + addrs.join(QLatin1Char(' '));
    // A one-time key: the announcement carries a network address, so it is
    // never tied to the user's alias or key id.
    const QString r = submitPost(body.left(kMaxInputChars), forum::KeyPair::generate(), QString());
    setArchiveState(QStringLiteral("saved %1 on Logos Storage (%2…) and announced it "
                                   "in this topic%3; this device serves the snapshot while "
                                   "Basecamp runs")
                        .arg(count(posts, "post", "posts")).arg(cid.left(16))
                        .arg(r == QLatin1String("queued") ? QStringLiteral(" (announcement "
                                                                           "queued until connected)")
                                                          : QString()));
}

QString ForumModuleBackend::restoreSnapshot(QString announcement)
{
    if (m_archiveBusy) return QStringLiteral("error: a snapshot is already being saved or restored");
    const QString text = announcement.left(kMaxInputChars).trimmed();
    QString cid;
    const auto cm = QRegularExpression(QStringLiteral("(?:^|\\n)cid: (\\S+)")).match(text);
    if (cm.hasMatch()) cid = cm.captured(1);
    else if (!text.contains(QRegularExpression(QStringLiteral("\\s")))) cid = text;
    if (!QRegularExpression(QStringLiteral("^[A-Za-z0-9]{20,128}$")).match(cid).hasMatch()) {
        return QStringLiteral("error: no snapshot CID found");
    }
    QString why;
    if (!ensureStorage(&why)) {
        setArchiveState(why);
        return QStringLiteral("error: ") + why;
    }
    const auto pm = QRegularExpression(QStringLiteral("(?:^|\\n)peer: (\\S+)")).match(text);
    const auto am = QRegularExpression(QStringLiteral("(?:^|\\n)addrs: ([^\\n]+)")).match(text);
    const int gen = m_restore.gen;  // stays monotonic: stale timers never match
    m_restore = Restore();
    m_restore.gen = gen;
    m_restore.cid = cid;
    // Only the newest download is kept: earlier ones are removed here.
    QDir dir(snapshotDir());
    for (const QString &old : dir.entryList({QStringLiteral("restore-*.txt")}, QDir::Files)) {
        dir.remove(old);
    }
    m_restore.file = snapshotDir() + QStringLiteral("/restore-%1-%2.txt")
                                         .arg(cid.left(16))
                                         .arg(QDateTime::currentMSecsSinceEpoch());
    if (pm.hasMatch() && am.hasMatch() && pm.captured(1) != storagePeerId()) {
        m_restore.peer = pm.captured(1).left(128);
        m_restore.addrs = am.captured(1).split(QLatin1Char(' '), Qt::SkipEmptyParts).mid(0, 4);
    }
    m_archiveBusy = true;
    setArchiveState(QStringLiteral("fetching snapshot %1… from Logos Storage").arg(cid.left(16)));
    if (m_restore.peer.isEmpty()) startDownload(cid, m_restore.file);  // content routing only
    else dialSnapshotPeer();
    return QStringLiteral("restoring");
}

void ForumModuleBackend::dialSnapshotPeer()
{
    // The download starts once the dial is confirmed (onSnapshotPeerDialed);
    // if no outcome arrives, it starts anyway after kDialWaitMs.
    const int gen = ++m_restore.gen;
    m_restore.dialing = true;
    ++m_restore.dials;
    const LogosResult c = modules().storage_module.connect(m_restore.peer, m_restore.addrs);
    if (!c.success) { onSnapshotPeerDialed(false, c.getError<QString>()); return; }
    QTimer::singleShot(kDialWaitMs, this, [this, gen]() {
        if (m_restore.dialing && m_restore.gen == gen) {
            m_restore.dialing = false;
            startDownload(m_restore.cid, m_restore.file);
        }
    });
}

void ForumModuleBackend::onSnapshotPeerDialed(bool ok, const QString &message)
{
    if (!m_archiveBusy || !m_restore.dialing) return;  // not ours / already moving
    m_restore.dialing = false;
    if (ok) { startDownload(m_restore.cid, m_restore.file); return; }
    m_restore.lastError = message;
    if (m_restore.dials < kMaxDials) {
        QTimer::singleShot(kDialRetryMs, this, [this]() { if (m_archiveBusy) dialSnapshotPeer(); });
        return;
    }
    m_archiveBusy = false;
    setArchiveState(QStringLiteral("could not reach the node serving snapshot %1…: %2 "
                                   "(it may be offline or not reachable from here)")
                        .arg(m_restore.cid.left(16), message));
}

void ForumModuleBackend::startDownload(const QString &cid, const QString &file)
{
    // Asynchronous: the Storage module fetches the manifest before it returns
    // a session (up to 30 s each for the manifest and the download start),
    // longer than a default module call may block.
    modules().storage_module.downloadToUrlAsync(
        cid, file, false, 65536, false, false,
        [this, cid, file](LogosResult d) {
            QMetaObject::invokeMethod(this, [this, cid, file, d]() {
                if (!d.success) {
                    // The manifest was not found: dial the serving node again
                    // (a fresh connection) while attempts remain.
                    if (!m_restore.peer.isEmpty() && m_restore.dials < kMaxDials) {
                        QTimer::singleShot(kDialRetryMs, this,
                                           [this]() { if (m_archiveBusy) dialSnapshotPeer(); });
                        return;
                    }
                    m_archiveBusy = false;
                    setArchiveState(QStringLiteral("could not fetch snapshot %1… from Logos "
                                                   "Storage after %2 attempt(s): %3 (the node "
                                                   "that serves it may be offline)")
                                        .arg(cid.left(16)).arg(qMax(1, m_restore.dials))
                                        .arg(d.getError<QString>()));
                    return;
                }
                m_downloadSession = d.getString();
                QTimer::singleShot(1000, this, [this, cid, file]() { pollDownload(cid, file, -1, 0, 0); });
            }, Qt::QueuedConnection);
        },
        Timeout(kDownloadStartTimeoutMs));
}

void ForumModuleBackend::pollDownload(const QString &cid, const QString &file,
                                      qint64 lastSize, int attempt, int stable)
{
    const qint64 size = QFileInfo(file).exists() ? QFileInfo(file).size() : -1;
    if (size > kMaxSnapshotBytes) {
        if (!m_downloadSession.isEmpty()) modules().storage_module.downloadCancel(m_downloadSession);
        QFile::remove(file);
        m_archiveBusy = false;
        setArchiveState(QStringLiteral("snapshot %1… is larger than %2 MiB — refused")
                            .arg(cid.left(16)).arg(kMaxSnapshotBytes / (1024 * 1024)));
        return;
    }
    // Done when the file exists and has not grown for kDownloadSettleS polls
    // (a short stall mid-download must not merge a partial file).
    const int settled = (size > 0 && size == lastSize) ? stable + 1 : 0;
    if (settled >= kDownloadSettleS) {
        mergeSnapshotFile(cid, file);
        return;
    }
    if (attempt + 1 >= kDownloadWaitS) {
        m_archiveBusy = false;
        setArchiveState(QStringLiteral("could not fetch snapshot %1… within %2 s — the node "
                                       "serving it may be offline or unreachable")
                            .arg(cid.left(16)).arg(kDownloadWaitS));
        return;
    }
    QTimer::singleShot(1000, this, [this, cid, file, size, attempt, settled]() {
        pollDownload(cid, file, size, attempt + 1, settled);
    });
}

void ForumModuleBackend::mergeSnapshotFile(const QString &cid, const QString &file)
{
    m_archiveBusy = false;
    forum::Store *st = store();
    QFile f(file);
    if (!st || !f.open(QIODevice::ReadOnly)) {
        setArchiveState(QStringLiteral("snapshot %1… downloaded but unreadable").arg(cid.left(16)));
        return;
    }
    const QList<QByteArray> lines = f.read(kMaxSnapshotBytes).split('\n');
    f.close();
    if (lines.isEmpty() || !lines.first().startsWith(kSnapshotMagic.toLatin1())) {
        setArchiveState(QStringLiteral("%1… is not a forum snapshot — ignored").arg(cid.left(16)));
        return;
    }
    int added = 0, known = 0, rejected = 0, unstored = 0;
    std::vector<std::string> verifiedIds;
    for (int i = 1; i < lines.size() && i <= kMaxSnapshotEvents + 1; ++i) {
        if (lines[i].trimmed().isEmpty()) continue;
        const QByteArray raw = QByteArray::fromBase64(
            lines[i].trimmed(), QByteArray::Base64Encoding | QByteArray::AbortOnBase64DecodingErrors);
        const int nl = raw.indexOf('\n');
        if (nl <= 0) { ++rejected; continue; }
        forum::Event ev;
        ev.canonical = std::string(raw.constData(), size_t(nl));
        ev.signature = std::string(raw.constData() + nl + 1, size_t(raw.size() - nl - 1));
        ev.id = forum::sha256_hex(ev.canonical);
        // The same verification as a live message: id = hash, signature, bounds.
        switch (st->merge_verified(ev)) {
        case forum::MergeResult::Accepted: ++added; verifiedIds.push_back(ev.id); break;
        case forum::MergeResult::Duplicate: ++known; verifiedIds.push_back(ev.id); break;
        case forum::MergeResult::Invalid: ++rejected; break;
        case forum::MergeResult::StoreError: ++unstored; break;
        }
    }
    // Show what was restored: open the snapshot's topic.
    for (const auto &p : st->posts()) {
        if (!p.topic_id.empty() && std::find(verifiedIds.begin(), verifiedIds.end(),
                                             p.event_id) != verifiedIds.end()) {
            m_currentTopicId = QString::fromStdString(p.topic_id);
            break;
        }
    }
    refreshTopics();
    refreshThread();
    setArchiveState(QStringLiteral("restored from Logos Storage (%1…): %2, %3 "
                                   "already here, %4 rejected by verification%5")
                        .arg(cid.left(16), count(added, "new post", "new posts"),
                             QString::number(known), QString::number(rejected),
                             unstored > 0 ? QStringLiteral("; %1 could not be stored (local "
                                                           "database error)").arg(unstored)
                                          : QString()));
}
