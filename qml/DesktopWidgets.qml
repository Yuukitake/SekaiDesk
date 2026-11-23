import QtQuick
import Quickshell
import SekaiDesk

Item {
    id: widgetsRoot
    visible: false

    required property var themeHub
    required property bool fullscreenActive

    // Live wall-clock tick shared cleanly by Clock, Profile, Calendar
    property date nowDate: new Date()
    property bool beatPhase: false
    Timer {
        interval: 1000
        repeat: true
        running: !widgetsRoot.fullscreenActive && (themeHub.wClockVisible || themeHub.wProfileVisible || themeHub.wCalendarVisible)
        onTriggered: {
            widgetsRoot.nowDate = new Date()
            widgetsRoot.beatPhase = !widgetsRoot.beatPhase
        }
    }

    // -------------------------------------------------------------------------
    // Core Window Shell & Drag Surface (desktopLayer: true)
    // -------------------------------------------------------------------------
    component WidgetShell: PanelWindow {
        id: wShell
        required property string widgetKey
        required property int cardWidth
        required property int cardHeight
        property int targetX: 0
        property int targetY: 0
        property bool allowFocus: false
        property bool freeResize: false
        property int minCardWidth: 220
        property int minCardHeight: 160
        property int maxCardWidth: 680
        property int maxCardHeight: 680
        property int defaultCardWidth: 320
        property int defaultCardHeight: 248
        property bool nativeDragging: false
        property bool resizingNow: false
        property real liveScale: 1.0
        property int liveW: cardWidth
        property int liveH: cardHeight
        readonly property real savedScale: widgetsRoot.themeHub.widgetScale(widgetKey)
        readonly property real effectiveScale: freeResize ? 1.0 : (resizingNow ? liveScale : savedScale)
        readonly property int displayCardW: freeResize ? (resizingNow ? liveW : cardWidth) : Math.max(40, Math.round(cardWidth * effectiveScale))
        readonly property int displayCardH: freeResize ? (resizingNow ? liveH : cardHeight) : Math.max(40, Math.round(cardHeight * effectiveScale))
        readonly property bool hasCustomSize: freeResize
            ? (cardWidth !== defaultCardWidth || cardHeight !== defaultCardHeight)
            : (Math.abs(effectiveScale - 1.0) > 0.015)
        property int padOffset: 7
        property int shadowOffset: Math.max(16, Math.round(6 * effectiveScale) + padOffset + 5)
        default property alias content: innerContainer.data

        color: "transparent"
        clickThrough: false
        desktopLayer: true
        desktopAllowFocus: allowFocus
        width: displayCardW + shadowOffset
        height: displayCardH + shadowOffset

        onTargetXChanged: if (!nativeDragging && !resizingNow) x = targetX
        onTargetYChanged: if (!nativeDragging && !resizingNow) y = targetY
        Component.onCompleted: {
            x = targetX
            y = targetY
        }

        Item {
            id: innerContainer
            x: wShell.padOffset
            y: wShell.padOffset
            width: wShell.freeResize ? wShell.displayCardW : wShell.cardWidth
            height: wShell.freeResize ? wShell.displayCardH : wShell.cardHeight
            scale: wShell.effectiveScale
            transformOrigin: Item.TopLeft
        }

        // Authentic SekaiPop+ Edit Desktop Chrome (dashed outline + 4 live resize diamonds + edge strips + reset chip)
        Item {
            id: editChrome
            x: innerContainer.x
            y: innerContainer.y
            width: wShell.displayCardW
            height: wShell.displayCardH
            visible: widgetsRoot.themeHub.editMode
            z: 90

            property bool resizeHot: false

            onVisibleChanged: {
                if (visible)
                    dashBorderCanvas.requestPaint()
            }

            Canvas {
                id: dashBorderCanvas
                x: -3
                y: -3
                width: parent.width + 6
                height: parent.height + 6
                property color accentCol: (wShell.resizingNow || editChrome.resizeHot)
                    ? widgetsRoot.themeHub.accentB
                    : widgetsRoot.themeHub.accentA
                property color inkCol: widgetsRoot.themeHub.darkInk
                property bool hovered: editShieldMa.containsMouse || editShieldMa.pressed || editChrome.resizeHot || wShell.resizingNow
                onAccentColChanged: requestPaint()
                onHoveredChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    if (width <= 8 || height <= 8)
                        return
                    const pad = 2
                    const rw = width - pad * 2
                    const rh = height - pad * 2
                    const r = 20
                    function traceRoundRect() {
                        ctx.beginPath()
                        ctx.moveTo(pad + r, pad)
                        ctx.lineTo(pad + rw - r, pad)
                        ctx.quadraticCurveTo(pad + rw, pad, pad + rw, pad + r)
                        ctx.lineTo(pad + rw, pad + rh - r)
                        ctx.quadraticCurveTo(pad + rw, pad + rh, pad + rw - r, pad + rh)
                        ctx.lineTo(pad + r, pad + rh)
                        ctx.quadraticCurveTo(pad, pad + rh, pad, pad + rh - r)
                        ctx.lineTo(pad, pad + r)
                        ctx.quadraticCurveTo(pad, pad, pad + r, pad)
                        ctx.closePath()
                    }
                    ctx.save()
                    ctx.setLineDash([8, 5])
                    ctx.lineWidth = hovered ? 4.5 : 3.5
                    ctx.strokeStyle = inkCol
                    traceRoundRect()
                    ctx.stroke()
                    ctx.lineWidth = hovered ? 2.5 : 2.0
                    ctx.strokeStyle = accentCol
                    traceRoundRect()
                    ctx.stroke()
                    ctx.restore()
                }
            }

            // Free-resize edge grips (Right & Bottom edges for Todo / Notes)
            MouseArea {
                visible: wShell.freeResize
                x: editChrome.width - 5
                y: 14
                width: 10
                height: Math.max(12, editChrome.height - 28)
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.SizeHorCursor
                z: 93
                property real startGx: 0
                property int startW: 0
                onContainsMouseChanged: editChrome.resizeHot = containsMouse || pressed
                onPressed: mouse => {
                    const gp = mapToGlobal(mouse.x, mouse.y)
                    startGx = gp.x
                    startW = wShell.displayCardW
                    wShell.liveW = startW
                    wShell.liveH = wShell.displayCardH
                    wShell.resizingNow = true
                    editChrome.resizeHot = true
                }
                onPositionChanged: mouse => {
                    if (!pressed || !wShell.resizingNow)
                        return
                    const gp = mapToGlobal(mouse.x, mouse.y)
                    const maxWByScreen = Math.max(wShell.minCardWidth, Math.round(widgetsRoot.themeHub.virtMaxX - 8 - wShell.shadowOffset - wShell.x))
                    wShell.liveW = Math.max(wShell.minCardWidth, Math.min(Math.min(wShell.maxCardWidth, maxWByScreen), Math.round(startW + (gp.x - startGx))))
                }
                function finishEdgeW() {
                    if (!wShell.resizingNow)
                        return
                    widgetsRoot.themeHub.saveWidgetSize(wShell.widgetKey, wShell.liveW, wShell.liveH)
                    wShell.resizingNow = false
                    editChrome.resizeHot = containsMouse
                }
                onReleased: finishEdgeW()
                onCanceled: finishEdgeW()
                onDoubleClicked: widgetsRoot.themeHub.resetWidgetSize(wShell.widgetKey)
            }

            MouseArea {
                visible: wShell.freeResize
                x: 14
                y: editChrome.height - 5
                width: Math.max(12, editChrome.width - 28)
                height: 10
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.SizeVerCursor
                z: 93
                property real startGy: 0
                property int startH: 0
                onContainsMouseChanged: editChrome.resizeHot = containsMouse || pressed
                onPressed: mouse => {
                    const gp = mapToGlobal(mouse.x, mouse.y)
                    startGy = gp.y
                    startH = wShell.displayCardH
                    wShell.liveW = wShell.displayCardW
                    wShell.liveH = startH
                    wShell.resizingNow = true
                    editChrome.resizeHot = true
                }
                onPositionChanged: mouse => {
                    if (!pressed || !wShell.resizingNow)
                        return
                    const gp = mapToGlobal(mouse.x, mouse.y)
                    const maxHByScreen = Math.max(wShell.minCardHeight, Math.round(widgetsRoot.themeHub.virtMaxY - 8 - wShell.shadowOffset - wShell.y))
                    wShell.liveH = Math.max(wShell.minCardHeight, Math.min(Math.min(wShell.maxCardHeight, maxHByScreen), Math.round(startH + (gp.y - startGy))))
                }
                function finishEdgeH() {
                    if (!wShell.resizingNow)
                        return
                    widgetsRoot.themeHub.saveWidgetSize(wShell.widgetKey, wShell.liveW, wShell.liveH)
                    wShell.resizingNow = false
                    editChrome.resizeHot = containsMouse
                }
                onReleased: finishEdgeH()
                onCanceled: finishEdgeH()
                onDoubleClicked: widgetsRoot.themeHub.resetWidgetSize(wShell.widgetKey)
            }

            // 4 interactive corner resize diamonds (Uniform scale for complex widgets, free W/H for Notes & Todo)
            Repeater {
                model: [
                    { east: false, south: false },
                    { east: true,  south: false },
                    { east: false, south: true  },
                    { east: true,  south: true  }
                ]
                delegate: Item {
                    id: cornerGrip
                    required property var modelData
                    readonly property bool east: modelData.east
                    readonly property bool south: modelData.south
                    readonly property bool active: cornerMa.containsMouse || cornerMa.pressed

                    width: 24
                    height: 24
                    x: Math.round((east ? editChrome.width : 0) - width * 0.5)
                    y: Math.round((south ? editChrome.height : 0) - height * 0.5)
                    z: 96

                    Rectangle {
                        anchors.centerIn: parent
                        width: cornerGrip.active ? 15 : (editShieldMa.containsMouse ? 13 : 11)
                        height: width
                        rotation: 45
                        radius: 2
                        color: cornerGrip.active
                            ? widgetsRoot.themeHub.accentB
                            : (editShieldMa.containsMouse ? widgetsRoot.themeHub.accentB : widgetsRoot.themeHub.accentA)
                        border.color: widgetsRoot.themeHub.darkInk
                        border.width: 2
                        antialiasing: true
                        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }
                    }

                    MouseArea {
                        id: cornerMa
                        anchors.fill: parent
                        hoverEnabled: true
                        preventStealing: true
                        cursorShape: cornerGrip.east === cornerGrip.south ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor

                        property real startGlobalX: 0
                        property real startGlobalY: 0
                        property real startWinX: 0
                        property real startWinY: 0
                        property int startDispW: 0
                        property int startDispH: 0
                        property real startRight: 0
                        property real startBottom: 0
                        property real startScale: 1.0
                        property int startBaseW: 0
                        property int startBaseH: 0

                        onContainsMouseChanged: editChrome.resizeHot = containsMouse || pressed

                        onPressed: mouse => {
                            const gp = mapToGlobal(mouse.x, mouse.y)
                            startGlobalX = gp.x
                            startGlobalY = gp.y
                            startWinX = wShell.x
                            startWinY = wShell.y
                            startDispW = wShell.displayCardW
                            startDispH = wShell.displayCardH
                            startRight = wShell.x + wShell.displayCardW
                            startBottom = wShell.y + wShell.displayCardH
                            startScale = wShell.effectiveScale
                            startBaseW = wShell.cardWidth
                            startBaseH = wShell.cardHeight
                            if (wShell.freeResize) {
                                wShell.liveW = startDispW
                                wShell.liveH = startDispH
                            } else {
                                wShell.liveScale = startScale
                            }
                            wShell.resizingNow = true
                            editChrome.resizeHot = true
                        }

                        onPositionChanged: mouse => {
                            if (!pressed || !wShell.resizingNow)
                                return
                            const gp = mapToGlobal(mouse.x, mouse.y)
                            const dx = gp.x - startGlobalX
                            const dy = gp.y - startGlobalY
                            const hub = widgetsRoot.themeHub
                            const minXBound = hub.virtMinX + 8
                            const minYBound = hub.widgetMinYAt(wShell.x, wShell.y)
                            const maxXBound = Math.max(minXBound + 200, hub.virtMaxX - 8 - wShell.shadowOffset)
                            const maxYBound = Math.max(minYBound + 200, hub.virtMaxY - 8 - wShell.shadowOffset)

                            if (wShell.freeResize) {
                                const rawW = cornerGrip.east ? (startDispW + dx) : (startDispW - dx)
                                const rawH = cornerGrip.south ? (startDispH + dy) : (startDispH - dy)
                                let nextW = Math.max(wShell.minCardWidth, Math.min(wShell.maxCardWidth, Math.round(rawW)))
                                let nextH = Math.max(wShell.minCardHeight, Math.min(wShell.maxCardHeight, Math.round(rawH)))
                                if (mouse.modifiers & Qt.ShiftModifier) {
                                    const ratio = startDispW / Math.max(1, startDispH)
                                    if (Math.abs(dx) >= Math.abs(dy))
                                        nextH = Math.max(wShell.minCardHeight, Math.min(wShell.maxCardHeight, Math.round(nextW / ratio)))
                                    else
                                        nextW = Math.max(wShell.minCardWidth, Math.min(wShell.maxCardWidth, Math.round(nextH * ratio)))
                                }
                                let nextX = cornerGrip.east ? startWinX : (startRight - nextW)
                                let nextY = cornerGrip.south ? startWinY : (startBottom - nextH)
                                if (!cornerGrip.east && nextX < minXBound) {
                                    nextX = minXBound
                                    nextW = Math.max(wShell.minCardWidth, Math.round(startRight - minXBound))
                                }
                                if (cornerGrip.east && nextX + nextW > maxXBound)
                                    nextW = Math.max(wShell.minCardWidth, Math.round(maxXBound - nextX))
                                if (!cornerGrip.south && nextY < minYBound) {
                                    nextY = minYBound
                                    nextH = Math.max(wShell.minCardHeight, Math.round(startBottom - minYBound))
                                }
                                if (cornerGrip.south && nextY + nextH > maxYBound)
                                    nextH = Math.max(wShell.minCardHeight, Math.round(maxYBound - nextY))
                                wShell.x = Math.round(nextX)
                                wShell.y = Math.round(nextY)
                                wShell.liveW = nextW
                                wShell.liveH = nextH
                            } else {
                                const sx = (cornerGrip.east ? dx : -dx) / Math.max(1, startDispW)
                                const sy = (cornerGrip.south ? dy : -dy) / Math.max(1, startDispH)
                                const delta = Math.abs(sx) >= Math.abs(sy) ? sx : sy
                                let nextSc = Math.max(0.65, Math.min(1.65, startScale * (1.0 + delta)))
                                if (!cornerGrip.east)
                                    nextSc = Math.min(nextSc, (startRight - minXBound) / Math.max(1, startBaseW))
                                else
                                    nextSc = Math.min(nextSc, (maxXBound - startWinX) / Math.max(1, startBaseW))
                                if (!cornerGrip.south)
                                    nextSc = Math.min(nextSc, (startBottom - minYBound) / Math.max(1, startBaseH))
                                else
                                    nextSc = Math.min(nextSc, (maxYBound - startWinY) / Math.max(1, startBaseH))
                                nextSc = Math.max(0.65, Math.min(1.65, nextSc))
                                const nextW = Math.round(startBaseW * nextSc)
                                const nextH = Math.round(startBaseH * nextSc)
                                wShell.liveScale = nextSc
                                wShell.x = cornerGrip.east ? startWinX : Math.max(minXBound, Math.round(startRight - nextW))
                                wShell.y = cornerGrip.south ? startWinY : Math.max(minYBound, Math.round(startBottom - nextH))
                            }
                        }

                        function finishCorner() {
                            if (!wShell.resizingNow)
                                return
                            if (wShell.freeResize)
                                widgetsRoot.themeHub.saveWidgetSize(wShell.widgetKey, wShell.liveW, wShell.liveH)
                            else
                                widgetsRoot.themeHub.saveWidgetScale(wShell.widgetKey, wShell.liveScale)
                            widgetsRoot.themeHub.saveWidgetPos(wShell.widgetKey, wShell.x, wShell.y)
                            wShell.resizingNow = false
                            editChrome.resizeHot = containsMouse
                        }

                        onReleased: finishCorner()
                        onCanceled: finishCorner()
                        onDoubleClicked: widgetsRoot.themeHub.resetWidgetSize(wShell.widgetKey)
                    }
                }
            }

            // Full-card drag & right-click-remove shield while in Edit Mode
            MouseArea {
                id: editShieldMa
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: wShell.nativeDragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                z: 91

                onPressed: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        widgetsRoot.themeHub.setWidgetVisible(wShell.widgetKey, false)
                        return
                    }
                    const hub = widgetsRoot.themeHub
                    const maxW = Math.max(hub.virtMinX + 100, hub.virtMaxX - 80)
                    const maxH = Math.max(hub.virtMinY + 100, hub.virtMaxY - 60)
                    wShell.nativeDragging = true
                    wShell.beginNativeDrag(hub.virtMinX + 8, hub.virtMinY + 8, maxW, maxH)
                }
                onPositionChanged: {
                    if (wShell.nativeDragging)
                        wShell.stepNativeDrag()
                }
                onReleased: {
                    if (wShell.nativeDragging) {
                        wShell.nativeDragging = false
                        wShell.endNativeDrag()
                        widgetsRoot.themeHub.saveWidgetPos(wShell.widgetKey, wShell.x, wShell.y)
                    }
                }
                onCanceled: {
                    if (wShell.nativeDragging) {
                        wShell.nativeDragging = false
                        wShell.endNativeDrag()
                    }
                }
            }

            // Top-left Edit mode badge (displays live % scale or WxH dimensions)
            Rectangle {
                x: 16
                y: -3
                width: editTagTxt.implicitWidth + 14
                height: 20
                radius: 10
                color: (wShell.resizingNow || editChrome.resizeHot || editShieldMa.containsMouse)
                    ? widgetsRoot.themeHub.accentB
                    : widgetsRoot.themeHub.darkInk
                border.color: widgetsRoot.themeHub.darkInk
                border.width: 2
                z: 94
                Text {
                    id: editTagTxt
                    anchors.centerIn: parent
                    text: {
                        const base = wShell.widgetKey.toUpperCase()
                        if (wShell.resizingNow || wShell.hasCustomSize) {
                            if (wShell.freeResize)
                                return base + " · " + wShell.displayCardW + "×" + wShell.displayCardH
                            return base + " · " + Math.round(wShell.effectiveScale * 100) + "%"
                        }
                        return editShieldMa.containsMouse ? (base + " · DRAG") : base
                    }
                    font.pixelSize: 9
                    font.weight: Font.Black
                    color: (wShell.resizingNow || editChrome.resizeHot || editShieldMa.containsMouse)
                        ? widgetsRoot.themeHub.darkInk
                        : "#FFFFFF"
                }
            }

            // Optional 1:1 Size Reset button (appears when widget has custom size)
            Rectangle {
                visible: wShell.hasCustomSize && !wShell.resizingNow
                x: editChrome.width - 66
                y: -3
                width: 22
                height: 22
                radius: 11
                color: editResetMa.containsMouse ? widgetsRoot.themeHub.accentB : "#FFFFFF"
                border.color: widgetsRoot.themeHub.darkInk
                border.width: 2
                z: 95
                Text {
                    anchors.centerIn: parent
                    text: "↺"
                    font.pixelSize: 12
                    font.weight: Font.Black
                    color: widgetsRoot.themeHub.darkInk
                }
                MouseArea {
                    id: editResetMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: widgetsRoot.themeHub.resetWidgetSize(wShell.widgetKey)
                }
            }

            // Top-right Remove button (×)
            Rectangle {
                x: editChrome.width - width - 16
                y: -3
                width: 22
                height: 22
                radius: 11
                color: editRmMa.containsMouse ? "#FF5E7E" : "#FFFFFF"
                border.color: widgetsRoot.themeHub.darkInk
                border.width: 2
                z: 95
                Text {
                    anchors.centerIn: parent
                    text: "×"
                    font.pixelSize: 13
                    font.weight: Font.Black
                    color: editRmMa.containsMouse ? "#FFFFFF" : "#D92652"
                }
                MouseArea {
                    id: editRmMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: widgetsRoot.themeHub.setWidgetVisible(wShell.widgetKey, false)
                }
            }
        }
    }

    component DragSurface: MouseArea {
        required property var shellWin
        required property string widgetKey
        required property var hubRef
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        preventStealing: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: (hubRef && hubRef.widgetsLocked && !hubRef.editMode)
            ? Qt.ArrowCursor
            : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

        property bool dragging: false

        onPressed: mouse => {
            if (mouse.button === Qt.RightButton) {
                if (hubRef)
                    hubRef.setEditMode(true)
                return
            }
            if (hubRef && hubRef.widgetsLocked && !hubRef.editMode)
                return
            const minX = hubRef ? (hubRef.virtMinX + 8) : 8
            const minY = hubRef ? (hubRef.virtMinY + 8) : 52
            const maxW = hubRef ? Math.max(minX + 100, hubRef.virtMaxX - 80) : 1840
            const maxH = hubRef ? Math.max(minY + 100, hubRef.virtMaxY - 60) : 1020
            dragging = true
            shellWin.nativeDragging = true
            shellWin.beginNativeDrag(minX, minY, maxW, maxH)
        }
        onPositionChanged: {
            if (!dragging)
                return
            shellWin.stepNativeDrag()
        }
        onReleased: {
            if (dragging) {
                dragging = false
                shellWin.nativeDragging = false
                shellWin.endNativeDrag()
                if (hubRef)
                    hubRef.saveWidgetPos(widgetKey, shellWin.x, shellWin.y)
            }
        }
        onCanceled: {
            if (dragging) {
                dragging = false
                shellWin.nativeDragging = false
                shellWin.endNativeDrag()
            }
        }
    }

    // -------------------------------------------------------------------------
    // SekaiPop Visual Primitives (inline components — QRC-safe)
    // -------------------------------------------------------------------------
    component DiamondDot: Item {
        id: dd
        property int size: 8
        property color color: "#FFFFFF"
        property color borderColor: "#1A1B2E"
        property int borderWidth: 1
        width: size
        height: size
        Rectangle {
            anchors.centerIn: parent
            width: Math.max(4, Math.round(dd.size * 0.72))
            height: width
            rotation: 45
            radius: 1
            color: dd.color
            border.color: dd.borderColor
            border.width: dd.borderWidth
            antialiasing: true
        }
    }

    component Slant: Canvas {
        id: slantCanvas
        property color color: "#28FFFFFF"
        property color borderColor: "transparent"
        property int borderWidth: 0
        property bool useGradient: false
        property color gradientTop: "#FF5E9E"
        property color gradientBottom: "#4ECDC4"
        property real skew: 0.28
        property int cornerRadius: 0
        readonly property real lean: Math.abs(skew) * height
        onColorChanged: requestPaint()
        onBorderColorChanged: requestPaint()
        onBorderWidthChanged: requestPaint()
        onUseGradientChanged: requestPaint()
        onGradientTopChanged: requestPaint()
        onGradientBottomChanged: requestPaint()
        onSkewChanged: requestPaint()
        onCornerRadiusChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (width <= 2 || height <= 2)
                return
            const bw = borderWidth > 0 ? borderWidth : 0
            const ins = bw * 0.5
            const w = width - bw
            const h = height - bw
            if (w <= 2 || h <= 2)
                return
            const dx = Math.min(w * 0.45, Math.abs(skew) * h)
            const x0 = ins + (skew >= 0 ? dx : 0)
            const y0 = ins
            const x1 = ins + (skew >= 0 ? w : w - dx)
            const y1 = ins
            const x2 = ins + (skew >= 0 ? w - dx : w)
            const y2 = ins + h
            const x3 = ins + (skew >= 0 ? 0 : dx)
            const y3 = ins + h

            const r = Math.min(cornerRadius, h * 0.45, w * 0.25)
            ctx.beginPath()
            if (r > 0.5) {
                const pts = [[x0, y0], [x1, y1], [x2, y2], [x3, y3]]
                for (let i = 0; i < 4; i++) {
                    const pPrev = pts[(i + 3) % 4]
                    const pCur = pts[i]
                    const pNext = pts[(i + 1) % 4]
                    const v1x = pPrev[0] - pCur[0], v1y = pPrev[1] - pCur[1]
                    const v2x = pNext[0] - pCur[0], v2y = pNext[1] - pCur[1]
                    const l1 = Math.max(0.001, Math.hypot(v1x, v1y))
                    const l2 = Math.max(0.001, Math.hypot(v2x, v2y))
                    const d1 = Math.min(r, l1 * 0.4)
                    const d2 = Math.min(r, l2 * 0.4)
                    const sx = pCur[0] + v1x / l1 * d1
                    const sy = pCur[1] + v1y / l1 * d1
                    const ex = pCur[0] + v2x / l2 * d2
                    const ey = pCur[1] + v2y / l2 * d2
                    if (i === 0) ctx.moveTo(sx, sy)
                    else ctx.lineTo(sx, sy)
                    ctx.quadraticCurveTo(pCur[0], pCur[1], ex, ey)
                }
                ctx.closePath()
            } else {
                ctx.moveTo(x0, y0)
                ctx.lineTo(x1, y1)
                ctx.lineTo(x2, y2)
                ctx.lineTo(x3, y3)
                ctx.closePath()
            }

            if (useGradient) {
                const g = ctx.createLinearGradient(0, 0, width, 0)
                g.addColorStop(0.0, gradientTop)
                g.addColorStop(1.0, gradientBottom)
                ctx.fillStyle = g
            } else {
                ctx.fillStyle = color
            }
            ctx.fill()

            if (bw > 0) {
                ctx.lineWidth = bw
                ctx.strokeStyle = borderColor
                ctx.stroke()
            }
        }
    }

    component DotField: Canvas {
        id: dotFieldCanvas
        property color color: "#1A1B2E"
        property real dotAlpha: 0.14
        property int step: 14
        property real dotRadius: 1.5
        property real maxRadius: 3.4
        property string fadeCorner: ""
        property real reach: 0.95
        onColorChanged: requestPaint()
        onDotAlphaChanged: requestPaint()
        onStepChanged: requestPaint()
        onMaxRadiusChanged: requestPaint()
        onFadeCornerChanged: requestPaint()
        onReachChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (width <= 4 || height <= 4)
                return
            ctx.save()
            ctx.globalAlpha = dotAlpha
            ctx.fillStyle = color
            const useFade = fadeCorner !== ""
            const cx = fadeCorner.indexOf("r") >= 0 ? width : 0
            const cy = fadeCorner.indexOf("b") >= 0 ? height : 0
            const diag = Math.max(1, Math.sqrt(width * width + height * height) * reach)
            let row = 0
            const yStep = useFade ? (step * 0.866) : step
            for (let y = step * 0.5; y < height - 1; y += yStep) {
                const offset = (row % 2 === 1) ? step * 0.5 : 0
                row++
                for (let x = step * 0.5 + offset; x < width - 1; x += step) {
                    let r = dotRadius
                    if (useFade) {
                        const t = 1.0 - Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / diag
                        if (t <= 0)
                            continue
                        r = maxRadius * t
                        if (r < 0.6)
                            continue
                    }
                    ctx.beginPath()
                    ctx.arc(x, y, r, 0, Math.PI * 2)
                    ctx.fill()
                }
            }
            ctx.restore()
        }
    }

    component SekaiPill: Item {
        id: pillRoot
        property int radius: 18
        property color color: "#FFFFFF"
        property color gradientTop: "transparent"
        property color gradientBottom: "transparent"
        property bool useGradient: false
        property color inkColor: "#1A1B2E"
        property int borderWidth: 3
        property int shadowShift: 4
        property color shadowColor: "#1A1B2E"
        property bool showInnerRing: true
        property color ringColor: "#99FFFFFF"
        property bool pressedState: false
        property bool clipContent: true
        default property alias inner: pillContent.data

        readonly property int pressOffset: pressedState ? Math.max(2, shadowShift - 1) : 0

        Rectangle {
            id: pillShadow
            x: pillRoot.shadowShift
            y: pillRoot.shadowShift
            width: Math.max(0, pillRoot.width - pillRoot.shadowShift)
            height: Math.max(0, pillRoot.height - pillRoot.shadowShift)
            radius: pillRoot.radius
            color: pillRoot.shadowColor
            visible: pillRoot.shadowShift > 0
        }

        Rectangle {
            id: pillBody
            x: pillRoot.pressOffset
            y: pillRoot.pressOffset
            width: Math.max(0, pillRoot.width - pillRoot.shadowShift)
            height: Math.max(0, pillRoot.height - pillRoot.shadowShift)
            radius: pillRoot.radius
            color: pillRoot.useGradient ? "transparent" : pillRoot.color
            border.color: pillRoot.inkColor
            border.width: pillRoot.borderWidth
            clip: pillRoot.clipContent
            antialiasing: true

            Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutBack } }
            Behavior on y { NumberAnimation { duration: 130; easing.type: Easing.OutBack } }

            gradient: Gradient {
                GradientStop { position: 0.0; color: pillRoot.useGradient ? pillRoot.gradientTop : pillRoot.color }
                GradientStop { position: 1.0; color: pillRoot.useGradient ? pillRoot.gradientBottom : pillRoot.color }
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: pillRoot.borderWidth
                radius: Math.max(2, pillRoot.radius - pillRoot.borderWidth)
                color: "transparent"
                border.color: pillRoot.ringColor
                border.width: 2
                visible: pillRoot.showInnerRing
                z: 50
            }

            Item {
                id: pillContent
                anchors.fill: parent
                anchors.margins: pillRoot.borderWidth
            }
        }
    }

    component SekaiPlate: Item {
        id: plateRoot
        property int radius: 16
        property color topColor: "#FF5E9E"
        property color bottomColor: "#8A63FF"
        property color inkColor: "#1A1B2E"
        property int borderWidth: 3
        property int shadowShift: 4
        property real dotAlpha: 0.16
        default property alias plateContent: plateBody.data

        SekaiPill {
            anchors.fill: parent
            radius: plateRoot.radius
            useGradient: true
            gradientTop: plateRoot.topColor
            gradientBottom: plateRoot.bottomColor
            inkColor: plateRoot.inkColor
            borderWidth: plateRoot.borderWidth
            shadowShift: plateRoot.shadowShift
            ringColor: "#B3FFFFFF"

            DotField {
                anchors.fill: parent
                color: plateRoot.inkColor
                dotAlpha: plateRoot.dotAlpha
                fadeCorner: "tr"
                step: 14
                maxRadius: 3.4
                reach: 0.95
            }

            Slant {
                x: Math.round(parent.width * 0.56)
                y: -8
                width: 46
                height: parent.height + 16
                color: "#38FFFFFF"
                skew: 0.22
            }

            Slant {
                x: Math.round(parent.width * 0.56) + 56
                y: -8
                width: 20
                height: parent.height + 16
                color: "#38FFFFFF"
                skew: 0.22
            }
        }

        Item {
            id: plateBody
            x: plateRoot.borderWidth
            y: plateRoot.borderWidth
            width: Math.max(0, plateRoot.width - plateRoot.shadowShift - plateRoot.borderWidth * 2)
            height: Math.max(0, plateRoot.height - plateRoot.shadowShift - plateRoot.borderWidth * 2)
        }
    }

    component StickerText: Item {
        id: stRoot
        property string text: ""
        property int fontSize: 28
        property color fillColor: "#FFFFFF"
        property color inkColor: "#1A1B2E"
        property color haloColor: "#FFFFFF"
        property int shadowShift: 3
        property real inkThickness: 3
        property real haloThickness: 2
        property bool ringInside: false
        property real maxWidth: 0
        property bool popOnChange: false
        property string fontFamily: "Segoe UI"
        property int fontWeight: Font.Black

        readonly property real padX: (inkThickness + haloThickness) * 2 + shadowShift + 4
        readonly property real wrapLimit: maxWidth > padX + 20 ? (maxWidth - padX) : 200
        readonly property real innerW: maxWidth > 0 ? Math.min(wrapLimit, Math.ceil(wrapProbe.contentWidth) + 2) : Math.ceil(mainTxt.implicitWidth)
        readonly property real innerH: maxWidth > 0 ? Math.ceil(wrapProbe.contentHeight) : Math.ceil(mainTxt.implicitHeight)

        implicitWidth: innerW + padX
        implicitHeight: innerH + (inkThickness + haloThickness) * 2 + shadowShift + 2
        width: implicitWidth
        height: implicitHeight

        Text {
            id: wrapProbe
            visible: false
            width: stRoot.maxWidth > 0 ? stRoot.wrapLimit : 4000
            wrapMode: stRoot.maxWidth > 0 ? Text.Wrap : Text.NoWrap
            text: stRoot.text
            font.family: stRoot.fontFamily
            font.pixelSize: Math.max(8, Math.round(stRoot.fontSize))
            font.weight: stRoot.fontWeight
        }

        onTextChanged: {
            if (popOnChange)
                popAnim.restart()
        }

        SequentialAnimation {
            id: popAnim
            NumberAnimation { target: stScale; property: "xScale"; to: 1.12; duration: 75; easing.type: Easing.OutQuad }
            NumberAnimation { target: stScale; property: "xScale"; to: 1.0; duration: 150; easing.type: Easing.OutBack }
        }

        Item {
            anchors.fill: parent
            transform: Scale {
                id: stScale
                origin.x: stRoot.width / 2
                origin.y: stRoot.height / 2
                xScale: 1.0
                yScale: xScale
            }

            // Hard comic drop shadow (follows outer outline offset when ringInside)
            Text {
                x: stRoot.inkThickness + stRoot.haloThickness + stRoot.shadowShift + (stRoot.ringInside ? (stRoot.inkThickness + stRoot.haloThickness) * 0.35 : 0)
                y: stRoot.inkThickness + stRoot.haloThickness + stRoot.shadowShift + (stRoot.ringInside ? (stRoot.inkThickness + stRoot.haloThickness) * 0.35 : 0)
                width: stRoot.maxWidth > 0 ? stRoot.innerW : implicitWidth
                wrapMode: stRoot.maxWidth > 0 ? Text.Wrap : Text.NoWrap
                horizontalAlignment: stRoot.maxWidth > 0 ? Text.AlignHCenter : Text.AlignLeft
                text: stRoot.text
                font.family: stRoot.fontFamily
                font.pixelSize: Math.max(8, Math.round(stRoot.fontSize))
                font.weight: stRoot.fontWeight
                color: stRoot.inkColor
            }

            // Outer ring layer: inkColor when ringInside (SekaiPop dark-fill style), else white haloColor
            Repeater {
                model: (stRoot.ringInside || stRoot.haloThickness > 0) ? [
                    { dx: -1, dy: 0 }, { dx: 1, dy: 0 }, { dx: 0, dy: -1 }, { dx: 0, dy: 1 },
                    { dx: -1, dy: -1 }, { dx: 1, dy: -1 }, { dx: -1, dy: 1 }, { dx: 1, dy: 1 }
                ] : []
                Text {
                    required property var modelData
                    x: stRoot.inkThickness + stRoot.haloThickness + modelData.dx * (stRoot.inkThickness + stRoot.haloThickness)
                    y: stRoot.inkThickness + stRoot.haloThickness + modelData.dy * (stRoot.inkThickness + stRoot.haloThickness)
                    width: stRoot.maxWidth > 0 ? stRoot.innerW : implicitWidth
                    wrapMode: stRoot.maxWidth > 0 ? Text.Wrap : Text.NoWrap
                    horizontalAlignment: stRoot.maxWidth > 0 ? Text.AlignHCenter : Text.AlignLeft
                    text: stRoot.text
                    font.family: stRoot.fontFamily
                    font.pixelSize: Math.max(8, Math.round(stRoot.fontSize))
                    font.weight: stRoot.fontWeight
                    color: stRoot.ringInside ? stRoot.inkColor : stRoot.haloColor
                }
            }

            // Inner ring layer: white haloColor when ringInside, else dark inkColor
            Repeater {
                model: (!stRoot.ringInside || stRoot.haloThickness > 0) ? [
                    { dx: -1, dy: 0 }, { dx: 1, dy: 0 }, { dx: 0, dy: -1 }, { dx: 0, dy: 1 },
                    { dx: -1, dy: -1 }, { dx: 1, dy: -1 }, { dx: -1, dy: 1 }, { dx: 1, dy: 1 }
                ] : []
                Text {
                    required property var modelData
                    readonly property real ringRad: stRoot.ringInside ? stRoot.haloThickness : stRoot.inkThickness
                    x: stRoot.inkThickness + stRoot.haloThickness + modelData.dx * ringRad
                    y: stRoot.inkThickness + stRoot.haloThickness + modelData.dy * ringRad
                    width: stRoot.maxWidth > 0 ? stRoot.innerW : implicitWidth
                    wrapMode: stRoot.maxWidth > 0 ? Text.Wrap : Text.NoWrap
                    horizontalAlignment: stRoot.maxWidth > 0 ? Text.AlignHCenter : Text.AlignLeft
                    text: stRoot.text
                    font.family: stRoot.fontFamily
                    font.pixelSize: Math.max(8, Math.round(stRoot.fontSize))
                    font.weight: stRoot.fontWeight
                    color: stRoot.ringInside ? stRoot.haloColor : stRoot.inkColor
                }
            }

            Text {
                id: mainTxt
                x: stRoot.inkThickness + stRoot.haloThickness
                y: stRoot.inkThickness + stRoot.haloThickness
                width: stRoot.maxWidth > 0 ? stRoot.innerW : implicitWidth
                wrapMode: stRoot.maxWidth > 0 ? Text.Wrap : Text.NoWrap
                horizontalAlignment: stRoot.maxWidth > 0 ? Text.AlignHCenter : Text.AlignLeft
                text: stRoot.text
                font.family: stRoot.fontFamily
                font.pixelSize: Math.max(8, Math.round(stRoot.fontSize))
                font.weight: stRoot.fontWeight
                color: stRoot.fillColor
            }
        }
    }

    component Burst: Item {
        id: burstRoot
        property color colorA: "#FF5E9E"
        property color colorB: "#4ECDC4"
        property color inkColor: "#1A1B2E"
        property real progress: 0.0
        property bool active: false
        width: 72
        height: 72
        visible: active

        function fire() {
            active = true
            burstAnim.restart()
        }

        SequentialAnimation {
            id: burstAnim
            NumberAnimation { target: burstRoot; property: "progress"; from: 0.0; to: 1.0; duration: 420; easing.type: Easing.OutCubic }
            ScriptAction { script: burstRoot.active = false }
        }

        Repeater {
            model: 8
            Item {
                required property int index
                readonly property real angle: index * Math.PI / 4
                readonly property real dist: 12 + burstRoot.progress * 24
                x: burstRoot.width / 2 + Math.cos(angle) * dist - 4
                y: burstRoot.height / 2 + Math.sin(angle) * dist - 4
                width: 8
                height: 8
                opacity: 1.0 - burstRoot.progress
                scale: 1.15 - burstRoot.progress * 0.55

                Rectangle {
                    anchors.centerIn: parent
                    width: 6
                    height: 6
                    rotation: 45
                    color: (index % 2 === 0) ? burstRoot.colorA : burstRoot.colorB
                    border.color: burstRoot.inkColor
                    border.width: 1
                }
            }
        }
    }

    component WeatherGlyph: Canvas {
        id: wgCanvas
        property int code: 0
        property bool isDay: true
        property color inkColor: "#FFFFFF"
        property color accentColor: "#FFD166"
        onCodeChanged: requestPaint()
        onIsDayChanged: requestPaint()
        onInkColorChanged: requestPaint()
        onAccentColorChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const w = width
            const h = height
            const cx = w * 0.5
            const cy = h * 0.5
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            ctx.strokeStyle = inkColor
            ctx.lineWidth = Math.max(2, Math.round(Math.min(w, h) * 0.09))

            function drawSun(sx, sy, sr) {
                ctx.fillStyle = accentColor
                ctx.beginPath()
                ctx.arc(sx, sy, sr, 0, Math.PI * 2)
                ctx.fill()
                ctx.stroke()
                for (let i = 0; i < 8; i++) {
                    const a = i * Math.PI / 4
                    ctx.beginPath()
                    ctx.moveTo(sx + Math.cos(a) * (sr + 3), sy + Math.sin(a) * (sr + 3))
                    ctx.lineTo(sx + Math.cos(a) * (sr + 6), sy + Math.sin(a) * (sr + 6))
                    ctx.stroke()
                }
            }
            function drawMoon(mx, my, mr) {
                ctx.fillStyle = accentColor
                ctx.beginPath()
                ctx.arc(mx, my, mr, 0.35, Math.PI * 1.65, false)
                ctx.arc(mx + mr * 0.45, my - mr * 0.15, mr * 0.78, Math.PI * 1.55, 0.45, true)
                ctx.closePath()
                ctx.fill()
                ctx.stroke()
            }
            function drawCloud(cx0, cy0, cw) {
                ctx.fillStyle = "#FFFFFF"
                ctx.beginPath()
                ctx.moveTo(cx0 - cw * 0.35, cy0 + cw * 0.22)
                ctx.arc(cx0 - cw * 0.24, cy0 + cw * 0.04, cw * 0.20, Math.PI * 0.65, Math.PI * 1.85)
                ctx.arc(cx0 + cw * 0.02, cy0 - cw * 0.08, cw * 0.25, Math.PI * 1.05, Math.PI * 1.98)
                ctx.arc(cx0 + cw * 0.28, cy0 + cw * 0.06, cw * 0.18, Math.PI * 1.35, Math.PI * 0.5)
                ctx.closePath()
                ctx.fill()
                ctx.stroke()
            }

            if (code === 0) {
                if (isDay) drawSun(cx, cy, Math.min(w, h) * 0.20)
                else drawMoon(cx, cy, Math.min(w, h) * 0.26)
            } else if (code <= 2) {
                if (isDay) drawSun(cx - w * 0.14, cy - h * 0.12, Math.min(w, h) * 0.15)
                else drawMoon(cx - w * 0.14, cy - h * 0.12, Math.min(w, h) * 0.18)
                drawCloud(cx + w * 0.06, cy + h * 0.08, Math.min(w, h) * 0.66)
            } else if (code === 3 || code === 45 || code === 48) {
                drawCloud(cx, cy - (code >= 45 ? h * 0.08 : 0), Math.min(w, h) * 0.72)
                if (code >= 45) {
                    ctx.beginPath()
                    ctx.moveTo(cx - w * 0.24, cy + h * 0.24)
                    ctx.lineTo(cx + w * 0.24, cy + h * 0.24)
                    ctx.moveTo(cx - w * 0.18, cy + h * 0.36)
                    ctx.lineTo(cx + w * 0.18, cy + h * 0.36)
                    ctx.stroke()
                }
            } else if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
                drawCloud(cx, cy - h * 0.08, Math.min(w, h) * 0.68)
                ctx.strokeStyle = "#4ECDC4"
                for (let k = -1; k <= 1; k++) {
                    const rx = cx + k * w * 0.16
                    ctx.beginPath()
                    ctx.moveTo(rx, cy + h * 0.18)
                    ctx.lineTo(rx - w * 0.05, cy + h * 0.36)
                    ctx.stroke()
                }
            } else if ((code >= 71 && code <= 77) || code === 85 || code === 86) {
                drawCloud(cx, cy - h * 0.08, Math.min(w, h) * 0.68)
                ctx.fillStyle = "#D8F3FF"
                for (let k = -1; k <= 1; k++) {
                    ctx.beginPath()
                    ctx.arc(cx + k * w * 0.17, cy + h * 0.28, Math.max(2, w * 0.055), 0, Math.PI * 2)
                    ctx.fill()
                }
            } else if (code >= 95) {
                drawCloud(cx, cy - h * 0.10, Math.min(w, h) * 0.68)
                ctx.strokeStyle = "#FFD166"
                ctx.beginPath()
                ctx.moveTo(cx + w * 0.04, cy + h * 0.12)
                ctx.lineTo(cx - w * 0.08, cy + h * 0.26)
                ctx.lineTo(cx + w * 0.04, cy + h * 0.26)
                ctx.lineTo(cx - w * 0.06, cy + h * 0.42)
                ctx.stroke()
            } else {
                drawCloud(cx, cy, Math.min(w, h) * 0.70)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Helper Functions (strict JS math for Calendar & Weather)
    // -------------------------------------------------------------------------
    function pad2(n) {
        return n < 10 ? "0" + n : "" + n
    }

    function isoDateStr(d) {
        return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
    }

    function isoWeekNumber(d) {
        const tmp = new Date(d.getFullYear(), d.getMonth(), d.getDate())
        tmp.setHours(0, 0, 0, 0)
        tmp.setDate(tmp.getDate() + 3 - ((tmp.getDay() + 6) % 7))
        const week1 = new Date(tmp.getFullYear(), 0, 4)
        return 1 + Math.round(((tmp.getTime() - week1.getTime()) / 86400000 - 3 + ((week1.getDay() + 6) % 7)) / 7)
    }

    function attrColor(attr) {
        if (attr === "cute") return "#FF5E9E"
        if (attr === "cool") return "#4ECDC4"
        if (attr === "pure") return "#54D17A"
        if (attr === "happy") return "#FFA94D"
        if (attr === "mysterious") return "#9B72FF"
        return themeHub.accentA
    }

    function uvColor(uv) {
        if (uv < 3) return "#54D17A"
        if (uv < 6) return "#FFD166"
        if (uv < 8) return "#FFA94D"
        if (uv < 11) return "#FF5E7E"
        return "#9B72FF"
    }

    // =========================================================================
    // 1. CLOCK WIDGET (4 SekaiPop Modes: KEYS / TOWER / STICKER / STACK)
    // =========================================================================
    WidgetShell {
        id: clockWin
        widgetKey: "clock"
        allowFocus: false
        readonly property int mode: Math.max(0, Math.min(3, themeHub.clockStyle))
        cardWidth: mode === 0 ? 320 : (mode === 1 ? 238 : (mode === 2 ? 344 : 224))
        cardHeight: mode === 0 ? 276 : (mode === 1 ? 304 : (mode === 2 ? 176 : 254))
        targetX: themeHub.wClockX
        targetY: themeHub.wClockY
        visible: themeHub.wClockVisible && !widgetsRoot.fullscreenActive

        readonly property int rawH: widgetsRoot.nowDate.getHours()
        readonly property int dispH: themeHub.clockUse24h ? rawH : ((rawH % 12 === 0) ? 12 : rawH % 12)
        readonly property int mins: widgetsRoot.nowDate.getMinutes()
        readonly property int secs: widgetsRoot.nowDate.getSeconds()
        readonly property string h1: Math.floor(dispH / 10) + ""
        readonly property string h2: (dispH % 10) + ""
        readonly property string m1: Math.floor(mins / 10) + ""
        readonly property string m2: (mins % 10) + ""
        readonly property string ampm: themeHub.clockUse24h ? "24H" : (rawH >= 12 ? "PM" : "AM")
        readonly property int weekdayIdx: (widgetsRoot.nowDate.getDay() + 6) % 7
        readonly property string monthShort: ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"][widgetsRoot.nowDate.getMonth()]
        readonly property string dayShort: ["MON","TUE","WED","THU","FRI","SAT","SUN"][weekdayIdx]
        readonly property int dayNum: widgetsRoot.nowDate.getDate()
        property bool hovered: false

        DragSurface {
            shellWin: clockWin
            widgetKey: "clock"
            hubRef: widgetsRoot.themeHub
            onDoubleClicked: widgetsRoot.themeHub.setClockUse24h(!widgetsRoot.themeHub.clockUse24h)
        }

        HoverHandler {
            onHoveredChanged: clockWin.hovered = hovered
        }

        // Floating hover action strip (Mode / 12-24h / Close)
        Row {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 6
            anchors.rightMargin: 10
            spacing: 5
            z: 40
            opacity: clockWin.hovered ? 1.0 : 0.0
            visible: opacity > 0.02
            Behavior on opacity { NumberAnimation { duration: 130 } }

            Rectangle {
                height: 22
                width: modeLabel.implicitWidth + 14
                radius: 11
                color: themeHub.darkInk
                border.color: "#FFFFFF"
                border.width: 2
                Text {
                    id: modeLabel
                    anchors.centerIn: parent
                    text: themeHub.clockDesignNames[clockWin.mode] || "KEYS"
                    font.pixelSize: 10
                    font.weight: Font.Black
                    color: "#FFFFFF"
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: themeHub.cycleClockStyle()
                }
            }

            Rectangle {
                height: 22
                width: 22
                radius: 11
                color: "#FFFFFF"
                border.color: themeHub.darkInk
                border.width: 2
                Text {
                    anchors.centerIn: parent
                    text: "×"
                    font.pixelSize: 13
                    font.weight: Font.Black
                    color: themeHub.darkInk
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: themeHub.setWidgetVisible("clock", false)
                }
            }
        }

        // --- MODE 0: KEYS (SekaiPop 320x276 3D Keycap Board) ---
        SekaiPill {
            anchors.fill: parent
            visible: clockWin.mode === 0
            radius: 22
            color: "#FFFDF9"
            inkColor: themeHub.darkInk
            shadowShift: 5

            // Subtle vertical guide lanes
            Row {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 42
                opacity: 0.06
                Repeater {
                    model: 6
                    Rectangle { width: 2; height: parent.height; color: themeHub.darkInk }
                }
            }

            // Header: DateSticker + AmPmSwitch
            Item {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 14
                height: 36

                SekaiPill {
                    id: dateSticker
                    visible: themeHub.clockShowDate
                    width: 146
                    height: 32
                    radius: 11
                    color: themeHub.accentB
                    inkColor: themeHub.darkInk
                    borderWidth: 2
                    shadowShift: 3
                    rotation: -2.0
                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: clockWin.dayShort + " " + widgetsRoot.pad2(clockWin.dayNum) + " " + clockWin.monthShort
                            font.pixelSize: 11
                            font.weight: Font.Black
                            color: "#FFFFFF"
                        }
                    }
                }

                SekaiPill {
                    id: ampmBtn
                    anchors.left: themeHub.clockShowDate ? dateSticker.right : parent.left
                    anchors.leftMargin: themeHub.clockShowDate ? 8 : 0
                    y: 2
                    width: 48
                    height: 28
                    radius: 10
                    color: "#FFFFFF"
                    inkColor: themeHub.darkInk
                    borderWidth: 2
                    shadowShift: 2
                    pressedState: ampmMa.pressed
                    Text {
                        anchors.centerIn: parent
                        text: clockWin.ampm
                        font.pixelSize: 11
                        font.weight: Font.Black
                        color: themeHub.darkInk
                    }
                    MouseArea {
                        id: ampmMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: themeHub.setClockUse24h(!themeHub.clockUse24h)
                    }
                }
            }

            // 4 Staggered 3D Keycap Tiles + 2 Beat Diamonds
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 66
                spacing: 6

                Repeater {
                    model: [
                        { val: clockWin.h1, rot: -2.6, tint: "#FFFFFF", txt: themeHub.darkInk, accent: themeHub.accentA },
                        { val: clockWin.h2, rot: 1.8,  tint: "#FFF5FA", txt: themeHub.darkInk, accent: themeHub.accentA },
                        { val: ":",         rot: 0,    isColon: true },
                        { val: clockWin.m1, rot: -1.6, tint: "#F3FBFF", txt: themeHub.darkInk, accent: themeHub.accentB },
                        { val: clockWin.m2, rot: 2.5,  tint: "#FFFFFF", txt: themeHub.darkInk, accent: themeHub.accentB }
                    ]

                    Item {
                        required property var modelData
                        readonly property bool isColon: !!modelData.isColon
                        width: isColon ? 20 : 62
                        height: 92

                        // 2 Beat diamonds for colon
                        Column {
                            visible: isColon
                            anchors.centerIn: parent
                            spacing: 16
                            DiamondDot {
                                size: 13
                                color: widgetsRoot.beatPhase ? themeHub.accentA : themeHub.accentB
                                borderColor: themeHub.darkInk
                                borderWidth: 2
                                scale: widgetsRoot.beatPhase ? 1.18 : 0.92
                                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                            }
                            DiamondDot {
                                size: 13
                                color: widgetsRoot.beatPhase ? themeHub.accentB : themeHub.accentA
                                borderColor: themeHub.darkInk
                                borderWidth: 2
                                scale: widgetsRoot.beatPhase ? 0.92 : 1.18
                                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                            }
                        }

                        // 3D Mechanical Keycap
                        Item {
                            visible: !isColon
                            anchors.fill: parent
                            rotation: modelData.rot

                            // Keycap base skirt
                            Rectangle {
                                x: 3
                                y: 7
                                width: 56
                                height: 82
                                radius: 14
                                color: themeHub.darkInk
                            }
                            // Bottom colored lip
                            Rectangle {
                                x: 0
                                y: 6
                                width: 56
                                height: 80
                                radius: 14
                                color: modelData.accent || themeHub.accentA
                                border.color: themeHub.darkInk
                                border.width: 3
                            }
                            // Top key face
                            Rectangle {
                                x: 0
                                y: 0
                                width: 56
                                height: 74
                                radius: 13
                                color: modelData.tint || "#FFFFFF"
                                border.color: themeHub.darkInk
                                border.width: 3
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.val
                                    font.pixelSize: 40
                                    font.weight: Font.Black
                                    color: modelData.txt || themeHub.darkInk
                                }
                            }
                        }
                    }
                }
            }

            // 60-Second Lane + Sliding SecChip
            Item {
                visible: themeHub.clockSeconds
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 16
                y: 174
                height: 32

                Rectangle {
                    id: secTrack
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 12
                    radius: 6
                    color: "#EEF1F8"
                    border.color: themeHub.darkInk
                    border.width: 2

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: 2
                        width: Math.max(8, Math.round((parent.width - 4) * (clockWin.secs / 59.0)))
                        radius: 4
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: themeHub.accentA }
                            GradientStop { position: 1.0; color: themeHub.accentB }
                        }
                        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    }

                    // 15s / 30s / 45s gates
                    Repeater {
                        model: [0.25, 0.5, 0.75]
                        Rectangle {
                            required property real modelData
                            x: Math.round(secTrack.width * modelData) - 1
                            y: 2
                            width: 2
                            height: 8
                            color: "#661A1B2E"
                        }
                    }
                }

                // Sliding SecChip
                SekaiPill {
                    width: 44
                    height: 26
                    radius: 9
                    color: themeHub.darkInk
                    inkColor: "#FFFFFF"
                    borderWidth: 2
                    shadowShift: 2
                    showInnerRing: false
                    rotation: (clockWin.secs % 2 === 0) ? -3 : 3
                    x: Math.max(0, Math.min(parent.width - width, Math.round((parent.width - width) * (clockWin.secs / 59.0))))
                    y: 3
                    Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    Text {
                        anchors.centerIn: parent
                        text: ":" + widgetsRoot.pad2(clockWin.secs)
                        font.pixelSize: 11
                        font.weight: Font.Black
                        color: "#FFFFFF"
                    }
                }
            }

            // 7-Day Badge Strip
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 12
                spacing: 6
                Repeater {
                    model: ["M","T","W","T","F","S","S"]
                    SekaiPill {
                        required property int index
                        required property string modelData
                        readonly property bool isToday: index === clockWin.weekdayIdx
                        width: 34
                        height: 34
                        radius: 10
                        color: isToday ? themeHub.accentA : "#F4F6FB"
                        inkColor: themeHub.darkInk
                        borderWidth: 2
                        shadowShift: isToday ? 3 : 1
                        showInnerRing: isToday
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            font.pixelSize: 12
                            font.weight: Font.Black
                            color: isToday ? "#FFFFFF" : "#661A1B2E"
                        }
                    }
                }
            }
        }

        // --- MODE 1: TOWER (Vertical Keycap Stack 238x304) ---
        SekaiPill {
            anchors.fill: parent
            visible: clockWin.mode === 1
            radius: 22
            color: "#FFFDF9"
            inkColor: themeHub.darkInk
            shadowShift: 5

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10

                // Date + 12/24 pill
                Row {
                    spacing: 6
                    SekaiPill {
                        visible: themeHub.clockShowDate
                        width: 118
                        height: 28
                        radius: 9
                        color: themeHub.accentA
                        inkColor: themeHub.darkInk
                        borderWidth: 2
                        shadowShift: 2
                        Text {
                            anchors.centerIn: parent
                            text: clockWin.dayShort + " " + clockWin.dayNum + " " + clockWin.monthShort
                            font.pixelSize: 10
                            font.weight: Font.Black
                            color: "#FFFFFF"
                        }
                    }
                    SekaiPill {
                        width: 44
                        height: 28
                        radius: 9
                        color: "#FFFFFF"
                        inkColor: themeHub.darkInk
                        borderWidth: 2
                        shadowShift: 2
                        Text {
                            anchors.centerIn: parent
                            text: clockWin.ampm
                            font.pixelSize: 10
                            font.weight: Font.Black
                            color: themeHub.darkInk
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: themeHub.setClockUse24h(!themeHub.clockUse24h)
                        }
                    }
                }

                // Hours Row + Minutes Row + Vertical Seconds Strip
                Row {
                    spacing: 10
                    Column {
                        spacing: 10
                        Row {
                            spacing: 8
                            Repeater {
                                model: [clockWin.h1, clockWin.h2]
                                Item {
                                    required property string modelData
                                    required property int index
                                    width: 70; height: 84
                                    rotation: index === 0 ? -2.2 : 1.8
                                    Rectangle { x: 2; y: 6; width: 66; height: 76; radius: 14; color: themeHub.darkInk }
                                    Rectangle { x: 0; y: 5; width: 66; height: 74; radius: 14; color: themeHub.accentA; border.color: themeHub.darkInk; border.width: 3 }
                                    Rectangle {
                                        x: 0; y: 0; width: 66; height: 68; radius: 13; color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 3
                                        Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 40; font.weight: Font.Black; color: themeHub.darkInk }
                                    }
                                }
                            }
                        }
                        Row {
                            spacing: 8
                            Repeater {
                                model: [clockWin.m1, clockWin.m2]
                                Item {
                                    required property string modelData
                                    required property int index
                                    width: 70; height: 84
                                    rotation: index === 0 ? 1.8 : -2.0
                                    Rectangle { x: 2; y: 6; width: 66; height: 76; radius: 14; color: themeHub.darkInk }
                                    Rectangle { x: 0; y: 5; width: 66; height: 74; radius: 14; color: themeHub.accentB; border.color: themeHub.darkInk; border.width: 3 }
                                    Rectangle {
                                        x: 0; y: 0; width: 66; height: 68; radius: 13; color: "#F7FBFF"; border.color: themeHub.darkInk; border.width: 3
                                        Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 40; font.weight: Font.Black; color: themeHub.darkInk }
                                    }
                                }
                            }
                        }
                    }

                    // Vertical seconds tower
                    Item {
                        visible: themeHub.clockSeconds
                        width: 34
                        height: 178
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 14; height: parent.height; radius: 7
                            color: "#EEF1F8"; border.color: themeHub.darkInk; border.width: 2
                            Rectangle {
                                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 2
                                height: Math.max(8, Math.round((parent.height - 4) * (clockWin.secs / 59.0)))
                                radius: 5; color: themeHub.accentB
                                Behavior on height { NumberAnimation { duration: 240 } }
                            }
                        }
                        SekaiPill {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: parent.height - height - Math.round((parent.height - height) * (clockWin.secs / 59.0))
                            width: 34; height: 24; radius: 8
                            color: themeHub.darkInk; inkColor: "#FFFFFF"; borderWidth: 2; shadowShift: 1; showInnerRing: false
                            Text { anchors.centerIn: parent; text: widgetsRoot.pad2(clockWin.secs); font.pixelSize: 10; font.weight: Font.Black; color: "#FFFFFF" }
                        }
                    }
                }

                // Compact week dots
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Repeater {
                        model: ["M","T","W","T","F","S","S"]
                        Rectangle {
                            required property int index
                            required property string modelData
                            readonly property bool isToday: index === clockWin.weekdayIdx
                            width: 22; height: 22; radius: 7
                            color: isToday ? themeHub.accentA : "#EEF1F8"
                            border.color: themeHub.darkInk; border.width: isToday ? 2 : 1
                            Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 10; font.weight: Font.Black; color: isToday ? "#FFFFFF" : "#661A1B2E" }
                        }
                    }
                }
            }
        }

        // --- MODE 2: STICKER (Cardless Floating Desktop Stickers) ---
        Item {
            anchors.fill: parent
            visible: clockWin.mode === 2

            Row {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -12
                spacing: 4
                StickerText {
                    text: clockWin.h1 + clockWin.h2
                    fontSize: 64
                    fillColor: themeHub.accentA
                    inkColor: themeHub.darkInk
                    inkThickness: 4
                    haloThickness: 3
                    shadowShift: 4
                    popOnChange: true
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    DiamondDot { size: 14; color: themeHub.accentB; borderColor: themeHub.darkInk; borderWidth: 2; scale: widgetsRoot.beatPhase ? 1.2 : 0.9 }
                    DiamondDot { size: 14; color: themeHub.accentA; borderColor: themeHub.darkInk; borderWidth: 2; scale: widgetsRoot.beatPhase ? 0.9 : 1.2 }
                }
                StickerText {
                    text: clockWin.m1 + clockWin.m2
                    fontSize: 64
                    fillColor: "#FFFFFF"
                    inkColor: themeHub.darkInk
                    inkThickness: 4
                    haloThickness: 3
                    shadowShift: 4
                    popOnChange: true
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 8
                spacing: 8
                SekaiPill {
                    visible: themeHub.clockShowDate
                    width: 132; height: 30; radius: 10; color: themeHub.accentB; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; rotation: -2
                    Text { anchors.centerIn: parent; text: clockWin.dayShort + " " + clockWin.dayNum + " " + clockWin.monthShort; font.pixelSize: 11; font.weight: Font.Black; color: "#FFFFFF" }
                }
                SekaiPill {
                    visible: themeHub.clockSeconds || !themeHub.clockUse24h
                    width: 56; height: 30; radius: 10; color: themeHub.darkInk; inkColor: "#FFFFFF"; borderWidth: 2; shadowShift: 3; showInnerRing: false; rotation: 2
                    Text { anchors.centerIn: parent; text: (themeHub.clockSeconds ? ":" + widgetsRoot.pad2(clockWin.secs) + " " : "") + (themeHub.clockUse24h ? "" : clockWin.ampm); font.pixelSize: 11; font.weight: Font.Black; color: "#FFFFFF" }
                }
            }
        }

        // --- MODE 3: STACK (Cardless Vertical Sticker Stack) ---
        Item {
            anchors.fill: parent
            visible: clockWin.mode === 3

            Column {
                anchors.centerIn: parent
                spacing: 0
                StickerText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: clockWin.h1 + clockWin.h2
                    fontSize: 62
                    fillColor: themeHub.accentA
                    inkColor: themeHub.darkInk
                    inkThickness: 4
                    haloThickness: 3
                    shadowShift: 4
                    rotation: -3
                    popOnChange: true
                }
                StickerText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: clockWin.m1 + clockWin.m2
                    fontSize: 62
                    fillColor: themeHub.accentB
                    inkColor: themeHub.darkInk
                    inkThickness: 4
                    haloThickness: 3
                    shadowShift: 4
                    rotation: 2.5
                    popOnChange: true
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    SekaiPill {
                        visible: themeHub.clockShowDate
                        width: 112; height: 28; radius: 9; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; rotation: -1.5
                        Text { anchors.centerIn: parent; text: clockWin.dayShort + " " + clockWin.dayNum + " " + clockWin.monthShort; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                    }
                    SekaiPill {
                        visible: themeHub.clockSeconds
                        width: 44; height: 28; radius: 9; color: themeHub.darkInk; inkColor: "#FFFFFF"; borderWidth: 2; shadowShift: 3; showInnerRing: false; rotation: 2
                        Text { anchors.centerIn: parent; text: ":" + widgetsRoot.pad2(clockWin.secs); font.pixelSize: 11; font.weight: Font.Black; color: "#FFFFFF" }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 2. WEATHER WIDGET (SekaiPop Classic & Minimal Modes)
    // =========================================================================
    WidgetShell {
        id: weatherWin
        widgetKey: "weather"
        allowFocus: false
        readonly property bool isMinimal: themeHub.weatherMinimal
        cardWidth: 320
        cardHeight: isMinimal ? 212 : 276
        targetX: themeHub.wWeatherX
        targetY: themeHub.wWeatherY
        visible: themeHub.wWeatherVisible && !widgetsRoot.fullscreenActive

        property int hoveredHour: -1
        property int hoveredDay: -1
        property bool hovered: false

        readonly property var hourList: WeatherService.hourlyForecast || []
        readonly property var dayList: WeatherService.dailyForecast || []
        readonly property int activeTemp: (hoveredHour >= 0 && hoveredHour < hourList.length)
                                          ? Math.round(hourList[hoveredHour].temp)
                                          : ((hoveredDay >= 0 && hoveredDay < dayList.length)
                                             ? Math.round(dayList[hoveredDay].high)
                                             : WeatherService.temperature)
        readonly property string activeCond: (hoveredHour >= 0 && hoveredHour < hourList.length)
                                             ? (hourList[hoveredHour].condition || WeatherService.conditionText)
                                             : ((hoveredDay >= 0 && hoveredDay < dayList.length)
                                                ? (dayList[hoveredDay].condition || WeatherService.conditionText)
                                                : WeatherService.conditionText)
        readonly property int activeCode: (hoveredHour >= 0 && hoveredHour < hourList.length)
                                          ? (hourList[hoveredHour].code || 0)
                                          : ((hoveredDay >= 0 && hoveredDay < dayList.length)
                                             ? (dayList[hoveredDay].code || 0)
                                             : WeatherService.weatherCode)
        readonly property bool activeIsDay: (hoveredHour >= 0 && hoveredHour < hourList.length)
                                            ? !!hourList[hoveredHour].isDay
                                            : WeatherService.isDay

        readonly property var daySpan: {
            const n = Math.min(3, dayList.length)
            if (n <= 0)
                return { lo: 0, hi: 1 }
            let lo = 1e9
            let hi = -1e9
            for (let i = 0; i < n; i++) {
                const d = dayList[i]
                lo = Math.min(lo, Number(d.low))
                hi = Math.max(hi, Number(d.high))
            }
            return { lo: lo, hi: Math.max(hi, lo + 1) }
        }

        DragSurface {
            shellWin: weatherWin
            widgetKey: "weather"
            hubRef: widgetsRoot.themeHub
        }

        HoverHandler {
            onHoveredChanged: weatherWin.hovered = hovered
        }

        SekaiPill {
            anchors.fill: parent
            radius: 22
            color: "#FFFDF9"
            inkColor: themeHub.darkInk
            shadowShift: 5

            // --- CLASSIC BODY (Authentic SekaiPop 286x238 Layout) ---
            Item {
                id: weatherClassic
                visible: !weatherWin.isMinimal
                anchors.centerIn: parent
                width: 286
                height: 238

                // 1. Hero SekaiPlate + Hanging Place Slant + View/Refresh Pill Keys
                Item {
                    id: wHead
                    x: 0; y: 0
                    width: 286
                    height: 100

                    SekaiPlate {
                        id: wPlate
                        x: 0; y: 0
                        width: 286
                        height: 88
                        radius: 16
                        topColor: themeHub.accentA
                        bottomColor: themeHub.accentB
                        inkColor: themeHub.darkInk
                        borderWidth: 3
                        shadowShift: 4

                        // Condition or hovered forecast readout
                        Text {
                            x: 10; y: 4
                            width: 176
                            elide: Text.ElideRight
                            text: {
                                if (weatherWin.hoveredHour >= 0 && weatherWin.hoveredHour < weatherWin.hourList.length) {
                                    const h = weatherWin.hourList[weatherWin.hoveredHour]
                                    return (h.label || "") + " · " + weatherWin.activeCond
                                }
                                if (weatherWin.hoveredDay >= 0 && weatherWin.hoveredDay < weatherWin.dayList.length) {
                                    const d = weatherWin.dayList[weatherWin.hoveredDay]
                                    return (d.label || "") + " · " + weatherWin.activeCond
                                }
                                return (weatherWin.activeCond || (WeatherService.loading ? "SYNCING..." : "CLEAR")).toUpperCase()
                            }
                            font.pixelSize: 10
                            font.weight: Font.Black
                            color: Qt.rgba(themeHub.darkInk.r, themeHub.darkInk.g, themeHub.darkInk.b, 0.85)
                        }

                        // Dark-filled StickerText temp with white inner ring + dark outer ink + H/L arrows
                        StickerText {
                            id: wTempNum
                            x: 2; y: 12
                            text: String(themeHub.formatTemp(weatherWin.activeTemp))
                            fontSize: 40
                            fillColor: Qt.darker(themeHub.darkInk, 1.8)
                            inkColor: themeHub.darkInk
                            haloColor: "#FFFFFF"
                            inkThickness: 2.2
                            haloThickness: 1.6
                            ringInside: true
                            shadowShift: 3
                            popOnChange: true
                        }

                        StickerText {
                            id: wTempUnit
                            x: wTempNum.x + wTempNum.width - 5
                            y: 19
                            text: "°" + themeHub.weatherUnit
                            fontSize: 18
                            fillColor: Qt.darker(themeHub.darkInk, 1.8)
                            inkColor: themeHub.darkInk
                            haloColor: "#FFFFFF"
                            inkThickness: 2.0
                            haloThickness: 1.5
                            ringInside: true
                            shadowShift: 2
                        }

                        Column {
                            x: wTempUnit.x + wTempUnit.width + 2
                            y: 34
                            spacing: 0
                            Row {
                                spacing: 2
                                Image { anchors.verticalCenter: parent.verticalCenter; width: 10; height: 10; source: "qrc:/qml/icons/arrow-up-dark.svg"; sourceSize: Qt.size(20, 20); smooth: true }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: themeHub.formatTemp(WeatherService.tempMax) + "°"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                            }
                            Row {
                                spacing: 2
                                Image { anchors.verticalCenter: parent.verticalCenter; width: 10; height: 10; source: "qrc:/qml/icons/arrow-down-dark.svg"; sourceSize: Qt.size(20, 20); smooth: true }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: themeHub.formatTemp(WeatherService.tempMin) + "°"; font.pixelSize: 11; font.weight: Font.Black; color: Qt.rgba(themeHub.darkInk.r, themeHub.darkInk.g, themeHub.darkInk.b, 0.78) }
                            }
                        }

                        // Overlapping tilted dark weather disc
                        SekaiPill {
                            id: wDisc
                            x: wPlate.width - width - 14
                            y: 4
                            width: 66
                            height: 68
                            radius: 33
                            color: themeHub.darkInk
                            inkColor: "#FFFFFF"
                            borderWidth: 2
                            shadowShift: 3
                            rotation: 6
                            pressedState: wDiscMa.pressed

                            property real sx: 1.0
                            property real sy: 1.0
                            transform: Scale {
                                origin.x: wDisc.width * 0.5
                                origin.y: wDisc.height * 0.5
                                xScale: wDisc.sx
                                yScale: wDisc.sy
                            }

                            WeatherGlyph {
                                anchors.centerIn: parent
                                width: 40
                                height: 40
                                code: weatherWin.activeCode
                                isDay: weatherWin.activeIsDay
                                inkColor: "#FFFFFF"
                                accentColor: "#FFD166"
                            }

                            Burst {
                                id: wBurst
                                anchors.centerIn: parent
                                colorA: themeHub.accentA
                                colorB: "#FFD166"
                                inkColor: themeHub.darkInk
                            }

                            SequentialAnimation {
                                id: wDiscSquish
                                ParallelAnimation {
                                    NumberAnimation { target: wDisc; property: "sx"; to: 1.18; duration: 80; easing.type: Easing.OutQuad }
                                    NumberAnimation { target: wDisc; property: "sy"; to: 0.82; duration: 80; easing.type: Easing.OutQuad }
                                }
                                ParallelAnimation {
                                    NumberAnimation { target: wDisc; property: "sx"; to: 1.0; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 2.6 }
                                    NumberAnimation { target: wDisc; property: "sy"; to: 1.0; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 2.6 }
                                }
                            }

                            MouseArea {
                                id: wDiscMa
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    wDiscSquish.restart()
                                    wBurst.fire()
                                    WeatherService.refresh()
                                }
                            }
                        }
                    }

                    // Hanging Slant location tab overlapping lower edge of plate
                    Text {
                        id: wPlaceProbe
                        visible: false
                        text: (WeatherService.city || "Local").toUpperCase()
                        font.pixelSize: 10
                        font.weight: Font.Black
                    }
                    Slant {
                        id: wPlaceTab
                        x: 2; y: 74
                        width: Math.min(wPlaceProbe.implicitWidth + 42 + 26 * 0.2, 198)
                        height: 26
                        skew: 0.2
                        cornerRadius: 8
                        color: themeHub.darkInk
                        borderColor: "#FFFFFF"
                        borderWidth: 2
                    }
                    Row {
                        x: wPlaceTab.x + wPlaceTab.lean * 0.5 + 8
                        y: wPlaceTab.y
                        height: wPlaceTab.height
                        spacing: 4
                        Image {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 13; height: 13
                            source: "qrc:/qml/icons/map-point-teal.svg"
                            sourceSize: Qt.size(26, 26)
                            smooth: true
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, wPlaceTab.width - wPlaceTab.lean - 30)
                            elide: Text.ElideRight
                            text: wPlaceProbe.text
                            font.pixelSize: 10
                            font.weight: Font.Black
                            color: "#FFFFFF"
                        }
                    }

                    // View toggle pill key (Hourly <-> 3-Day)
                    SekaiPill {
                        x: wHead.width - 34 - 6 - 34
                        y: 71
                        width: 34
                        height: 31
                        radius: 11
                        color: themeHub.darkInk
                        inkColor: "#FFFFFF"
                        borderWidth: 2
                        shadowShift: 3
                        pressedState: wViewMa.pressed
                        Image {
                            anchors.centerIn: parent
                            width: 16; height: 16
                            source: themeHub.weatherView === "days" ? "qrc:/qml/icons/clock-circle-light.svg" : "qrc:/qml/icons/calendar-light.svg"
                            sourceSize: Qt.size(32, 32)
                            smooth: true
                        }
                        MouseArea {
                            id: wViewMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: themeHub.setWeatherView(themeHub.weatherView === "days" ? "hourly" : "days")
                        }
                    }

                    // Refresh pill key
                    SekaiPill {
                        x: wHead.width - 34
                        y: 71
                        width: 34
                        height: 31
                        radius: 11
                        color: themeHub.darkInk
                        inkColor: "#FFFFFF"
                        borderWidth: 2
                        shadowShift: 3
                        pressedState: wRefreshMa.pressed
                        Image {
                            id: wRefreshSvg
                            anchors.centerIn: parent
                            width: 16; height: 16
                            source: "qrc:/qml/icons/refresh-light.svg"
                            sourceSize: Qt.size(32, 32)
                            smooth: true
                            RotationAnimation on rotation {
                                running: WeatherService.loading
                                from: 0; to: 360; duration: 900; loops: Animation.Infinite
                                onRunningChanged: if (!running) wRefreshSvg.rotation = 0
                            }
                        }
                        MouseArea {
                            id: wRefreshMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: WeatherService.refresh()
                        }
                    }
                }

                // 2. Three Tilted Metric Cards (y: 106, h: 54, spacing: 8)
                Row {
                    id: gaugesRow
                    x: 0; y: 106
                    width: 286
                    height: 54
                    spacing: 8

                    // Humidity Tank (-1.6 deg)
                    Item {
                        width: 76; height: 54
                        Item {
                            anchors.fill: parent
                            transformOrigin: Item.Center
                            rotation: humMa.containsMouse ? 0.0 : -1.6
                            scale: humMa.containsMouse ? 1.05 : 1.0
                            Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2 } }
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }

                            SekaiPill {
                                anchors.fill: parent
                                radius: 13
                                color: "#F3FAFF"
                                inkColor: themeHub.darkInk
                                borderWidth: 2
                                shadowShift: 3
                                showInnerRing: false

                                Rectangle {
                                    id: humFill
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: Math.max(5, Math.round(parent.height * Math.min(1.0, Math.max(0.08, WeatherService.humidity / 100.0))))
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "#5C4ECDC4" }
                                        GradientStop { position: 1.0; color: "#1F4ECDC4" }
                                    }
                                    Behavior on height { NumberAnimation { duration: 300 } }
                                    Rectangle {
                                        visible: humFill.height > 8
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                        anchors.leftMargin: 4; anchors.rightMargin: 4
                                        height: 2; radius: 1
                                        color: "#D84ECDC4"
                                    }
                                }
                                Text { x: 6; y: 3; text: "HUMIDITY"; font.pixelSize: 8; font.weight: Font.Black; color: "#991A1B2E" }
                                Text { x: 6; y: 15; text: WeatherService.humidity + "%"; font.pixelSize: 18; font.weight: Font.Black; color: themeHub.darkInk }
                            }
                        }
                        MouseArea { id: humMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    }

                    // Wind Compass Dial (+1.2 deg)
                    Item {
                        width: 120; height: 54
                        Item {
                            anchors.fill: parent
                            transformOrigin: Item.Center
                            rotation: windMa.containsMouse ? 0.0 : 1.2
                            scale: windMa.containsMouse ? 1.05 : 1.0
                            Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2 } }
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }

                            SekaiPill {
                                anchors.fill: parent
                                radius: 13
                                color: "#F8F6FF"
                                inkColor: themeHub.darkInk
                                borderWidth: 2
                                shadowShift: 3
                                showInnerRing: false

                                Text {
                                    x: 6; y: 3
                                    width: parent.width - 10
                                    elide: Text.ElideRight
                                    text: "WIND" + (WeatherService.windDirection ? (" · " + WeatherService.windDirection) : "")
                                    font.pixelSize: 8; font.weight: Font.Black; color: "#991A1B2E"
                                }
                                Row {
                                    x: 6; y: 15; spacing: 2
                                    Text { id: windNumTxt; text: String(WeatherService.windSpeed); font.pixelSize: 18; font.weight: Font.Black; color: themeHub.darkInk }
                                    Text { anchors.baseline: windNumTxt.baseline; text: "km/h"; font.pixelSize: 8; font.weight: Font.Bold; color: "#881A1B2E" }
                                }
                                Item {
                                    x: parent.width - width - 6
                                    y: 9
                                    width: 28; height: 28
                                    Rectangle {
                                        anchors.fill: parent; radius: 14
                                        color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 2
                                    }
                                    DiamondDot {
                                        x: (parent.width - width) * 0.5; y: -3
                                        size: 6; color: themeHub.accentA; borderColor: themeHub.darkInk; borderWidth: 1
                                    }
                                    Item {
                                        anchors.centerIn: parent
                                        width: 14; height: 14
                                        rotation: ((WeatherService.windDeg || 0) + 180) % 360
                                        Behavior on rotation { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
                                        Canvas {
                                            anchors.fill: parent
                                            onPaint: {
                                                const ctx = getContext("2d")
                                                ctx.clearRect(0, 0, width, height)
                                                ctx.fillStyle = "#1A1B2E"
                                                ctx.beginPath()
                                                ctx.moveTo(7, 1)
                                                ctx.lineTo(12, 12)
                                                ctx.lineTo(7, 9)
                                                ctx.lineTo(2, 12)
                                                ctx.closePath()
                                                ctx.fill()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        MouseArea { id: windMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    }

                    // UV 5-Diamond Meter (-1.2 deg)
                    Item {
                        width: 74; height: 54
                        Item {
                            anchors.fill: parent
                            transformOrigin: Item.Center
                            rotation: uvMa.containsMouse ? 0.0 : -1.2
                            scale: uvMa.containsMouse ? 1.05 : 1.0
                            Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2 } }
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }

                            SekaiPill {
                                anchors.fill: parent
                                radius: 13
                                color: "#FFF9F2"
                                inkColor: themeHub.darkInk
                                borderWidth: 2
                                shadowShift: 3
                                showInnerRing: false

                                Text { x: 6; y: 3; text: "UV INDEX"; font.pixelSize: 8; font.weight: Font.Black; color: "#991A1B2E" }
                                Text { x: 6; y: 12; text: String(WeatherService.uvIndex); font.pixelSize: 18; font.weight: Font.Black; color: themeHub.darkInk }
                                Row {
                                    x: 7; y: 34; spacing: 4
                                    Repeater {
                                        model: 5
                                        DiamondDot {
                                            required property int index
                                            readonly property int litCount: Math.min(5, Math.max(0, Math.ceil(WeatherService.uvIndex / 2.2)))
                                            size: 7
                                            color: index < litCount ? widgetsRoot.uvColor(WeatherService.uvIndex) : "#E4E7F0"
                                            borderColor: themeHub.darkInk
                                            borderWidth: 1
                                        }
                                    }
                                }
                            }
                        }
                        MouseArea { id: uvMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    }
                }

                // 3. Forecast Section (y: 166, height: 72 -> ends cleanly at 238 with ZERO clip!)
                Item {
                    x: 0; y: 166
                    width: 286
                    height: 72

                    // Hourly View (double-stroked cubic bezier + diamond nodes)
                    Rectangle {
                        anchors.fill: parent
                        visible: themeHub.weatherView !== "days"
                        radius: 13
                        color: "#FFFFFF"
                        border.width: 2
                        border.color: themeHub.darkInk
                        clip: true

                        Text {
                            anchors.centerIn: parent
                            visible: weatherWin.hourList.length === 0
                            text: WeatherService.loading ? "Loading forecast..." : "Tap icon to refresh"
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            color: "#881A1B2E"
                        }

                        Canvas {
                            id: hourlyCanvas
                            anchors.fill: parent
                            visible: weatherWin.hourList.length > 0
                            property var pointsData: weatherWin.hourList
                            property int hoverIdx: weatherWin.hoveredHour
                            property color lineColor: themeHub.accentA
                            property color dotColor: themeHub.accentB
                            property string tempUnit: themeHub.weatherUnit
                            onPointsDataChanged: requestPaint()
                            onHoverIdxChanged: requestPaint()
                            onLineColorChanged: requestPaint()
                            onDotColorChanged: requestPaint()
                            onTempUnitChanged: requestPaint()
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                const list = pointsData || []
                                const n = Math.min(7, list.length)
                                if (n < 2)
                                    return
                                let minT = 999, maxT = -999
                                for (let i = 0; i < n; i++) {
                                    const t = Number(list[i].temp)
                                    if (t < minT) minT = t
                                    if (t > maxT) maxT = t
                                }
                                const span = Math.max(2, maxT - minT)
                                const padX = 20
                                const topY = 23
                                const botY = height - 21
                                const pts = []
                                for (let i = 0; i < n; i++) {
                                    const x = padX + (width - padX * 2) * (i / (n - 1))
                                    const norm = (Number(list[i].temp) - minT) / span
                                    const y = botY - norm * (botY - topY)
                                    pts.push({ x: x, y: y, item: list[i] })
                                }

                                function traceCurve() {
                                    ctx.beginPath()
                                    ctx.moveTo(pts[0].x, pts[0].y)
                                    for (let i = 0; i < n - 1; i++) {
                                        const xc = (pts[i].x + pts[i + 1].x) * 0.5
                                        ctx.bezierCurveTo(xc, pts[i].y, xc, pts[i + 1].y, pts[i + 1].x, pts[i + 1].y)
                                    }
                                }

                                // Double-stroked SekaiPop melody curve (navy outline + bright core)
                                ctx.lineJoin = "round"
                                ctx.lineCap = "round"
                                traceCurve()
                                ctx.strokeStyle = "#1A1B2E"
                                ctx.lineWidth = 5.5
                                ctx.stroke()
                                traceCurve()
                                ctx.strokeStyle = dotColor
                                ctx.lineWidth = 2.4
                                ctx.stroke()

                                // Diamond nodes + temp & time labels
                                ctx.textAlign = "center"
                                ctx.font = 'bold 9px "Segoe UI"'
                                for (let i = 0; i < n; i++) {
                                    const isHov = (i === hoverIdx)
                                    const dr = isHov ? 5.2 : (i === 0 ? 4.4 : 3.6)
                                    ctx.save()
                                    ctx.translate(pts[i].x, pts[i].y)
                                    ctx.rotate(Math.PI / 4)
                                    ctx.fillStyle = isHov ? lineColor : (i === 0 ? dotColor : "#FFFFFF")
                                    ctx.fillRect(-dr, -dr, dr * 2, dr * 2)
                                    ctx.lineWidth = 1.8
                                    ctx.strokeStyle = "#1A1B2E"
                                    ctx.strokeRect(-dr, -dr, dr * 2, dr * 2)
                                    ctx.restore()

                                    ctx.fillStyle = "#1A1B2E"
                                    ctx.fillText(themeHub.formatTemp(pts[i].item.temp) + "°", pts[i].x, pts[i].y - 8)
                                    ctx.fillStyle = "#881A1B2E"
                                    ctx.fillText(pts[i].item.label || "", pts[i].x, height - 4)
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onPositionChanged: mouse => {
                                const n = Math.min(7, weatherWin.hourList.length)
                                if (n <= 0) { weatherWin.hoveredHour = -1; return }
                                const idx = Math.max(0, Math.min(n - 1, Math.round((mouse.x - 18) / Math.max(1, width - 36) * (n - 1))))
                                weatherWin.hoveredHour = idx
                            }
                            onExited: weatherWin.hoveredHour = -1
                        }
                    }

                    // 3-Day View (3 SEPARATED bordered pill rows, 22px each + 3px spacing = 72px exact)
                    Column {
                        anchors.fill: parent
                        spacing: 3
                        visible: themeHub.weatherView === "days"

                        Repeater {
                            model: Math.min(3, weatherWin.dayList.length)
                            Item {
                                required property int index
                                readonly property var dayObj: weatherWin.dayList[index]
                                readonly property bool rowHov: weatherWin.hoveredDay === index
                                readonly property real dLo: Number(dayObj.low)
                                readonly property real dHi: Number(dayObj.high)
                                readonly property real spanDen: Math.max(1, weatherWin.daySpan.hi - weatherWin.daySpan.lo)
                                width: 286
                                height: 22

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 11
                                    color: rowHov ? "#EEF6FF" : "#F8FAFF"
                                    border.width: 2
                                    border.color: rowHov ? themeHub.accentB : themeHub.darkInk
                                    clip: true
                                    Behavior on border.color { ColorAnimation { duration: 120 } }

                                    // Rain probability fill from left
                                    Rectangle {
                                        x: 2; y: 2
                                        height: parent.height - 4
                                        width: Math.max(0, (parent.width - 4) * Math.min(1.0, Math.max(0.0, (dayObj.rain || 0) / 100.0)))
                                        radius: 9
                                        color: Qt.rgba(themeHub.accentB.r, themeHub.accentB.g, themeHub.accentB.b, 0.20)
                                    }
                                }

                                // Slant day badge (Today uses accent gradient)
                                Slant {
                                    x: 5; y: 3
                                    width: 62; height: 16
                                    skew: 0.2
                                    cornerRadius: 5
                                    useGradient: index === 0
                                    gradientTop: themeHub.accentA
                                    gradientBottom: themeHub.accentB
                                    color: themeHub.darkInk
                                    borderColor: themeHub.darkInk
                                    borderWidth: 2
                                }
                                Text {
                                    x: 5; y: 3
                                    width: 62; height: 16
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                    text: (dayObj.label || "").toUpperCase()
                                    font.pixelSize: 9
                                    font.weight: Font.Black
                                    color: index === 0 ? themeHub.darkInk : "#FFFFFF"
                                }

                                WeatherGlyph {
                                    x: 69
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 17; height: 17
                                    code: dayObj.code || 0
                                    isDay: true
                                    inkColor: themeHub.darkInk
                                    accentColor: "#FFB703"
                                }

                                Row {
                                    x: 90
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 3
                                    Text { text: themeHub.formatTemp(dHi) + "°"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                                    Text { anchors.bottom: parent.bottom; anchors.bottomMargin: 1; text: themeHub.formatTemp(dLo) + "°"; font.pixelSize: 9; font.weight: Font.Bold; color: "#881A1B2E" }
                                }

                                // Shared-span [lo, hi] temperature range bar across 3 days
                                Rectangle {
                                    id: dayTrack
                                    x: 144
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 72
                                    height: 5
                                    radius: 3
                                    color: "#221A1B2E"

                                    Rectangle {
                                        readonly property real barW: Math.max(14, ((dHi - dLo) / spanDen) * dayTrack.width)
                                        x: Math.max(0, Math.min(dayTrack.width - barW, ((dLo - weatherWin.daySpan.lo) / spanDen) * dayTrack.width))
                                        width: barW
                                        height: parent.height
                                        radius: 3
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: themeHub.accentA }
                                            GradientStop { position: 1.0; color: themeHub.accentB }
                                        }
                                    }
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 11; height: 11
                                        source: "qrc:/qml/icons/waterdrop-dark.svg"
                                        sourceSize: Qt.size(22, 22)
                                        smooth: true
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (dayObj.rain || 0) + "%"
                                        font.pixelSize: 10
                                        font.weight: Font.Black
                                        color: themeHub.darkInk
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: weatherWin.hoveredDay = index
                                    onExited: if (weatherWin.hoveredDay === index) weatherWin.hoveredDay = -1
                                }
                            }
                        }
                    }
                }
            }

            // Close badge on widget hover (top-right corner)
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 4
                width: 20; height: 20; radius: 10
                color: "#FFFFFF"
                border.color: themeHub.darkInk
                border.width: 2
                z: 40
                opacity: weatherWin.hovered ? 1.0 : 0.0
                visible: opacity > 0.02
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWidgetVisible("weather", false) }
            }

            // --- MINIMAL BODY (SekaiPlate + 4 Quick Slots) ---
            Item {
                visible: weatherWin.isMinimal
                anchors.fill: parent
                anchors.margins: 8

                SekaiPlate {
                    id: mPlate
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 114
                    radius: 17
                    topColor: themeHub.accentA
                    bottomColor: themeHub.accentB
                    inkColor: themeHub.darkInk
                    borderWidth: 3
                    shadowShift: 4

                    Text {
                        x: 10; y: 4
                        width: 176
                        elide: Text.ElideRight
                        text: (weatherWin.activeCond || (WeatherService.loading ? "SYNCING..." : "CLEAR")).toUpperCase()
                        font.pixelSize: 10; font.weight: Font.Black
                        color: Qt.rgba(themeHub.darkInk.r, themeHub.darkInk.g, themeHub.darkInk.b, 0.85)
                    }
                    StickerText {
                        id: mTempNum
                        x: 2; y: 18
                        text: String(themeHub.formatTemp(weatherWin.activeTemp))
                        fontSize: 42
                        fillColor: Qt.darker(themeHub.darkInk, 1.8)
                        inkColor: themeHub.darkInk
                        haloColor: "#FFFFFF"
                        inkThickness: 2.2
                        haloThickness: 1.6
                        ringInside: true
                        shadowShift: 3
                        popOnChange: true
                    }
                    StickerText {
                        x: mTempNum.x + mTempNum.width - 5
                        y: 25
                        text: "°" + themeHub.weatherUnit
                        fontSize: 18
                        fillColor: Qt.darker(themeHub.darkInk, 1.8)
                        inkColor: themeHub.darkInk
                        haloColor: "#FFFFFF"
                        inkThickness: 2.0
                        haloThickness: 1.5
                        ringInside: true
                        shadowShift: 2
                    }
                    SekaiPill {
                        x: mPlate.width - width - 14
                        y: 8
                        width: 66; height: 68; radius: 33
                        color: themeHub.darkInk; inkColor: "#FFFFFF"; borderWidth: 2; shadowShift: 3; rotation: 6
                        WeatherGlyph { anchors.centerIn: parent; width: 40; height: 40; code: weatherWin.activeCode; isDay: weatherWin.activeIsDay; inkColor: "#FFFFFF"; accentColor: "#FFD166" }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: WeatherService.refresh() }
                    }
                }

                Row {
                    anchors.top: mPlate.bottom
                    anchors.topMargin: 6
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 6

                    Repeater {
                        model: Math.min(4, weatherWin.hourList.length)
                        SekaiPill {
                            required property int index
                            readonly property var hObj: weatherWin.hourList[index]
                            width: Math.floor((parent.width - 18) / 4)
                            height: parent.height
                            radius: 12
                            color: index === 0 ? "#E6FFFA" : "#F6F8FC"
                            inkColor: themeHub.darkInk
                            borderWidth: 2
                            shadowShift: 2

                            Column {
                                anchors.centerIn: parent
                                spacing: 2
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: index === 0 ? "NOW" : (hObj.label || ""); font.pixelSize: 9; font.weight: Font.Black; color: index === 0 ? themeHub.darkInk : "#881A1B2E" }
                                WeatherGlyph { anchors.horizontalCenter: parent.horizontalCenter; width: 22; height: 22; code: hObj.code || 0; isDay: !!hObj.isDay; inkColor: themeHub.darkInk; accentColor: "#FFB703" }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: themeHub.formatTemp(hObj.temp) + "°"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 3. PROFILE CARD WIDGET (Custom Avatar/Banner, StatKeys, TODAY Lane)
    // =========================================================================
    WidgetShell {
        id: profileWin
        widgetKey: "profile"
        property bool editing: false
        allowFocus: editing
        cardWidth: 320
        cardHeight: 276
        targetX: themeHub.wProfileX
        targetY: themeHub.wProfileY
        visible: themeHub.wProfileVisible && !widgetsRoot.fullscreenActive

        property bool hovered: false
        readonly property int nowHour: widgetsRoot.nowDate.getHours()
        readonly property int nowMin: widgetsRoot.nowDate.getMinutes()
        readonly property int dayPct: Math.round(((nowHour * 60 + nowMin) / 1440.0) * 100)
        readonly property string greetingText: nowHour < 5 ? "LATE NIGHT"
                                             : (nowHour < 12 ? "GOOD MORNING"
                                             : (nowHour < 18 ? "GOOD AFTERNOON" : "GOOD EVENING"))

        DragSurface {
            shellWin: profileWin
            widgetKey: "profile"
            hubRef: widgetsRoot.themeHub
        }

        HoverHandler {
            onHoveredChanged: profileWin.hovered = hovered
        }

        SekaiPill {
            anchors.fill: parent
            radius: 22
            color: "#FFFDF9"
            inkColor: themeHub.darkInk
            shadowShift: 5

            // Banner Area (Image or Gradient + SparkDiamonds)
            Item {
                id: pBannerBox
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                height: 88

                SekaiPill {
                    anchors.fill: parent
                    radius: 16
                    useGradient: true
                    gradientTop: themeHub.accentA
                    gradientBottom: themeHub.accentB
                    inkColor: themeHub.darkInk
                    borderWidth: 3
                    shadowShift: 3

                    Image {
                        anchors.fill: parent
                        source: themeHub.profileBannerUrl
                        fillMode: Image.PreserveAspectCrop
                        visible: themeHub.profileBannerUrl.length > 0 && status === Image.Ready
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "#331A1B2E"
                        visible: themeHub.profileBannerUrl.length > 0
                    }

                    DotField {
                        anchors.fill: parent
                        color: "#FFFFFF"
                        dotAlpha: 0.16
                        step: 10
                    }

                    // SparkDiamonds
                    Repeater {
                        model: [
                            { x: 0.18, y: 0.25, s: 7 }, { x: 0.34, y: 0.65, s: 6 },
                            { x: 0.50, y: 0.22, s: 8 }, { x: 0.68, y: 0.56, s: 7 },
                            { x: 0.82, y: 0.28, s: 9 }, { x: 0.90, y: 0.72, s: 6 }
                        ]
                        DiamondDot {
                            required property var modelData
                            x: Math.round(parent.width * modelData.x)
                            y: Math.round(parent.height * modelData.y)
                            size: modelData.s
                            color: "#FFFFFF"
                            borderColor: themeHub.darkInk
                            borderWidth: 1
                        }
                    }

                    // Tilted GreetChip
                    SekaiPill {
                        x: 10
                        y: 10
                        width: greetLbl.implicitWidth + 18
                        height: 24
                        radius: 8
                        color: themeHub.darkInk
                        inkColor: "#FFFFFF"
                        borderWidth: 2
                        shadowShift: 2
                        showInnerRing: false
                        rotation: -2.5
                        Text {
                            id: greetLbl
                            anchors.centerIn: parent
                            text: profileWin.greetingText
                            font.pixelSize: 9
                            font.weight: Font.Black
                            color: "#FFFFFF"
                        }
                    }

                    // Top-right edit & close controls
                    Row {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 8
                        spacing: 4
                        opacity: (profileWin.hovered || profileWin.editing) ? 1.0 : 0.0
                        visible: opacity > 0.02
                        Behavior on opacity { NumberAnimation { duration: 120 } }

                        Rectangle {
                            width: 22; height: 22; radius: 11
                            color: profileWin.editing ? themeHub.accentA : "#FFFFFF"
                            border.color: themeHub.darkInk; border.width: 2
                            Text { anchors.centerIn: parent; text: profileWin.editing ? "✓" : "✎"; font.pixelSize: 11; font.weight: Font.Black; color: profileWin.editing ? "#FFFFFF" : themeHub.darkInk }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (profileWin.editing)
                                        themeHub.saveProfile(nameEdit.text.trim() || themeHub.profileName, statusEdit.text.trim())
                                    profileWin.editing = !profileWin.editing
                                }
                            }
                        }
                        Rectangle {
                            width: 22; height: 22; radius: 11
                            color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 2
                            Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWidgetVisible("profile", false) }
                        }
                    }
                }
            }

            // Overlapping Tilted Circular Avatar
            SekaiPill {
                id: avatarBadge
                x: 18
                y: 60
                width: 64
                height: 64
                radius: 32
                color: themeHub.accentB
                inkColor: themeHub.darkInk
                borderWidth: 3
                shadowShift: 3
                rotation: avMa.containsMouse ? 4 : -4
                pressedState: avMa.pressed
                Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

                Image {
                    id: avImg
                    anchors.fill: parent
                    source: themeHub.profileAvatarUrl
                    fillMode: Image.PreserveAspectCrop
                    visible: themeHub.profileAvatarUrl.length > 0 && status === Image.Ready
                }

                Text {
                    anchors.centerIn: parent
                    visible: !avImg.visible
                    text: (themeHub.profileName || "Y").charAt(0).toUpperCase()
                    font.pixelSize: 26
                    font.weight: Font.Black
                    color: "#FFFFFF"
                }

                Burst {
                    id: avBurst
                    anchors.centerIn: parent
                    colorA: themeHub.accentA
                    colorB: themeHub.accentB
                    inkColor: themeHub.darkInk
                }

                MouseArea {
                    id: avMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: avBurst.fire()
                    onDoubleClicked: {
                        const url = SystemControl.pickImageFile("Choose Profile Avatar")
                        if (url && url.length > 0)
                            themeHub.setProfileAvatar(url)
                    }
                }
            }

            // Name & Machine / Inline Editor
            Item {
                anchors.left: avatarBadge.right
                anchors.right: parent.right
                anchors.leftMargin: 10
                anchors.rightMargin: 12
                y: 94
                height: 44

                Column {
                    anchors.fill: parent
                    visible: !profileWin.editing
                    spacing: 1
                    Row {
                        spacing: 5
                        Text {
                            text: themeHub.profileName
                            font.pixelSize: 15
                            font.weight: Font.Black
                            color: themeHub.darkInk
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "@" + (WindowTracker.machineName || "sekaidesk").toLowerCase()
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            color: "#881A1B2E"
                        }
                    }
                    Text {
                        text: themeHub.profileStatus
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: "#AA1A1B2E"
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                Column {
                    anchors.fill: parent
                    visible: profileWin.editing
                    spacing: 3
                    Row {
                        width: parent.width; height: 20; spacing: 4
                        Rectangle {
                            width: Math.max(70, parent.width - 102); height: 20; radius: 6
                            color: "#F3F5FA"; border.color: themeHub.darkInk; border.width: 1
                            TextInput {
                                id: nameEdit
                                anchors.fill: parent; anchors.margins: 3
                                verticalAlignment: TextInput.AlignVCenter
                                text: themeHub.profileName
                                font.pixelSize: 10; font.weight: Font.Bold; color: themeHub.darkInk
                                onAccepted: { themeHub.saveProfile(text.trim() || themeHub.profileName, statusEdit.text.trim()); profileWin.editing = false }
                            }
                        }
                        Rectangle {
                            width: 48; height: 20; radius: 6; color: themeHub.accentA; border.color: themeHub.darkInk; border.width: 1
                            Text { anchors.centerIn: parent; text: "Avatar"; font.pixelSize: 9; font.weight: Font.Black; color: "#FFFFFF" }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { const u = SystemControl.pickImageFile("Choose Profile Avatar"); if (u) themeHub.setProfileAvatar(u) } }
                        }
                        Rectangle {
                            width: 46; height: 20; radius: 6; color: themeHub.accentB; border.color: themeHub.darkInk; border.width: 1
                            Text { anchors.centerIn: parent; text: "Banner"; font.pixelSize: 9; font.weight: Font.Black; color: "#FFFFFF" }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { const u = SystemControl.pickImageFile("Choose Profile Banner"); if (u) themeHub.setProfileBanner(u) } }
                        }
                    }
                    Rectangle {
                        width: parent.width; height: 20; radius: 6
                        color: "#F3F5FA"; border.color: themeHub.darkInk; border.width: 1
                        TextInput {
                            id: statusEdit
                            anchors.fill: parent; anchors.margins: 3
                            verticalAlignment: TextInput.AlignVCenter
                            text: themeHub.profileStatus
                            font.pixelSize: 10; color: themeHub.darkInk
                            onAccepted: { themeHub.saveProfile(nameEdit.text.trim() || themeHub.profileName, text.trim()); profileWin.editing = false }
                        }
                    }
                }
            }

            // 3 Shallow-V StatKey Keycaps (UPTIME / CPU / RAM)
            Row {
                id: statRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 12
                y: 142
                height: 50
                spacing: 8

                Repeater {
                    model: [
                        { lbl: "UPTIME", val: WindowTracker.uptimeText || "0m", rot: -1.5, c: "#FFF5FA" },
                        { lbl: "CPU",    val: WindowTracker.cpuUsage + "%",     rot: 0.0,  c: "#F3FBFF" },
                        { lbl: "RAM",    val: WindowTracker.ramUsage + "%",     rot: 1.5,  c: "#F6F3FF" }
                    ]
                    SekaiPill {
                        required property var modelData
                        width: Math.floor((statRow.width - 16) / 3)
                        height: 46
                        radius: 12
                        color: modelData.c
                        inkColor: themeHub.darkInk
                        borderWidth: 2
                        shadowShift: 3
                        rotation: modelData.rot
                        Column {
                            anchors.centerIn: parent
                            spacing: 0
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.lbl; font.pixelSize: 8; font.weight: Font.Black; color: "#881A1B2E" }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.val; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.darkInk }
                        }
                    }
                }
            }

            // TODAY 24h Segmented Progress Lane
            Item {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 12
                y: 198
                height: 28

                Row {
                    anchors.fill: parent
                    spacing: 8
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "TODAY"
                        font.pixelSize: 9
                        font.weight: Font.Black
                        color: themeHub.darkInk
                    }
                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 96
                        height: 14
                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            color: "#EEF1F8"
                            border.color: themeHub.darkInk
                            border.width: 2
                            Rectangle {
                                anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.margins: 2
                                width: Math.max(6, Math.round((parent.width - 4) * (profileWin.dayPct / 100.0)))
                                radius: 5
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: themeHub.accentB }
                                    GradientStop { position: 1.0; color: themeHub.accentA }
                                }
                            }
                            Repeater {
                                model: [0.25, 0.5, 0.75]
                                Rectangle {
                                    required property real modelData
                                    x: Math.round(parent.width * modelData) - 1
                                    y: 2; width: 2; height: 10; color: "#551A1B2E"
                                }
                            }
                        }
                        DiamondDot {
                            anchors.verticalCenter: parent.verticalCenter
                            x: Math.max(0, Math.min(parent.width - width, Math.round(parent.width * (profileWin.dayPct / 100.0) - width / 2)))
                            size: 14
                            color: "#FFFFFF"
                            borderColor: themeHub.darkInk
                            borderWidth: 2
                        }
                    }
                    SekaiPill {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40; height: 22; radius: 8
                        color: themeHub.darkInk; inkColor: "#FFFFFF"; borderWidth: 1; shadowShift: 2; showInnerRing: false; rotation: 3
                        Text { anchors.centerIn: parent; text: profileWin.dayPct + "%"; font.pixelSize: 9; font.weight: Font.Black; color: "#FFFFFF" }
                    }
                }
            }

            // Bottom Quick Utility Pills (Home / Shot / Themes / Lock)
            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                anchors.bottomMargin: 10
                spacing: 6
                Repeater {
                    model: [
                        { id: "home",   lbl: "Home" },
                        { id: "shot",   lbl: "Shot" },
                        { id: "themes", lbl: "Themes" },
                        { id: "lock",   lbl: "Lock" }
                    ]
                    SekaiPill {
                        required property var modelData
                        width: Math.floor((parent.width - 18) / 4)
                        height: 26
                        radius: 9
                        color: pBtnMa.containsMouse ? themeHub.hoverTint : "#F4F6FB"
                        inkColor: themeHub.darkInk
                        borderWidth: 2
                        shadowShift: 2
                        showInnerRing: false
                        pressedState: pBtnMa.pressed
                        Text {
                            anchors.centerIn: parent
                            text: modelData.lbl
                            font.pixelSize: 10
                            font.weight: Font.Black
                            color: themeHub.darkInk
                        }
                        MouseArea {
                            id: pBtnMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (modelData.id === "home") WindowTracker.openSpecialFolder("home")
                                else if (modelData.id === "shot") WindowTracker.takeScreenshot()
                                else if (modelData.id === "themes") themeHub.settingsOpen = true
                                else if (modelData.id === "lock") WindowTracker.lockWorkstation()
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 4. CALENDAR WIDGET (SekaiPop Month Grid + Colored Attribute Diamonds + Events)
    // =========================================================================
    WidgetShell {
        id: calendarWin
        widgetKey: "calendar"
        allowFocus: true
        cardWidth: 346
        cardHeight: 520
        targetX: themeHub.wCalendarX
        targetY: themeHub.wCalendarY
        visible: themeHub.wCalendarVisible && !widgetsRoot.fullscreenActive

        property int viewYear: widgetsRoot.nowDate.getFullYear()
        property int viewMonth: widgetsRoot.nowDate.getMonth()
        property string selectedDay: ""
        property bool showEditor: false
        property string editingId: ""
        property string draftAttr: "cute"
        property bool draftDeadline: false
        property bool hovered: false

        readonly property string todayStr: widgetsRoot.isoDateStr(widgetsRoot.nowDate)
        readonly property string monthLabel: ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"][viewMonth] + " " + viewYear
        readonly property int isoWeek: widgetsRoot.isoWeekNumber(widgetsRoot.nowDate)

        readonly property var dayCells: {
            const first = new Date(viewYear, viewMonth, 1)
            const lead = (first.getDay() + 6) % 7
            const start = new Date(viewYear, viewMonth, 1 - lead)
            const out = []
            for (let i = 0; i < 42; i++) {
                const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i)
                out.push({
                    dateStr: widgetsRoot.isoDateStr(d),
                    dayNum: d.getDate(),
                    inMonth: d.getMonth() === viewMonth
                })
            }
            return out
        }

        function eventsForDay(dateStr) {
            const list = themeHub.calendarEvents || []
            const out = []
            for (let i = 0; i < list.length; i++) {
                if (list[i].date === dateStr)
                    out.push(list[i])
            }
            return out
        }

        readonly property var visibleEvents: {
            const list = themeHub.calendarEvents || []
            const out = []
            for (let i = 0; i < list.length; i++) {
                const ev = list[i]
                if (selectedDay.length > 0) {
                    if (ev.date === selectedDay) out.push(ev)
                } else {
                    if (!ev.done || ev.date >= todayStr) out.push(ev)
                }
            }
            out.sort(function(a, b) {
                if (!!a.done !== !!b.done) return a.done ? 1 : -1
                const ka = (a.date || "") + " " + (a.time || "99:99")
                const kb = (b.date || "") + " " + (b.time || "99:99")
                return ka < kb ? -1 : (ka > kb ? 1 : 0)
            })
            return out
        }

        readonly property int upcomingCount: {
            const list = themeHub.calendarEvents || []
            let c = 0
            for (let i = 0; i < list.length; i++) if (!list[i].done) c++
            return c
        }

        function stepMonth(delta) {
            let m = viewMonth + delta
            let y = viewYear
            while (m < 0) { m += 12; y-- }
            while (m > 11) { m -= 12; y++ }
            viewMonth = m
            viewYear = y
        }

        function openNewEvent(dateOverride) {
            editingId = ""
            evTitleIn.text = ""
            evDateIn.text = (dateOverride && dateOverride.length > 0) ? dateOverride : (selectedDay.length > 0 ? selectedDay : todayStr)
            evTimeIn.text = "18:00"
            draftAttr = "cute"
            draftDeadline = false
            showEditor = true
        }

        function openEditEvent(ev) {
            editingId = ev.id || ""
            evTitleIn.text = ev.title || ""
            evDateIn.text = ev.date || todayStr
            evTimeIn.text = ev.time || ""
            draftAttr = ev.attr || "cute"
            draftDeadline = !!ev.isDeadline
            showEditor = true
        }

        DragSurface {
            shellWin: calendarWin
            widgetKey: "calendar"
            hubRef: widgetsRoot.themeHub
        }

        HoverHandler {
            onHoveredChanged: calendarWin.hovered = hovered
        }

        SekaiPill {
            anchors.fill: parent
            radius: 22
            color: "#FFFDF9"
            inkColor: themeHub.darkInk
            shadowShift: 5

            // SekaiPlate Header
            SekaiPlate {
                id: calPlate
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                height: 86
                radius: 16
                topColor: themeHub.accentB
                bottomColor: themeHub.accentA
                inkColor: themeHub.darkInk
                borderWidth: 3
                shadowShift: 3

                WheelHandler {
                    onWheel: event => calendarWin.stepMonth(event.angleDelta.y > 0 ? -1 : 1)
                }

                Column {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: 10
                    spacing: 2
                    StickerText {
                        text: calendarWin.monthLabel
                        fontSize: 22
                        fillColor: "#FFFFFF"
                        inkColor: themeHub.darkInk
                        inkThickness: 2
                        haloThickness: 1
                        shadowShift: 2
                    }
                    Row {
                        spacing: 6
                        Text {
                            text: "WEEK " + calendarWin.isoWeek + (calendarWin.selectedDay ? "  •  " + calendarWin.selectedDay : "")
                            font.pixelSize: 10
                            font.weight: Font.Black
                            color: "#EEFFFFFF"
                        }
                    }
                }

                // Hanging Slant Tally Tab
                Item {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 10
                    anchors.bottomMargin: 5
                    width: calTallyTxt.implicitWidth + 20
                    height: 18
                    Slant { anchors.fill: parent; color: themeHub.darkInk; skew: 0.25 }
                    Text {
                        id: calTallyTxt
                        anchors.centerIn: parent
                        text: calendarWin.upcomingCount + " OPEN"
                        font.pixelSize: 9
                        font.weight: Font.Black
                        color: "#FFFFFF"
                    }
                }

                // Nav & Action buttons + Today tilted disc
                Row {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    spacing: 4

                    Repeater {
                        model: [
                            { act: "prev", lbl: "‹" },
                            { act: "next", lbl: "›" },
                            { act: "add",  lbl: "+" },
                            { act: "close", lbl: "×" }
                        ]
                        Rectangle {
                            required property var modelData
                            width: 22; height: 22; radius: 11
                            color: modelData.act === "add" ? themeHub.accentA : "#FFFFFF"
                            border.color: themeHub.darkInk; border.width: 2
                            Text {
                                anchors.centerIn: parent
                                text: modelData.lbl
                                font.pixelSize: 12; font.weight: Font.Black
                                color: modelData.act === "add" ? "#FFFFFF" : themeHub.darkInk
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.act === "prev") calendarWin.stepMonth(-1)
                                    else if (modelData.act === "next") calendarWin.stepMonth(1)
                                    else if (modelData.act === "add") {
                                        if (calendarWin.showEditor) calendarWin.showEditor = false
                                        else calendarWin.openNewEvent("")
                                    }
                                    else if (modelData.act === "close") themeHub.setWidgetVisible("calendar", false)
                                }
                            }
                        }
                    }
                }

                // Clickable tilted Today Disc (jumps back to current month/day)
                SekaiPill {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: 10
                    anchors.bottomMargin: 6
                    width: 42; height: 42; radius: 21
                    color: themeHub.darkInk; inkColor: "#FFFFFF"; borderWidth: 2; shadowShift: 2; rotation: 6
                    pressedState: calTodayMa.pressed
                    Column {
                        anchors.centerIn: parent
                        spacing: -2
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "TODAY"; font.pixelSize: 7; font.weight: Font.Black; color: "#BBFFFFFF" }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "" + widgetsRoot.nowDate.getDate(); font.pixelSize: 14; font.weight: Font.Black; color: "#FFFFFF" }
                    }
                    Burst { id: calBurst; anchors.centerIn: parent; colorA: themeHub.accentA; colorB: themeHub.accentB; inkColor: themeHub.darkInk }
                    MouseArea {
                        id: calTodayMa
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            calBurst.fire()
                            calendarWin.viewYear = widgetsRoot.nowDate.getFullYear()
                            calendarWin.viewMonth = widgetsRoot.nowDate.getMonth()
                            calendarWin.selectedDay = ""
                        }
                    }
                }
            }

            // Weekday Header Row
            Row {
                id: calWeekdayRow
                anchors.top: calPlate.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 10
                anchors.topMargin: 6
                spacing: 4
                Repeater {
                    model: ["MON","TUE","WED","THU","FRI","SAT","SUN"]
                    Text {
                        required property string modelData
                        width: Math.floor((calWeekdayRow.width - 24) / 7)
                        horizontalAlignment: Text.AlignHCenter
                        text: modelData
                        font.pixelSize: 9
                        font.weight: Font.Black
                        color: "#881A1B2E"
                    }
                }
            }

            // 6x7 Month Keycap Grid
            Grid {
                id: calGrid
                anchors.top: calWeekdayRow.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 10
                anchors.topMargin: 4
                columns: 7
                spacing: 4

                WheelHandler {
                    onWheel: event => calendarWin.stepMonth(event.angleDelta.y > 0 ? -1 : 1)
                }

                Repeater {
                    model: calendarWin.dayCells
                    Item {
                        required property var modelData
                        readonly property var dayEvents: calendarWin.eventsForDay(modelData.dateStr)
                        readonly property bool isToday: modelData.dateStr === calendarWin.todayStr
                        readonly property bool isSel: modelData.dateStr === calendarWin.selectedDay
                        readonly property bool hasDeadline: {
                            for (let k = 0; k < dayEvents.length; k++)
                                if (dayEvents[k].isDeadline && !dayEvents[k].done) return true
                            return false
                        }
                        width: Math.floor((calGrid.width - 24) / 7)
                        height: 30

                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: isToday ? themeHub.accentA : (dayEvents.length > 0 ? "#FFF4FA" : (modelData.inMonth ? "#F4F6FB" : "#FAFBFD"))
                            border.color: isSel ? themeHub.darkInk : (isToday ? themeHub.darkInk : (modelData.inMonth ? "#331A1B2E" : "#151A1B2E"))
                            border.width: isSel ? 2 : (isToday ? 2 : 1)
                            opacity: modelData.inMonth ? 1.0 : 0.45

                            // Deadline corner flag
                            Rectangle {
                                visible: hasDeadline
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: 2
                                width: 6; height: 6; radius: 2
                                color: "#FF3B6B"
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.top
                                anchors.topMargin: 3
                                text: "" + modelData.dayNum
                                font.pixelSize: 10
                                font.weight: (isToday || isSel || dayEvents.length > 0) ? Font.Black : Font.Bold
                                color: isToday ? "#FFFFFF" : themeHub.darkInk
                            }

                            // Up to 3 Attribute Diamonds
                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 3
                                spacing: 2
                                Repeater {
                                    model: Math.min(3, dayEvents.length)
                                    DiamondDot {
                                        required property int index
                                        size: 6
                                        color: widgetsRoot.attrColor(dayEvents[index].attr || "cute")
                                        borderColor: themeHub.darkInk
                                        borderWidth: 1
                                    }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: calendarWin.selectedDay = (calendarWin.selectedDay === modelData.dateStr ? "" : modelData.dateStr)
                            onDoubleClicked: calendarWin.openNewEvent(modelData.dateStr)
                        }
                    }
                }
            }

            // Inline Event / Deadline Form (slides open when editing/adding)
            SekaiPill {
                id: evFormBox
                visible: calendarWin.showEditor
                anchors.top: calGrid.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 10
                anchors.topMargin: 6
                height: visible ? 116 : 0
                radius: 14
                color: "#FFF8FC"
                inkColor: themeHub.darkInk
                borderWidth: 2
                shadowShift: 3

                Column {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 6

                    Rectangle {
                        width: parent.width; height: 26; radius: 8
                        color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 1
                        TextInput {
                            id: evTitleIn
                            anchors.fill: parent; anchors.margins: 5
                            verticalAlignment: TextInput.AlignVCenter
                            font.pixelSize: 11; font.weight: Font.Bold; color: themeHub.darkInk
                            Text { anchors.fill: parent; verticalAlignment: Text.AlignVCenter; text: "Event or deadline title..."; font.pixelSize: 11; color: "#771A1B2E"; visible: !parent.text }
                        }
                    }

                    Row {
                        width: parent.width; spacing: 6
                        Rectangle {
                            width: 104; height: 24; radius: 7; color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 1
                            TextInput { id: evDateIn; anchors.fill: parent; anchors.margins: 4; verticalAlignment: TextInput.AlignVCenter; font.pixelSize: 10; font.weight: Font.Bold; color: themeHub.darkInk }
                        }
                        Rectangle {
                            width: 58; height: 24; radius: 7; color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 1
                            TextInput { id: evTimeIn; anchors.fill: parent; anchors.margins: 4; verticalAlignment: TextInput.AlignVCenter; font.pixelSize: 10; font.weight: Font.Bold; color: themeHub.darkInk }
                        }
                        Rectangle {
                            width: 72; height: 24; radius: 7
                            color: calendarWin.draftDeadline ? "#FF5E7E" : "#EEF1F8"
                            border.color: themeHub.darkInk; border.width: 1
                            Text { anchors.centerIn: parent; text: calendarWin.draftDeadline ? "DEADLINE" : "EVENT"; font.pixelSize: 9; font.weight: Font.Black; color: calendarWin.draftDeadline ? "#FFFFFF" : themeHub.darkInk }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: calendarWin.draftDeadline = !calendarWin.draftDeadline }
                        }
                    }

                    Row {
                        width: parent.width; spacing: 6
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 5
                            Repeater {
                                model: ["cute", "cool", "pure", "happy", "mysterious"]
                                Rectangle {
                                    required property string modelData
                                    width: 18; height: 18; radius: 9
                                    color: widgetsRoot.attrColor(modelData)
                                    border.color: themeHub.darkInk
                                    border.width: calendarWin.draftAttr === modelData ? 3 : 1
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: calendarWin.draftAttr = modelData }
                                }
                            }
                        }
                        Item { width: Math.max(4, parent.width - 216); height: 1 }
                        Rectangle {
                            width: 48; height: 24; radius: 7; color: "#EEF1F8"; border.color: themeHub.darkInk; border.width: 1
                            Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 9; font.weight: Font.Black; color: themeHub.darkInk }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: calendarWin.showEditor = false }
                        }
                        Rectangle {
                            width: 48; height: 24; radius: 7; color: themeHub.accentA; border.color: themeHub.darkInk; border.width: 2
                            Text { anchors.centerIn: parent; text: "Save"; font.pixelSize: 9; font.weight: Font.Black; color: "#FFFFFF" }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const t = evTitleIn.text.trim()
                                    if (!t) return
                                    themeHub.upsertCalendarEvent({
                                        id: calendarWin.editingId,
                                        title: t,
                                        date: evDateIn.text.trim() || calendarWin.todayStr,
                                        time: evTimeIn.text.trim(),
                                        attr: calendarWin.draftAttr,
                                        isDeadline: calendarWin.draftDeadline,
                                        done: false
                                    })
                                    calendarWin.showEditor = false
                                }
                            }
                        }
                    }
                }
            }

            // Coming Up / Selected-Day Event List
            Item {
                anchors.top: calendarWin.showEditor ? evFormBox.bottom : calGrid.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 10
                anchors.topMargin: 8

                Row {
                    id: listHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 18
                    Text {
                        text: calendarWin.selectedDay ? ("DAY " + calendarWin.selectedDay) : "COMING UP"
                        font.pixelSize: 10
                        font.weight: Font.Black
                        color: themeHub.darkInk
                    }
                    Item { width: parent.width - 130; height: 1 }
                    Text {
                        visible: calendarWin.selectedDay.length > 0
                        text: "Show all"
                        font.pixelSize: 9
                        font.weight: Font.Black
                        color: themeHub.accentA
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: calendarWin.selectedDay = "" }
                    }
                }

                ListView {
                    anchors.top: listHeader.bottom
                    anchors.topMargin: 4
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    clip: true
                    spacing: 6
                    model: calendarWin.visibleEvents

                    delegate: SekaiPill {
                        required property var modelData
                        width: ListView.view.width
                        height: 44
                        radius: 11
                        color: modelData.done ? "#F4F6FA" : "#FFFFFF"
                        inkColor: themeHub.darkInk
                        borderWidth: 2
                        shadowShift: 2
                        opacity: modelData.done ? 0.65 : 1.0

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            // Colored attribute stripe + check diamond
                            Rectangle {
                                width: 16; height: 16; radius: 8
                                anchors.verticalCenter: parent.verticalCenter
                                color: modelData.done ? widgetsRoot.attrColor(modelData.attr) : "#FFFFFF"
                                border.color: themeHub.darkInk; border.width: 2
                                Text { anchors.centerIn: parent; visible: !!modelData.done; text: "✓"; font.pixelSize: 10; font.weight: Font.Black; color: "#FFFFFF" }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.toggleCalendarDone(modelData.id) }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(80, parent.width - 110)
                                spacing: 0
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.title || ""
                                    font.pixelSize: 11
                                    font.weight: Font.Black
                                    font.strikeout: !!modelData.done
                                    color: themeHub.darkInk
                                }
                                Text {
                                    text: (modelData.date || "") + (modelData.time ? (" · " + modelData.time) : "") + (modelData.isDeadline ? " · DEADLINE" : "")
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                    color: (modelData.isDeadline && !modelData.done && modelData.date < calendarWin.todayStr) ? "#FF3B6B" : "#881A1B2E"
                                }
                            }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4
                                Rectangle {
                                    width: 20; height: 20; radius: 6; color: "#EEF1F8"; border.color: themeHub.darkInk; border.width: 1
                                    Text { anchors.centerIn: parent; text: "✎"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: calendarWin.openEditEvent(modelData) }
                                }
                                Rectangle {
                                    width: 20; height: 20; radius: 6; color: "#FFE8EE"; border.color: themeHub.darkInk; border.width: 1
                                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 11; font.weight: Font.Black; color: "#D92652" }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.deleteCalendarEvent(modelData.id) }
                                }
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: calendarWin.visibleEvents.length === 0
                        text: "No events — click + to add"
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        color: "#771A1B2E"
                    }
                }
            }
        }
    }

    // =========================================================================
    // 5. LYRICS WIDGET (Cardless Floating Desktop Outlined Stickers + Hover Controls)
    // =========================================================================
    WidgetShell {
        id: lyricsWin
        widgetKey: "lyrics"
        property bool searchOpen: false
        allowFocus: searchOpen
        cardWidth: 560
        cardHeight: 220
        targetX: themeHub.wLyricsX
        targetY: themeHub.wLyricsY
        visible: themeHub.wLyricsVisible && !widgetsRoot.fullscreenActive

        property bool hovered: false
        property string subLang: ConfigStore.stringValue("lyrics.subLang", "en")
        Component.onCompleted: LyricsService.setTranslateLang(subLang)
        readonly property var linesList: LyricsService.lines || []
        readonly property var transList: LyricsService.translatedLines || []
        readonly property int actIdx: LyricsService.activeIndex
        readonly property bool validSync: LyricsService.hasLyrics && linesList.length > 0
        readonly property var prevLine: (validSync && actIdx > 0 && actIdx - 1 < linesList.length) ? linesList[actIdx - 1] : null
        readonly property var curLine: (validSync && actIdx >= 0 && actIdx < linesList.length) ? linesList[actIdx] : (validSync ? linesList[0] : null)
        readonly property int curSubIdx: actIdx >= 0 ? actIdx : 0
        readonly property string curSubText: {
            if (subLang === "off" || !validSync || curSubIdx < 0 || curSubIdx >= transList.length)
                return ""
            const s = (transList[curSubIdx] || "").trim()
            const orig = curLine ? (curLine.text || "").trim() : ""
            if (s === "" || s === orig || orig === "♪")
                return ""
            return s
        }
        readonly property var nextLine: (validSync && actIdx >= 0 && actIdx + 1 < linesList.length) ? linesList[actIdx + 1] : (validSync && actIdx < 0 && linesList.length > 1 ? linesList[1] : null)

        DragSurface {
            shellWin: lyricsWin
            widgetKey: "lyrics"
            hubRef: widgetsRoot.themeHub
        }

        HoverHandler {
            onHoveredChanged: lyricsWin.hovered = hovered
        }

        // Hover-only Pill Toolbar (transparent when idle so widget stays 100% cardless!)
        Item {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 20
            height: 30
            z: 30
            opacity: (lyricsWin.hovered || lyricsWin.searchOpen) ? 1.0 : 0.0
            visible: opacity > 0.02
            Behavior on opacity { NumberAnimation { duration: 150 } }

            Row {
                anchors.centerIn: parent
                spacing: 6

                SekaiPill {
                    visible: !lyricsWin.searchOpen
                    width: Math.min(240, trackChipLbl.implicitWidth + 20)
                    height: 26
                    radius: 13
                    color: themeHub.darkInk
                    inkColor: "#FFFFFF"
                    borderWidth: 2
                    shadowShift: 2
                    showInnerRing: false
                    Text {
                        id: trackChipLbl
                        anchors.centerIn: parent
                        width: parent.width - 14
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        text: MediaService.hasSession ? ((MediaService.title || "Playing") + (MediaService.artist ? " — " + MediaService.artist : "")) : "Lyrics Ready"
                        font.pixelSize: 10
                        font.weight: Font.Black
                        color: "#FFFFFF"
                    }
                }

                // Inline manual search box
                SekaiPill {
                    visible: lyricsWin.searchOpen
                    width: 240
                    height: 26
                    radius: 13
                    color: "#FFFFFF"
                    inkColor: themeHub.darkInk
                    borderWidth: 2
                    shadowShift: 2
                    showInnerRing: false
                    TextInput {
                        id: lyricSearchIn
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        color: themeHub.darkInk
                        Text { anchors.fill: parent; verticalAlignment: Text.AlignVCenter; text: "Artist - Song..."; font.pixelSize: 10; color: "#771A1B2E"; visible: !parent.text }
                        onAccepted: {
                            const q = text.trim()
                            if (q.length > 0) LyricsService.searchManual(q)
                            lyricsWin.searchOpen = false
                        }
                    }
                }

                Rectangle {
                    width: Math.max(48, subBtnLbl.implicitWidth + 14); height: 26; radius: 13
                    color: lyricsWin.subLang !== "off" ? themeHub.accentB : "#FFFFFF"
                    border.color: themeHub.darkInk; border.width: 2
                    Text {
                        id: subBtnLbl
                        anchors.centerIn: parent
                        text: lyricsWin.subLang === "off" ? "SUB: OFF" : ("SUB: " + lyricsWin.subLang.toUpperCase())
                        font.pixelSize: 10; font.weight: Font.Black
                        color: themeHub.darkInk
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const next = lyricsWin.subLang === "en" ? "vi" : (lyricsWin.subLang === "vi" ? "off" : "en")
                            lyricsWin.subLang = next
                            ConfigStore.set("lyrics.subLang", next)
                            LyricsService.setTranslateLang(next)
                        }
                    }
                }
                Rectangle {
                    width: 26; height: 26; radius: 13
                    color: lyricsWin.searchOpen ? themeHub.accentA : "#FFFFFF"
                    border.color: themeHub.darkInk; border.width: 2
                    Text { anchors.centerIn: parent; text: "⌕"; font.pixelSize: 12; font.weight: Font.Black; color: lyricsWin.searchOpen ? "#FFFFFF" : themeHub.darkInk }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            lyricsWin.searchOpen = !lyricsWin.searchOpen
                            if (lyricsWin.searchOpen) lyricSearchIn.forceActiveFocus()
                        }
                    }
                }
                Rectangle {
                    width: 26; height: 26; radius: 13
                    color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 2
                    Text { anchors.centerIn: parent; text: "↻"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: LyricsService.refresh() }
                }
                Rectangle {
                    width: 26; height: 26; radius: 13
                    color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 2
                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWidgetVisible("lyrics", false) }
                }
            }
        }

        // Cardless Outlined Desktop Lyrics Stickers
        Column {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 10
            width: parent.width - 16
            spacing: 4

            // Previous Line (faded sticker)
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width, prevSticker.implicitWidth)
                height: visible ? prevSticker.implicitHeight : 0
                visible: lyricsWin.validSync && lyricsWin.prevLine !== null
                opacity: 0.62
                StickerText {
                    id: prevSticker
                    anchors.centerIn: parent
                    text: lyricsWin.prevLine ? (lyricsWin.prevLine.text || "") : ""
                    fontSize: 13
                    maxWidth: lyricsWin.width - 24
                    fillColor: "#EAF4FF"
                    inkColor: themeHub.darkInk
                    inkThickness: 2
                    haloThickness: 1
                    shadowShift: 2
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: if (lyricsWin.prevLine && lyricsWin.prevLine.time >= 0) MediaService.seek(lyricsWin.prevLine.time)
                }
            }

            // Current Active Line (large vibrant sticker + bouncing diamond)
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                visible: lyricsWin.validSync && lyricsWin.curLine !== null

                DiamondDot {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 11
                    color: themeHub.accentA
                    borderColor: themeHub.darkInk
                    borderWidth: 2
                }
                StickerText {
                    id: curSticker
                    text: lyricsWin.curLine ? (lyricsWin.curLine.text || "♪") : "♪"
                    fontSize: 20
                    maxWidth: lyricsWin.width - 44
                    fillColor: "#FFFFFF"
                    inkColor: themeHub.darkInk
                    inkThickness: 3
                    haloThickness: 2
                    shadowShift: 3
                    popOnChange: true
                }
            }

            // Bilingual Subtitle Line (EN / VI) underneath active lyric
            StickerText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: lyricsWin.validSync && lyricsWin.curSubText !== ""
                text: lyricsWin.curSubText
                fontSize: 13
                maxWidth: lyricsWin.width - 36
                fillColor: "#FEF08A"
                inkColor: themeHub.darkInk
                inkThickness: 2
                haloThickness: 1
                shadowShift: 2
            }

            // Next Line (tilted anticipation sticker)
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width, nextSticker.implicitWidth)
                height: visible ? nextSticker.implicitHeight : 0
                visible: lyricsWin.validSync && lyricsWin.nextLine !== null
                opacity: 0.78
                rotation: 1.0
                StickerText {
                    id: nextSticker
                    anchors.centerIn: parent
                    text: lyricsWin.nextLine ? (lyricsWin.nextLine.text || "") : ""
                    fontSize: 14
                    maxWidth: lyricsWin.width - 24
                    fillColor: themeHub.accentB
                    inkColor: themeHub.darkInk
                    inkThickness: 2
                    haloThickness: 1
                    shadowShift: 2
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: if (lyricsWin.nextLine && lyricsWin.nextLine.time >= 0) MediaService.seek(lyricsWin.nextLine.time)
                }
            }

            // Fallback / Status Sticker when unsynced or idle
            StickerText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !lyricsWin.validSync
                text: LyricsService.loading ? "Searching lyrics..."
                      : (LyricsService.plainText && LyricsService.plainText.length > 0
                         ? LyricsService.plainText.split("\n")[0]
                         : (MediaService.hasSession ? (LyricsService.statusText || "No synced lyrics") : "Play music for lyrics"))
                fontSize: 17
                maxWidth: lyricsWin.width - 24
                fillColor: "#FFFFFF"
                inkColor: themeHub.darkInk
                inkThickness: 3
                haloThickness: 2
                shadowShift: 3
            }
        }
    }

    // =========================================================================
    // 6. TO-DO CARD WIDGET (SekaiPill Checklist + Inline Rename + Clear Done)
    // =========================================================================
    WidgetShell {
        id: todoWin
        widgetKey: "todo"
        allowFocus: true
        freeResize: true
        minCardWidth: 240
        minCardHeight: 190
        maxCardWidth: 580
        maxCardHeight: 680
        defaultCardWidth: 320
        defaultCardHeight: 340
        cardWidth: themeHub.wTodoW
        cardHeight: themeHub.wTodoH
        targetX: themeHub.wTodoX
        targetY: themeHub.wTodoY
        visible: themeHub.wTodoVisible && !widgetsRoot.fullscreenActive

        property int editingIndex: -1

        readonly property int openTodoCount: {
            const list = themeHub.todoItems || []
            let c = 0
            for (let i = 0; i < list.length; i++) if (!list[i].done) c++
            return c
        }

        DragSurface {
            shellWin: todoWin
            widgetKey: "todo"
            hubRef: widgetsRoot.themeHub
        }

        SekaiPill {
            anchors.fill: parent
            radius: 22
            color: "#FFFDF9"
            inkColor: themeHub.darkInk
            shadowShift: 5

            // Header (left/right anchored so × NEVER overflows)
            Item {
                id: todoHdr
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 12
                height: 32

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    SekaiPill {
                        width: 26; height: 26; radius: 8
                        useGradient: true; gradientTop: themeHub.accentA; gradientBottom: themeHub.accentB
                        inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 2
                        Text { anchors.centerIn: parent; text: "✓"; font.pixelSize: 13; font.weight: Font.Black; color: "#FFFFFF" }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "TO-DO"
                        font.pixelSize: 13
                        font.weight: Font.Black
                        color: themeHub.darkInk
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        height: 20; width: todoCntTxt.implicitWidth + 12; radius: 10
                        color: "#EEF1F8"; border.color: themeHub.darkInk; border.width: 1
                        Text { id: todoCntTxt; anchors.centerIn: parent; text: todoWin.openTodoCount + " left"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34; height: 22; radius: 8
                        color: "#F4F6FB"; border.color: themeHub.darkInk; border.width: 1
                        Text { anchors.centerIn: parent; text: "Clear"; font.pixelSize: 9; font.weight: Font.Black; color: themeHub.darkInk }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.clearDoneTodos() }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 8
                        color: "#F4F6FB"; border.color: themeHub.darkInk; border.width: 1
                        Text { anchors.centerIn: parent; text: themeHub.todoSmall ? "↕" : "▾"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setTodoSmall(!themeHub.todoSmall) }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 11
                        color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 2
                        Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWidgetVisible("todo", false) }
                    }
                }
            }

            // Add-Task Row
            Row {
                id: todoAddRow
                anchors.top: todoHdr.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 12
                anchors.topMargin: 8
                height: 34
                spacing: 6

                SekaiPill {
                    width: parent.width - 42
                    height: 34
                    radius: 12
                    color: "#F5F7FC"
                    inkColor: themeHub.darkInk
                    borderWidth: 2
                    shadowShift: 2
                    showInnerRing: false
                    TextInput {
                        id: todoInput
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        font.pixelSize: 12; font.weight: Font.DemiBold; color: themeHub.darkInk
                        Text { anchors.fill: parent; verticalAlignment: Text.AlignVCenter; text: "Add a task..."; font.pixelSize: 12; color: "#771A1B2E"; visible: !parent.text }
                        onAccepted: {
                            if (text.trim().length > 0) {
                                themeHub.addTodo(text)
                                text = ""
                            }
                        }
                    }
                }

                SekaiPill {
                    width: 34; height: 34; radius: 12
                    color: themeHub.accentA; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 2
                    pressedState: todoAddBtnMa.pressed
                    Text { anchors.centerIn: parent; text: "+"; font.pixelSize: 18; font.weight: Font.Black; color: "#FFFFFF" }
                    MouseArea {
                        id: todoAddBtnMa
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (todoInput.text.trim().length > 0) {
                                themeHub.addTodo(todoInput.text)
                                todoInput.text = ""
                            }
                        }
                    }
                }
            }

            // Checklist
            ListView {
                anchors.top: todoAddRow.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                anchors.topMargin: 8
                clip: true
                spacing: 6
                model: themeHub.todoItems

                delegate: SekaiPill {
                    required property int index
                    required property var modelData
                    readonly property bool isEditing: todoWin.editingIndex === index
                    width: ListView.view.width
                    height: 38
                    radius: 11
                    color: modelData.done ? "#F4F6FA" : "#FFFFFF"
                    inkColor: themeHub.darkInk
                    borderWidth: 2
                    shadowShift: 2
                    opacity: modelData.done ? 0.65 : 1.0

                    Item {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8

                        Rectangle {
                            id: todoChkBox
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18; radius: 9
                            color: modelData.done ? themeHub.accentA : "#FFFFFF"
                            border.color: themeHub.darkInk; border.width: 2
                            Text { anchors.centerIn: parent; visible: !!modelData.done; text: "✓"; font.pixelSize: 11; font.weight: Font.Black; color: "#FFFFFF" }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.toggleTodo(index) }
                        }

                        Rectangle {
                            id: todoDelBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20; height: 20; radius: 6
                            color: todoDelMa.containsMouse ? "#FFD1DC" : "#FFE8EE"
                            border.color: themeHub.darkInk; border.width: 1
                            Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 11; font.weight: Font.Black; color: "#D92652" }
                            MouseArea { id: todoDelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.removeTodo(index) }
                        }

                        Item {
                            anchors.left: todoChkBox.right
                            anchors.leftMargin: 8
                            anchors.right: todoDelBtn.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            height: 26

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                visible: !isEditing
                                elide: Text.ElideRight
                                text: modelData.text || ""
                                font.pixelSize: 12
                                font.weight: Font.Bold
                                font.strikeout: !!modelData.done
                                color: themeHub.darkInk
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: themeHub.toggleTodo(index)
                                    onDoubleClicked: {
                                        todoWin.editingIndex = index
                                        rowEdit.text = modelData.text || ""
                                        rowEdit.forceActiveFocus()
                                    }
                                }
                            }

                            TextInput {
                                id: rowEdit
                                anchors.fill: parent
                                verticalAlignment: TextInput.AlignVCenter
                                visible: isEditing
                                font.pixelSize: 12
                                font.weight: Font.Bold
                                color: themeHub.darkInk
                                onAccepted: {
                                    themeHub.renameTodo(index, text)
                                    todoWin.editingIndex = -1
                                }
                                onActiveFocusChanged: {
                                    if (!activeFocus && isEditing) {
                                        themeHub.renameTodo(index, text)
                                        todoWin.editingIndex = -1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // 7. STICKY NOTES WIDGET (5 SekaiPop Paper Tints + 2-Click Clear Confirm)
    // =========================================================================
    WidgetShell {
        id: notesWin
        widgetKey: "notes"
        allowFocus: true
        freeResize: true
        minCardWidth: 230
        minCardHeight: 170
        maxCardWidth: 680
        maxCardHeight: 620
        defaultCardWidth: 288
        defaultCardHeight: 248
        cardWidth: themeHub.wNotesW
        cardHeight: themeHub.wNotesH
        targetX: themeHub.wNotesX
        targetY: themeHub.wNotesY
        visible: themeHub.wNotesVisible && !widgetsRoot.fullscreenActive

        property bool hovered: false
        property bool confirmClear: false
        readonly property color paperColor: {
            if (themeHub.noteTint === "mint") return "#E2FAEE"
            if (themeHub.noteTint === "pink") return "#FFE6F1"
            if (themeHub.noteTint === "sky") return "#E3F4FF"
            if (themeHub.noteTint === "lavender") return "#EFE8FF"
            return "#FFF6CC"
        }

        Timer {
            id: clearResetTimer
            interval: 2200
            onTriggered: notesWin.confirmClear = false
        }

        DragSurface {
            shellWin: notesWin
            widgetKey: "notes"
            hubRef: widgetsRoot.themeHub
        }

        HoverHandler {
            onHoveredChanged: notesWin.hovered = hovered
        }

        SekaiPill {
            anchors.fill: parent
            radius: 20
            color: notesWin.paperColor
            inkColor: themeHub.darkInk
            shadowShift: 5

            // Subtle ruled lines across paper
            Column {
                anchors.fill: parent
                anchors.topMargin: 48
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                anchors.bottomMargin: 10
                clip: true
                spacing: 22
                opacity: 0.08
                Repeater {
                    model: Math.max(8, Math.floor((parent.height + 12) / 23))
                    Rectangle { width: parent.width; height: 1; color: themeHub.darkInk }
                }
            }

            // Header bar with tint swatches + Clear confirm + Close
            Item {
                id: noteHdr
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 10
                height: 28

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "NOTE"
                        font.pixelSize: 12
                        font.weight: Font.Black
                        color: themeHub.darkInk
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        opacity: notesWin.hovered ? 1.0 : 0.65
                        Repeater {
                            model: [
                                { k: "butter",   c: "#FFE66D" },
                                { k: "mint",     c: "#7CE8B5" },
                                { k: "pink",     c: "#FF92C2" },
                                { k: "sky",      c: "#7DD3FC" },
                                { k: "lavender", c: "#C4B5FD" }
                            ]
                            Rectangle {
                                required property var modelData
                                width: 14; height: 14; radius: 7
                                color: modelData.c
                                border.color: themeHub.darkInk
                                border.width: themeHub.noteTint === modelData.k ? 2 : 1
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setNoteTint(modelData.k) }
                            }
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: notesWin.confirmClear ? 46 : 36
                        height: 22; radius: 8
                        color: notesWin.confirmClear ? "#FF5E7E" : "#88FFFFFF"
                        border.color: themeHub.darkInk; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: notesWin.confirmClear ? "Sure?" : "Clear"
                            font.pixelSize: 9; font.weight: Font.Black
                            color: notesWin.confirmClear ? "#FFFFFF" : themeHub.darkInk
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!notesWin.confirmClear) {
                                    notesWin.confirmClear = true
                                    clearResetTimer.restart()
                                } else {
                                    noteEdit.text = ""
                                    themeHub.saveNoteText("")
                                    notesWin.confirmClear = false
                                }
                            }
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 11
                        color: "#FFFFFF"; border.color: themeHub.darkInk; border.width: 2
                        Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.darkInk }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWidgetVisible("notes", false) }
                    }
                }
            }

            Flickable {
                anchors.top: noteHdr.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                anchors.topMargin: 6
                contentWidth: width
                contentHeight: Math.max(height, noteEdit.contentHeight + 12)
                clip: true

                TextEdit {
                    id: noteEdit
                    width: parent.width
                    wrapMode: TextEdit.Wrap
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    color: themeHub.darkInk
                    text: themeHub.noteText
                    onTextChanged: {
                        if (text !== themeHub.noteText)
                            themeHub.saveNoteText(text)
                    }
                    Text {
                        anchors.fill: parent
                        text: "Jot something down..."
                        font.pixelSize: 13
                        color: "#661A1B2E"
                        visible: noteEdit.text.length === 0
                    }
                }
            }
        }
    }

    // =========================================================================
    // 8. AUTHENTIC SEKAIPOP EDIT DESKTOP TRAY (6-Tab Bottom Floating Shelf)
    // =========================================================================
    PanelWindow {
        id: editTrayWin
        visible: widgetsRoot.themeHub.editMode && !widgetsRoot.fullscreenActive
        clickThrough: false
        desktopLayer: false
        desktopAllowFocus: true
        color: "transparent"

        anchors.bottom: true
        anchors.margins.bottom: 14

        width: Math.min(widgetsRoot.themeHub.screenW - 28, 920)
        height: 214
        x: Math.max(14, Math.round((widgetsRoot.themeHub.screenW - width) * 0.5))

        property var presetsList: []
        property bool hasPreviousPreset: false
        property bool namingPreset: false
        property string deleteConfirmPreset: ""

        function refreshPresets() {
            const all = ConfigStore.listPresets() || []
            const shown = []
            let hasPrev = false
            for (let i = 0; i < all.length; ++i) {
                if (all[i].name === ".previous")
                    hasPrev = true
                else
                    shown.push(all[i])
            }
            presetsList = shown
            hasPreviousPreset = hasPrev
            deleteConfirmPreset = ""
        }

        onVisibleChanged: {
            if (visible) {
                namingPreset = false
                deleteConfirmPreset = ""
                refreshPresets()
                focusActivate()
                editEscScope.forceActiveFocus()
            }
        }

        Item {
            id: editEscScope
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: {
                if (editTrayWin.namingPreset) {
                    editTrayWin.namingPreset = false
                    editEscScope.forceActiveFocus()
                } else {
                    widgetsRoot.themeHub.setEditMode(false)
                }
            }

            // Hard comic shadow under main shelf card
            Rectangle {
                x: 5
                y: 16
                width: parent.width - 8
                height: parent.height - 20
                radius: 22
                color: themeHub.darkInk
            }

            // Main Edit Desktop shelf card
            Rectangle {
                id: editTrayCard
                x: 0
                y: 11
                width: parent.width - 8
                height: parent.height - 20
                radius: 22
                color: "#FFFDF9"
                border.width: 3
                border.color: themeHub.darkInk

                // Subtle DotField texture
                DotField {
                    anchors.fill: parent
                    anchors.margins: 4
                    color: themeHub.darkInk
                    dotAlpha: 0.045
                    step: 12
                }

                // Header Bar: Title + 6 SekaiPop Tabs + RESET POS + LOCK ALL + DONE
                Item {
                    id: editHeaderRow
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 12
                    height: 34

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7

                        DiamondDot {
                            anchors.verticalCenter: parent.verticalCenter
                            size: 11
                            color: themeHub.accentA
                            borderColor: themeHub.darkInk
                            borderWidth: 2
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "EDIT DESKTOP"
                            font.family: "Segoe UI"
                            font.pixelSize: 13
                            font.weight: Font.Black
                            font.letterSpacing: 1
                            color: themeHub.darkInk
                        }

                        // 6 Tabs: WIDGETS / BAR / DOCK / VIEWS / THEMES / PRESETS
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4
                            Repeater {
                                model: [
                                    { id: "widgets", label: "WIDGETS" },
                                    { id: "bar",     label: "BAR" },
                                    { id: "dock",    label: "DOCK" },
                                    { id: "views",   label: "VIEWS" },
                                    { id: "themes",  label: "THEMES" },
                                    { id: "presets", label: "PRESETS" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool active: widgetsRoot.themeHub.editTab === modelData.id
                                        || (modelData.id === "themes" && widgetsRoot.themeHub.editTab === "theme")
                                        || (modelData.id === "views" && widgetsRoot.themeHub.editTab === "controls")
                                    width: tabLbl.implicitWidth + 16
                                    height: 26
                                    radius: 9
                                    color: active ? themeHub.accentA : (tabMa.containsMouse ? themeHub.hoverTint : "#F1F5F9")
                                    border.width: active ? 2 : 1.5
                                    border.color: themeHub.darkInk
                                    Text {
                                        id: tabLbl
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        font.family: "Segoe UI"
                                        font.pixelSize: 10
                                        font.weight: Font.Black
                                        color: themeHub.darkInk
                                    }
                                    MouseArea {
                                        id: tabMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            widgetsRoot.themeHub.editTab = modelData.id
                                            if (modelData.id === "presets")
                                                editTrayWin.refreshPresets()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Right action pills: RESET POS + LOCK ALL + DONE
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        SekaiPill {
                            width: resetPosLbl.implicitWidth + 16
                            height: 30
                            radius: 10
                            color: resetPosMa.containsMouse ? "#FFE4E6" : "#FFFFFF"
                            inkColor: themeHub.darkInk
                            borderWidth: 2
                            shadowShift: 2
                            pressedState: resetPosMa.pressed
                            showInnerRing: false
                            Text {
                                id: resetPosLbl
                                anchors.centerIn: parent
                                text: "↺ RESET"
                                font.family: "Segoe UI"
                                font.pixelSize: 10
                                font.weight: Font.Black
                                color: "#D92652"
                            }
                            MouseArea {
                                id: resetPosMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    widgetsRoot.themeHub.resetWidgetPositions()
                                    VisualizerService.resetPosition()
                                }
                            }
                        }

                        SekaiPill {
                            width: lockAllLbl.implicitWidth + 20
                            height: 30
                            radius: 10
                            color: widgetsRoot.themeHub.widgetsLocked ? "#FFD166" : "#F1F5F9"
                            inkColor: themeHub.darkInk
                            borderWidth: 2
                            shadowShift: 2
                            pressedState: lockAllMa.pressed
                            showInnerRing: false
                            Text {
                                id: lockAllLbl
                                anchors.centerIn: parent
                                text: widgetsRoot.themeHub.widgetsLocked ? "LOCK ALL: ON" : "LOCK ALL"
                                font.family: "Segoe UI"
                                font.pixelSize: 10
                                font.weight: Font.Black
                                color: themeHub.darkInk
                            }
                            MouseArea {
                                id: lockAllMa
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: widgetsRoot.themeHub.setWidgetsLocked(!widgetsRoot.themeHub.widgetsLocked)
                            }
                        }

                        SekaiPill {
                            width: 68
                            height: 30
                            radius: 10
                            useGradient: true
                            gradientTop: themeHub.accentB
                            gradientBottom: themeHub.accentA
                            inkColor: themeHub.darkInk
                            borderWidth: 2
                            shadowShift: 2
                            pressedState: doneBtnMa.pressed
                            Text {
                                anchors.centerIn: parent
                                text: "DONE"
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.weight: Font.Black
                                color: themeHub.darkInk
                            }
                            MouseArea {
                                id: doneBtnMa
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: widgetsRoot.themeHub.setEditMode(false)
                            }
                        }
                    }
                }

                // Body Area
                Item {
                    anchors.top: editHeaderRow.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 12
                    anchors.topMargin: 6

                    // =========================================================
                    // TAB 1: WIDGETS (7 Widgets + Visualizer Slot with + / ✓)
                    // =========================================================
                    Flickable {
                        visible: widgetsRoot.themeHub.editTab === "widgets"
                        anchors.fill: parent
                        contentWidth: widgetSlotsRow.implicitWidth + 12
                        contentHeight: height
                        clip: true

                        Row {
                            id: widgetSlotsRow
                            spacing: 10
                            y: 6

                            Repeater {
                                model: [
                                    { key: "clock",      label: "Clock",      tag: "TIME" },
                                    { key: "weather",    label: "Weather",    tag: "WX" },
                                    { key: "calendar",   label: "Calendar",   tag: "PLAN" },
                                    { key: "profile",    label: "Profile",    tag: "USER" },
                                    { key: "todo",       label: "To-Do",      tag: "LIST" },
                                    { key: "notes",      label: "Notes",      tag: "NOTE" },
                                    { key: "lyrics",     label: "Lyrics",     tag: "SYNC" },
                                    { key: "visualizer", label: "Visualizer", tag: "AUDIO" }
                                ]
                                delegate: Item {
                                    id: slotItem
                                    required property int index
                                    required property var modelData
                                    readonly property bool isViz: modelData.key === "visualizer"
                                    readonly property bool isOn: isViz ? VisualizerService.enabled : widgetsRoot.themeHub.widgetVisible(modelData.key)
                                    readonly property bool hot: slotMa.containsMouse

                                    width: 102
                                    height: 120

                                    Item {
                                        anchors.fill: parent
                                        y: hot ? -4 : 0
                                        rotation: hot ? 0 : (slotItem.index % 2 === 0 ? -1.4 : 1.4)
                                        Behavior on y { NumberAnimation { duration: 170; easing.type: Easing.OutBack } }
                                        Behavior on rotation { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

                                        // Hard shadow
                                        Rectangle {
                                            x: 3; y: 7
                                            width: parent.width - 4
                                            height: parent.height - 10
                                            radius: 14
                                            color: themeHub.darkInk
                                        }

                                        // Slot mount
                                        Rectangle {
                                            x: 0; y: 4
                                            width: parent.width - 4
                                            height: parent.height - 10
                                            radius: 14
                                            color: slotItem.isOn ? "#FFFFFF" : "#F4F6FA"
                                            border.width: 2.5
                                            border.color: slotItem.isOn ? themeHub.darkInk : "#64748B"

                                            // Mini dark screen preview
                                            Rectangle {
                                                x: 6; y: 6
                                                width: parent.width - 12
                                                height: 68
                                                radius: 9
                                                color: "#1B1E32"
                                                border.width: 1.5
                                                border.color: themeHub.darkInk
                                                clip: true
                                                opacity: slotItem.isOn ? 1.0 : 0.72

                                                // Clock miniature
                                                Row {
                                                    visible: slotItem.modelData.key === "clock"
                                                    anchors.centerIn: parent
                                                    spacing: 4
                                                    Rectangle {
                                                        width: 24; height: 32; radius: 6; color: themeHub.accentA; border.width: 1.5; border.color: themeHub.darkInk
                                                        Text { anchors.centerIn: parent; text: "12"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                                                    }
                                                    Rectangle {
                                                        width: 24; height: 32; radius: 6; color: themeHub.accentB; border.width: 1.5; border.color: themeHub.darkInk
                                                        Text { anchors.centerIn: parent; text: "34"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                                                    }
                                                }

                                                // Weather miniature
                                                Row {
                                                    visible: slotItem.modelData.key === "weather"
                                                    anchors.centerIn: parent
                                                    spacing: 6
                                                    Rectangle { width: 20; height: 20; radius: 10; color: "#FFD166"; border.width: 1.5; border.color: themeHub.darkInk }
                                                    Text { anchors.verticalCenter: parent.verticalCenter; text: widgetsRoot.themeHub.formatTemp(WeatherService.temperature) + "°"; font.pixelSize: 14; font.weight: Font.Black; color: "#FFFFFF" }
                                                }

                                                // Calendar miniature
                                                Grid {
                                                    visible: slotItem.modelData.key === "calendar"
                                                    anchors.centerIn: parent
                                                    columns: 4; spacing: 4
                                                    Repeater {
                                                        model: 8
                                                        Rectangle {
                                                            required property int index
                                                            width: 10; height: 10; radius: 3
                                                            color: index === 2 ? themeHub.accentA : (index === 5 ? "#FF5E9E" : "#334155")
                                                        }
                                                    }
                                                }

                                                // Profile miniature
                                                Item {
                                                    visible: slotItem.modelData.key === "profile"
                                                    anchors.fill: parent
                                                    Rectangle {
                                                        x: 6; y: 6; width: parent.width - 12; height: 22; radius: 5
                                                        gradient: Gradient {
                                                            orientation: Gradient.Horizontal
                                                            GradientStop { position: 0.0; color: themeHub.accentA }
                                                            GradientStop { position: 1.0; color: themeHub.accentB }
                                                        }
                                                    }
                                                    Rectangle {
                                                        x: 10; y: 20; width: 22; height: 22; radius: 11
                                                        color: "#FFFFFF"; border.width: 2; border.color: themeHub.darkInk
                                                    }
                                                }

                                                // To-Do miniature
                                                Column {
                                                    visible: slotItem.modelData.key === "todo"
                                                    anchors.centerIn: parent
                                                    spacing: 5
                                                    Repeater {
                                                        model: 3
                                                        Row {
                                                            required property int index
                                                            spacing: 4
                                                            Rectangle { width: 8; height: 8; radius: 4; color: index === 0 ? themeHub.accentB : "#475569" }
                                                            Rectangle { width: 46; height: 6; radius: 3; anchors.verticalCenter: parent.verticalCenter; color: index === 0 ? "#64748B" : "#E2E8F0" }
                                                        }
                                                    }
                                                }

                                                // Notes miniature
                                                Rectangle {
                                                    visible: slotItem.modelData.key === "notes"
                                                    anchors.centerIn: parent
                                                    width: 56; height: 42; radius: 7
                                                    color: "#FFF6CC"; border.width: 1.5; border.color: themeHub.darkInk
                                                    Column {
                                                        anchors.centerIn: parent; spacing: 5
                                                        Rectangle { width: 40; height: 3; radius: 1; color: "#94A3B8" }
                                                        Rectangle { width: 32; height: 3; radius: 1; color: "#94A3B8" }
                                                        Rectangle { width: 36; height: 3; radius: 1; color: "#94A3B8" }
                                                    }
                                                }

                                                // Lyrics miniature
                                                Column {
                                                    visible: slotItem.modelData.key === "lyrics"
                                                    anchors.centerIn: parent
                                                    spacing: 5
                                                    Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 42; height: 5; radius: 2; color: "#64748B" }
                                                    Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 62; height: 8; radius: 4; color: themeHub.accentA }
                                                    Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 48; height: 5; radius: 2; color: "#64748B" }
                                                }

                                                // Visualizer miniature
                                                Row {
                                                    visible: slotItem.isViz
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    anchors.bottom: parent.bottom
                                                    anchors.bottomMargin: 12
                                                    spacing: 3
                                                    Repeater {
                                                        model: [18, 32, 24, 38, 28, 34, 20, 28]
                                                        delegate: Rectangle {
                                                            required property int modelData
                                                            required property int index
                                                            anchors.bottom: parent.bottom
                                                            width: 6
                                                            height: modelData
                                                            radius: 3
                                                            color: index % 2 === 0 ? themeHub.accentA : themeHub.accentB
                                                        }
                                                    }
                                                }
                                            }

                                            Text {
                                                anchors.bottom: parent.bottom
                                                anchors.bottomMargin: 8
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: slotItem.modelData.label
                                                font.family: "Segoe UI"
                                                font.pixelSize: 11
                                                font.weight: Font.Black
                                                color: themeHub.darkInk
                                            }
                                        }

                                        // Top-right + / ✓ status badge
                                        Rectangle {
                                            x: parent.width - width
                                            y: 0
                                            width: 24; height: 24; radius: 12
                                            color: slotItem.isOn ? themeHub.accentB : "#FFFFFF"
                                            border.width: 2
                                            border.color: themeHub.darkInk
                                            Text {
                                                anchors.centerIn: parent
                                                text: slotItem.isOn ? "✓" : "+"
                                                font.pixelSize: 12
                                                font.weight: Font.Black
                                                color: themeHub.darkInk
                                            }
                                        }

                                        MouseArea {
                                            id: slotMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: mouse => {
                                                if (slotItem.isViz) {
                                                    if (mouse.button === Qt.RightButton)
                                                        VisualizerService.enabled = false
                                                    else
                                                        VisualizerService.enabled = !VisualizerService.enabled
                                                } else {
                                                    if (mouse.button === Qt.RightButton)
                                                        widgetsRoot.themeHub.setWidgetVisible(slotItem.modelData.key, false)
                                                    else
                                                        widgetsRoot.themeHub.setWidgetVisible(slotItem.modelData.key, !slotItem.isOn)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // Add Photo Frame (#6 ImageWidget) slot
                            Item {
                                id: addPhotoSlot
                                width: 102; height: 120
                                readonly property bool hot: addPhotoMa.containsMouse

                                Item {
                                    anchors.fill: parent
                                    y: addPhotoSlot.hot ? -4 : 0
                                    rotation: addPhotoSlot.hot ? 0 : -1.4
                                    Behavior on y { NumberAnimation { duration: 170; easing.type: Easing.OutBack } }
                                    Behavior on rotation { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

                                    Rectangle { x: 3; y: 7; width: parent.width - 4; height: parent.height - 10; radius: 14; color: themeHub.darkInk }
                                    Rectangle {
                                        x: 0; y: 4; width: parent.width - 4; height: parent.height - 10; radius: 14
                                        color: "#FFFDF7"; border.width: 2.5; border.color: themeHub.darkInk
                                        Rectangle {
                                            x: 6; y: 6; width: parent.width - 12; height: 68; radius: 9
                                            color: "#1B1E32"; border.width: 1.5; border.color: themeHub.darkInk
                                            Rectangle {
                                                anchors.centerIn: parent; width: 46; height: 50; radius: 6; color: "#FFFDF7"; rotation: -4
                                                Rectangle { x: 4; y: 4; width: 38; height: 32; radius: 4; color: themeHub.accentB }
                                            }
                                        }
                                        Text {
                                            anchors.bottom: parent.bottom; anchors.bottomMargin: 8; anchors.horizontalCenter: parent.horizontalCenter
                                            text: "Photo (" + (widgetsRoot.themeHub.imageFrames ? widgetsRoot.themeHub.imageFrames.length : 0) + ")"
                                            font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk
                                        }
                                    }
                                    Rectangle {
                                        x: parent.width - width; y: 0; width: 24; height: 24; radius: 12
                                        color: themeHub.accentA; border.width: 2; border.color: themeHub.darkInk
                                        Text { anchors.centerIn: parent; text: "+"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.darkInk }
                                    }
                                    MouseArea {
                                        id: addPhotoMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const picked = SystemControl.pickImageFile("Add Polaroid Photo Frame")
                                            if (picked !== "")
                                                widgetsRoot.themeHub.addImageFrame(picked)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // =========================================================
                    // TAB 2: BAR (Style, Auto-Hide, Module Visibility)
                    // =========================================================
                    Flickable {
                        visible: widgetsRoot.themeHub.editTab === "bar"
                        anchors.fill: parent
                        contentWidth: barTabRow.implicitWidth + 12
                        contentHeight: height
                        clip: true

                        Row {
                            id: barTabRow
                            spacing: 12
                            y: 6

                            // Card 1: Bar Style
                            SekaiPill {
                                width: 256; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "BAR STYLE"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Grid {
                                        columns: 2; spacing: 6; width: parent.width
                                        Repeater {
                                            model: [
                                                { id: "float",       label: "Float" },
                                                { id: "straight",    label: "Straight" },
                                                { id: "capsule",     label: "Capsule" },
                                                { id: "transparent", label: "Clear" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool act: widgetsRoot.themeHub.barStyle === modelData.id
                                                width: 114; height: 34; radius: 10
                                                color: act ? themeHub.accentA : (bsMa.containsMouse ? themeHub.hoverTint : "#F1F5F9")
                                                border.width: act ? 2 : 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: (act ? "● " : "") + modelData.label; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                                                MouseArea { id: bsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setBarStyle(modelData.id) }
                                            }
                                        }
                                    }
                                }
                            }

                            // Card 2: Bar Position & Hide Mode
                            SekaiPill {
                                width: 224; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "EDGE & VISIBILITY"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Row {
                                        width: parent.width; spacing: 5
                                        Repeater {
                                            model: [
                                                { id: "top",    l: "TOP" },
                                                { id: "bottom", l: "BOT" },
                                                { id: "left",   l: "LEFT" },
                                                { id: "right",  l: "RIGHT" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool act: widgetsRoot.themeHub.barEdge === modelData.id
                                                width: 47; height: 32; radius: 9
                                                color: act ? themeHub.accentA : "#F1F5F9"
                                                border.width: act ? 2 : 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setBarEdge(modelData.id) }
                                            }
                                        }
                                    }
                                    Row {
                                        width: parent.width; spacing: 6
                                        Rectangle {
                                            width: 98; height: 34; radius: 9
                                            color: widgetsRoot.themeHub.barAutoHide ? themeHub.accentB : "#F1F5F9"
                                            border.width: widgetsRoot.themeHub.barAutoHide ? 2 : 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "AUTO-HIDE"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setBarAutoHide(true) }
                                        }
                                        Rectangle {
                                            width: 98; height: 34; radius: 9
                                            color: !widgetsRoot.themeHub.barAutoHide ? themeHub.accentA : "#F1F5F9"
                                            border.width: !widgetsRoot.themeHub.barAutoHide ? 2 : 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "NO-HIDE"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setBarAutoHide(false) }
                                        }
                                    }
                                }
                            }

                            // Card 3: Bar Modules
                            SekaiPill {
                                width: 420; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "BAR MODULES"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Flow {
                                        width: parent.width; spacing: 6
                                        Repeater {
                                            model: [
                                                { key: "active",  label: "Active App", on: widgetsRoot.themeHub.barShowActiveWindow },
                                                { key: "media",   label: "Media Pill", on: widgetsRoot.themeHub.barShowMedia },
                                                { key: "weather", label: "Weather",    on: widgetsRoot.themeHub.barShowWeather },
                                                { key: "stats",   label: "CPU / RAM",  on: widgetsRoot.themeHub.barShowStats },
                                                { key: "tray",    label: "Sys Tray",   on: widgetsRoot.themeHub.barShowTray },
                                                { key: "clock",   label: "Clock",      on: widgetsRoot.themeHub.barShowClock }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: 128; height: 34; radius: 10
                                                color: modelData.on ? themeHub.accentB : "#F1F5F9"
                                                border.width: modelData.on ? 2 : 1.5; border.color: themeHub.darkInk
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: (modelData.on ? "✓ " : "○ ") + modelData.label
                                                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        const k = modelData.key
                                                        if (k === "active") widgetsRoot.themeHub.setBarShowActiveWindow(!modelData.on)
                                                        else if (k === "media") widgetsRoot.themeHub.setBarShowMedia(!modelData.on)
                                                        else if (k === "weather") widgetsRoot.themeHub.setBarShowWeather(!modelData.on)
                                                        else if (k === "stats") widgetsRoot.themeHub.setBarShowStats(!modelData.on)
                                                        else if (k === "tray") widgetsRoot.themeHub.setBarShowTray(!modelData.on)
                                                        else if (k === "clock") widgetsRoot.themeHub.setBarShowClock(!modelData.on)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // =========================================================
                    // TAB 3: DOCK (Style, Dodge, Tile Size, Magnify, Tools)
                    // =========================================================
                    Flickable {
                        visible: widgetsRoot.themeHub.editTab === "dock"
                        anchors.fill: parent
                        contentWidth: dockTabRow.implicitWidth + 12
                        contentHeight: height
                        clip: true

                        Row {
                            id: dockTabRow
                            spacing: 12
                            y: 6

                            // Card 1: Dock Style
                            SekaiPill {
                                width: 176; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 6
                                    Text { text: "DOCK STYLE"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Repeater {
                                        model: [
                                            { id: "float",       label: "Float Card" },
                                            { id: "capsule",     label: "Capsule Pill" },
                                            { id: "transparent", label: "Transparent" }
                                        ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property bool act: widgetsRoot.themeHub.dockStyle === modelData.id
                                            width: parent.width; height: 24; radius: 8
                                            color: act ? themeHub.accentA : "#F1F5F9"
                                            border.width: act ? 2 : 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: (act ? "● " : "") + modelData.label; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setDockStyle(modelData.id) }
                                        }
                                    }
                                }
                            }

                            // Card 2: Size + Magnify + Dodge
                            SekaiPill {
                                width: 320; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "SIZE & MOTION"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Row {
                                        spacing: 6
                                        Repeater {
                                            model: [
                                                { sz: 40, label: "40px S" },
                                                { sz: 48, label: "48px M" },
                                                { sz: 56, label: "56px L" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool act: widgetsRoot.themeHub.dockTileSize === modelData.sz
                                                width: 96; height: 32; radius: 9
                                                color: act ? themeHub.accentB : "#F1F5F9"
                                                border.width: act ? 2 : 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: modelData.label; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setDockTileSize(modelData.sz) }
                                            }
                                        }
                                    }
                                    Row {
                                        spacing: 5
                                        Rectangle {
                                            width: 110; height: 34; radius: 9
                                            color: widgetsRoot.themeHub.dockMagnify ? themeHub.accentA : "#F1F5F9"
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "Magnify: " + (widgetsRoot.themeHub.dockMagnify ? "ON" : "OFF"); font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setDockMagnify(!widgetsRoot.themeHub.dockMagnify) }
                                        }
                                        Rectangle {
                                            width: 90; height: 34; radius: 9
                                            color: widgetsRoot.themeHub.dockAutoHide ? themeHub.accentB : "#F1F5F9"
                                            border.width: widgetsRoot.themeHub.dockAutoHide ? 2 : 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "AUTO-HIDE"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setDockAutoHide(true) }
                                        }
                                        Rectangle {
                                            width: 90; height: 34; radius: 9
                                            color: !widgetsRoot.themeHub.dockAutoHide ? themeHub.accentA : "#F1F5F9"
                                            border.width: !widgetsRoot.themeHub.dockAutoHide ? 2 : 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "NO-HIDE"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setDockAutoHide(false) }
                                        }
                                    }
                                }
                            }

                            // Card 2b: Dock 4-Edge Position
                            SekaiPill {
                                width: 176; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "DOCK POSITION"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Grid {
                                        columns: 2; spacing: 6; width: parent.width
                                        Repeater {
                                            model: [
                                                { id: "bottom", l: "BOTTOM" },
                                                { id: "top",    l: "TOP" },
                                                { id: "left",   l: "LEFT" },
                                                { id: "right",  l: "RIGHT" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool act: widgetsRoot.themeHub.dockEdge === modelData.id
                                                width: 75; height: 34; radius: 9
                                                color: act ? themeHub.accentA : "#F1F5F9"
                                                border.width: act ? 2 : 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setDockEdge(modelData.id) }
                                            }
                                        }
                                    }
                                }
                            }

                            // Card 3: Dock Tools
                            SekaiPill {
                                width: 416; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "DOCK UTILITY KEYS"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Grid {
                                        columns: 4; spacing: 6
                                        Repeater {
                                            model: [
                                                { key: "finder",    label: "Spotlight",  on: widgetsRoot.themeHub.dockShowFinder },
                                                { key: "clipboard", label: "Clipboard",  on: widgetsRoot.themeHub.dockShowClipboard },
                                                { key: "dropshelf", label: "Drop Shelf", on: widgetsRoot.themeHub.dockShowDropShelf },
                                                { key: "trash",     label: "Trash Bin",  on: widgetsRoot.themeHub.dockShowTrash },
                                                { key: "timer",     label: "Timer",      on: widgetsRoot.themeHub.dockShowTimer },
                                                { key: "files",     label: "Files",      on: widgetsRoot.themeHub.dockShowFiles },
                                                { key: "media",     label: "Media Pill", on: widgetsRoot.themeHub.dockShowMedia },
                                                { key: "iconshape", label: "Icons: " + (widgetsRoot.themeHub.dockIconShape === "circle" ? "Round" : (widgetsRoot.themeHub.dockIconShape === "square" ? "Square" : "Auto")), on: widgetsRoot.themeHub.dockIconShape !== "auto" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: 94; height: 34; radius: 9
                                                color: modelData.on ? themeHub.accentB : "#F1F5F9"
                                                border.width: modelData.on ? 2 : 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: modelData.key === "iconshape" ? modelData.label : ((modelData.on ? "✓ " : "○ ") + modelData.label); font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        const k = modelData.key
                                                        if (k === "finder") widgetsRoot.themeHub.setDockShowFinder(!modelData.on)
                                                        else if (k === "clipboard") widgetsRoot.themeHub.setDockShowClipboard(!modelData.on)
                                                        else if (k === "dropshelf") widgetsRoot.themeHub.setDockShowDropShelf(!modelData.on)
                                                        else if (k === "trash") widgetsRoot.themeHub.setDockShowTrash(!modelData.on)
                                                        else if (k === "timer") widgetsRoot.themeHub.setDockShowTimer(!modelData.on)
                                                        else if (k === "files") widgetsRoot.themeHub.setDockShowFiles(!modelData.on)
                                                        else if (k === "media") widgetsRoot.themeHub.setDockShowMedia(!modelData.on)
                                                        else if (k === "iconshape") {
                                                            const cur = widgetsRoot.themeHub.dockIconShape
                                                            widgetsRoot.themeHub.setDockIconShape(cur === "auto" ? "circle" : (cur === "circle" ? "square" : "auto"))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // =========================================================
                    // TAB 4: VIEWS (Phone, Notifications, OSD, Styles, Jumps)
                    // =========================================================
                    Flickable {
                        visible: widgetsRoot.themeHub.editTab === "views" || widgetsRoot.themeHub.editTab === "controls"
                        anchors.fill: parent
                        contentWidth: viewsTabRow.implicitWidth + 12
                        contentHeight: height
                        clip: true

                        Row {
                            id: viewsTabRow
                            spacing: 10
                            y: 6

                            // Card 1: Phone & Shell Views
                            SekaiPill {
                                width: 224; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 7
                                    Text { text: "SHELL & NOTIFICATIONS"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Row {
                                        spacing: 6
                                        Rectangle {
                                            width: 98; height: 32; radius: 9
                                            color: widgetsRoot.themeHub.phoneMode ? themeHub.accentA : "#F1F5F9"
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: widgetsRoot.themeHub.phoneMode ? "Phone: 2.5D" : "Phone: 2D"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setPhoneMode(!widgetsRoot.themeHub.phoneMode) }
                                        }
                                        Rectangle {
                                            width: 98; height: 32; radius: 9
                                            color: widgetsRoot.themeHub.osdEnabled ? themeHub.accentB : "#F1F5F9"
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "OSD: " + (widgetsRoot.themeHub.osdEnabled ? "ON" : "OFF"); font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setOsdEnabled(!widgetsRoot.themeHub.osdEnabled) }
                                        }
                                    }
                                    Row {
                                        spacing: 6
                                        Rectangle {
                                            width: 98; height: 32; radius: 9
                                            color: widgetsRoot.themeHub.screenRoundEnabled ? themeHub.accentB : "#F1F5F9"
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "Corners: " + (widgetsRoot.themeHub.screenRoundEnabled ? "ON" : "OFF"); font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: widgetsRoot.themeHub.setScreenRound(!widgetsRoot.themeHub.screenRoundEnabled) }
                                        }
                                        Rectangle {
                                            width: 98; height: 32; radius: 9
                                            color: "#F1F5F9"
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            Text {
                                                anchors.centerIn: parent
                                                text: "Alert: " + (widgetsRoot.themeHub.notifyStyle === "peek" ? "PEEK" : (widgetsRoot.themeHub.notifyStyle === "popup" ? "POPUP" : "OFF"))
                                                font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk
                                            }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    const cur = widgetsRoot.themeHub.notifyStyle
                                                    widgetsRoot.themeHub.setNotifyStyle(cur === "peek" ? "popup" : (cur === "popup" ? "off" : "peek"))
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Card 2: Clock & Weather Styles
                            SekaiPill {
                                width: 220; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 7
                                    Text { text: "CLOCK & WEATHER"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Row {
                                        spacing: 6
                                        Rectangle {
                                            width: 122; height: 32; radius: 9; color: themeHub.accentB; border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: themeHub.clockDesignNames[themeHub.clockStyle] + " ↻"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.cycleClockStyle() }
                                        }
                                        Rectangle {
                                            width: 72; height: 32; radius: 9; color: themeHub.clockUse24h ? themeHub.accentA : "#F1F5F9"; border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: themeHub.clockUse24h ? "24H" : "12H"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setClockUse24h(!themeHub.clockUse24h) }
                                        }
                                    }
                                    Row {
                                        spacing: 6
                                        Rectangle {
                                            width: 112; height: 32; radius: 9; color: themeHub.weatherMinimal ? themeHub.accentA : themeHub.accentB; border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: themeHub.weatherMinimal ? "WX: MINIMAL" : "WX: CLASSIC"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWeatherMinimal(!themeHub.weatherMinimal) }
                                        }
                                        Rectangle {
                                            width: 82; height: 32; radius: 9; color: "#F1F5F9"; border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: themeHub.weatherView === "days" ? "3-DAY" : "HOURLY"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWeatherView(themeHub.weatherView === "days" ? "hourly" : "days") }
                                        }
                                    }
                                }
                            }

                            // Card 3: Visualizer Quick Controls
                            SekaiPill {
                                width: 204; height: 118; radius: 16; color: "#FFFFFF"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 7
                                    Text { text: "AUDIO VISUALIZER"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Rectangle {
                                        width: parent.width; height: 32; radius: 9
                                        color: VisualizerService.enabled ? themeHub.accentA : "#F1F5F9"
                                        border.width: 1.5; border.color: themeHub.darkInk
                                        Text { anchors.centerIn: parent; text: "Visualizer: " + (VisualizerService.enabled ? "ON" : "OFF"); font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: VisualizerService.enabled = !VisualizerService.enabled }
                                    }
                                    Row {
                                        spacing: 6
                                        Rectangle {
                                            width: 116; height: 32; radius: 9; color: themeHub.accentB; border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: VisualizerService.style.toUpperCase() + " ↻"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    const order = ["tide", "ribbons", "aurora", "pulse", "scope", "mirror", "ring", "dots", "sekai", "bars", "wave"]
                                                    const i = order.indexOf(VisualizerService.style)
                                                    VisualizerService.style = order[(i + 1) % order.length]
                                                }
                                            }
                                        }
                                        Rectangle {
                                            width: 62; height: 32; radius: 9; color: "#F1F5F9"; border.width: 1.5; border.color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: ["S", "M", "L", "XL"][Math.max(0, Math.min(3, VisualizerService.sizeIndex))]; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: VisualizerService.cycleSize() }
                                        }
                                    }
                                }
                            }

                            // Card 4: Wallpapers & Full Settings Jumps
                            SekaiPill {
                                width: 196; height: 118; radius: 16; color: "#FFF8F0"; inkColor: themeHub.darkInk; borderWidth: 2; shadowShift: 3; showInnerRing: false
                                Column {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    Text { text: "STUDIO JUMPS"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#64748B" }
                                    Rectangle {
                                        width: parent.width; height: 34; radius: 10
                                        color: wpJumpMa.containsMouse ? themeHub.accentA : themeHub.accentB
                                        border.width: 2; border.color: themeHub.darkInk
                                        Text { anchors.centerIn: parent; text: "🖼 Wallpapers"; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                                        MouseArea {
                                            id: wpJumpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                widgetsRoot.themeHub.setEditMode(false)
                                                widgetsRoot.themeHub.wallpaperSelectorOpen = true
                                            }
                                        }
                                    }
                                    Rectangle {
                                        width: parent.width; height: 34; radius: 10
                                        color: setJumpMa.containsMouse ? themeHub.hoverTint : "#FFFFFF"
                                        border.width: 2; border.color: themeHub.darkInk
                                        Text { anchors.centerIn: parent; text: "⚙ Full Settings"; font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.darkInk }
                                        MouseArea {
                                            id: setJumpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                widgetsRoot.themeHub.setEditMode(false)
                                                widgetsRoot.themeHub.openSettings("")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // =========================================================
                    // TAB 5: THEMES (7 Units + Wallpaper Match + OS Dark/Light)
                    // =========================================================
                    Flickable {
                        visible: widgetsRoot.themeHub.editTab === "themes" || widgetsRoot.themeHub.editTab === "theme"
                        anchors.fill: parent
                        contentWidth: themeSlotsRow.implicitWidth + 12
                        contentHeight: height
                        clip: true

                        Row {
                            id: themeSlotsRow
                            spacing: 10
                            y: 6

                            // Wallpaper Match Tile
                            Item {
                                id: wallMatchTile
                                width: 124; height: 112
                                readonly property bool active: widgetsRoot.themeHub.useCustomPalette
                                readonly property var previewPal: WallpaperService.currentWallpaper !== ""
                                    ? WallpaperService.extractPalette(WallpaperService.currentWallpaper)
                                    : ({ accentA: themeHub.customAccentA, accentB: themeHub.customAccentB })

                                Rectangle { x: 3; y: 3; width: parent.width - 3; height: parent.height - 3; radius: 14; color: themeHub.darkInk }
                                Rectangle {
                                    width: parent.width - 3; height: parent.height - 3; radius: 14
                                    color: wallMatchTile.active ? "#ECFEFF" : (wmTileMa.containsMouse ? "#F8FAFC" : "#FFFFFF")
                                    border.width: wallMatchTile.active ? 3 : 2; border.color: themeHub.darkInk

                                    Rectangle {
                                        x: 8; y: 8; width: parent.width - 16; height: 46; radius: 10
                                        border.width: 2; border.color: themeHub.darkInk
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: wallMatchTile.previewPal.accentA || themeHub.customAccentA }
                                            GradientStop { position: 1.0; color: wallMatchTile.previewPal.accentB || themeHub.customAccentB }
                                        }
                                        Text { anchors.centerIn: parent; text: "WALL"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                    }
                                    Text {
                                        x: 8; y: 60; width: parent.width - 16; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                                        text: "Wallpaper Match"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk
                                    }
                                    Rectangle {
                                        visible: wallMatchTile.active
                                        anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 6
                                        width: 50; height: 16; radius: 8; color: themeHub.darkInk
                                        Text { anchors.centerIn: parent; text: "ACTIVE"; font.pixelSize: 8; font.weight: Font.Black; color: themeHub.accentA }
                                    }
                                    MouseArea {
                                        id: wmTileMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const pal = WallpaperService.extractCurrentPalette()
                                            if (WallpaperService.currentWallpaper !== "" && pal && pal.accentA) {
                                                widgetsRoot.themeHub.applyWallpaperPalette(pal)
                                            } else {
                                                widgetsRoot.themeHub.setEditMode(false)
                                                widgetsRoot.themeHub.wallpaperSelectorOpen = true
                                            }
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: widgetsRoot.themeHub.bands
                                delegate: Item {
                                    id: bandTile
                                    required property var modelData
                                    readonly property bool active: !widgetsRoot.themeHub.useCustomPalette && widgetsRoot.themeHub.bandId === modelData.id
                                    width: 112; height: 112

                                    Rectangle {
                                        x: 3; y: 3
                                        width: parent.width - 3; height: parent.height - 3
                                        radius: 14; color: themeHub.darkInk
                                    }
                                    Rectangle {
                                        width: parent.width - 3; height: parent.height - 3
                                        radius: 14
                                        color: bandTile.active ? modelData.hoverTint : (tMa.containsMouse ? "#F8FAFC" : "#FFFFFF")
                                        border.width: bandTile.active ? 3 : 2
                                        border.color: themeHub.darkInk

                                        Rectangle {
                                            x: 8; y: 8; width: parent.width - 16; height: 46; radius: 10
                                            border.width: 2; border.color: themeHub.darkInk
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: modelData.A }
                                                GradientStop { position: 1.0; color: modelData.B }
                                            }
                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData.shortName
                                                font.pixelSize: 13; font.weight: Font.Black
                                                color: themeHub.darkInk
                                            }
                                        }

                                        Text {
                                            x: 8; y: 60; width: parent.width - 16
                                            elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignHCenter
                                            text: modelData.name
                                            font.pixelSize: 10; font.weight: Font.Bold
                                            color: themeHub.darkInk
                                        }

                                        Rectangle {
                                            visible: bandTile.active
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            anchors.bottom: parent.bottom; anchors.bottomMargin: 6
                                            width: 48; height: 16; radius: 8
                                            color: themeHub.darkInk
                                            Text { anchors.centerIn: parent; text: "ACTIVE"; font.pixelSize: 8; font.weight: Font.Black; color: modelData.A }
                                        }

                                        MouseArea {
                                            id: tMa
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: widgetsRoot.themeHub.setBand(modelData.id)
                                        }
                                    }
                                }
                            }

                            // OS Dark / Light Mode card
                            Item {
                                width: 108; height: 112
                                Rectangle { x: 3; y: 3; width: 105; height: 109; radius: 14; color: themeHub.darkInk }
                                Rectangle {
                                    width: 105; height: 109; radius: 14
                                    color: SystemControl.darkMode ? "#1E2238" : "#FFFDF9"
                                    border.width: 2.5; border.color: themeHub.darkInk
                                    Column {
                                        anchors.centerIn: parent; spacing: 6
                                        Image {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 24; height: 24; sourceSize.width: 48; sourceSize.height: 48; smooth: true
                                            source: SystemControl.darkMode ? "qrc:/qml/icons/sun-dark.svg" : "qrc:/qml/icons/moon-dark.svg"
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: SystemControl.darkMode ? "OS: DARK" : "OS: LIGHT"
                                            font.pixelSize: 10; font.weight: Font.Black
                                            color: SystemControl.darkMode ? "#FFFFFF" : themeHub.darkInk
                                        }
                                    }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: SystemControl.toggleDarkMode() }
                                }
                            }
                        }
                    }

                    // =========================================================
                    // TAB 6: PRESETS (Save Look, Undo, Star, 1-Click Apply, 2-Click Delete)
                    // =========================================================
                    Flickable {
                        visible: widgetsRoot.themeHub.editTab === "presets"
                        anchors.fill: parent
                        contentWidth: presetsTabRow.implicitWidth + 12
                        contentHeight: height
                        clip: true

                        Row {
                            id: presetsTabRow
                            spacing: 10
                            y: 6

                            // Tile 1: Save This Look
                            Item {
                                width: 150; height: 114
                                Rectangle { x: 3; y: 3; width: 147; height: 111; radius: 14; color: themeHub.darkInk }
                                Rectangle {
                                    width: 147; height: 111; radius: 14
                                    color: saveLookMa.containsMouse && !editTrayWin.namingPreset ? themeHub.hoverTint : "#FFFFFF"
                                    border.width: 2.5; border.color: themeHub.darkInk

                                    Column {
                                        visible: !editTrayWin.namingPreset
                                        anchors.centerIn: parent; spacing: 6
                                        Rectangle {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 34; height: 34; radius: 17
                                            border.width: 2; border.color: themeHub.darkInk
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: themeHub.accentB }
                                                GradientStop { position: 1.0; color: themeHub.accentA }
                                            }
                                            Text { anchors.centerIn: parent; text: "+"; font.pixelSize: 20; font.weight: Font.Black; color: themeHub.darkInk }
                                        }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "SAVE THIS LOOK"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Click to name"; font.family: "Segoe UI"; font.pixelSize: 9; color: "#64748B" }
                                    }

                                    Column {
                                        visible: editTrayWin.namingPreset
                                        anchors.fill: parent; anchors.margins: 10; spacing: 7
                                        Text { text: "PRESET NAME"; font.family: "Segoe UI"; font.pixelSize: 9; font.weight: Font.Black; color: "#64748B" }
                                        Rectangle {
                                            width: parent.width; height: 32; radius: 8
                                            color: "#F8FAFC"; border.width: 2; border.color: themeHub.darkInk
                                            TextInput {
                                                id: presetNameInput
                                                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                                verticalAlignment: TextInput.AlignVCenter
                                                font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: themeHub.darkInk
                                                clip: true
                                                function commitPreset() {
                                                    const nm = text.trim() || ("Look " + (editTrayWin.presetsList.length + 1))
                                                    ConfigStore.savePreset(nm, widgetsRoot.themeHub.captureLookMap(), false)
                                                    editTrayWin.namingPreset = false
                                                    editTrayWin.refreshPresets()
                                                    editEscScope.forceActiveFocus()
                                                }
                                                onAccepted: commitPreset()
                                                Keys.onEscapePressed: {
                                                    editTrayWin.namingPreset = false
                                                    editEscScope.forceActiveFocus()
                                                }
                                            }
                                        }
                                        Row {
                                            spacing: 6; width: parent.width
                                            Rectangle {
                                                width: 60; height: 26; radius: 8; color: themeHub.accentA; border.width: 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: "Save"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: presetNameInput.commitPreset() }
                                            }
                                            Rectangle {
                                                width: 60; height: 26; radius: 8; color: "#F1F5F9"; border.width: 1.5; border.color: themeHub.darkInk
                                                Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 10; font.weight: Font.Bold; color: themeHub.darkInk }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { editTrayWin.namingPreset = false; editEscScope.forceActiveFocus() }
                                                }
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: saveLookMa
                                        enabled: !editTrayWin.namingPreset
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            editTrayWin.namingPreset = true
                                            presetNameInput.text = "Look " + (editTrayWin.presetsList.length + 1)
                                            Qt.callLater(function() {
                                                presetNameInput.forceActiveFocus()
                                                presetNameInput.selectAll()
                                            })
                                        }
                                    }
                                }
                            }

                            // Tile 2: Undo Look (shown when .previous exists)
                            Item {
                                visible: editTrayWin.hasPreviousPreset
                                width: 112; height: 114
                                Rectangle { x: 3; y: 3; width: 109; height: 111; radius: 14; color: themeHub.darkInk }
                                Rectangle {
                                    width: 109; height: 111; radius: 14
                                    color: undoMa.containsMouse ? "#FEF3C7" : "#FFFBEB"
                                    border.width: 2.5; border.color: themeHub.darkInk
                                    Column {
                                        anchors.centerIn: parent; spacing: 6
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "↶"; font.pixelSize: 24; font.weight: Font.Black; color: "#D97706" }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "UNDO LOOK"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.darkInk }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Restore prev"; font.family: "Segoe UI"; font.pixelSize: 9; color: "#64748B" }
                                    }
                                    MouseArea {
                                        id: undoMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const prev = ConfigStore.loadPreset(".previous")
                                            if (prev && Object.keys(prev).length > 0) {
                                                ConfigStore.savePreset(".previous", widgetsRoot.themeHub.captureLookMap(), false)
                                                widgetsRoot.themeHub.applyLookMap(prev)
                                                editTrayWin.refreshPresets()
                                            }
                                        }
                                    }
                                }
                            }

                            // Saved Preset Cards
                            Repeater {
                                model: editTrayWin.presetsList
                                delegate: Item {
                                    id: presetCard
                                    required property var modelData
                                    readonly property bool delPending: editTrayWin.deleteConfirmPreset === modelData.name

                                    width: 148; height: 114
                                    Rectangle { x: 3; y: 3; width: 145; height: 111; radius: 14; color: themeHub.darkInk }
                                    Rectangle {
                                        width: 145; height: 111; radius: 14
                                        color: presetCard.delPending ? "#FFE4E6" : (prMa.containsMouse ? "#F8FAFC" : "#FFFFFF")
                                        border.width: 2.5; border.color: themeHub.darkInk

                                        // Accent / Wallpaper Banner Strip
                                        Rectangle {
                                            x: 8; y: 8; width: parent.width - 16; height: 50; radius: 9
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            clip: true
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: presetCard.modelData.accentA || themeHub.accentA }
                                                GradientStop { position: 1.0; color: presetCard.modelData.accentB || themeHub.accentB }
                                            }
                                            Image {
                                                anchors.fill: parent
                                                source: presetCard.modelData.wallpaper ? ("file:///" + String(presetCard.modelData.wallpaper).replace(/\\/g, "/")) : ""
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                sourceSize.width: 200
                                                visible: status === Image.Ready
                                            }
                                        }

                                        Text {
                                            x: 8; y: 64; width: parent.width - 16; elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignHCenter
                                            text: presetCard.delPending ? "Right-click to delete" : (presetCard.modelData.name || "Preset")
                                            font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black
                                            color: presetCard.delPending ? "#DC2626" : themeHub.darkInk
                                        }

                                        Text {
                                            x: 8; y: 84; width: parent.width - 16; horizontalAlignment: Text.AlignHCenter
                                            text: presetCard.delPending ? "Confirm delete ×" : "L: Apply · R: Delete"
                                            font.family: "Segoe UI"; font.pixelSize: 9; color: "#64748B"
                                        }

                                        MouseArea {
                                            id: prMa; anchors.fill: parent; hoverEnabled: true
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: mouse => {
                                                if (mouse.button === Qt.RightButton) {
                                                    if (editTrayWin.deleteConfirmPreset === presetCard.modelData.name) {
                                                        ConfigStore.deletePreset(presetCard.modelData.name)
                                                        editTrayWin.refreshPresets()
                                                    } else {
                                                        editTrayWin.deleteConfirmPreset = presetCard.modelData.name
                                                    }
                                                } else {
                                                    editTrayWin.deleteConfirmPreset = ""
                                                    ConfigStore.savePreset(".previous", widgetsRoot.themeHub.captureLookMap(), false)
                                                    const loaded = ConfigStore.loadPreset(presetCard.modelData.name)
                                                    widgetsRoot.themeHub.applyLookMap(loaded)
                                                    editTrayWin.refreshPresets()
                                                }
                                            }
                                        }

                                        // Favorite Star Toggle Badge
                                        Rectangle {
                                            x: 4; y: 4; width: 24; height: 24; radius: 12
                                            color: presetCard.modelData.favorite ? "#FFD166" : "#FFFFFF"
                                            border.width: 1.5; border.color: themeHub.darkInk
                                            z: 5
                                            Text {
                                                anchors.centerIn: parent
                                                text: presetCard.modelData.favorite ? "★" : "☆"
                                                font.pixelSize: 12; font.weight: Font.Black
                                                color: themeHub.darkInk
                                            }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    ConfigStore.togglePresetFavorite(presetCard.modelData.name)
                                                    editTrayWin.refreshPresets()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Decorative SekaiPop Washi Tape Strips overlapping top corners
            Rectangle {
                x: 24
                y: 2
                width: 68
                height: 16
                radius: 3
                rotation: -11
                color: themeHub.accentB
                opacity: 0.88
                border.width: 1.5
                border.color: themeHub.darkInk
                antialiasing: true
            }
            Rectangle {
                x: parent.width - 96
                y: 2
                width: 68
                height: 16
                radius: 3
                rotation: 10
                color: themeHub.accentA
                opacity: 0.88
                border.width: 1.5
                border.color: themeHub.darkInk
                antialiasing: true
            }
        }
    }
}
