import QtQuick
import Quickshell
import SekaiDesk

// #8: TopBar extra popups & hover tooltips:
// - WeatherPopup (click Weather pill on Bar)
// - ResourcePopup (click CPU/GPU/RAM telemetry pill on Bar)
// - BatteryPopup (click Battery indicator pill on Bar, laptops only)
// - BarTip (clean hover tooltip anchored outside Bar edge)
Item {
    id: root
    visible: false

    required property var themeHub
    required property var topBarWindow
    property bool fullscreenActive: false

    function weatherIconFor(code, isDay) {
        const c = Number(code) || 0
        if (c === 0 || c === 1)
            return isDay === false ? "qrc:/qml/icons/moon-dark.svg" : "qrc:/qml/icons/sun-dark.svg"
        if (c === 2)
            return isDay === false ? "qrc:/qml/icons/cloudy-moon-dark.svg" : "qrc:/qml/icons/cloud-sun-dark.svg"
        if (c === 45 || c === 48)
            return "qrc:/qml/icons/fog-dark.svg"
        if ((c >= 51 && c <= 67) || (c >= 80 && c <= 82))
            return "qrc:/qml/icons/cloud-rain-dark.svg"
        if ((c >= 71 && c <= 77) || c === 85 || c === 86)
            return "qrc:/qml/icons/cloud-snowfall-dark.svg"
        if (c >= 95)
            return "qrc:/qml/icons/cloud-storm-dark.svg"
        return "qrc:/qml/icons/cloud-dark.svg"
    }

    // Tooltip state driven from Shell.qml via root.showTip(...) / hideTip()
    property bool tipWanted: false
    property string tipText: ""
    property real tipAnchorX: 0
    property real tipAnchorY: 0
    property bool tipVisible: false

    Timer {
        id: tipDelayTimer
        interval: 380
        onTriggered: {
            if (root.tipWanted && root.tipText !== "" && !root.topBarWindow.anyPopupOpen)
                root.tipVisible = true
        }
    }

    function showTip(text, gx, gy) {
        if (!text || root.topBarWindow.anyPopupOpen) {
            hideTip()
            return
        }
        tipText = text
        tipAnchorX = gx
        tipAnchorY = gy
        tipWanted = true
        if (!tipVisible)
            tipDelayTimer.restart()
    }

    function hideTip() {
        tipWanted = false
        tipVisible = false
        tipDelayTimer.stop()
    }

    // =========================================================================
    // 1) WeatherPopup
    // =========================================================================
    PanelWindow {
        id: weatherPop
        visible: root.topBarWindow.weatherPopupOpen && !root.fullscreenActive
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0
        property string tab: "hourly" // "hourly" | "daily"

        width: 342 + cardShadow
        height: wxCol.implicitHeight + 28 + cardShadow
        x: root.topBarWindow.barPopupX(width, Math.round((root.themeHub.screenW - width) * 0.5))
        y: root.topBarWindow.barPopupY(height, Math.round((root.themeHub.screenH - height) * 0.5))

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                root.hideTip()
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: weatherPop.visible
            onTriggered: {
                if ((Date.now() - weatherPop.openedAt) > 220 && weatherPop.isPointerOutsideAndPressed()) {
                    root.topBarWindow.weatherPopupClosedAt = Date.now()
                    root.topBarWindow.weatherPopupOpen = false
                }
            }
        }

        Rectangle {
            x: weatherPop.cardShadow; y: weatherPop.cardShadow
            width: weatherPop.width - weatherPop.cardShadow
            height: weatherPop.height - weatherPop.cardShadow
            radius: 18; color: "#1A1B2E"
        }

        Rectangle {
            width: weatherPop.width - weatherPop.cardShadow
            height: weatherPop.height - weatherPop.cardShadow
            radius: 18; color: "#FFFFFF"
            border.width: 2.5; border.color: "#1A1B2E"

            Rectangle {
                anchors.fill: parent; anchors.margins: 3; radius: 15
                color: "#F5F8FF"

                Column {
                    id: wxCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 10

                    // Banner Card
                    Rectangle {
                        width: parent.width; height: 92; radius: 14
                        border.width: 2; border.color: "#1A1B2E"
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: root.themeHub.accentB }
                            GradientStop { position: 1.0; color: root.themeHub.accentA }
                        }

                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10

                            Image {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 40; height: 40; sourceSize.width: 80; sourceSize.height: 80; smooth: true
                                source: root.weatherIconFor(WeatherService.weatherCode, WeatherService.isDay)
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                Row {
                                    spacing: 6
                                    Text {
                                        text: root.themeHub.formatTemp(WeatherService.temperature) + "°" + root.themeHub.weatherUnit
                                        font.family: "Segoe UI"; font.pixelSize: 28; font.weight: Font.Black; color: "#1A1B2E"
                                    }
                                    Text {
                                        anchors.bottom: parent.bottom; anchors.bottomMargin: 5
                                        text: "Feels " + root.themeHub.formatTemp(WeatherService.feelsLike) + "°"
                                        font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: "#334155"
                                    }
                                }
                                Text {
                                    width: 176; elide: Text.ElideRight
                                    text: (WeatherService.city || "Local") + " · " + (WeatherService.conditionText || "")
                                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: "#1A1B2E"
                                }
                                Text {
                                    text: "H " + root.themeHub.formatTemp(WeatherService.tempMax) + "°  ·  L " + root.themeHub.formatTemp(WeatherService.tempMin) + "°  ·  " + WeatherService.sunrise + " / " + WeatherService.sunset
                                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.DemiBold; color: "#1E293B"
                                }
                            }
                        }

                        // Refresh pill
                        Rectangle {
                            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                            width: 28; height: 28; radius: 14
                            color: wxRefMa.containsMouse ? "#FFFFFF" : "#AAFFFFFF"
                            border.width: 1.5; border.color: "#1A1B2E"
                            Text { anchors.centerIn: parent; text: "↻"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                            MouseArea { id: wxRefMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: WeatherService.refresh() }
                        }
                    }

                    // 3 Mini Stats Badges (Humidity, Wind, UV)
                    Row {
                        width: parent.width; spacing: 6
                        Repeater {
                            model: [
                                { k: "HUMIDITY", v: WeatherService.humidity + "%" },
                                { k: "WIND",     v: WeatherService.windSpeed + " km/h " + (WeatherService.windDirection || "") },
                                { k: "UV INDEX", v: String(WeatherService.uvIndex) }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: (parent.width - 12) / 3; height: 42; radius: 10
                                color: "#FFFFFF"; border.width: 1.5; border.color: "#1A1B2E"
                                Column {
                                    anchors.centerIn: parent; spacing: 1
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.k; font.family: "Consolas"; font.pixelSize: 8; font.weight: Font.Black; color: "#64748B" }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.v; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: "#1A1B2E" }
                                }
                            }
                        }
                    }

                    // Forecast Mode Toggle + Strip
                    Row {
                        width: parent.width; spacing: 6
                        Repeater {
                            model: [{ id: "hourly", l: "3-HOURLY" }, { id: "daily", l: "3-DAY FORECAST" }]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: weatherPop.tab === modelData.id
                                width: (parent.width - 6) * 0.5; height: 26; radius: 9
                                color: sel ? root.themeHub.accentA : "#FFFFFF"
                                border.width: 1.5; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: weatherPop.tab = modelData.id }
                            }
                        }
                    }

                    // Hourly Strip
                    Row {
                        visible: weatherPop.tab === "hourly"
                        width: parent.width; spacing: 4
                        Repeater {
                            model: WeatherService.hourlyForecast ? WeatherService.hourlyForecast.slice(0, 6) : []
                            delegate: Rectangle {
                                required property var modelData
                                width: (parent.width - 20) / 6; height: 68; radius: 10
                                color: "#FFFFFF"; border.width: 1.5; border.color: "#CBD5E1"
                                Column {
                                    anchors.centerIn: parent; spacing: 3
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.time || ""; font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Bold; color: "#64748B" }
                                    Image { anchors.horizontalCenter: parent.horizontalCenter; width: 18; height: 18; sourceSize.width: 36; sourceSize.height: 36; source: root.weatherIconFor(modelData.code, modelData.isDay) }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.themeHub.formatTemp(modelData.temp) + "°"; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: "#1A1B2E" }
                                }
                            }
                        }
                    }

                    // 3-Day Rows
                    Column {
                        visible: weatherPop.tab === "daily"
                        width: parent.width; spacing: 5
                        Repeater {
                            model: WeatherService.dailyForecast || []
                            delegate: Rectangle {
                                required property var modelData
                                width: parent.width; height: 34; radius: 10
                                color: "#FFFFFF"; border.width: 1.5; border.color: "#CBD5E1"
                                Row {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                    Text { anchors.verticalCenter: parent.verticalCenter; width: 72; text: modelData.label || ""; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: "#1A1B2E" }
                                    Image { anchors.verticalCenter: parent.verticalCenter; width: 18; height: 18; sourceSize.width: 36; sourceSize.height: 36; source: root.weatherIconFor(modelData.code, true) }
                                    Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 178; elide: Text.ElideRight; text: modelData.condition || ""; font.family: "Segoe UI"; font.pixelSize: 10; color: "#475569" }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.themeHub.formatTemp(modelData.high) + "° / " + root.themeHub.formatTemp(modelData.low) + "°"; font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Black; color: "#1A1B2E" }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 2) ResourcePopup (CPU / GPU / RAM sparklines + top processes)
    // =========================================================================
    PanelWindow {
        id: resPop
        visible: root.topBarWindow.resourcePopupOpen && !root.fullscreenActive
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0
        property var procs: []

        function refreshProcs() {
            procs = WindowTracker.topProcesses(6)
        }

        width: 340 + cardShadow
        height: resCol.implicitHeight + 28 + cardShadow
        x: root.topBarWindow.barPopupX(width, root.themeHub.screenW - width - 140)
        y: root.topBarWindow.barPopupY(height, Math.round((root.themeHub.screenH - height) * 0.5))

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                root.hideTip()
                refreshProcs()
                cpuChart.requestPaint()
                ramChart.requestPaint()
                focusActivate()
            }
        }

        Connections {
            target: WindowTracker
            function onStatsChanged() {
                if (!resPop.visible)
                    return
                cpuChart.requestPaint()
                ramChart.requestPaint()
            }
        }

        Timer {
            interval: 1500
            repeat: true
            running: resPop.visible
            onTriggered: resPop.refreshProcs()
        }

        Timer {
            interval: 60
            repeat: true
            running: resPop.visible
            onTriggered: {
                if ((Date.now() - resPop.openedAt) > 220 && resPop.isPointerOutsideAndPressed()) {
                    root.topBarWindow.resourcePopupClosedAt = Date.now()
                    root.topBarWindow.resourcePopupOpen = false
                }
            }
        }

        Rectangle {
            x: resPop.cardShadow; y: resPop.cardShadow
            width: resPop.width - resPop.cardShadow
            height: resPop.height - resPop.cardShadow
            radius: 18; color: "#1A1B2E"
        }

        Rectangle {
            width: resPop.width - resPop.cardShadow
            height: resPop.height - resPop.cardShadow
            radius: 18; color: "#FFFFFF"
            border.width: 2.5; border.color: "#1A1B2E"

            Rectangle {
                anchors.fill: parent; anchors.margins: 3; radius: 15
                color: "#F5F8FF"

                Column {
                    id: resCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 10

                    // Top KPI Summary Strip
                    Row {
                        width: parent.width; spacing: 6
                        Repeater {
                            model: [
                                { k: "CPU", v: WindowTracker.cpuUsage + "%", sub: WindowTracker.cpuTemp >= 0 ? (WindowTracker.cpuTemp + "°C") : (WindowTracker.gpuTemp >= 0 ? ("GPU " + WindowTracker.gpuTemp + "°") : "Load"), col: "#E0F2FE" },
                                { k: "RAM", v: WindowTracker.ramUsage + "%", sub: WindowTracker.ramDetailText || "Memory", col: "#FCE7F3" },
                                { k: "UPTIME", v: WindowTracker.uptimeText || "0m", sub: "Session", col: "#ECFDF5" }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: (parent.width - 12) / 3; height: 56; radius: 12
                                color: modelData.col; border.width: 1.5; border.color: "#1A1B2E"
                                Column {
                                    anchors.centerIn: parent; spacing: 1
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.k; font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: "#475569" }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.v; font.family: "Consolas"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E" }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.sub; font.family: "Segoe UI"; font.pixelSize: 9; font.weight: Font.Bold; color: "#334155" }
                                }
                            }
                        }
                    }

                    // Dual Live Sparklines (CPU & RAM 30-sample history)
                    Row {
                        width: parent.width; spacing: 8

                        Rectangle {
                            width: (parent.width - 8) * 0.5; height: 68; radius: 12
                            color: "#1A1B2E"; border.width: 2; border.color: "#1A1B2E"
                            Text { x: 8; y: 5; text: "CPU HISTORY"; font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: root.themeHub.accentA }
                            Canvas {
                                id: cpuChart
                                x: 6; y: 20; width: parent.width - 12; height: 42
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    const arr = WindowTracker.cpuHistory || []
                                    if (arr.length < 2) return
                                    ctx.beginPath()
                                    for (let i = 0; i < arr.length; ++i) {
                                        const px = (i / Math.max(1, arr.length - 1)) * width
                                        const py = height - (Math.max(0, Math.min(100, Number(arr[i]) || 0)) / 100.0) * (height - 4) - 2
                                        if (i === 0) ctx.moveTo(px, py)
                                        else ctx.lineTo(px, py)
                                    }
                                    ctx.lineWidth = 2.2
                                    ctx.strokeStyle = root.themeHub.accentA
                                    ctx.stroke()
                                }
                            }
                        }

                        Rectangle {
                            width: (parent.width - 8) * 0.5; height: 68; radius: 12
                            color: "#1A1B2E"; border.width: 2; border.color: "#1A1B2E"
                            Text { x: 8; y: 5; text: "RAM HISTORY"; font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: root.themeHub.accentB }
                            Canvas {
                                id: ramChart
                                x: 6; y: 20; width: parent.width - 12; height: 42
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    const arr = WindowTracker.ramHistory || []
                                    if (arr.length < 2) return
                                    ctx.beginPath()
                                    for (let i = 0; i < arr.length; ++i) {
                                        const px = (i / Math.max(1, arr.length - 1)) * width
                                        const py = height - (Math.max(0, Math.min(100, Number(arr[i]) || 0)) / 100.0) * (height - 4) - 2
                                        if (i === 0) ctx.moveTo(px, py)
                                        else ctx.lineTo(px, py)
                                    }
                                    ctx.lineWidth = 2.2
                                    ctx.strokeStyle = root.themeHub.accentB
                                    ctx.stroke()
                                }
                            }
                        }
                    }

                    // Top Memory Processes
                    Text {
                        text: "TOP MEMORY PROCESSES"
                        font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B"
                    }

                    Column {
                        width: parent.width; spacing: 4
                        Repeater {
                            model: resPop.procs || []
                            delegate: Rectangle {
                                required property var modelData
                                width: parent.width; height: 26; radius: 8
                                color: "#FFFFFF"; border.width: 1.5; border.color: "#CBD5E1"
                                Row {
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 6
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 78; elide: Text.ElideRight
                                        text: (modelData.name || "process") + (modelData.instances > 1 ? (" (" + modelData.instances + ")") : "")
                                        font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: "#1A1B2E"
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 70; horizontalAlignment: Text.AlignRight
                                        text: (modelData.ramMb || 0) + " MB"
                                        font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Black; color: "#334155"
                                    }
                                }
                            }
                        }
                    }

                    // Footer: Deep Clean RAM + Task Manager
                    Row {
                        width: parent.width; height: 30; spacing: 6

                        Rectangle {
                            width: (parent.width - 6) * 0.54; height: 30; radius: 10
                            color: RamCleanerService.cleaning
                                   ? "#FEF3C7"
                                   : (ramCleanBtnMa.containsMouse ? "#4ADE80" : root.themeHub.accentB)
                            border.width: 1.5; border.color: "#1A1B2E"
                            Text {
                                anchors.centerIn: parent
                                text: RamCleanerService.cleaning ? "Cleaning..." : "CLEAN RAM (DEEP)"
                                font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: "#1A1B2E"
                            }
                            MouseArea {
                                id: ramCleanBtnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                enabled: !RamCleanerService.cleaning
                                onClicked: RamCleanerService.cleanNowDeep()
                            }
                        }

                        Rectangle {
                            width: (parent.width - 6) * 0.46; height: 30; radius: 10
                            color: tmBtnMa.containsMouse ? root.themeHub.accentA : "#FFFFFF"
                            border.width: 1.5; border.color: "#1A1B2E"
                            Text { anchors.centerIn: parent; text: "Task Manager"; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: "#1A1B2E" }
                            MouseArea {
                                id: tmBtnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.topBarWindow.resourcePopupOpen = false
                                    WindowTracker.openTaskManager()
                                }
                            }
                        }
                    }

                    Text {
                        visible: RamCleanerService.lastResultText !== ""
                        width: parent.width; elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        text: RamCleanerService.lastResultText + (RamCleanerService.lastCleanTime !== "" ? (" (" + RamCleanerService.lastCleanTime + ")") : "")
                        font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold; color: "#334155"
                    }
                }
            }
        }
    }

    // =========================================================================
    // 3) BatteryPopup (laptops only)
    // =========================================================================
    PanelWindow {
        id: batPop
        visible: root.topBarWindow.batteryPopupOpen && WindowTracker.hasBattery && !root.fullscreenActive
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0

        width: 260 + cardShadow
        height: batCol.implicitHeight + 28 + cardShadow
        x: root.topBarWindow.barPopupX(width, root.themeHub.screenW - width - 90)
        y: root.topBarWindow.barPopupY(height, Math.round((root.themeHub.screenH - height) * 0.5))

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                root.hideTip()
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: batPop.visible
            onTriggered: {
                if ((Date.now() - batPop.openedAt) > 220 && batPop.isPointerOutsideAndPressed()) {
                    root.topBarWindow.batteryPopupClosedAt = Date.now()
                    root.topBarWindow.batteryPopupOpen = false
                }
            }
        }

        Rectangle {
            x: batPop.cardShadow; y: batPop.cardShadow
            width: batPop.width - batPop.cardShadow
            height: batPop.height - batPop.cardShadow
            radius: 16; color: "#1A1B2E"
        }

        Rectangle {
            width: batPop.width - batPop.cardShadow
            height: batPop.height - batPop.cardShadow
            radius: 16; color: "#FFFFFF"
            border.width: 2; border.color: "#1A1B2E"

            Rectangle {
                anchors.fill: parent; anchors.margins: 3; radius: 13; color: "#F5F8FF"

                Column {
                    id: batCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 10

                    Item {
                        width: parent.width; height: 34
                        Text {
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            text: (WindowTracker.batteryCharging ? "⚡ BATTERY" : "🔋 BATTERY")
                            font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                        }
                        Text {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            text: WindowTracker.batteryPercent + "%"
                            font.family: "Consolas"; font.pixelSize: 22; font.weight: Font.Black
                            color: WindowTracker.batteryPercent <= 20 ? "#E11D48" : "#1A1B2E"
                        }
                    }

                    Rectangle {
                        width: parent.width; height: 14; radius: 7
                        color: "#E2E8F0"; border.width: 2; border.color: "#1A1B2E"
                        Rectangle {
                            x: 2; y: 2; height: 10; radius: 5
                            width: Math.max(0, (parent.width - 4) * (WindowTracker.batteryPercent / 100.0))
                            color: WindowTracker.batteryPercent <= 20 ? "#FB7185" : (WindowTracker.batteryCharging ? "#34D399" : root.themeHub.accentA)
                        }
                    }

                    Text {
                        width: parent.width
                        text: WindowTracker.batteryTimeText || (WindowTracker.batteryCharging ? "Plugged in" : "On Battery")
                        font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: "#475569"
                    }

                    Rectangle {
                        width: parent.width; height: 28; radius: 10
                        color: pwrSetMa.containsMouse ? root.themeHub.hoverTint : "#FFFFFF"
                        border.width: 1.5; border.color: "#1A1B2E"
                        Text { anchors.centerIn: parent; text: "Power & Battery Settings"; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: "#1A1B2E" }
                        MouseArea {
                            id: pwrSetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.topBarWindow.batteryPopupOpen = false
                                SystemControl.openSettings("ms-settings:powersleep")
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 4) BarTip (Hover tooltip anchored outside the Bar edge)
    // =========================================================================
    PanelWindow {
        id: barTipWin
        visible: root.tipVisible && !root.fullscreenActive && !root.topBarWindow.anyPopupOpen
        clickThrough: true
        color: "transparent"
        mask: []

        width: Math.max(60, tipLbl.implicitWidth + 22)
        height: 28
        x: {
            const scrW = root.themeHub.screenW
            if (root.themeHub.barEdge === "left")
                return Math.min(scrW - width - 8, root.themeHub.barStripThickness + 8)
            if (root.themeHub.barEdge === "right")
                return Math.max(8, scrW - root.themeHub.barStripThickness - width - 8)
            return Math.max(8, Math.min(scrW - width - 8, Math.round(root.tipAnchorX - width * 0.5)))
        }
        y: {
            const scrH = root.themeHub.screenH
            if (root.themeHub.barEdge === "bottom")
                return Math.max(8, scrH - root.themeHub.barStripThickness - height - 8)
            if (root.themeHub.barEdge === "top")
                return Math.min(scrH - height - 8, root.themeHub.barStripThickness + 6)
            return Math.max(8, Math.min(scrH - height - 8, Math.round(root.tipAnchorY - height * 0.5)))
        }

        Rectangle {
            anchors.fill: parent
            radius: 10
            color: root.themeHub.darkInk
            border.width: 2
            border.color: root.themeHub.accentA

            Text {
                id: tipLbl
                anchors.centerIn: parent
                text: root.tipText
                font.family: "Segoe UI"
                font.pixelSize: 10
                font.weight: Font.Black
                color: "#FFFFFF"
            }
        }
    }
}
