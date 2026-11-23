import QtQuick
import Quickshell
import SekaiDesk

// #8: DockTimerCard (Timer / Stopwatch / Pomodoro with persistent running ticker)
//     & DockFilesCard (Quick Folder Stack for Downloads / Desktop / Pictures / Documents)
Item {
    id: cardsRoot
    visible: false

    required property var themeHub
    required property var dockWindow
    property bool fullscreenActive: false

    property bool timerOpen: false
    property bool filesOpen: false

    // =========================================================================
    // Persistent Timer / Stopwatch / Pomodoro State
    // =========================================================================
    property string timerTab: "timer" // "timer" | "stopwatch" | "pomodoro"
    property int timerPresetSec: 300
    property real timerLeft: 300
    property bool timerRunning: false
    property bool timerPaused: false

    property real swElapsed: 0
    property bool swRunning: false
    property var swLaps: []

    property int pomWorkMin: 25
    property int pomShortMin: 5
    property int pomLongMin: 15
    property int pomRounds: 4
    property string pomPhase: "focus" // "focus" | "short" | "long"
    property int pomRound: 1
    property real pomLeft: 25 * 60
    property bool pomRunning: false

    readonly property bool anyTimerActive: timerRunning || swRunning || pomRunning
    readonly property string timerBadgeText: {
        if (timerRunning)
            return fmtClock(timerLeft, false)
        if (pomRunning)
            return fmtClock(pomLeft, false)
        if (swRunning)
            return fmtClock(swElapsed, false)
        return ""
    }

    function fmtClock(sec, showTenths) {
        const s = Math.max(0, sec)
        const whole = Math.floor(s)
        const h = Math.floor(whole / 3600)
        const m = Math.floor((whole % 3600) / 60)
        const r = whole % 60
        const pad2 = n => (n < 10 ? "0" + n : "" + n)
        if (showTenths) {
            const tenth = Math.floor((s - whole) * 10)
            return (h > 0 ? (h + ":") : "") + pad2(m) + ":" + pad2(r) + "." + tenth
        }
        return h > 0 ? (h + ":" + pad2(m) + ":" + pad2(r)) : (pad2(m) + ":" + pad2(r))
    }

    function toggleTimer() {
        if (timerRunning) {
            timerRunning = false
            timerPaused = true
        } else {
            if (timerLeft <= 0.1)
                timerLeft = timerPresetSec
            timerRunning = true
            timerPaused = false
        }
    }

    function resetTimer() {
        timerRunning = false
        timerPaused = false
        timerLeft = timerPresetSec
    }

    function setPomPhaseDuration(ph) {
        pomPhase = ph
        if (ph === "short")
            pomLeft = pomShortMin * 60
        else if (ph === "long")
            pomLeft = pomLongMin * 60
        else
            pomLeft = pomWorkMin * 60
    }

    Timer {
        interval: 100
        repeat: true
        running: cardsRoot.anyTimerActive
        onTriggered: {
            if (cardsRoot.timerRunning) {
                cardsRoot.timerLeft = Math.max(0, cardsRoot.timerLeft - 0.1)
                if (cardsRoot.timerLeft <= 0.01) {
                    cardsRoot.timerRunning = false
                    cardsRoot.timerPaused = false
                    cardsRoot.timerOpen = true
                    NotificationService.emitTestNotification()
                }
            }
            if (cardsRoot.swRunning) {
                cardsRoot.swElapsed += 0.1
            }
            if (cardsRoot.pomRunning) {
                cardsRoot.pomLeft = Math.max(0, cardsRoot.pomLeft - 0.1)
                if (cardsRoot.pomLeft <= 0.01) {
                    if (cardsRoot.pomPhase === "focus") {
                        if (cardsRoot.pomRound >= cardsRoot.pomRounds) {
                            cardsRoot.pomRound = 1
                            cardsRoot.setPomPhaseDuration("long")
                        } else {
                            cardsRoot.setPomPhaseDuration("short")
                        }
                    } else {
                        cardsRoot.pomRound += 1
                        cardsRoot.setPomPhaseDuration("focus")
                    }
                    cardsRoot.pomRunning = false
                    cardsRoot.timerOpen = true
                }
            }
        }
    }

    function cardAnchorX(w) {
        const scrW = cardsRoot.themeHub.screenW
        if (cardsRoot.dockWindow.isLeft)
            return Math.min(scrW - w - 12, cardsRoot.dockWindow.x + cardsRoot.dockWindow.width + 6)
        if (cardsRoot.dockWindow.isRight)
            return Math.max(12, cardsRoot.dockWindow.x - w - 6)
        return Math.max(12, Math.min(scrW - w - 12, Math.round((scrW - w) * 0.5)))
    }

    function cardAnchorY(h) {
        const scrH = cardsRoot.themeHub.screenH
        if (cardsRoot.dockWindow.isTop)
            return Math.min(scrH - h - 12, cardsRoot.dockWindow.y + cardsRoot.dockWindow.height + 6)
        if (cardsRoot.dockWindow.isVertical)
            return Math.max(12, Math.min(scrH - h - 12, Math.round((scrH - h) * 0.5)))
        return Math.max(12, cardsRoot.dockWindow.y - h + 6)
    }

    // =========================================================================
    // 1) DockTimerCard Window
    // =========================================================================
    PanelWindow {
        id: timerWin
        visible: cardsRoot.timerOpen && !cardsRoot.fullscreenActive
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0

        width: 356 + cardShadow
        height: 304 + cardShadow
        x: cardsRoot.cardAnchorX(width)
        y: cardsRoot.cardAnchorY(height)

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                if (cardsRoot.pomRunning)
                    cardsRoot.timerTab = "pomodoro"
                else if (cardsRoot.swRunning)
                    cardsRoot.timerTab = "stopwatch"
                else if (cardsRoot.timerRunning)
                    cardsRoot.timerTab = "timer"
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: timerWin.visible
            onTriggered: {
                if ((Date.now() - timerWin.openedAt) > 220 && timerWin.isPointerOutsideAndPressed())
                    cardsRoot.timerOpen = false
            }
        }

        Rectangle {
            x: timerWin.cardShadow; y: timerWin.cardShadow
            width: timerWin.width - timerWin.cardShadow
            height: timerWin.height - timerWin.cardShadow
            radius: 18; color: "#1A1B2E"
        }

        Rectangle {
            width: timerWin.width - timerWin.cardShadow
            height: timerWin.height - timerWin.cardShadow
            radius: 18; color: cardsRoot.themeHub.phoneCardBg
            border.width: 2.5; border.color: cardsRoot.themeHub.phoneBorder

            Rectangle {
                anchors.fill: parent; anchors.margins: 3; radius: 15
                color: cardsRoot.themeHub.phoneScreenBg

                Column {
                    anchors.fill: parent; anchors.margins: 12; spacing: 10

                    // Tabs row
                    Row {
                        width: parent.width; spacing: 6
                        Repeater {
                            model: [
                                { id: "timer",     label: "Timer" },
                                { id: "stopwatch", label: "Stopwatch" },
                                { id: "pomodoro",  label: "Pomodoro" }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: cardsRoot.timerTab === modelData.id
                                width: (parent.width - 12) / 3; height: 32; radius: 10
                                color: sel ? cardsRoot.themeHub.accentA : (tTabMa.containsMouse ? cardsRoot.themeHub.hoverTint : cardsRoot.themeHub.phoneCardBg)
                                border.width: 2; border.color: (sel || tTabMa.containsMouse) ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder
                                Text {
                                    anchors.centerIn: parent; text: modelData.label
                                    font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black
                                    color: (sel || tTabMa.containsMouse) ? "#1A1B2E" : cardsRoot.themeHub.phoneInk
                                }
                                MouseArea {
                                    id: tTabMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: cardsRoot.timerTab = modelData.id
                                }
                            }
                        }
                    }

                    // --- TAB A: COUNTDOWN TIMER ---
                    Column {
                        visible: cardsRoot.timerTab === "timer"
                        width: parent.width; spacing: 12

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: cardsRoot.fmtClock(cardsRoot.timerLeft, false)
                            font.family: "Consolas"; font.pixelSize: 48; font.weight: Font.Black
                            color: cardsRoot.timerRunning ? cardsRoot.themeHub.phoneInk : cardsRoot.themeHub.phoneMutedInk
                        }

                        // Progress Bar
                        Rectangle {
                            width: parent.width; height: 10; radius: 5
                            color: cardsRoot.themeHub.phonePillBg; border.width: 1.5; border.color: cardsRoot.themeHub.phoneBorder
                            Rectangle {
                                x: 2; y: 2; height: 6; radius: 3
                                width: Math.max(0, (parent.width - 4) * Math.min(1, cardsRoot.timerPresetSec > 0 ? (cardsRoot.timerLeft / cardsRoot.timerPresetSec) : 0))
                                color: cardsRoot.themeHub.accentB
                            }
                        }

                        // Quick presets
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 6
                            Repeater {
                                model: [1, 5, 10, 15, 25, 45]
                                delegate: Rectangle {
                                    required property int modelData
                                    readonly property bool act: cardsRoot.timerPresetSec === modelData * 60
                                    width: 48; height: 28; radius: 9
                                    color: act ? cardsRoot.themeHub.accentB : cardsRoot.themeHub.phoneCardBg
                                    border.width: 1.5; border.color: act ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder
                                    Text { anchors.centerIn: parent; text: modelData + "m"; font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Black; color: act ? "#1A1B2E" : cardsRoot.themeHub.phoneInk }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            cardsRoot.timerRunning = false
                                            cardsRoot.timerPaused = false
                                            cardsRoot.timerPresetSec = modelData * 60
                                            cardsRoot.timerLeft = cardsRoot.timerPresetSec
                                        }
                                    }
                                }
                            }
                        }

                        // Action buttons
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                            Rectangle {
                                width: 126; height: 38; radius: 12
                                color: cardsRoot.timerRunning ? "#FDE68A" : cardsRoot.themeHub.accentA
                                border.width: 2; border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: cardsRoot.timerRunning ? "❚❚ PAUSE" : (cardsRoot.timerPaused ? "▶ RESUME" : "▶ START")
                                    font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E"
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cardsRoot.toggleTimer() }
                            }
                            Rectangle {
                                width: 76; height: 38; radius: 12; color: cardsRoot.themeHub.phoneCardBg; border.width: 2; border.color: cardsRoot.themeHub.phoneBorder
                                Text { anchors.centerIn: parent; text: "+1m"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: cardsRoot.themeHub.phoneInk }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        cardsRoot.timerLeft += 60
                                        if (!cardsRoot.timerRunning)
                                            cardsRoot.timerPresetSec = Math.round(cardsRoot.timerLeft)
                                    }
                                }
                            }
                            Rectangle {
                                width: 76; height: 38; radius: 12; color: "#FFE4E6"; border.width: 2; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: "RESET"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cardsRoot.resetTimer() }
                            }
                        }
                    }

                    // --- TAB B: STOPWATCH ---
                    Column {
                        visible: cardsRoot.timerTab === "stopwatch"
                        width: parent.width; spacing: 10

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: cardsRoot.fmtClock(cardsRoot.swElapsed, true)
                            font.family: "Consolas"; font.pixelSize: 44; font.weight: Font.Black
                            color: cardsRoot.swRunning ? cardsRoot.themeHub.phoneInk : cardsRoot.themeHub.phoneMutedInk
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                            Rectangle {
                                width: 120; height: 36; radius: 11
                                color: cardsRoot.swRunning ? "#FDE68A" : cardsRoot.themeHub.accentA
                                border.width: 2; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: cardsRoot.swRunning ? "❚❚ PAUSE" : "▶ START"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cardsRoot.swRunning = !cardsRoot.swRunning }
                            }
                            Rectangle {
                                width: 78; height: 36; radius: 11; color: cardsRoot.themeHub.phoneCardBg; border.width: 2; border.color: cardsRoot.themeHub.phoneBorder
                                Text { anchors.centerIn: parent; text: "LAP"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: cardsRoot.themeHub.phoneInk }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (cardsRoot.swElapsed <= 0.05)
                                            return
                                        const nxt = cardsRoot.swLaps.slice()
                                        nxt.unshift("#" + (nxt.length + 1) + "  " + cardsRoot.fmtClock(cardsRoot.swElapsed, true))
                                        if (nxt.length > 10) nxt.length = 10
                                        cardsRoot.swLaps = nxt
                                    }
                                }
                            }
                            Rectangle {
                                width: 78; height: 36; radius: 11; color: "#FFE4E6"; border.width: 2; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: "RESET"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { cardsRoot.swRunning = false; cardsRoot.swElapsed = 0; cardsRoot.swLaps = [] }
                                }
                            }
                        }

                        Flickable {
                            width: parent.width; height: 96
                            contentWidth: width; contentHeight: lapCol.implicitHeight
                            clip: true
                            Column {
                                id: lapCol; width: parent.width; spacing: 4
                                Text {
                                    visible: cardsRoot.swLaps.length === 0
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "Press LAP to record split times"
                                    font.family: "Segoe UI"; font.pixelSize: 11; color: cardsRoot.themeHub.phoneMutedInk
                                }
                                Repeater {
                                    model: cardsRoot.swLaps
                                    delegate: Rectangle {
                                        required property string modelData
                                        width: lapCol.width; height: 24; radius: 8
                                        color: cardsRoot.themeHub.phoneCardBg; border.width: 1.5; border.color: cardsRoot.themeHub.phoneBorder
                                        Text { anchors.centerIn: parent; text: modelData; font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Bold; color: cardsRoot.themeHub.phoneInk }
                                    }
                                }
                            }
                        }
                    }

                    // --- TAB C: POMODORO ---
                    Column {
                        visible: cardsRoot.timerTab === "pomodoro"
                        width: parent.width; spacing: 10

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 6
                            Repeater {
                                model: [
                                    { id: "focus", label: "Focus 25m" },
                                    { id: "short", label: "Short 5m" },
                                    { id: "long",  label: "Long 15m" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: cardsRoot.pomPhase === modelData.id
                                    width: 96; height: 26; radius: 9
                                    color: sel ? cardsRoot.themeHub.accentB : cardsRoot.themeHub.phoneCardBg
                                    border.width: 1.5; border.color: sel ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder
                                    Text { anchors.centerIn: parent; text: modelData.label; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: sel ? "#1A1B2E" : cardsRoot.themeHub.phoneInk }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { cardsRoot.pomRunning = false; cardsRoot.setPomPhaseDuration(modelData.id) }
                                    }
                                }
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: cardsRoot.fmtClock(cardsRoot.pomLeft, false)
                            font.family: "Consolas"; font.pixelSize: 48; font.weight: Font.Black
                            color: cardsRoot.pomRunning ? cardsRoot.themeHub.phoneInk : cardsRoot.themeHub.phoneMutedInk
                        }

                        // Round diamonds
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                            Repeater {
                                model: cardsRoot.pomRounds
                                delegate: Rectangle {
                                    required property int index
                                    width: 12; height: 12; rotation: 45; radius: 2
                                    color: (index + 1) <= cardsRoot.pomRound ? cardsRoot.themeHub.accentA : cardsRoot.themeHub.phonePillBg
                                    border.width: 1.5; border.color: cardsRoot.themeHub.phoneBorder
                                }
                            }
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                            Rectangle {
                                width: 148; height: 38; radius: 12
                                color: cardsRoot.pomRunning ? "#FDE68A" : cardsRoot.themeHub.accentA
                                border.width: 2; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: cardsRoot.pomRunning ? "❚❚ PAUSE FOCUS" : "▶ START FOCUS"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cardsRoot.pomRunning = !cardsRoot.pomRunning }
                            }
                            Rectangle {
                                width: 92; height: 38; radius: 12; color: "#FFE4E6"; border.width: 2; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: "RESET"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { cardsRoot.pomRunning = false; cardsRoot.pomRound = 1; cardsRoot.setPomPhaseDuration("focus") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 2) DockFilesCard Window (Quick Folder Stack)
    // =========================================================================
    PanelWindow {
        id: filesWin
        visible: cardsRoot.filesOpen && !cardsRoot.fullscreenActive
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0
        property string activePlace: "downloads"
        property string currentFolderPath: ""
        property var trail: []
        property string viewMode: "grid" // "grid" | "list"
        property string searchQuery: ""
        property var allFiles: []

        readonly property var filteredFiles: {
            const q = searchQuery.trim().toLowerCase()
            if (q === "")
                return allFiles || []
            const out = []
            for (let i = 0; i < allFiles.length; ++i) {
                const it = allFiles[i]
                if (String(it.name || "").toLowerCase().indexOf(q) >= 0)
                    out.push(it)
            }
            return out
        }

        function loadPlace(place) {
            activePlace = place
            trail = []
            currentFolderPath = WindowTracker.resolveFolderPath(place)
            allFiles = WindowTracker.listFolderFiles(currentFolderPath, 60)
        }

        function enterFolder(folderPath) {
            trail = trail.concat([currentFolderPath])
            currentFolderPath = folderPath
            allFiles = WindowTracker.listFolderFiles(currentFolderPath, 60)
        }

        function goBack() {
            if (trail.length === 0)
                return
            currentFolderPath = trail[trail.length - 1]
            trail = trail.slice(0, -1)
            allFiles = WindowTracker.listFolderFiles(currentFolderPath, 60)
        }

        width: 492 + cardShadow
        height: 416 + cardShadow
        x: cardsRoot.cardAnchorX(width)
        y: cardsRoot.cardAnchorY(height)

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                loadPlace(activePlace)
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: filesWin.visible
            onTriggered: {
                if ((Date.now() - filesWin.openedAt) > 220 && filesWin.isPointerOutsideAndPressed())
                    cardsRoot.filesOpen = false
            }
        }

        Rectangle {
            x: filesWin.cardShadow; y: filesWin.cardShadow
            width: filesWin.width - filesWin.cardShadow
            height: filesWin.height - filesWin.cardShadow
            radius: 18; color: "#1A1B2E"
        }

        Rectangle {
            width: filesWin.width - filesWin.cardShadow
            height: filesWin.height - filesWin.cardShadow
            radius: 18; color: cardsRoot.themeHub.phoneCardBg
            border.width: 2.5; border.color: cardsRoot.themeHub.phoneBorder

            Rectangle {
                anchors.fill: parent; anchors.margins: 3; radius: 15
                color: cardsRoot.themeHub.phoneScreenBg

                Column {
                    anchors.fill: parent; anchors.margins: 12; spacing: 8

                    // Header row: Back button + Title/Path + View toggle + Refresh
                    Item {
                        width: parent.width; height: 30
                        Row {
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                            Rectangle {
                                visible: filesWin.trail.length > 0
                                width: 54; height: 26; radius: 9; color: cardsRoot.themeHub.phoneCardBg; border.width: 1.5; border.color: cardsRoot.themeHub.phoneBorder
                                Text { anchors.centerIn: parent; text: "← Back"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: cardsRoot.themeHub.phoneInk }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: filesWin.goBack() }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 250; elide: Text.ElideMiddle
                                text: filesWin.currentFolderPath !== "" ? filesWin.currentFolderPath : "Files"
                                font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: cardsRoot.themeHub.phoneInk
                            }
                        }

                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                            Rectangle {
                                width: 52; height: 26; radius: 9
                                color: cardsRoot.themeHub.accentB; border.width: 1.5; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: filesWin.viewMode === "grid" ? "GRID" : "LIST"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: filesWin.viewMode = (filesWin.viewMode === "grid" ? "list" : "grid")
                                }
                            }
                            Rectangle {
                                width: 28; height: 26; radius: 9; color: cardsRoot.themeHub.phoneCardBg; border.width: 1.5; border.color: cardsRoot.themeHub.phoneBorder
                                Text { anchors.centerIn: parent; text: "↻"; font.pixelSize: 13; font.weight: Font.Black; color: cardsRoot.themeHub.phoneInk }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: filesWin.allFiles = WindowTracker.listFolderFiles(filesWin.currentFolderPath, 60)
                                }
                            }
                        }
                    }

                    // Place quick pills + Search filter
                    Row {
                        width: parent.width; spacing: 6
                        Repeater {
                            model: [
                                { k: "downloads", l: "Downloads" },
                                { k: "desktop",   l: "Desktop" },
                                { k: "pictures",  l: "Pictures" },
                                { k: "documents", l: "Docs" }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: filesWin.activePlace === modelData.k && filesWin.trail.length === 0
                                width: (parent.width - 134) / 4; height: 28; radius: 9
                                color: sel ? cardsRoot.themeHub.accentA : cardsRoot.themeHub.phoneCardBg
                                border.width: 1.5; border.color: sel ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder
                                Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: sel ? "#1A1B2E" : cardsRoot.themeHub.phoneInk }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: filesWin.loadPlace(modelData.k) }
                            }
                        }
                        Rectangle {
                            width: 110; height: 28; radius: 9; color: cardsRoot.themeHub.phoneSubBg; border.width: 1.5; border.color: cardsRoot.themeHub.phoneBorder
                            clip: true
                            TextInput {
                                id: filesSearchInput
                                anchors.fill: parent; anchors.margins: 6
                                verticalAlignment: TextInput.AlignVCenter
                                font.family: "Segoe UI"; font.pixelSize: 10; color: cardsRoot.themeHub.phoneInk
                                onTextChanged: filesWin.searchQuery = text
                                Text {
                                    visible: parent.text === ""
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Filter..."
                                    font.family: "Segoe UI"; font.pixelSize: 10; color: cardsRoot.themeHub.phoneMutedInk
                                }
                            }
                        }
                    }

                    // Files Grid / List Area
                    Item {
                        width: parent.width; height: parent.height - 108

                        Text {
                            visible: filesWin.filteredFiles.length === 0
                            anchors.centerIn: parent
                            text: "Folder is empty"
                            font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Bold; color: cardsRoot.themeHub.phoneMutedInk
                        }

                        GridView {
                            visible: filesWin.viewMode === "grid" && filesWin.filteredFiles.length > 0
                            anchors.fill: parent
                            clip: true
                            cellWidth: 92
                            cellHeight: 96
                            cacheBuffer: 200
                            model: filesWin.filteredFiles
                            delegate: Item {
                                required property var modelData
                                width: 90; height: 92
                                Rectangle {
                                    anchors.fill: parent; anchors.margins: 2; radius: 12
                                    color: gTileMa.containsMouse ? cardsRoot.themeHub.hoverTint : cardsRoot.themeHub.phoneCardBg
                                    border.width: 1.5; border.color: gTileMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder

                                    Column {
                                        anchors.fill: parent; anchors.margins: 6; spacing: 4
                                        Rectangle {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 48; height: 48; radius: 10
                                            color: modelData.isDir ? "#FEF3C7" : "#EFF6FF"
                                            border.width: 1.5; border.color: "#1A1B2E"
                                            clip: true
                                            Image {
                                                anchors.fill: parent
                                                visible: modelData.isImage
                                                source: modelData.isImage ? (modelData.fileUrl || "") : ""
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                sourceSize.width: 96
                                                sourceSize.height: 96
                                            }
                                            Image {
                                                anchors.centerIn: parent
                                                visible: !modelData.isImage && modelData.isDir
                                                width: 24; height: 24; sourceSize.width: 48; sourceSize.height: 48
                                                source: "qrc:/qml/icons/folder-2-dark.svg"
                                            }
                                            Text {
                                                visible: !modelData.isImage && !modelData.isDir
                                                anchors.centerIn: parent
                                                text: String(modelData.ext || "FILE").slice(0, 4)
                                                font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E"
                                            }
                                        }
                                        Text {
                                            width: parent.width; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                                            text: modelData.name || ""
                                            font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Bold
                                            color: gTileMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneInk
                                        }
                                    }
                                    MouseArea {
                                        id: gTileMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.isDir) {
                                                filesWin.enterFolder(modelData.path)
                                            } else {
                                                WindowTracker.openPath(modelData.path)
                                                cardsRoot.filesOpen = false
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        ListView {
                            visible: filesWin.viewMode === "list" && filesWin.filteredFiles.length > 0
                            anchors.fill: parent
                            clip: true
                            spacing: 4
                            model: filesWin.filteredFiles
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width; height: 34; radius: 10
                                color: lRowMa.containsMouse ? cardsRoot.themeHub.hoverTint : cardsRoot.themeHub.phoneCardBg
                                border.width: 1.5; border.color: lRowMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder
                                Row {
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 34; height: 22; radius: 6
                                        color: modelData.isDir ? "#FEF3C7" : cardsRoot.themeHub.accentB
                                        border.width: 1; border.color: "#1A1B2E"
                                        Text { anchors.centerIn: parent; text: String(modelData.ext || "FILE").slice(0, 4); font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: "#1A1B2E" }
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 150; elide: Text.ElideRight
                                        text: modelData.name || ""
                                        font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold
                                        color: lRowMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneInk
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 96; horizontalAlignment: Text.AlignRight
                                        text: modelData.sizeText || ""
                                        font.family: "Consolas"; font.pixelSize: 10
                                        color: lRowMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneMutedInk
                                    }
                                }
                                MouseArea {
                                    id: lRowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (modelData.isDir) {
                                            filesWin.enterFolder(modelData.path)
                                        } else {
                                            WindowTracker.openPath(modelData.path)
                                            cardsRoot.filesOpen = false
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Footer: Open Folder in Explorer
                    Rectangle {
                        width: parent.width; height: 28; radius: 10
                        color: expBtnMa.containsMouse ? cardsRoot.themeHub.accentA : cardsRoot.themeHub.phoneCardBg
                        border.width: 1.5; border.color: expBtnMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneBorder
                        Text { anchors.centerIn: parent; text: "Open in Explorer"; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: expBtnMa.containsMouse ? "#1A1B2E" : cardsRoot.themeHub.phoneInk }
                        MouseArea {
                            id: expBtnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                WindowTracker.openPath(filesWin.currentFolderPath)
                                cardsRoot.filesOpen = false
                            }
                        }
                    }
                }
            }
        }
    }
}
