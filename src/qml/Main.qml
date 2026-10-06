import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// LP-0026 Forum — the forum view. Plain text only: no remote images,
// avatars, previews, or automatic outbound requests from rendered content.
// States shown are honest: pending/sent/failed per post; transport refusal
// keeps the composer text; a dead backend is surfaced, never hidden.
Item {
    id: root

    readonly property var backend: logos.module("forum_module")
    property bool ready: false
    // Transport diagnostics are for troubleshooting; folded away by default.
    property bool showDetails: false
    readonly property string status: backend ? backend.status : ""
    readonly property string transportState: backend ? backend.transportState : ""
    readonly property string connection: backend ? backend.connection : "offline"
    // The "Connecting…" hint from the Connect button must not outlive it.
    onConnectionChanged: {
        if (connection === "connected" && outcome.text.startsWith("Connecting"))
            outcome.text = "Connected — posts go out through Mix."
    }
    readonly property string historyState: backend ? backend.historyState : ""
    readonly property var accounts: backend ? backend.accounts : []
    readonly property string selectedAlias: backend ? backend.selectedAlias : ""
    readonly property string selectedUid: backend ? backend.selectedUid : ""
    readonly property bool aliasHidden: backend ? backend.aliasHidden : false
    readonly property string rotationInfo: backend ? backend.rotationInfo : ""
    readonly property int rotateEvery: backend ? backend.rotateEvery : 0
    readonly property int rotateDays: backend ? backend.rotateDays : 0
    readonly property string searchText: backend ? backend.searchText : ""
    readonly property string archiveState: backend ? backend.archiveState : ""
    readonly property var topics: backend ? backend.topics : []
    readonly property string currentTopicId: backend ? backend.currentTopicId : ""
    readonly property string currentTopicTitle: backend ? backend.currentTopicTitle : ""
    readonly property var threadPosts: backend ? backend.threadPosts : []
    readonly property var threadTimes: backend ? backend.threadTimes : []
    readonly property int maxPostBytes: 4096   // the signed body's limit, in UTF-8 bytes
    // Narrow windows stack the topic list above the thread.
    readonly property bool compact: width < 760
    readonly property string snapshotTitle: "Snapshot of this topic on Logos Storage"

    // Light palette: Basecamp hosts module views on a white panel.
    readonly property color cText: "#1f2328"
    readonly property color cMuted: "#59636e"
    readonly property color cBorder: "#d1d9e0"
    readonly property color cSurface: "#f6f8fa"
    readonly property color cAccent: "#6639ba"
    readonly property color cGood: "#1a7f37"
    readonly property color cWarn: "#9a6700"
    readonly property color cBad: "#cf222e"

    // Honest liveness (ping after handshake; a dead backend disables actions).
    property double lastBackendOk: Date.now()
    property int aliveTick: 0
    Timer {
        interval: 3000
        running: root.backend !== null && root.ready
        repeat: true
        onTriggered: {
            if (root.backend === null) return
            logos.watch(root.backend.echo("liveness"), function (v) {
                root.lastBackendOk = Date.now()
            }, function (e) {
                root.lastBackendOk = Date.now()
            })
        }
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.aliveTick++
    }
    // Show this profile's saved topics and posts as soon as the module opens.
    // The backend opens its store lazily (never inside the handshake), so ask
    // once, shortly after it reports ready; setSearch("") is side-effect free.
    property bool storeOpened: false
    Timer {
        interval: 300
        running: root.ready && !root.storeOpened && root.backend !== null
        onTriggered: {
            root.storeOpened = true
            logos.watch(root.backend.setSearch(""), function (v) {}, function (e) {})
        }
    }
    // Honest liveness: optimistic before the handshake (no pings yet), real
    // decay afterwards.
    readonly property bool backendAlive:
        !root.ready || (aliveTick, Date.now() - lastBackendOk) < 10000
    readonly property bool usable: root.backendAlive && root.backend !== null

    Connections {
        target: logos
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "forum_module") {
                root.ready = isReady && root.backend !== null
                if (root.ready) root.lastBackendOk = Date.now()  // start decay at handshake
            }
        }
    }
    Component.onCompleted: {
        root.ready = root.backend !== null && logos.isViewModuleReady("forum_module")
        if (root.ready) root.lastBackendOk = Date.now()
    }

    // Parse a thread row "<author> [state]: body" (backend contract).
    function utf8Bytes(s) {
        var n = 0
        for (var i = 0; i < s.length; ++i) {
            var c = s.charCodeAt(i)
            if (c < 0x80) n += 1
            else if (c < 0x800) n += 2
            else if (c >= 0xD800 && c < 0xDC00) { n += 4; ++i }  // surrogate pair
            else n += 3
        }
        return n
    }
    function rowParts(line) {
        var m = /^(.*?) \[(\w+)\]: ([\s\S]*)$/.exec(line)
        if (!m) return { author: "", state: "", body: line }
        return { author: m[1], state: m[2], body: m[3] }
    }
    // Parse a topic row "<id>|<title (N)>|<unread>" (backend contract).
    function topicParts(line) {
        var p = line.split("|")
        return { id: p[0], label: p.slice(1, p.length - 1).join("|"), unread: parseInt(p[p.length - 1]) || 0 }
    }
    function stateLabel(s) {
        if (s === "pending") return root.connection === "connected" ? "sending…" : "waiting to send"
        if (s === "failed") return "not sent — kept for retry"
        return s
    }
    function stateColor(s) {
        if (s === "sent") return root.cGood
        if (s === "failed") return root.cBad
        if (s === "pending") return root.cWarn
        return root.cMuted
    }

    Rectangle { anchors.fill: parent; color: "#ffffff" }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        // ---- Header: title + network status ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            ColumnLayout {
                spacing: 2
                Text {
                    text: "Logos Forum"
                    font.pixelSize: 22
                    font.bold: true
                    color: root.cText
                }
                Text {
                    text: !root.backendAlive ? "Backend unresponsive — restart the app"
                         : (root.ready ? "Module ready" : "Starting…")
                    color: !root.backendAlive ? root.cBad : root.cMuted
                    font.pixelSize: 11
                }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                id: networkChip
                objectName: "networkChip"
                radius: 14
                color: root.cSurface
                border.color: root.cBorder
                implicitHeight: 30
                implicitWidth: chipRow.implicitWidth + 24
                RowLayout {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 8
                    Rectangle {
                        width: 9; height: 9; radius: 5
                        color: root.connection === "connected" ? root.cGood
                             : root.connection === "connecting" ? root.cWarn : "#8c959f"
                    }
                    Text {
                        id: networkLabel
                        objectName: "networkLabel"
                        text: root.connection === "connected" ? "Connected to logos.dev · sending through Mix"
                            : root.connection === "connecting" ? "Connecting to logos.dev…"
                            : "Offline — not connected"
                        color: root.cText
                        font.pixelSize: 13
                    }
                }
            }
            Button {
                id: connectButton
                // Joining a public network is the user's explicit choice.
                text: "Connect to Logos network"
                visible: root.connection === "offline"
                enabled: root.usable
                ToolTip.visible: hovered
                ToolTip.text: "Joins the public logos.dev network. Posts are only ever sent through the Mix anonymity network — never as plain messages."
                onClicked: {
                    outcome.text = "Connecting… posts you write now are saved and sent once connected."
                    logos.watch(root.backend.connectNetwork(), function (v) {
                    }, function (e) { outcome.text = "Error: " + e })
                }
            }
        }

        // ---- Identity ----
        Rectangle {
            Layout.fillWidth: true
            color: root.cSurface
            border.color: root.cBorder
            radius: 8
            implicitHeight: identityCol.implicitHeight + 20
            ColumnLayout {
                id: identityCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "Posting as"; color: root.cText; font.pixelSize: 13; font.bold: true
                        height: identityBox.height; verticalAlignment: Text.AlignVCenter
                    }
                    ComboBox {
                        id: identityBox
                        model: ["Anonymous"].concat(root.accounts)
                        enabled: root.usable
                        width: 210
                        Accessible.name: "Posting identity"
                        // Follow the backend's selection (createAccount auto-selects the
                        // new alias); a model reset would otherwise snap back to index 0.
                        function syncToBackend() {
                            currentIndex = root.selectedAlias === ""
                                ? 0 : root.accounts.indexOf(root.selectedAlias) + 1
                        }
                        onModelChanged: syncToBackend()
                        Connections {
                            target: root
                            function onSelectedAliasChanged() { identityBox.syncToBackend() }
                        }
                        onActivated: {
                            var name = currentIndex === 0 ? "" : model[currentIndex]
                            logos.watch(root.backend.selectIdentity(name), function (v) {
                                outcome.text = v === "ok" ? ("Now posting as " + (name || "anonymous")) : v
                            }, function (e) { outcome.text = "Error: " + e })
                        }
                    }
                    CheckBox {
                        id: hideAliasBox
                        text: "Hide my alias (show key id only)"
                        visible: root.selectedAlias !== ""
                        enabled: root.usable && root.selectedAlias !== ""
                        checked: root.aliasHidden
                        onToggled: logos.watch(root.backend.hideAlias(checked), function (v) {
                            outcome.text = checked ? "Posting with key id only" : "Posting with alias + key id"
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    TextField {
                        id: aliasInput
                        placeholderText: "new alias"
                        enabled: root.usable
                        width: 140
                        Accessible.name: "New alias"
                        onAccepted: if (addAliasButton.enabled) addAliasButton.clicked()
                    }
                    Button {
                        id: addAliasButton
                        text: "Add alias"
                        enabled: root.usable && aliasInput.text.length > 0
                        onClicked: logos.watch(root.backend.createAccount(aliasInput.text), function (v) {
                            outcome.text = v === "ok" ? "Alias created" : v
                            if (v === "ok") aliasInput.text = ""
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                }
                // Key rotation: unlinks later posts from earlier ones.
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: root.selectedAlias !== ""
                    Button {
                        id: rotateButton
                        objectName: "rotateButton"
                        text: "New key now"
                        flat: true
                        enabled: root.usable
                        ToolTip.visible: hovered
                        ToolTip.text: "Switch this alias to a fresh key. Earlier posts stay valid, but later posts no longer share their key id. Readers still see the alias name unless you hide it."
                        onClicked: logos.watch(root.backend.rotateKey(), function (v) {
                            outcome.text = v === "ok" ? ("New key: id " + root.selectedUid) : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    ComboBox {
                        id: autoRotateBox
                        objectName: "autoRotateBox"
                        readonly property var steps: [0, 5, 10, 25, 100]
                        model: ["By posts: off", "Rotate every 5 posts", "Rotate every 10 posts",
                                "Rotate every 25 posts", "Rotate every 100 posts"]
                        width: 200
                        enabled: root.usable
                        Accessible.name: "Automatic key rotation by posts"
                        currentIndex: Math.max(0, steps.indexOf(root.rotateEvery))
                        onActivated: logos.watch(root.backend.setAutoRotate(steps[currentIndex]), function (v) {
                            outcome.text = v === "ok" ? (steps[currentIndex] === 0
                                ? "Automatic rotation off" : ("A new key every " + steps[currentIndex] + " posts"))
                                : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    ComboBox {
                        id: autoRotateDaysBox
                        objectName: "autoRotateDaysBox"
                        readonly property var steps: [0, 1, 7, 30]
                        model: ["By age: off", "Rotate daily", "Rotate weekly", "Rotate monthly"]
                        width: 170
                        enabled: root.usable
                        Accessible.name: "Automatic key rotation by age"
                        currentIndex: Math.max(0, steps.indexOf(root.rotateDays))
                        onActivated: logos.watch(root.backend.setAutoRotateDays(steps[currentIndex]), function (v) {
                            outcome.text = v === "ok" ? (steps[currentIndex] === 0
                                ? "Rotation by age off" : ("A new key once the current one is " + steps[currentIndex] + (steps[currentIndex] === 1 ? " day" : " days") + " old"))
                                : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    Text {
                        objectName: "rotationInfo"
                        text: root.rotationInfo
                        color: root.cMuted; font.pixelSize: 12
                        height: rotateButton.height; verticalAlignment: Text.AlignVCenter
                    }
                }
                Text {
                    id: identityHint
                    objectName: "identityHint"  // stable handle for property-only drivers
                    // Privacy implications stated where the choice is made.
                    text: root.selectedAlias === ""
                          ? "Identity: anonymous — a new one-time key per post; your posts cannot be linked to each other"
                          : root.aliasHidden
                            ? ("Identity: id " + root.selectedUid + " (alias hidden) — your posts are linkable to each other")
                            : ("Identity: " + root.selectedAlias + " · id " + root.selectedUid
                               + " — your posts are linkable to each other")
                    color: root.cMuted; font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
        }

        // ---- Topics + thread ----
        GridLayout {
            columns: root.compact ? 1 : 3
            columnSpacing: 16
            rowSpacing: 12
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                spacing: 8
                Layout.preferredWidth: root.compact ? -1 : 250
                Layout.maximumWidth: root.compact ? Number.POSITIVE_INFINITY : 250
                Layout.fillWidth: root.compact
                Layout.fillHeight: !root.compact
                Layout.preferredHeight: root.compact ? 170 : -1
                Text { text: "Topics"; color: root.cText; font.bold: true; font.pixelSize: 15 }
                TextField {
                    id: searchInput
                    objectName: "searchInput"
                    placeholderText: "Search titles, posts, authors"
                    Layout.fillWidth: true
                    enabled: root.usable
                    Accessible.name: "Search"
                    // Filter as you type (local only; nothing is sent).
                    onTextChanged: searchDelay.restart()
                    Timer {
                        id: searchDelay
                        interval: 250
                        onTriggered: logos.watch(root.backend.setSearch(searchInput.text),
                                                 function (v) {}, function (e) { outcome.text = "Error: " + e })
                    }
                }
                ListView {
                    id: topicsList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: root.topics
                    clip: true
                    spacing: 2
                    delegate: ItemDelegate {
                        id: topicRow
                        objectName: "topicRow"
                        readonly property var parts: root.topicParts(modelData)
                        width: ListView.view.width
                        highlighted: parts.id === root.currentTopicId
                        Accessible.name: parts.label + (parts.unread > 0 ? (", " + parts.unread + " new") : "")
                        contentItem: RowLayout {
                            spacing: 6
                            Text {
                                text: topicRow.parts.label
                                color: root.cText; font.pixelSize: 13
                                font.bold: topicRow.parts.unread > 0
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Rectangle {
                                objectName: "unreadBadge"
                                visible: topicRow.parts.unread > 0
                                radius: 9; color: root.cAccent
                                implicitHeight: 18
                                implicitWidth: Math.max(18, unreadText.implicitWidth + 10)
                                Text {
                                    id: unreadText
                                    anchors.centerIn: parent
                                    text: topicRow.parts.unread
                                    color: "#ffffff"; font.pixelSize: 11; font.bold: true
                                }
                            }
                        }
                        onClicked: {
                            logos.watch(root.backend.openTopic(parts.id), function (v) {
                                outcome.text = v === "ok" ? "Opened topic" : v
                            }, function (e) { outcome.text = "Error: " + e })
                        }
                    }
                    Text {
                        anchors.fill: parent
                        visible: topicsList.count === 0
                        text: root.searchText !== ""
                              ? "Nothing matches “" + root.searchText + "”."
                              : "No topics yet. “General” appears with the first post, or start your own below."
                        color: root.cMuted; font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }
                RowLayout {
                    TextField {
                        id: topicInput
                        placeholderText: "new topic title"
                        Layout.fillWidth: true
                        enabled: root.usable
                        maximumLength: 128
                        onAccepted: if (createTopicButton.enabled) createTopicButton.clicked()
                    }
                    Button {
                        id: createTopicButton
                        text: "Create"
                        enabled: root.usable && topicInput.text.length > 0
                        onClicked: logos.watch(root.backend.createTopic(topicInput.text), function (v) {
                            outcome.text = v.startsWith("error") ? v : "Topic created"
                            if (!v.startsWith("error")) topicInput.text = ""
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                }
            }

            Rectangle {
                visible: !root.compact
                width: 1; Layout.fillHeight: true; color: root.cBorder
            }

            ColumnLayout {
                spacing: 8
                Layout.fillWidth: true
                Layout.fillHeight: true
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: root.currentTopicId === "" ? "Thread"
                              : (root.currentTopicTitle !== "" ? root.currentTopicTitle
                                                               : root.currentTopicId.slice(0, 12) + "…")
                        color: root.cText; font.bold: true; font.pixelSize: 15
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Button {
                        id: archiveButton
                        objectName: "archiveButton"
                        text: "Save snapshot"
                        flat: true
                        visible: root.connection === "connected" && root.currentTopicId !== ""
                        enabled: root.usable
                        ToolTip.visible: hovered
                        ToolTip.text: "Save this topic's published posts on Logos Storage so people can read them after the network's own history has expired. This device serves the snapshot while Basecamp runs, and the announcement includes its Storage address (not anonymous). The announcement is signed with a one-time key, never your alias."
                        onClicked: logos.watch(root.backend.archiveTopic(), function (v) {
                            outcome.text = v === "saving" ? "Saving a snapshot to Logos Storage…" : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    Button {
                        id: historyButton
                        objectName: "historyButton"
                        text: "Load older posts"
                        flat: true
                        visible: root.connection === "connected"
                        enabled: root.usable
                        ToolTip.visible: hovered
                        ToolTip.text: "Ask a logos.dev store node for this forum's posts from the last 7 days. Reading is a direct request: that node learns your node asked for this forum (posting stays anonymous through Mix)."
                        onClicked: logos.watch(root.backend.loadHistory(), function (v) {
                            outcome.text = v === "loading" ? "Asking the network for older posts…" : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                }
                ListView {
                    id: threadList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 160  // stays readable when stacked
                    model: root.threadPosts
                    clip: true
                    spacing: 8
                    // Newest at the bottom, like a conversation.
                    onCountChanged: Qt.callLater(function () { threadList.positionViewAtEnd() })
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        objectName: "threadRow"
                        // Full row text kept as a property for drivers/tests.
                        property string text: modelData
                        readonly property var parts: root.rowParts(modelData)
                        width: ListView.view.width - 12
                        implicitHeight: postCol.implicitHeight + 18
                        radius: 8
                        color: parts.state === "failed" ? "#fff5f5" : "#ffffff"
                        border.color: parts.state === "failed" ? "#ffcecb" : root.cBorder
                        ColumnLayout {
                            id: postCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 9
                            spacing: 4
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    text: parts.author
                                    color: root.cText; font.pixelSize: 12; font.bold: true
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: root.stateLabel(parts.state)
                                    color: root.stateColor(parts.state); font.pixelSize: 11
                                }
                                Text {
                                    text: root.threadTimes[index] || ""
                                    color: root.cMuted; font.pixelSize: 11
                                }
                            }
                            Text {
                                readonly property bool snapshot: parts.body.indexOf(root.snapshotTitle) === 0
                                // Snapshot announcements: show the summary line and the CID only.
                                text: snapshot ? parts.body.split("\n").slice(0, 2).join("\n") : parts.body
                                textFormat: Text.PlainText
                                color: snapshot ? root.cMuted : root.cText
                                font.pixelSize: snapshot ? 12 : 14
                                wrapMode: Text.WrapAnywhere
                                Layout.fillWidth: true
                            }
                            Button {
                                objectName: "restoreButton"
                                visible: parts.body.indexOf(root.snapshotTitle) === 0
                                text: "Restore these posts"
                                flat: true
                                enabled: root.usable
                                ToolTip.visible: hovered
                                ToolTip.text: "Fetch this snapshot from Logos Storage. Every post in it is verified before it is shown. Fetching is a direct connection to the node that serves it (not anonymous)."
                                onClicked: logos.watch(root.backend.restoreSnapshot(parts.body), function (v) {
                                    outcome.text = v === "restoring" ? "Fetching the snapshot from Logos Storage…" : v
                                }, function (e) { outcome.text = "Error: " + e })
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        width: parent.width * 0.8
                        visible: threadList.count === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        color: root.cMuted; font.pixelSize: 13
                        text: root.searchText !== ""
                              ? "No posts in this topic match \u201c" + root.searchText + "\u201d."
                              : root.connection === "offline"
                              ? "No posts here yet.\nConnect to the Logos network to read what others have written, or write the first post — it is saved on this device and sent when you connect."
                              : root.connection === "connecting"
                                ? "Connecting… posts made while you were away will appear here."
                                : "No posts in this topic yet — write the first one."
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        ScrollView {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 72
                            TextArea {
                                id: composer
                                placeholderText: "Write a post (plain text)"
                                Accessible.name: "Post text"
                                wrapMode: TextArea.Wrap
                                enabled: root.usable
                                // Cmd/Ctrl+Enter sends; Enter alone starts a new line.
                                Keys.onPressed: function (event) {
                                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                            && (event.modifiers & Qt.ControlModifier)) {
                                        if (sendButton.enabled) sendButton.clicked()
                                        event.accepted = true
                                    }
                                }
                                background: Rectangle {
                                    color: "#ffffff"; radius: 6
                                    border.color: composer.activeFocus ? root.cAccent : root.cBorder
                                }
                            }
                        }
                        ColumnLayout {
                            spacing: 4
                            Button {
                                id: sendButton
                                text: "Send"
                                Layout.fillWidth: true
                                enabled: root.usable && composer.text.trim().length > 0
                                         && root.utf8Bytes(composer.text) <= root.maxPostBytes
                                onClicked: logos.watch(root.backend.postMessage(composer.text), function (value) {
                                    if (value === "unavailable" || value === "failed" || value === "empty") {
                                        outcome.text = "Not sent (" + value + ") — your text is kept here."
                                            + (root.connection === "offline"
                                               ? " Connect to the Logos network to send it." : "")
                                    } else if (value === "too long") {
                                        outcome.text = "Not sent — the post is longer than " + root.maxPostBytes + " bytes."
                                    } else if (value === "queued") {
                                        outcome.text = "Saved — it will be sent through Mix as soon as you are connected."
                                        composer.text = ""
                                    } else if (value === "retrying") {
                                        outcome.text = "Saved, not sent yet — it is retried through Mix automatically."
                                        composer.text = ""
                                    } else {
                                        outcome.text = "Sending through Mix…"
                                        composer.text = ""
                                    }
                                }, function (e) { outcome.text = "Error: " + e })
                            }
                            Button {
                                id: retryButton
                                objectName: "retryButton"
                                text: "Retry stored"
                                flat: true
                                Layout.fillWidth: true
                                // Offered when connected and something in this thread is
                                // waiting (offline, waiting posts go out on Connect).
                                visible: root.connection === "connected" && root.threadPosts.some(function (l) {
                                    return l.indexOf(" [failed]: ") >= 0 || l.indexOf(" [pending]: ") >= 0
                                })
                                enabled: root.usable
                                onClicked: logos.watch(root.backend.retryPending(), function (v) {
                                    outcome.text = "Retried " + v + (Number(v) === 1 ? " stored post" : " stored posts")
                                }, function (e) { outcome.text = "Error: " + e })
                            }
                        }
                    }
                    Text {
                        readonly property int bytes: root.utf8Bytes(composer.text)
                        text: bytes + " / " + root.maxPostBytes + " bytes"
                        visible: bytes > root.maxPostBytes * 0.8
                        color: bytes > root.maxPostBytes ? root.cBad : root.cMuted
                        font.pixelSize: 11
                    }
                }
            }
        }

        Text {
            id: outcome
            text: ""
            color: root.cText
            font.pixelSize: 13
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            visible: text.length > 0
        }

        // ---- Details (honest network state, diagnostics) ----
        Rectangle { Layout.fillWidth: true; height: 1; color: root.cBorder }
        Text {
            id: historyLine
            objectName: "historyLine"
            visible: root.historyState.length > 0
            text: "History: " + root.historyState
            // A finished history request replaces the "asking…" note.
            onTextChanged: if (outcome.text === "Asking the network for older posts…"
                               && !root.historyState.startsWith("loading")) outcome.text = ""
            color: root.cMuted
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        Text {
            id: archiveLine
            objectName: "archiveLine"
            visible: root.archiveState.length > 0
            text: "Storage: " + root.archiveState
            onTextChanged: if ((outcome.text.indexOf("Saving a snapshot") === 0
                                || outcome.text.indexOf("Fetching the snapshot") === 0)
                               && root.archiveState.indexOf("saving") !== 0
                               && root.archiveState.indexOf("fetching") !== 0) outcome.text = ""
            color: root.cMuted
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        Text {
            visible: root.showDetails
            text: "Transport: " + (root.transportState || "-")
            color: root.cMuted
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Button {
                id: checkButton
                visible: root.showDetails
                text: "Check transport"
                flat: true
                font.pixelSize: 12
                enabled: root.usable
                onClicked: logos.watch(root.backend.transportStatus(), function (v) {
                    outcome.text = v
                }, function (e) { outcome.text = "Error: " + e })
            }
            Button {
                id: recheckButton
                visible: root.showDetails
                text: "Re-check transport"
                flat: true
                font.pixelSize: 12
                enabled: root.usable
                onClicked: logos.watch(root.backend.recheckTransport(), function (v) {
                    outcome.text = v
                }, function (e) { outcome.text = "Error: " + e })
            }
            Item { Layout.fillWidth: true }
            Button {
                id: detailsButton
                text: root.showDetails ? "Hide network details" : "Network details"
                flat: true
                font.pixelSize: 12
                Accessible.name: "Show or hide network details"
                onClicked: root.showDetails = !root.showDetails
            }
            Text {
                text: "Backend status: " + root.status
                color: root.cMuted; font.pixelSize: 11
            }
        }
    }
}
