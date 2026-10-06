#pragma once

#include "rep_forum_module_source.h"
#include "logos_ui_plugin_context.h"
#include "forum_core.h"

#include <QObject>
#include <QHash>
#include <QTimer>
#include <memory>

/**
 * @brief UI backend for the forum view (universal authoring model).
 *
 * Thin QtRO adapter over the Qt-free core (src/core). Pipeline per action:
 * canonicalise → sign → DURABILY ENQUEUE (privacy=required) → then attempt
 * transport dispatch. Failure keeps the stored row and the composer text.
 * Event callbacks hop onto this object's thread (Qt::QueuedConnection)
 * before touching the store or QtRO.
 *
 * Identity: accounts persist aliases + keys in the local store; anonymous
 * posting uses a FRESH key per post with no alias in the wire form.
 * A "General" topic is auto-created on first use so the composer always
 * has a destination (honest, visible in the topic list).
 */
class ForumModuleBackend : public ForumSimpleSource,
                           public LogosUiPluginContext
{
public:
    ForumModuleBackend();

    QString echo(QString text) override;
    QString transportStatus() override;
    QString recheckTransport() override;
    QString connectNetwork() override;

    QString createAccount(QString alias) override;
    QString selectIdentity(QString alias) override;
    QString hideAlias(bool hide) override;
    QString rotateKey() override;
    QString setAutoRotate(int everyPosts) override;
    QString setAutoRotateDays(int days) override;
    QString createTopic(QString title) override;
    QString openTopic(QString topicId) override;
    QString setSearch(QString text) override;
    QString postMessage(QString text) override;
    int retryPending() override;
    QString loadHistory() override;
    QString archiveTopic() override;
    QString restoreSnapshot(QString announcement) override;

    void onContextReady() override;

private:
    forum::Store *store();  // lazy open; nullptr on failure (honest surfacing)
    static QString profileStorePath();  // <user-dir>/module_data/forum_module/forum.db or ""
    void setTransportStateFromEvent(const QString &state)
    {
        setTransportState(state);  // generated PROP setter (QtRO-synced)
    }
    void tryConfigureTransport();
    void refreshIdentityProps();
    void rotateIfDueByAge();                 // before signing with an alias key
    void noteSigned();                       // after: counts toward rotate-every-N
    void refreshTopics();
    void refreshThread();
    bool ensureTopic();                      // auto "General"
    bool dispatchWire(const forum::Event &ev);  // send if transport ready
    // Connection lifecycle: a started node is "connecting" until Delivery
    // reports Connected/PartiallyConnected (for Required that includes a
    // ready Mix pool); only then are posts sent. Posts written meanwhile are
    // stored and flushed on the transition.
    void onConnectionStatus(const QString &status);
    void becomeReady(const QString &status);
    int flushStored(const QString &why);       // resend failed/pending rows
    void scheduleAutoRetry(const QString &eventId, const QString &error);
    void refreshHistoryState();
    void queryHistoryPage(int peerIndex, int page, const QString &cursor);
    int mergeWirePayload(const QByteArray &payload, bool fromHistory);  // 1 if new
    // Sign + durably store + send (paced) one post in the current topic.
    QString submitPost(const QString &text, const forum::KeyPair &signer,
                       const QString &alias);
    // Pacing (no flooding): a token bucket in front of dispatchWire. Sends
    // beyond the burst wait in m_sendQueue and drain one per interval.
    bool sendPaced(const forum::Event &ev);
    void drainSendQueue();
    // Logos Storage (snapshots). Storage is started on first use only.
    bool ensureStorage(QString *why);
    QString snapshotDir();
    void pollUploadedCid(const QString &file, const QStringList &before, int posts, int attempt);
    void announceSnapshot(const QString &cid, int posts);
    void wireStorageEvents();
    void dialSnapshotPeer();
    void onSnapshotPeerDialed(bool ok, const QString &message);
    void startDownload(const QString &cid, const QString &file);
    void pollDownload(const QString &cid, const QString &file, qint64 lastSize, int attempt,
                      int stable);
    void mergeSnapshotFile(const QString &cid, const QString &file);
    QStringList storageCids();
    QString currentSignerAlias() const;      // selectedAlias, or "" (anonymous / alias hidden)
    static QString shortId(const std::string &pubHex);  // display id of a public key

    bool m_contextReady = false;
    bool m_transportAttempted = false;
    bool m_transportReady = false;
    bool m_nodeStarted = false;              // createNode+start+subscribe succeeded
    QString m_connStatus;                    // last Delivery connection status
    QTimer m_connPoll;                       // fallback poll while connecting
    QHash<QString, int> m_autoRetries;       // event id -> automatic retries used
    int m_historyAccepted = 0;               // new posts recovered via store backfill
    int m_liveAccepted = 0;                  // new posts received live
    bool m_historyBusy = false;              // a loadHistory() query is running
    int m_historyFetched = 0;                // messages seen by the current query
    QString m_ownPeerId;
    QString m_networkCfg;                    // set by connectNetwork(); env config wins
    QString m_selectedAlias;                 // "" = anonymous
    forum::KeyPair m_selectedKey;            // valid when alias non-empty
    bool m_hasSelectedKey = false;
    bool m_aliasHidden = false;
    QString m_search;                        // topic/thread filter (lower-case)
    double m_sendTokens = 0;                 // pacing bucket (refilled on use)
    qint64 m_tokensAt = 0;
    QStringList m_sendQueue;                 // event ids waiting for a token
    QTimer m_paceTimer;
    bool m_storageStarted = false;
    bool m_archiveBusy = false;
    bool m_lastSigned = false;               // submitPost stored a new signed post
    bool m_storageEventsWired = false;
    struct Restore {
        QString cid, file, peer, lastError;
        QStringList addrs;
        int dials = 0, gen = 0;
        bool dialing = false;
    } m_restore;
    QString m_downloadSession;               // Storage download session (for cancel)
    QString m_currentTopicId;
    QString m_lastSendRequest;
    QHash<QString, QString> m_requestToEvent; // requestId -> event id
    QStringList m_receivedPosts;
    std::unique_ptr<forum::Store> m_store;
};
