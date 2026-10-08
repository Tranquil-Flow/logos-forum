import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// LP-0026 Forum — the forum view. Plain text only: no remote images,
// previews, or automatic outbound requests from rendered content (the key
// avatars are drawn locally from the key id). States shown are honest:
// pending/sent/failed per post; a stored post clears the composer, one that
// cannot be stored keeps its text; a dead backend is surfaced, never hidden.
Item {
    id: root

    readonly property var backend: logos.module("forum_module")
    property bool ready: false
    // Transport diagnostics are for troubleshooting; folded away by default.
    property bool showDetails: false
    // The identity settings fold out above the composer.
    property bool identityOpen: false
    property bool newTopicOpen: false
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
    // Must match kSnapshotTitle in forum_module_backend.cpp.
    readonly property string snapshotTitle: "Snapshot of this topic on Logos Storage"

    // Basecamp's dark theme: values from logos-design-system (the revision
    // Basecamp 0.3.1 ships), kept here so the view also renders in hosts
    // without the Logos.Theme module (the test host, CI).
    QtObject {
        id: t
        readonly property color bg: "#171717"            // background
        readonly property color panel: "#262626"         // backgroundSecondary
        readonly property color inset: "#141414"         // backgroundInset
        readonly property color surface: "#343434"       // surface
        readonly property color raised: "#232323"        // surfaceRaised
        readonly property color hover: "#434343"         // surfaceInteractiveHover
        readonly property color line: "#333333"          // borderSubtle
        readonly property color text: "#FFFFFF"
        readonly property color body: "#E6E6E6"
        readonly property color text2: "#A4A4A4"         // textSecondary
        readonly property color text3: "#969696"         // textTertiary
        readonly property color placeholder: "#717784"   // textPlaceholder
        readonly property color accent: "#ED7B58"        // primary
        readonly property color accentHover: "#F55702"   // primaryHover
        readonly property color accentInk: "#1A0D07"
        readonly property color accentSoft: Qt.rgba(0.929, 0.482, 0.345, 0.14)
        readonly property color accentLine: Qt.rgba(0.929, 0.482, 0.345, 0.35)
        readonly property color good: "#49F563"          // success
        readonly property color goodText: "#9FEFAE"
        readonly property color goodSoft: Qt.rgba(0.286, 0.961, 0.388, 0.12)
        readonly property color warn: "#FEBC2E"          // warning
        readonly property color warnText: "#FFD98A"
        readonly property color warnSoft: Qt.rgba(0.996, 0.737, 0.180, 0.12)
        readonly property color bad: "#FB3748"           // error
        readonly property color badText: "#FFA4AC"
        readonly property color badSoft: Qt.rgba(0.984, 0.216, 0.282, 0.12)
        readonly property string sans: "Public Sans"     // loaded by Basecamp; system font otherwise
        readonly property string mono: "monospace"
        readonly property int radiusS: 4
        readonly property int radiusM: 6
        readonly property int radiusL: 8
    }

    // ---- Small themed controls ----
    component FButton: Button {
        id: fb
        property string kind: "secondary"   // primary | secondary | ghost
        font.family: t.sans
        font.pixelSize: 13
        font.weight: Font.Medium
        padding: 8
        leftPadding: 12
        rightPadding: 12
        hoverEnabled: true
        contentItem: Text {
            text: fb.text
            font: fb.font
            color: !fb.enabled ? t.placeholder
                 : fb.kind === "primary" ? t.accentInk
                 : fb.kind === "ghost" && !fb.hovered ? t.text2 : t.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            implicitHeight: 32
            radius: t.radiusM
            color: fb.kind === "primary"
                   ? (!fb.enabled ? t.raised : fb.down || fb.hovered ? t.accentHover : t.accent)
                   : fb.kind === "ghost"
                     ? (fb.hovered ? t.raised : "transparent")
                     : (fb.hovered ? t.hover : t.surface)
            border.width: fb.kind === "ghost" ? 0 : 1
            border.color: fb.kind === "primary" && fb.enabled ? t.accent : t.line
            Rectangle {   // keyboard focus ring
                anchors.fill: parent; anchors.margins: -3
                radius: t.radiusM + 2; color: "transparent"
                border.width: 2; border.color: t.accent
                visible: fb.visualFocus
            }
        }
    }
    component FField: TextField {
        id: ff
        font.family: t.sans
        font.pixelSize: 13
        color: t.text
        placeholderTextColor: t.placeholder
        selectionColor: t.accentLine
        selectedTextColor: t.text
        leftPadding: 10
        rightPadding: 10
        background: Rectangle {
            implicitHeight: 34
            radius: t.radiusM
            color: t.inset
            border.color: ff.activeFocus ? t.accent : t.line
        }
    }
    // Drawn chevron (the ▾ glyph is missing from Basecamp's fonts).
    component Chevron: Canvas {
        property bool up: false
        property color tint: t.text3
        implicitWidth: 10; implicitHeight: 6
        onUpChanged: requestPaint()
        onTintChanged: requestPaint()
        onPaint: {
            const c = getContext("2d")
            c.reset()
            c.strokeStyle = tint; c.lineWidth = 1.5; c.lineCap = "round"; c.lineJoin = "round"
            c.beginPath()
            if (up) { c.moveTo(1, 5); c.lineTo(5, 1); c.lineTo(9, 5) }
            else { c.moveTo(1, 1); c.lineTo(5, 5); c.lineTo(9, 1) }
            c.stroke()
        }
    }
    component FCombo: ComboBox {
        id: fc
        font.family: t.sans
        font.pixelSize: 13
        contentItem: Text {
            leftPadding: 10
            text: fc.displayText
            font: fc.font
            color: fc.enabled ? t.text : t.placeholder
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        indicator: Chevron {
            x: fc.width - width - 12
            y: (fc.height - height) / 2
        }
        background: Rectangle {
            implicitHeight: 32
            radius: t.radiusM
            color: fc.hovered ? t.hover : t.raised
            border.color: fc.activeFocus ? t.accent : t.line
        }
    }
    component FCheck: CheckBox {
        id: fk
        font.family: t.sans
        font.pixelSize: 13
        indicator: Rectangle {
            x: fk.leftPadding; y: (fk.height - height) / 2
            implicitWidth: 16; implicitHeight: 16; radius: t.radiusS
            color: fk.checked ? t.accent : t.inset
            border.color: fk.checked ? t.accent : t.hover
            Text {
                anchors.centerIn: parent; visible: fk.checked
                text: "✓"; color: t.accentInk; font.pixelSize: 11; font.bold: true
            }
        }
        contentItem: Text {
            leftPadding: fk.indicator.width + 8
            text: fk.text; font: fk.font; color: t.text2
            verticalAlignment: Text.AlignVCenter
        }
    }
    component Chip: Rectangle {
        property alias label: chipText.text
        property color fg: t.text3
        radius: height / 2
        implicitHeight: 20
        implicitWidth: chipText.implicitWidth + 16
        Text {
            id: chipText
            anchors.centerIn: parent
            color: parent.fg
            font.family: t.sans; font.pixelSize: 11; font.weight: Font.Medium
        }
    }
    // A 5x5 mirrored pattern drawn from a key id's hex digits, so the same
    // key always looks the same. Local drawing only; nothing is fetched.
    component KeyAvatar: Rectangle {
        id: av
        property string keyId: ""
        readonly property string hex: keyId.replace(/[^0-9a-f]/gi, "").toLowerCase()
        readonly property var digits: {
            var d = []
            for (var i = 0; i < av.hex.length; ++i) d.push(parseInt(av.hex[i], 16))
            return d.length > 0 ? d : [0]
        }
        readonly property color ink: Qt.hsla(((digits[0] * 16 + (digits[1] || 0)) % 360) / 360, 0.7, 0.64, 1)
        implicitWidth: 30; implicitHeight: 30
        radius: t.radiusM
        color: t.raised
        Grid {
            anchors.fill: parent; anchors.margins: 5
            columns: 5; spacing: 1
            Repeater {
                model: 25
                Rectangle {
                    readonly property int r: Math.floor(index / 5)
                    readonly property int c: index % 5 < 3 ? index % 5 : 4 - index % 5
                    width: (av.width - 14) / 5; height: width; radius: 1
                    color: av.digits[(r * 3 + c) % av.digits.length] % 2 === 0 ? av.ink : "transparent"
                }
            }
        }
    }

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
                root.lastBackendOk = Date.now()  // an error reply still proves it answers
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

    // UTF-8 length: the signed body's limit is in bytes.
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
    // Parse a thread row "<author> [state]: body" (backend contract; the
    // backend shows brackets in aliases as parentheses).
    // The key id is split off the alias and drawn on its own, never elided:
    // a long alias must not push the real key id out of view.
    function rowParts(line) {
        var m = /^([\s\S]*?) \[(\w+)\]: ([\s\S]*)$/.exec(line)
        if (!m) return { alias: "", keyId: "", state: "", body: line }
        var k = m[1].lastIndexOf(" · id ")
        return { alias: k >= 0 ? m[1].slice(0, k) : "",
                 keyId: k >= 0 ? m[1].slice(k + 3) : m[1],
                 state: m[2], body: m[3] }
    }
    // Parse a topic row "<id>|<title (N)>|<unread>" (backend contract).
    function topicParts(line) {
        var p = line.split("|")
        var label = p.slice(1, p.length - 1).join("|")
        var m = /^([\s\S]*) \((\d+)\)$/.exec(label)
        return { id: p[0], label: label,
                 title: m ? m[1] : label, count: m ? m[2] : "",
                 unread: parseInt(p[p.length - 1]) || 0 }
    }
    // Snapshot announcement body: "<title>: N post(s).\ncid: <cid>".
    function snapshotParts(body) {
        var n = /: (\d+) post/.exec(body)
        var c = /(?:^|\n)cid: (\S+)/.exec(body)
        return { posts: n ? parseInt(n[1]) : 0, cid: c ? c[1] : "" }
    }
    function stateLabel(s) {
        if (s === "pending") return root.connection === "connected" ? "sending…" : "waiting to send"
        if (s === "failed") return "not sent — kept for retry"
        return s
    }
    function stateFg(s) {
        if (s === "sent") return t.goodText
        if (s === "failed") return t.badText
        if (s === "pending") return t.warnText
        return t.text3
    }
    function stateBg(s) {
        if (s === "sent") return t.goodSoft
        if (s === "failed") return t.badSoft
        if (s === "pending") return t.warnSoft
        return t.raised
    }

    // Friendlier times. The backend shows each post's signed time as
    // "d MMM yyyy, HH:mm" (C locale); the thread shows it relative to now
    // under day separators, with the exact time on hover.
    property double nowMs: Date.now()
    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }
    readonly property var monthsShort: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    readonly property var monthsLong: ["January", "February", "March", "April", "May", "June", "July",
                                       "August", "September", "October", "November", "December"]
    readonly property var weekdays: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    function parseShownTime(s) {
        var m = /^(\d{1,2}) (\w{3}) (\d{4}), (\d{2}):(\d{2})$/.exec(s || "")
        var mon = m ? monthsShort.indexOf(m[2]) : -1
        return mon < 0 ? null : new Date(+m[3], mon, +m[1], +m[4], +m[5])
    }
    function two(n) { return (n < 10 ? "0" : "") + n }
    function daysAgo(d, now) {
        var a = new Date(now); a.setHours(0, 0, 0, 0)
        var b = new Date(d.getTime()); b.setHours(0, 0, 0, 0)
        return Math.round((a.getTime() - b.getTime()) / 86400000)
    }
    function relativeTime(s, now) {
        var d = parseShownTime(s)
        if (!d) return s || ""
        var diff = now - d.getTime()
        // Signed times have minute precision: under two minutes is "just now".
        if (diff >= -60000 && diff < 120000) return "just now"
        if (diff > 0 && diff < 3600000) return Math.floor(diff / 60000) + " min ago"
        return two(d.getHours()) + ":" + two(d.getMinutes())
    }
    function dayKey(s) {
        var d = parseShownTime(s)
        return d ? d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate() : ""
    }
    function dayLabel(s, now) {
        var d = parseShownTime(s)
        if (!d) return ""
        var days = daysAgo(d, now)
        if (days === 0) return "Today"
        if (days === 1) return "Yesterday"
        return weekdays[d.getDay()] + " " + d.getDate() + " " + monthsLong[d.getMonth()]
               + (d.getFullYear() !== new Date(now).getFullYear() ? " " + d.getFullYear() : "")
    }

    // The thread is a ListModel updated in place, so a refresh (a post
    // turning "sent", history arriving) keeps the reader's scroll position.
    // It follows the newest post only if the reader was already at the
    // bottom, switched topic or just posted; otherwise "New posts below".
    property bool followNext: true
    property int threadRev: 0
    onCurrentTopicIdChanged: followNext = true
    onSearchTextChanged: followNext = true
    onThreadPostsChanged: Qt.callLater(syncThread)
    onThreadTimesChanged: Qt.callLater(syncThread)
    ListModel { id: threadModel; Component.onCompleted: Qt.callLater(root.syncThread) }
    function syncThread() {
        var lines = root.threadPosts || [], times = root.threadTimes || []
        var wasAtEnd = threadList.atEnd
        var prevCount = threadModel.count
        var prevLast = prevCount > 0 ? threadModel.get(prevCount - 1).line : ""
        for (var i = 0; i < lines.length; ++i) {
            var row = { line: String(lines[i]), time: String(times[i] || "") }
            if (i >= threadModel.count) { threadModel.append(row); continue }
            var cur = threadModel.get(i)
            if (cur.line !== row.line || cur.time !== row.time) threadModel.set(i, row)
        }
        if (threadModel.count > lines.length)
            threadModel.remove(lines.length, threadModel.count - lines.length)
        threadRev++
        var last = lines.length > 0 ? String(lines[lines.length - 1]) : ""
        var ownNew = last !== prevLast && rowParts(last).state === "pending"
        if (followNext || wasAtEnd || prevCount === 0 || ownNew) {
            followNext = false
            threadList.newBelow = false
            Qt.callLater(threadList.scrollToEnd)
        } else if (last !== prevLast) {
            threadList.newBelow = true
        }
    }

    // Click to copy (key ids, snapshot CIDs), confirmed by a short note.
    TextEdit { id: clipHelper; visible: false }
    function copyText(value, what) {
        clipHelper.text = value
        clipHelper.selectAll()
        clipHelper.copy()
        clipHelper.text = ""
        toast.show("Copied " + what)
    }

    // Keyboard: Ctrl+F (Cmd+F on macOS) search, Ctrl+N new topic, Esc closes.
    Shortcut {
        sequence: StandardKey.Find
        enabled: root.usable
        onActivated: { searchInput.forceActiveFocus(); searchInput.selectAll() }
    }
    Shortcut {
        sequence: "Ctrl+N"
        enabled: root.usable
        onActivated: { root.newTopicOpen = true; topicInput.forceActiveFocus() }
    }
    Shortcut {
        sequence: "Esc"
        enabled: root.identityOpen || root.newTopicOpen || root.showDetails || searchInput.text !== ""
        onActivated: root.closeTopmost()
    }
    function closeTopmost() {
        if (root.identityOpen) root.identityOpen = false
        else if (root.newTopicOpen) root.newTopicOpen = false
        else if (root.showDetails) root.showDetails = false
        else searchInput.text = ""
    }

    Rectangle { anchors.fill: parent; color: t.bg }

    Rectangle {
        id: toast
        objectName: "toast"
        property string message: ""
        property bool shown: false
        function show(m) { message = m; shown = true; toastTimer.restart() }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 72
        z: 100
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        radius: t.radiusM
        color: t.raised
        border.color: t.line
        implicitWidth: toastText.implicitWidth + 24
        implicitHeight: toastText.implicitHeight + 14
        Text {
            id: toastText
            anchors.centerIn: parent
            text: toast.message
            color: t.text; font.family: t.sans; font.pixelSize: 13
        }
        Timer { id: toastTimer; interval: 1600; onTriggered: toast.shown = false }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- Header: title, network status, details ----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: headerRow.implicitHeight + 28
            color: t.bg
            RowLayout {
                id: headerRow
                anchors.fill: parent
                anchors.leftMargin: 20; anchors.rightMargin: 16
                spacing: 12
                Text {
                    text: "Logos Forum"
                    font.family: t.sans; font.pixelSize: 18; font.weight: Font.Bold
                    color: t.text
                }
                Rectangle {
                    id: networkChip
                    objectName: "networkChip"
                    radius: height / 2
                    color: root.connection === "connected" ? t.goodSoft
                         : root.connection === "connecting" ? t.warnSoft : t.raised
                    implicitHeight: 26
                    implicitWidth: chipRow.implicitWidth + 22
                    Layout.maximumWidth: headerRow.width * 0.55
                    RowLayout {
                        id: chipRow
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, networkChip.width - 22)
                        spacing: 7
                        Rectangle {
                            width: 7; height: 7; radius: 4
                            color: root.connection === "connected" ? t.good
                                 : root.connection === "connecting" ? t.warn : t.text3
                        }
                        Text {
                            id: networkLabel
                            objectName: "networkLabel"
                            text: root.connection === "connected" ? "Connected to logos.dev · sending through Mix"
                                : root.connection === "connecting" ? "Connecting to logos.dev…"
                                : "Offline — not connected"
                            color: root.connection === "connected" ? "#BDF7C6"
                                 : root.connection === "connecting" ? t.warnText : t.text2
                            font.family: t.sans; font.pixelSize: 12
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }
                FButton {
                    id: connectButton
                    // Joining a public network is the user's explicit choice.
                    kind: "primary"
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
                Item { Layout.fillWidth: true }
                FButton {
                    id: detailsButton
                    kind: "ghost"
                    text: root.showDetails ? "Hide network details" : "Network details"
                    Accessible.name: "Show or hide network details"
                    onClicked: root.showDetails = !root.showDetails
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: t.line }
        }

        // ---- Network details (diagnostics, folded away by default) ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.showDetails
            color: t.inset
            implicitHeight: detailsCol.implicitHeight + 20
            ColumnLayout {
                id: detailsCol
                anchors.fill: parent
                anchors.margins: 10; anchors.leftMargin: 20; anchors.rightMargin: 16
                spacing: 6
                Text {
                    text: "Transport: " + (root.transportState || "-")
                    textFormat: Text.PlainText
                    color: t.text2; font.family: t.sans; font.pixelSize: 12
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                }
                RowLayout {
                    spacing: 8
                    FButton {
                        id: checkButton
                        visible: root.showDetails
                        text: "Check transport"
                        enabled: root.usable
                        onClicked: logos.watch(root.backend.transportStatus(), function (v) {
                            outcome.text = v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    FButton {
                        id: recheckButton
                        visible: root.showDetails
                        text: "Re-check transport"
                        enabled: root.usable
                        onClicked: logos.watch(root.backend.recheckTransport(), function (v) {
                            outcome.text = v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "Backend status: " + root.status
                        textFormat: Text.PlainText
                        color: t.text3; font.family: t.sans; font.pixelSize: 11
                    }
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: t.line }
        }

        // ---- Topics + thread ----
        GridLayout {
            columns: root.compact ? 1 : 3
            columnSpacing: 0
            rowSpacing: 0
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Topic list
            ColumnLayout {
                spacing: 10
                Layout.preferredWidth: root.compact ? -1 : 270
                Layout.maximumWidth: root.compact ? Number.POSITIVE_INFINITY : 270
                Layout.fillWidth: root.compact
                Layout.fillHeight: !root.compact
                Layout.preferredHeight: root.compact ? 210 : -1
                Layout.margins: 14
                FField {
                    id: searchInput
                    objectName: "searchInput"
                    placeholderText: "Search titles, posts, authors"
                    Layout.fillWidth: true
                    enabled: root.usable
                    Accessible.name: "Search"
                    rightPadding: searchKeyHint.visible ? searchKeyHint.width + 16 : 10
                    Text {
                        id: searchKeyHint
                        anchors.right: parent.right; anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: searchInput.text === "" && !searchInput.activeFocus
                        text: Qt.platform.os === "osx" ? "Cmd F" : "Ctrl F"
                        color: t.text3; font.family: t.mono; font.pixelSize: 11
                    }
                    // Filter as you type (local only; nothing is sent).
                    onTextChanged: searchDelay.restart()
                    Timer {
                        id: searchDelay
                        interval: 250
                        onTriggered: logos.watch(root.backend.setSearch(searchInput.text),
                                                 function (v) {}, function (e) { outcome.text = "Error: " + e })
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "TOPICS"
                        color: t.text3; font.family: t.sans; font.pixelSize: 11
                        font.weight: Font.Medium; font.letterSpacing: 0.8
                        Layout.fillWidth: true
                    }
                    FButton {
                        kind: "ghost"
                        text: root.newTopicOpen ? "Cancel" : "+ New topic"
                        padding: 4; leftPadding: 8; rightPadding: 8
                        enabled: root.usable
                        onClicked: {
                            root.newTopicOpen = !root.newTopicOpen
                            if (root.newTopicOpen) topicInput.forceActiveFocus()
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.newTopicOpen
                    spacing: 6
                    FField {
                        id: topicInput
                        placeholderText: "new topic title"
                        Layout.fillWidth: true
                        enabled: root.usable
                        maximumLength: 128
                        onAccepted: if (createTopicButton.enabled) createTopicButton.clicked()
                    }
                    FButton {
                        id: createTopicButton
                        kind: "primary"
                        text: "Create"
                        enabled: root.usable && topicInput.text.length > 0
                        onClicked: logos.watch(root.backend.createTopic(topicInput.text), function (v) {
                            outcome.text = v.startsWith("error") ? v : "Topic created"
                            if (!v.startsWith("error")) { topicInput.text = ""; root.newTopicOpen = false }
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                }
                ListView {
                    id: topicsList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: root.topics
                    clip: true
                    spacing: 2
                    ScrollBar.vertical: ScrollBar { }
                    delegate: ItemDelegate {
                        id: topicRow
                        objectName: "topicRow"
                        readonly property var parts: root.topicParts(modelData)
                        readonly property bool current: parts.id === root.currentTopicId
                        width: ListView.view.width
                        highlighted: current
                        hoverEnabled: true
                        padding: 10
                        Accessible.name: parts.label + (parts.unread > 0 ? (", " + parts.unread + " new") : "")
                        background: Rectangle {
                            radius: t.radiusM
                            color: topicRow.current ? t.surface : topicRow.hovered ? t.raised : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 8
                            Text {
                                text: topicRow.parts.title
                                textFormat: Text.PlainText
                                color: topicRow.current || topicRow.parts.unread > 0 ? t.text : t.body
                                font.family: t.sans; font.pixelSize: 14
                                font.weight: topicRow.parts.unread > 0 ? Font.Bold : Font.Medium
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Text {
                                visible: topicRow.parts.unread === 0 && topicRow.parts.count !== ""
                                text: topicRow.parts.count
                                color: t.text3; font.family: t.sans; font.pixelSize: 12
                            }
                            Rectangle {
                                objectName: "unreadBadge"
                                visible: topicRow.parts.unread > 0
                                radius: 9; color: t.accent
                                implicitHeight: 18
                                implicitWidth: Math.max(18, unreadText.implicitWidth + 10)
                                Text {
                                    id: unreadText
                                    anchors.centerIn: parent
                                    text: topicRow.parts.unread
                                    color: t.accentInk; font.family: t.sans; font.pixelSize: 11; font.bold: true
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
                        anchors.margins: 6
                        visible: topicsList.count === 0
                        text: root.searchText !== ""
                              ? "Nothing matches “" + root.searchText + "”."
                              : "No topics yet. “General” appears with the first post, or start your own with + New topic."
                        color: t.text3; font.family: t.sans; font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }
            }

            Rectangle {
                visible: !root.compact
                width: 1; Layout.fillHeight: true; color: t.line
            }

            // Thread
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 14; Layout.leftMargin: 20; Layout.rightMargin: 16
                    spacing: 8
                    Text {
                        text: root.currentTopicId === "" ? "Thread"
                              : (root.currentTopicTitle !== "" ? root.currentTopicTitle
                                                               : root.currentTopicId.slice(0, 12) + "…")
                        textFormat: Text.PlainText
                        color: t.text; font.family: t.sans; font.pixelSize: 16; font.weight: Font.Bold
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    FButton {
                        id: historyButton
                        objectName: "historyButton"
                        text: "Load older posts"
                        visible: root.connection === "connected"
                        enabled: root.usable
                        ToolTip.visible: hovered
                        ToolTip.text: "Ask a logos.dev store node for this forum's posts from the last 7 days. Reading is a direct request: that node learns your node asked for this forum (posting stays anonymous through Mix)."
                        onClicked: logos.watch(root.backend.loadHistory(), function (v) {
                            outcome.text = v === "loading" ? "Asking the network for older posts…" : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                    FButton {
                        id: archiveButton
                        objectName: "archiveButton"
                        text: "Save snapshot"
                        visible: root.connection === "connected" && root.currentTopicId !== ""
                        enabled: root.usable
                        ToolTip.visible: hovered
                        ToolTip.text: "Save this topic's published posts on Logos Storage so people can read them after the network's own history has expired. This device serves the snapshot while Basecamp runs, and the announcement includes its Storage address (not anonymous). The announcement is signed with a one-time key, never your alias."
                        onClicked: logos.watch(root.backend.archiveTopic(), function (v) {
                            outcome.text = v === "saving" ? "Saving a snapshot to Logos Storage…" : v
                        }, function (e) { outcome.text = "Error: " + e })
                    }
                }
                ListView {
                    id: threadList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 160  // stays readable when stacked
                    Layout.leftMargin: 12; Layout.rightMargin: 8
                    // Newest at the bottom, like a conversation (see syncThread).
                    model: threadModel
                    clip: true
                    spacing: 2
                    property bool newBelow: false
                    readonly property bool atEnd: contentHeight <= height + 4
                                                  || contentY + height >= originY + contentHeight - 4
                    onAtEndChanged: if (atEnd) newBelow = false
                    // Rows differ in height, so the first jump can land short
                    // of the end once delegates settle; repeat it briefly.
                    function scrollToEnd() { positionViewAtEnd(); endSettle.restart() }
                    onMovementStarted: endSettle.stop()   // the reader takes over
                    Timer { id: endSettle; interval: 60; repeat: true; property int left: 0
                            onRunningChanged: if (running) left = 4
                            onTriggered: { threadList.positionViewAtEnd(); if (--left <= 0) stop() } }
                    ScrollBar.vertical: ScrollBar { }
                    FButton {
                        id: newPostsPill
                        objectName: "newPostsPill"
                        parent: threadList
                        z: 10
                        kind: "primary"
                        text: "New posts below"
                        visible: threadList.newBelow && !threadList.atEnd
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 10
                        onClicked: { threadList.newBelow = false; threadList.scrollToEnd() }
                    }
                    delegate: Item {
                        id: postRow
                        objectName: "threadRow"
                        // Full row text kept as a property for drivers/tests.
                        property string text: model.line
                        readonly property string shownTime: model.time
                        readonly property var parts: root.rowParts(model.line)
                        readonly property bool snapshot: parts.body.indexOf(root.snapshotTitle) === 0
                        readonly property var snap: snapshot ? root.snapshotParts(parts.body) : ({ posts: 0, cid: "" })
                        // A day separator above the first post of each day.
                        readonly property bool newDay: {
                            root.threadRev
                            const k = root.dayKey(model.time)
                            return k !== "" && (index === 0 || k !== root.dayKey(threadModel.get(index - 1).time))
                        }
                        width: ListView.view.width - 12
                        implicitHeight: (newDay ? daySep.height : 0) + rowBg.height
                        RowLayout {
                            id: daySep
                            objectName: "daySeparator"
                            visible: postRow.newDay
                            width: parent.width
                            height: 36
                            spacing: 10
                            Rectangle { Layout.fillWidth: true; Layout.leftMargin: 10; implicitHeight: 1; color: t.line }
                            Text {
                                text: root.dayLabel(model.time, root.nowMs)
                                color: t.text3; font.family: t.sans; font.pixelSize: 11; font.weight: Font.Medium
                            }
                            Rectangle { Layout.fillWidth: true; Layout.rightMargin: 10; implicitHeight: 1; color: t.line }
                        }
                        Rectangle {
                            id: rowBg
                            y: postRow.newDay ? daySep.height : 0
                            width: parent.width
                            height: postLayout.implicitHeight + 20
                            radius: t.radiusM
                            color: parts.state === "failed" ? t.badSoft : rowHover.hovered ? t.raised : "transparent"
                            HoverHandler { id: rowHover }
                            RowLayout {
                                id: postLayout
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                anchors.margins: 10
                                spacing: 12
                                KeyAvatar {
                                    keyId: parts.keyId
                                    Layout.alignment: Qt.AlignTop
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            objectName: "postAlias"
                                            Layout.alignment: Qt.AlignTop
                                            visible: parts.alias !== ""
                                            text: parts.alias
                                            textFormat: Text.PlainText
                                            color: t.text; font.family: t.sans; font.pixelSize: 13; font.weight: Font.Medium
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: 220
                                        }
                                        Text {
                                            objectName: "postKeyId"
                                            Layout.alignment: Qt.AlignTop
                                            text: parts.keyId
                                            textFormat: Text.PlainText
                                            color: keyHover.hovered ? t.accent : parts.alias !== "" ? t.text3 : t.text
                                            font.pixelSize: 12; font.family: t.mono
                                            font.weight: parts.alias === "" ? Font.Medium : Font.Normal
                                            HoverHandler { id: keyHover; cursorShape: Qt.PointingHandCursor }
                                            TapHandler { onTapped: root.copyText(parts.keyId.replace(/^id /, ""), "key id") }
                                            ToolTip.visible: keyHover.hovered
                                            ToolTip.text: "Click to copy the key id"
                                            ToolTip.delay: 400
                                        }
                                        Chip {
                                            Layout.alignment: Qt.AlignTop
                                            visible: parts.state !== ""
                                            label: root.stateLabel(parts.state)
                                            fg: root.stateFg(parts.state)
                                            color: root.stateBg(parts.state)
                                        }
                                        Item { Layout.fillWidth: true }
                                        // Time (relative), with the signed date always shown under it.
                                        ColumnLayout {
                                            Layout.alignment: Qt.AlignTop
                                            spacing: 0
                                            Text {
                                                objectName: "postTime"
                                                text: root.relativeTime(model.time, root.nowMs)
                                                color: t.text2; font.family: t.sans; font.pixelSize: 12
                                                Layout.alignment: Qt.AlignRight
                                            }
                                            Text {
                                                objectName: "postDate"
                                                visible: text !== ""
                                                text: model.time.split(", ")[0]
                                                color: t.text3; font.family: t.sans; font.pixelSize: 11
                                                Layout.alignment: Qt.AlignRight
                                            }
                                        }
                                    }
                                    Text {
                                        visible: !postRow.snapshot
                                        text: parts.body
                                        textFormat: Text.PlainText
                                        color: t.body
                                        font.family: t.sans; font.pixelSize: 14
                                        lineHeight: 1.15
                                        wrapMode: Text.WrapAnywhere
                                        Layout.fillWidth: true
                                    }
                                    // Snapshot announcements: a card with the CID and Restore.
                                    Rectangle {
                                        visible: postRow.snapshot
                                        Layout.fillWidth: true
                                        Layout.topMargin: 4
                                        implicitHeight: snapRow.implicitHeight + 20
                                        radius: t.radiusL
                                        color: t.panel
                                        border.color: t.accentLine
                                        Rectangle { anchors.fill: parent; radius: parent.radius; color: t.accentSoft }
                                        RowLayout {
                                            id: snapRow
                                            anchors.left: parent.left; anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.margins: 12
                                            spacing: 12
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2
                                                Text {
                                                    text: "Snapshot on Logos Storage · " + postRow.snap.posts
                                                          + (postRow.snap.posts === 1 ? " post" : " posts")
                                                    color: t.text; font.family: t.sans; font.pixelSize: 13; font.weight: Font.Medium
                                                    Layout.fillWidth: true
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    objectName: "snapshotCid"
                                                    text: postRow.snap.cid
                                                    textFormat: Text.PlainText
                                                    color: cidHover.hovered ? t.accent : t.text3
                                                    font.family: t.mono; font.pixelSize: 11
                                                    elide: Text.ElideMiddle
                                                    Layout.fillWidth: true
                                                    HoverHandler { id: cidHover; cursorShape: Qt.PointingHandCursor }
                                                    TapHandler { onTapped: root.copyText(postRow.snap.cid, "snapshot CID") }
                                                    ToolTip.visible: cidHover.hovered
                                                    ToolTip.text: "Click to copy the Storage CID"
                                                    ToolTip.delay: 400
                                                }
                                            }
                                            FButton {
                                                objectName: "restoreButton"
                                                visible: postRow.snapshot
                                                text: "Restore these posts"
                                                enabled: root.usable
                                                ToolTip.visible: hovered
                                                ToolTip.text: "Fetch this snapshot from Logos Storage. Every post in it is verified before it is shown. Fetching is a direct connection to the node that serves it (not anonymous)."
                                                onClicked: logos.watch(root.backend.restoreSnapshot(parts.body), function (v) {
                                                    outcome.text = v === "restoring" ? "Fetching the snapshot from Logos Storage…" : v
                                                }, function (e) { outcome.text = "Error: " + e })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        width: parent.width * 0.8
                        visible: threadList.count === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        color: t.text3; font.family: t.sans; font.pixelSize: 13
                        text: root.searchText !== ""
                              ? "No posts in this topic match “" + root.searchText + "”."
                              : root.connection === "offline"
                              ? "No posts here yet.\nConnect to the Logos network to read what others have written, or write the first post — it is saved on this device and sent when you connect."
                              : root.connection === "connecting"
                                ? "Connecting… posts made while you were away will appear here."
                                : "No posts in this topic yet — write the first one."
                    }
                }

                // ---- Composer: identity, text, send ----
                Rectangle {
                    Layout.fillWidth: true
                    Layout.margins: 12; Layout.leftMargin: 20; Layout.rightMargin: 16
                    implicitHeight: composerCol.implicitHeight + 20
                    radius: t.radiusL
                    color: t.panel
                    border.color: composer.activeFocus ? t.accentLine : t.line
                    ColumnLayout {
                        id: composerCol
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: 10
                        spacing: 8

                        // Identity settings, folded out from "Posting as".
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.identityOpen
                            spacing: 8
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                FCombo {
                                    id: identityBox
                                    model: ["Anonymous"].concat(root.accounts)
                                    enabled: root.usable
                                    width: 200
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
                                FField {
                                    id: aliasInput
                                    placeholderText: "new alias"
                                    enabled: root.usable
                                    width: 150
                                    Accessible.name: "New alias"
                                    onAccepted: if (addAliasButton.enabled) addAliasButton.clicked()
                                }
                                FButton {
                                    id: addAliasButton
                                    text: "Add alias"
                                    enabled: root.usable && aliasInput.text.length > 0
                                    onClicked: logos.watch(root.backend.createAccount(aliasInput.text), function (v) {
                                        outcome.text = v === "ok" ? "Alias created" : v
                                        if (v === "ok") aliasInput.text = ""
                                    }, function (e) { outcome.text = "Error: " + e })
                                }
                                FCheck {
                                    id: hideAliasBox
                                    text: "Hide my alias (show key id only)"
                                    visible: root.selectedAlias !== ""
                                    enabled: root.usable && root.selectedAlias !== ""
                                    checked: root.aliasHidden
                                    height: addAliasButton.height
                                    onToggled: logos.watch(root.backend.hideAlias(checked), function (v) {
                                        outcome.text = checked ? "Posting with key id only" : "Posting with alias + key id"
                                    }, function (e) { outcome.text = "Error: " + e })
                                }
                            }
                            // Key rotation: unlinks later posts from earlier ones.
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                visible: root.selectedAlias !== ""
                                FButton {
                                    id: rotateButton
                                    objectName: "rotateButton"
                                    text: "New key now"
                                    enabled: root.usable
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Switch this alias to a fresh key. Earlier posts stay valid, but later posts no longer share their key id. Readers still see the alias name unless you hide it."
                                    onClicked: logos.watch(root.backend.rotateKey(), function (v) {
                                        outcome.text = v === "ok" ? ("New key: id " + root.selectedUid) : v
                                    }, function (e) { outcome.text = "Error: " + e })
                                }
                                FCombo {
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
                                FCombo {
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
                                    color: t.text3; font.family: t.sans; font.pixelSize: 12
                                    height: rotateButton.height; verticalAlignment: Text.AlignVCenter
                                }
                            }
                            Text {
                                id: identityHint
                                objectName: "identityHint"  // stable handle for property-only drivers
                                // Privacy implications stated where the choice is made.
                                textFormat: Text.PlainText
                                text: root.selectedAlias === ""
                                      ? "Identity: anonymous — a new one-time key per post; your posts cannot be linked to each other"
                                      : root.aliasHidden
                                        ? ("Identity: id " + root.selectedUid + " (alias hidden) — your posts are linkable to each other")
                                        : ("Identity: " + root.selectedAlias + " · id " + root.selectedUid
                                           + " — your posts are linkable to each other")
                                color: t.text2; font.family: t.sans; font.pixelSize: 12
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                            Rectangle { Layout.fillWidth: true; height: 1; color: t.line }
                        }

                        ScrollView {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 56
                            TextArea {
                                id: composer
                                placeholderText: "Write a post (plain text)"
                                placeholderTextColor: t.placeholder
                                color: t.text
                                selectionColor: t.accentLine
                                selectedTextColor: t.text
                                font.family: t.sans; font.pixelSize: 14
                                Accessible.name: "Post text"
                                wrapMode: TextArea.Wrap
                                enabled: root.usable
                                padding: 2
                                background: Item { }
                                // Enter sends; Shift+Enter starts a new line.
                                Keys.onPressed: function (event) {
                                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                            && !(event.modifiers & Qt.ShiftModifier)
                                            && !composer.inputMethodComposing) {
                                        if (sendButton.enabled) sendButton.clicked()
                                        event.accepted = true
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            // "Posting as": the current identity; opens its settings.
                            AbstractButton {
                                id: postingAs
                                hoverEnabled: true
                                Accessible.name: "Posting identity settings"
                                Layout.maximumWidth: composerCol.width * 0.6
                                implicitHeight: 30
                                leftPadding: 10; rightPadding: 10
                                implicitWidth: postingRow.implicitWidth + leftPadding + rightPadding
                                onClicked: root.identityOpen = !root.identityOpen
                                background: Rectangle {
                                    radius: t.radiusM
                                    color: postingAs.hovered || root.identityOpen ? t.hover : t.raised
                                    border.color: root.identityOpen ? t.accentLine : t.line
                                }
                                contentItem: RowLayout {
                                    id: postingRow
                                    spacing: 6
                                    Text {
                                        text: "Posting as"
                                        color: t.text3; font.family: t.sans; font.pixelSize: 12
                                    }
                                    Text {
                                        text: root.selectedAlias === "" ? "Anonymous"
                                             : root.aliasHidden ? "key id only" : root.selectedAlias
                                        textFormat: Text.PlainText
                                        color: t.text; font.family: t.sans; font.pixelSize: 13; font.weight: Font.Medium
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 160
                                    }
                                    Text {
                                        visible: root.selectedAlias !== ""
                                        text: root.selectedUid.slice(0, 8)
                                        color: t.text3; font.family: t.mono; font.pixelSize: 11
                                    }
                                    Chevron { up: root.identityOpen; Layout.alignment: Qt.AlignVCenter }
                                }
                            }
                            Text {
                                visible: !root.compact
                                text: root.selectedAlias === "" ? "one-time key per post" : "posts linkable"
                                color: t.text3; font.family: t.sans; font.pixelSize: 12
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Item { visible: root.compact; Layout.fillWidth: true }
                            Text {
                                readonly property int bytes: root.utf8Bytes(composer.text)
                                text: bytes + " / " + root.maxPostBytes + " bytes"
                                visible: bytes > 0
                                color: bytes > root.maxPostBytes ? t.badText : t.text3
                                font.family: t.sans; font.pixelSize: 11
                            }
                            FButton {
                                id: retryButton
                                objectName: "retryButton"
                                text: "Retry stored"
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
                            FButton {
                                id: sendButton
                                kind: "primary"
                                text: "Send"
                                leftPadding: 18; rightPadding: 18
                                enabled: root.usable && composer.text.trim().length > 0
                                         && root.utf8Bytes(composer.text) <= root.maxPostBytes
                                onClicked: logos.watch(root.backend.postMessage(composer.text), function (value) {
                                    if (value === "empty") {
                                        outcome.text = "Nothing to send."
                                    } else if (value === "unavailable") {
                                        outcome.text = "Not sent — the local store is unavailable; your text is kept here."
                                    } else if (value === "failed") {
                                        outcome.text = "Not sent — the post was rejected by local validation; your text is kept here."
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
                        }
                    }
                }
            }
        }

        // ---- Status bar: outcome of the last action, history, storage ----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: statusCol.implicitHeight + 16
            color: t.bg
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: t.line }
            ColumnLayout {
                id: statusCol
                anchors.left: parent.left; anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 20; anchors.rightMargin: 16
                spacing: 4
                Text {
                    id: outcome
                    textFormat: Text.PlainText
                    text: ""
                    color: t.text
                    font.family: t.sans; font.pixelSize: 13
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    visible: text.length > 0
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16
                    Text {
                        id: historyLine
                        objectName: "historyLine"
                        visible: root.historyState.length > 0
                        text: "History: " + root.historyState
                        textFormat: Text.PlainText
                        // A finished history request replaces the "asking…" note.
                        onTextChanged: if (outcome.text === "Asking the network for older posts…"
                                           && !root.historyState.startsWith("loading")) outcome.text = ""
                        color: t.text3; font.family: t.sans; font.pixelSize: 12
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Layout.maximumWidth: implicitWidth
                    }
                    Text {
                        id: archiveLine
                        objectName: "archiveLine"
                        visible: root.archiveState.length > 0
                        text: "Storage: " + root.archiveState
                        textFormat: Text.PlainText
                        onTextChanged: if ((outcome.text.indexOf("Saving a snapshot") === 0
                                            || outcome.text.indexOf("Fetching the snapshot") === 0)
                                           && root.archiveState.indexOf("saving") !== 0
                                           && root.archiveState.indexOf("fetching") !== 0) outcome.text = ""
                        color: t.text3; font.family: t.sans; font.pixelSize: 12
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Layout.maximumWidth: implicitWidth
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: !root.backendAlive ? "Backend unresponsive — restart the app"
                             : (root.ready ? "Module ready" : "Starting…")
                        color: !root.backendAlive ? t.badText : t.text3
                        font.family: t.sans; font.pixelSize: 11
                    }
                }
            }
        }
    }
}
