import QtQuick
import QtQuick.Effects
import QtQuick.Window
import Quickshell
import SekaiDesk

// ===========================================================================
// PHASE 1c — Live DWM Window Thumbnails + Zero-Churn Cosine Magnification
//
// - Fixed-width PanelWindow during hover sweep: zero SetWindowPos / SetWindowRgn
//   churn on mouse move (CPU & DWM stay flat).
// - Clamped Cosine Magnification Wave (48px -> 82px keycaps).
// - Live DWM 60fps Window Preview popup when hovering any running app.
// ===========================================================================

PanelWindow {
    id: dockWindow
    visible: !GameModeService.active
    acceptFileDrops: true
    property bool dropFlash: false

    Timer {
        id: dropFlashTimer
        interval: 450
        repeat: false
        onTriggered: dockWindow.dropFlash = false
    }

    onFilesDropped: files => {
        const list = files
        Qt.callLater(() => {
            const added = AppLauncher.pinDroppedFiles(list)
            if (added > 0) {
                dockWindow.dropFlash = true
                dropFlashTimer.restart()
            }
        })
    }

    readonly property bool needsEdgePolling: themeHub.dockAutoHide || themeHub.barAutoHide
    onNeedsEdgePollingChanged: WindowTracker.setEdgePollingNeeded(needsEdgePolling)
    Component.onCompleted: WindowTracker.setEdgePollingNeeded(needsEdgePolling)

    readonly property string edge: themeHub.dockEdge
    readonly property bool isVertical: themeHub.dockVertical
    readonly property bool isTop: edge === "top"
    readonly property bool isBottom: edge === "bottom"
    readonly property bool isLeft: edge === "left"
    readonly property bool isRight: edge === "right"
    readonly property bool isCapsule: themeHub.dockStyle === "capsule"
    readonly property bool isTransparent: themeHub.dockStyle === "transparent"
    readonly property bool circleIcons: themeHub.dockIconShape === "circle"
        || (themeHub.dockIconShape === "auto" && isCapsule)

    readonly property int baseTileSize: themeHub.dockTileSize
    readonly property int maxTileSize: themeHub.dockMagnify ? Math.round(themeHub.dockTileSize * 1.65) : themeHub.dockTileSize
    readonly property int baseIconSize: Math.round(baseTileSize * 0.72)
    readonly property int maxIconSize: Math.round(maxTileSize * 0.78)
    readonly property int tileGap: isCapsule ? 7 : 8
    readonly property int pillMainPad: isCapsule ? 12 : 14
    readonly property int pillCrossPad: isCapsule ? 9 : 10
    readonly property int maxPillCross: baseTileSize + pillCrossPad * 2
    readonly property int mediaTileExtent: isVertical ? baseTileSize : Math.max(248, Math.round(baseTileSize * 5.4))
    readonly property int dividerExtent: 4
    readonly property int shadowOffset: isTransparent ? 0 : (isCapsule ? 3 : 4)
    readonly property int headroom: Math.max(14, maxTileSize - baseTileSize + 14)
    readonly property int hoverPadMain: 96
    readonly property int baseMargin: 10
    readonly property int sameEdgeBarClearance: (themeHub.barEdge === dockWindow.edge && !themeHub.barAutoHide && !topBarWindow.fullscreenActive)
        ? (themeHub.barStripThickness + 6)
        : 0

    readonly property real waveRadius: 128.0
    property bool dockHovered: pillHover.hovered
    property real pointerAxis: 0
    property real waveStrength: (dockHovered && dragFromSlot < 0) ? 1.0 : 0.0

    Item {
        id: screenMetrics
        visible: false
    }

    ThemeHub {
        id: themeHub
        screenW: screenMetrics.Screen.width > 0 ? screenMetrics.Screen.width : 1920
        screenH: screenMetrics.Screen.height > 0 ? screenMetrics.Screen.height : 1080
    }

    // Phase 3: Dock Auto-Hide / Dodge Active Window across all 4 edges (plus unconditional fullscreen hide)
    property bool dockAutoHideEnabled: themeHub.dockAutoHide
    readonly property bool dockEdgeOverlap: isTop ? WindowTracker.topOverlap
        : (isLeft ? WindowTracker.leftOverlap
            : (isRight ? WindowTracker.rightOverlap : WindowTracker.dockOverlap))
    readonly property bool dockEdgeHovered: isTop ? WindowTracker.topEdgeHovered
        : (isLeft ? WindowTracker.leftEdgeHovered
            : (isRight ? WindowTracker.rightEdgeHovered : WindowTracker.bottomEdgeHovered))
    readonly property bool barHoverWakesDock: themeHub.barEdge === dockWindow.edge
        && !themeHub.barAutoHide
        && topBarHover.hovered
    readonly property bool dockShouldHide: topBarWindow.fullscreenActive
        || (dockAutoHideEnabled
            && dockEdgeOverlap
            && !dockEdgeHovered
            && !dockHovered
            && !barHoverWakesDock
            && dragFromSlot < 0
            && !ctxOpen
            && !dockExtraCards.timerOpen
            && !dockExtraCards.filesOpen
            && activePreviewTarget === ""
            && !previewCardHovered)
    property real hideProgress: dockShouldHide ? 1.0 : 0.0
    Behavior on hideProgress {
        NumberAnimation {
            duration: 220
            easing.type: dockWindow.dockShouldHide ? Easing.InCubic : Easing.OutCubic
        }
    }
    property real presetSlide: 0
    NumberAnimation {
        id: dockPresetOut
        target: dockWindow
        property: "presetSlide"
        to: 1.0
        duration: themeHub.motionOutMs
        easing.type: Easing.InCubic
    }
    NumberAnimation {
        id: dockPresetIn
        target: dockWindow
        property: "presetSlide"
        to: 0.0
        duration: themeHub.motionInMs
        easing.type: Easing.OutBack
        easing.overshoot: 1.1
    }
    Connections {
        target: themeHub
        function onMotionDockOutChanged() {
            if (themeHub.motionDockOut) {
                dockPresetIn.stop()
                dockPresetOut.restart()
            } else {
                dockPresetOut.stop()
                dockPresetIn.restart()
            }
        }
    }
    readonly property real effectiveHideProgress: Math.max(hideProgress, presetSlide)
    readonly property real hideTravel: maxPillCross + baseMargin + sameEdgeBarClearance + shadowOffset + 16
    readonly property real hideOffsetX: isLeft ? (-effectiveHideProgress * hideTravel) : (isRight ? (effectiveHideProgress * hideTravel) : 0)
    readonly property real hideOffsetY: isTop ? (-effectiveHideProgress * hideTravel) : (isBottom ? (effectiveHideProgress * hideTravel) : 0)

    // Preview state for Phase 1c
    property string hoveredAppTarget: ""
    property string hoveredAppName: ""
    property real hoveredIconGlobalX: 0
    property real hoveredIconGlobalY: 0
    property string activePreviewTarget: ""
    property string activePreviewName: ""
    property var activePreviewWindows: []
    property bool previewCardHovered: false

    // Phase 2: Right-click context menu state
    property bool ctxOpen: false
    property string ctxTarget: ""
    property string ctxName: ""
    property string ctxArgs: ""
    property bool ctxPinned: false
    property bool ctxRunning: false
    property bool ctxIsSeparator: false
    property int ctxPinnedIndex: -1
    property real ctxGlobalX: 0
    property real ctxGlobalY: 0

    // Phase 2b: Smooth unified drag-to-reorder across the app row/column
    property int dragFromSlot: -1
    property int dragHoverSlot: -1
    property real dragLivePos: 0
    property real dragGrabOffset: 24
    property real dragItemSize: 48
    property var frozenDockItems: null

    function appStartSlot() {
        const list = dockItems
        for (let i = 0; i < list.length; ++i) {
            if (list[i].kind === "app")
                return i
        }
        return -1
    }

    function appSlotCount() {
        const list = dockItems
        const start = appStartSlot()
        if (start < 0)
            return 0
        let count = 0
        for (let i = start; i < list.length; ++i) {
            if (list[i].kind === "app")
                count++
            else
                break
        }
        return count
    }

    function updateDragHover(curCenterRowPos) {
        const list = dockItems
        if (dragFromSlot < 0)
            return
        let bestIdx = dragFromSlot
        let bestDist = 1e9
        for (let i = 0; i < list.length; ++i) {
            if (list[i].kind !== "app")
                continue
            const offset = (layoutData.offsets && layoutData.offsets[i] !== undefined)
                ? layoutData.offsets[i]
                : (i * (baseTileSize + tileGap))
            const cx = offset + baseTileSize * 0.5
            const d = Math.abs(curCenterRowPos - cx)
            if (d < bestDist) {
                bestDist = d
                bestIdx = i
            }
        }
        dragHoverSlot = bestIdx
    }

    function finishDrag() {
        const from = dragFromSlot
        const to = dragHoverSlot
        const list = frozenDockItems || dockItems
        frozenDockItems = null
        dragFromSlot = -1
        dragHoverSlot = -1
        dragLivePos = 0
        if (from >= 0 && to >= 0 && from !== to) {
            let firstApp = -1
            const apps = []
            for (let i = 0; i < list.length; ++i) {
                const it = list[i]
                if (it.kind === "app") {
                    if (firstApp < 0)
                        firstApp = i
                    apps.push({
                        name: it.name || "App",
                        target: it.target || "",
                        args: it.args || "",
                        pinned: !!it.pinned
                    })
                }
            }
            if (firstApp >= 0) {
                const relFrom = from - firstApp
                const relTo = to - firstApp
                if (relFrom >= 0 && relFrom < apps.length && relTo >= 0 && relTo < apps.length && relFrom !== relTo)
                    AppLauncher.reorderDock(apps, relFrom, relTo)
            }
        }
    }

    Behavior on waveStrength {
        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }

    // SekaiPop order: [Tools] | [Pinned & Running Apps] | [Pin Toggle] | [Media Player]
    readonly property var dockItems: {
        const pinned = AppLauncher.pinnedApps || []
        const running = WindowTracker.runningApps || []
        const items = []
        const seenExe = {}

        if (themeHub.dockShowFinder)
            items.push({ kind: "finder", name: "Spotlight" })
        if (themeHub.dockShowClipboard)
            items.push({ kind: "clipboard", name: "Clipboard" })
        if (themeHub.dockShowDropShelf)
            items.push({ kind: "dropshelf", name: "Drop Shelf" })
        if (themeHub.dockShowTimer)
            items.push({ kind: "timer", name: "Timer" })
        if (themeHub.dockShowFiles)
            items.push({ kind: "files", name: "Files" })
        if (themeHub.dockShowTrash)
            items.push({ kind: "trash", name: "Trash" })

        const hasTools = items.length > 0

        function normKey(p) {
            return String(p || "").trim().replace(/\//g, "\\").toLowerCase()
        }

        const appItems = []
        for (let i = 0; i < pinned.length; ++i) {
            const p = pinned[i]
            if (p.kind === "separator")
                continue
            const k = normKey(p.target)
            if (k !== "")
                seenExe[k] = true
            const st = WindowTracker.stateForTarget(p.target || "")
            appItems.push({
                kind: "app",
                name: p.name || "",
                target: p.target || "",
                args: p.args || "",
                pinned: true,
                pinnedIndex: i,
                running: !!st.running,
                active: !!st.active,
                minimized: !!st.minimized,
                count: st.count || 0
            })
        }

        for (let j = 0; j < running.length; ++j) {
            const r = running[j]
            const rk = normKey(r.target)
            if (!seenExe[rk]) {
                appItems.push({
                    kind: "app",
                    name: r.name || "",
                    target: r.target || "",
                    args: "",
                    pinned: false,
                    running: true,
                    active: !!r.active,
                    minimized: !!r.minimized,
                    count: r.count || 1
                })
            }
        }

        if (hasTools && appItems.length > 0)
            items.push({ kind: "divider" })

        for (let a = 0; a < appItems.length; ++a)
            items.push(appItems[a])

        if (themeHub.dockShowMedia && MediaService.hasSession) {
            if (items.length > 0)
                items.push({ kind: "divider" })
            items.push({ kind: "media", name: "Media" })
        }

        return items
    }

    function isDockKeycapKind(k) {
        return k === "app" || k === "trash" || k === "finder" || k === "clipboard" || k === "dropshelf" || k === "timer" || k === "files" || (k === "media" && dockWindow.isVertical)
    }

    readonly property real idleTotalExtent: {
        const list = dockItems
        const n = list.length
        let bpos = 0
        for (let i = 0; i < n; ++i) {
            const it = list[i]
            const bw = isDockKeycapKind(it.kind)
                ? baseTileSize
                : (it.kind === "media" ? mediaTileExtent : dividerExtent)
            bpos += bw + (i < n - 1 ? tileGap : 0)
        }
        return Math.max(1, bpos)
    }

    // One-pass Cosine Magnification layout solver (shared main axis for Horizontal & Vertical)
    readonly property var layoutData: {
        const list = dockItems
        const n = list.length
        const baseCenters = []
        let bpos = 0
        for (let i = 0; i < n; ++i) {
            const it = list[i]
            const bw = isDockKeycapKind(it.kind)
                ? baseTileSize
                : (it.kind === "media" ? mediaTileExtent : dividerExtent)
            baseCenters.push(bpos + bw * 0.5)
            bpos += bw + (i < n - 1 ? tileGap : 0)
        }

        const sizes = []
        const offsets = []
        const weights = []
        let cpos = 0
        for (let i = 0; i < n; ++i) {
            const it = list[i]
            let w = 0.0
            if (themeHub.dockMagnify && isDockKeycapKind(it.kind) && waveStrength > 0.001) {
                const dist = Math.abs(pointerAxis - baseCenters[i])
                if (dist < waveRadius) {
                    w = 0.5 * (1.0 + Math.cos(Math.PI * dist / waveRadius)) * waveStrength
                }
            }
            weights.push(w)
            const curS = isDockKeycapKind(it.kind)
                ? (baseTileSize + (maxTileSize - baseTileSize) * w)
                : (it.kind === "media" ? mediaTileExtent : dividerExtent)
            sizes.push(curS)
            offsets.push(cpos)
            cpos += curS + (i < n - 1 ? tileGap : 0)
        }

        return {
            totalExtent: Math.max(1, cpos),
            offsets: offsets,
            sizes: sizes,
            weights: weights
        }
    }

    // Fixed window extent so mouse sweep NEVER calls SetWindowPos or SetWindowRgn.
    width: isVertical
        ? (headroom + maxPillCross + shadowOffset)
        : (idleTotalExtent + pillMainPad * 2 + hoverPadMain + shadowOffset)
    height: isVertical
        ? (idleTotalExtent + pillMainPad * 2 + hoverPadMain + shadowOffset)
        : (headroom + maxPillCross + shadowOffset)

    anchors.left: isLeft
    anchors.right: isRight
    anchors.top: isTop
    anchors.bottom: isBottom
    anchors.margins.left: isLeft ? (baseMargin + sameEdgeBarClearance) : 0
    anchors.margins.right: isRight ? (baseMargin + sameEdgeBarClearance) : 0
    anchors.margins.top: isTop ? (baseMargin + sameEdgeBarClearance) : 0
    anchors.margins.bottom: isBottom ? (baseMargin + sameEdgeBarClearance) : 0
    clickThrough: topBarWindow.fullscreenActive || dockWindow.hideProgress > 0.5

    // When hidden (or fullscreen active), mask is empty (100% click-through). When idle, mask strictly to the static idle pill rect;
    // when hovered, use a static full-window mask so SetWindowRgn is NOT called per mouse pixel.
    mask: topBarWindow.fullscreenActive
        ? []
        : (dockWindow.hideProgress > 0.95
            ? []
            : (dockWindow.dockHovered || dockWindow.waveStrength > 0.02
                ? [{ x: 0, y: 0, width: dockWindow.width, height: dockWindow.height }]
                : (dockWindow.isVertical
                    ? [{
                        x: dockWindow.isLeft ? 0 : dockWindow.headroom,
                        y: (dockWindow.height - dockWindow.shadowOffset - (dockWindow.idleTotalExtent + dockWindow.pillMainPad * 2)) * 0.5,
                        width: dockWindow.maxPillCross + dockWindow.shadowOffset,
                        height: dockWindow.idleTotalExtent + dockWindow.pillMainPad * 2 + dockWindow.shadowOffset
                    }]
                    : [{
                        x: (dockWindow.width - dockWindow.shadowOffset - (dockWindow.idleTotalExtent + dockWindow.pillMainPad * 2)) * 0.5,
                        y: dockWindow.isTop ? 0 : dockWindow.headroom,
                        width: dockWindow.idleTotalExtent + dockWindow.pillMainPad * 2 + dockWindow.shadowOffset,
                        height: dockWindow.maxPillCross + dockWindow.shadowOffset
                    }])))

    Timer {
        id: previewShowTimer
        interval: 140
        repeat: false
        onTriggered: {
            if (dockWindow.hoveredAppTarget !== "") {
                const wins = WindowTracker.windowsForTarget(dockWindow.hoveredAppTarget)
                if (wins && wins.length > 0) {
                    dockWindow.activePreviewTarget = dockWindow.hoveredAppTarget
                    dockWindow.activePreviewName = dockWindow.hoveredAppName
                    dockWindow.activePreviewWindows = wins
                }
            }
        }
    }

    Timer {
        id: previewHideTimer
        interval: 200
        repeat: false
        onTriggered: {
            if (dockWindow.hoveredAppTarget === "" && !dockWindow.previewCardHovered) {
                dockWindow.activePreviewTarget = ""
                dockWindow.activePreviewWindows = []
            }
        }
    }

    function refreshPreviewIfOpen() {
        if (dockWindow.activePreviewTarget !== "") {
            const wins = WindowTracker.windowsForTarget(dockWindow.activePreviewTarget)
            if (!wins || wins.length === 0) {
                dockWindow.activePreviewTarget = ""
                dockWindow.activePreviewWindows = []
            } else {
                dockWindow.activePreviewWindows = wins
            }
        }
    }

    Connections {
        target: WindowTracker
        function onRunningAppsChanged() {
            dockWindow.refreshPreviewIfOpen()
        }
    }

    // Hard flat offset shadow
    Rectangle {
        visible: !dockWindow.isTransparent
        x: dockPill.x + dockWindow.shadowOffset
        y: dockPill.y + dockWindow.shadowOffset
        width: dockPill.width
        height: dockPill.height
        radius: dockPill.radius
        color: dockWindow.isCapsule ? themeHub.barShadeColor : "#1A1B2E"
    }

    // Main Dock Pill (centered in fixed dockWindow)
    Rectangle {
        id: dockPill
        x: (dockWindow.isVertical
                ? (dockWindow.isLeft ? 0 : dockWindow.headroom)
                : ((dockWindow.width - dockWindow.shadowOffset - width) * 0.5))
            + dockWindow.hideOffsetX
        y: (dockWindow.isVertical
                ? ((dockWindow.height - dockWindow.shadowOffset - height) * 0.5)
                : (dockWindow.isTop ? 0 : dockWindow.headroom))
            + dockWindow.hideOffsetY
        width: dockWindow.isVertical
            ? dockWindow.maxPillCross
            : (dockWindow.layoutData.totalExtent + dockWindow.pillMainPad * 2)
        height: dockWindow.isVertical
            ? (dockWindow.layoutData.totalExtent + dockWindow.pillMainPad * 2)
            : dockWindow.maxPillCross
        radius: dockWindow.isCapsule
            ? Math.round(Math.min(width, height) * 0.5)
            : 20
        Behavior on radius {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        color: dockWindow.isTransparent
            ? "transparent"
            : (dockWindow.isCapsule ? themeHub.barBodyColor : "#1A1B2E")
        border.width: dockWindow.isCapsule ? 2.5 : 0
        border.color: dockWindow.isCapsule ? themeHub.barRimColor : "transparent"

        // White inner ring (Float sticker style only)
        Rectangle {
            visible: !dockWindow.isTransparent && !dockWindow.isCapsule
            anchors.fill: parent
            anchors.margins: 2.5
            radius: Math.max(4, parent.radius - 2.5)
            color: "#FFFFFF"

            // Pastel body fill
            Rectangle {
                anchors.fill: parent
                anchors.margins: 3
                radius: Math.max(4, parent.radius - 3)
                color: "#F1F5FF"
            }
        }

        HoverHandler {
            id: pillHover
            onPointChanged: {
                // Map pointer relative to idle row/col center so wave centers stay stable
                if (dockWindow.isVertical) {
                    const idleTop = (dockPill.height - dockWindow.idleTotalExtent) * 0.5
                    dockWindow.pointerAxis = point.position.y - idleTop
                } else {
                    const idleLeft = (dockPill.width - dockWindow.idleTotalExtent) * 0.5
                    dockWindow.pointerAxis = point.position.x - idleLeft
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: dockPill.radius
            color: "transparent"
            border.width: dockWindow.dropFlash ? 3.5 : 0
            border.color: themeHub.accentB
            opacity: dockWindow.dropFlash ? 1.0 : 0.0
            z: 200
            antialiasing: true
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }

        Item {
            id: dockRow
            x: dockWindow.isVertical ? dockWindow.pillCrossPad : dockWindow.pillMainPad
            y: dockWindow.isVertical ? dockWindow.pillMainPad : dockWindow.pillCrossPad
            width: dockWindow.isVertical ? dockWindow.baseTileSize : dockWindow.layoutData.totalExtent
            height: dockWindow.isVertical ? dockWindow.layoutData.totalExtent : dockWindow.baseTileSize

            Repeater {
                model: (dockWindow.dragFromSlot >= 0 && dockWindow.frozenDockItems)
                    ? dockWindow.frozenDockItems
                    : dockWindow.dockItems

                delegate: Item {
                    id: slot
                    required property var modelData
                    required property int index

                    Component.onDestruction: {
                        if (isDraggingThis) {
                            dockWindow.frozenDockItems = null
                            dockWindow.dragFromSlot = -1
                            dockWindow.dragHoverSlot = -1
                            dockWindow.dragLivePos = 0
                        }
                    }

                    readonly property real wFactor: dockWindow.layoutData.weights[index] || 0
                    readonly property real slotSize: dockWindow.layoutData.sizes[index] || dockWindow.baseTileSize
                    readonly property real slotPos: dockWindow.layoutData.offsets[index] || 0
                    readonly property bool isAppItem: modelData.kind === "app"
                    readonly property int pIdx: (modelData.pinned && modelData.pinnedIndex !== undefined)
                        ? modelData.pinnedIndex : -1
                    readonly property bool isDraggingThis: isAppItem && dockWindow.dragFromSlot >= 0 && index === dockWindow.dragFromSlot
                    property real dragShift: {
                        const from = dockWindow.dragFromSlot
                        const to = dockWindow.dragHoverSlot
                        if (from < 0 || !isAppItem || isDraggingThis)
                            return 0
                        const step = dockWindow.baseTileSize + dockWindow.tileGap
                        if (from < to && index > from && index <= to)
                            return -step
                        if (from > to && index < from && index >= to)
                            return step
                        return 0
                    }

                    Behavior on dragShift {
                        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
                    }
                    Behavior on scale {
                        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                    }

                    z: isDraggingThis ? 100 : 1
                    scale: isDraggingThis ? 1.12 : 1.0
                    x: dockWindow.isVertical
                        ? (isDraggingThis ? (dockWindow.isLeft ? 6 : -6) : 0)
                        : (isDraggingThis ? dockWindow.dragLivePos : (slotPos + dragShift))
                    y: dockWindow.isVertical
                        ? (isDraggingThis ? dockWindow.dragLivePos : (slotPos + dragShift))
                        : (isDraggingThis ? (dockWindow.isTop ? 6 : -6) : 0)
                    width: dockWindow.isVertical ? dockWindow.baseTileSize : slotSize
                    height: dockWindow.isVertical ? slotSize : dockWindow.baseTileSize

                    // --- App Keycap ---
                    Item {
                        id: appBox
                        visible: slot.modelData.kind === "app"
                        x: dockWindow.isRight ? (parent.width - width) : (dockWindow.isLeft ? 0 : (parent.width - width) * 0.5)
                        y: dockWindow.isBottom ? (parent.height - height) : (dockWindow.isTop ? 0 : (parent.height - height) * 0.5)
                        width: slot.slotSize
                        height: slot.slotSize

                        readonly property bool hovered: appArea.containsMouse
                        readonly property bool pressed: appArea.pressed
                        readonly property bool isLit: appBox.hovered || !!slot.modelData.active
                        readonly property bool unplugged: !slot.modelData.running && !appBox.hovered
                        readonly property real curIconSize: dockWindow.circleIcons
                            ? Math.round(slot.slotSize * 0.62)
                            : (dockWindow.baseIconSize + (dockWindow.maxIconSize - dockWindow.baseIconSize) * slot.wFactor)

                        onHoveredChanged: {
                            if (hovered && slot.modelData.running) {
                                dockWindow.hoveredAppTarget = slot.modelData.target || ""
                                dockWindow.hoveredAppName = slot.modelData.name || ""
                                dockWindow.hoveredIconGlobalX = dockWindow.x + dockPill.x
                                    + dockRow.x + slot.x + slot.width * 0.5
                                dockWindow.hoveredIconGlobalY = dockWindow.y + dockPill.y
                                    + dockRow.y + slot.y + slot.height * 0.5
                                previewHideTimer.stop()
                                previewShowTimer.restart()
                            } else if (!hovered && dockWindow.hoveredAppTarget === (slot.modelData.target || "")) {
                                dockWindow.hoveredAppTarget = ""
                                previewShowTimer.stop()
                                previewHideTimer.restart()
                            }
                        }

                        // Multi-window peeking sheets behind key (SekaiPop signature, square/keycap only)
                        Rectangle {
                            visible: !!slot.modelData.running && (slot.modelData.count || 0) > 2 && !dockWindow.circleIcons
                            x: -3
                            y: -2
                            width: keyCap.width
                            height: keyCap.height
                            radius: dockWindow.circleIcons ? Math.round(height * 0.5) : keyCap.radius
                            rotation: -9
                            color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"
                            border.width: 1.5
                            border.color: dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E"
                        }
                        Rectangle {
                            visible: !!slot.modelData.running && (slot.modelData.count || 0) > 1 && !dockWindow.circleIcons
                            x: 2
                            y: -3
                            width: keyCap.width
                            height: keyCap.height
                            radius: dockWindow.circleIcons ? Math.round(height * 0.5) : keyCap.radius
                            rotation: 7
                            color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"
                            border.width: 1.5
                            border.color: dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E"
                        }

                        // Keycap bottom lip (Float square keycap & SekaiPop 3D coin badge)
                        Rectangle {
                            visible: !dockWindow.isCapsule || dockWindow.circleIcons
                            anchors.fill: keyCap
                            anchors.topMargin: dockWindow.circleIcons ? 3 : 2.5
                            anchors.bottomMargin: dockWindow.circleIcons ? -3 : -2.5
                            radius: keyCap.radius
                            color: "#1A1B2E"
                            opacity: appBox.pressed ? 0.0 : (dockWindow.circleIcons ? 0.95 : 0.9)
                        }

                        Rectangle {
                            id: keyCap
                            width: parent.width
                            height: parent.height
                            x: appBox.pressed
                                ? (dockWindow.isLeft ? -2 : (dockWindow.isRight ? 2 : 0))
                                : (appBox.hovered ? (dockWindow.isLeft ? 2 : (dockWindow.isRight ? -2 : 0)) : 0)
                            y: appBox.pressed
                                ? (dockWindow.isTop ? -2 : (dockWindow.isBottom ? 2 : 0))
                                : (appBox.hovered ? (dockWindow.isTop ? 2 : (dockWindow.isBottom ? -2 : 0)) : 0)
                            radius: dockWindow.circleIcons
                                ? Math.round(Math.min(width, height) * 0.5)
                                : (13 + 5 * slot.wFactor)
                            color: dockWindow.isCapsule
                                ? (appBox.hovered ? themeHub.barChipHover : themeHub.barBodyColor)
                                : (appBox.hovered ? "#E0F2FE" : "#FFFFFF")
                            border.width: dockWindow.circleIcons
                                ? (appBox.isLit ? 3 : 2.5)
                                : (dockWindow.isCapsule ? (appBox.isLit ? 2.5 : 2) : 2)
                            border.color: dockWindow.circleIcons
                                ? (dockWindow.isCapsule && appBox.isLit ? themeHub.accentA : "#1A1B2E")
                                : (dockWindow.isCapsule
                                    ? (appBox.isLit ? themeHub.accentA : themeHub.barRimColor)
                                    : (appBox.isLit ? themeHub.accentA : "#1A1B2E"))

                            Item {
                                id: appIconBox
                                anchors.centerIn: parent
                                width: appBox.curIconSize
                                height: appBox.curIconSize

                                Image {
                                    anchors.fill: parent
                                    source: "image://winicon/" + encodeURIComponent(slot.modelData.target || "")
                                    sourceSize: Qt.size(dockWindow.maxIconSize * 2, dockWindow.maxIconSize * 2)
                                    smooth: true
                                    mipmap: true
                                    opacity: appBox.unplugged ? (dockWindow.circleIcons ? 0.72 : 0.65) : 1.0
                                }
                            }
                        }

                        // Running Dot (SekaiPop: pastel round dot in Capsule / Circle, diamond in Square Keycap)
                        Rectangle {
                            visible: !!slot.modelData.running
                            width: dockWindow.circleIcons ? (slot.modelData.active ? 7 : 5) : 6
                            height: width
                            rotation: dockWindow.circleIcons ? 0 : 45
                            radius: dockWindow.circleIcons ? Math.round(width * 0.5) : 1
                            x: dockWindow.isLeft
                                ? (dockWindow.isCapsule ? -7 : -5)
                                : (dockWindow.isRight ? (keyCap.width + (dockWindow.isCapsule ? 2 : -1)) : ((keyCap.width - width) * 0.5))
                            y: dockWindow.isBottom
                                ? (keyCap.height + (dockWindow.isCapsule ? 2 : -1))
                                : (dockWindow.isTop ? (dockWindow.isCapsule ? -7 : -5) : ((keyCap.height - height) * 0.5))
                            color: slot.modelData.minimized
                                ? "transparent"
                                : (dockWindow.isCapsule
                                    ? (slot.modelData.active ? themeHub.accentA : themeHub.accentB)
                                    : (slot.modelData.active ? "#06B6D4" : "#10B981"))
                            border.width: dockWindow.circleIcons ? (slot.modelData.minimized ? 1.5 : 0) : 1.5
                            border.color: dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E"
                            antialiasing: true
                        }

                        MouseArea {
                            id: appArea
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: slot.isDraggingThis ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                            property real pressGlobalMain: 0
                            property real grabRatio: 0.5
                            property bool didDrag: false

                            onPressed: (mouse) => {
                                didDrag = false
                                if (mouse.button === Qt.LeftButton) {
                                    const g = mapToGlobal(mouse.x, mouse.y)
                                    pressGlobalMain = dockWindow.isVertical ? g.y : g.x
                                    const localAxis = dockWindow.isVertical ? mouse.y : mouse.x
                                    grabRatio = Math.max(0.15, Math.min(0.85, localAxis / Math.max(1, slot.slotSize)))
                                }
                            }
                            onPositionChanged: (mouse) => {
                                if (!(mouse.buttons & Qt.LeftButton)) {
                                    if (didDrag || dockWindow.dragFromSlot >= 0) {
                                        didDrag = false
                                        Qt.callLater(dockWindow.finishDrag)
                                    }
                                    return
                                }
                                const g = mapToGlobal(mouse.x, mouse.y)
                                const globalMain = dockWindow.isVertical ? g.y : g.x
                                const delta = globalMain - pressGlobalMain
                                const rowLocal = dockRow.mapFromGlobal(g.x, g.y)
                                const rowMousePos = dockWindow.isVertical ? rowLocal.y : rowLocal.x
                                if (!didDrag && Math.abs(delta) > 6) {
                                    didDrag = true
                                    previewShowTimer.stop()
                                    dockWindow.activePreviewTarget = ""
                                    dockWindow.activePreviewWindows = []
                                    dockWindow.ctxOpen = false
                                    dockWindow.dragItemSize = dockWindow.baseTileSize
                                    dockWindow.dragGrabOffset = grabRatio * dockWindow.baseTileSize
                                    dockWindow.frozenDockItems = dockWindow.dockItems
                                    dockWindow.dragFromSlot = slot.index
                                    dockWindow.dragHoverSlot = slot.index
                                }
                                if (didDrag) {
                                    const firstIdx = dockWindow.appStartSlot()
                                    const maxApps = dockWindow.appSlotCount()
                                    const offs = dockWindow.layoutData.offsets || []
                                    const minPos = (firstIdx >= 0 && offs[firstIdx] !== undefined) ? (offs[firstIdx] - 8) : -8
                                    const lastIdx = firstIdx + Math.max(0, maxApps - 1)
                                    const maxPos = (lastIdx >= 0 && offs[lastIdx] !== undefined) ? (offs[lastIdx] + 8) : 0
                                    const rawPos = rowMousePos - dockWindow.dragGrabOffset
                                    dockWindow.dragLivePos = Math.max(minPos, Math.min(maxPos, rawPos))
                                    dockWindow.updateDragHover(dockWindow.dragLivePos + dockWindow.baseTileSize * 0.5)
                                }
                            }
                            onReleased: {
                                if (didDrag)
                                    Qt.callLater(dockWindow.finishDrag)
                            }
                            onCanceled: {
                                if (didDrag) {
                                    didDrag = false
                                    Qt.callLater(dockWindow.finishDrag)
                                }
                            }
                            onClicked: (mouse) => {
                                if (didDrag) {
                                    didDrag = false
                                    return
                                }
                                if (mouse.button === Qt.RightButton) {
                                    previewShowTimer.stop()
                                    dockWindow.activePreviewTarget = ""
                                    dockWindow.activePreviewWindows = []
                                    dockWindow.ctxIsSeparator = false
                                    dockWindow.ctxPinnedIndex = slot.pIdx
                                    dockWindow.ctxTarget = slot.modelData.target || ""
                                    dockWindow.ctxName = slot.modelData.name || "App"
                                    dockWindow.ctxArgs = slot.modelData.args || ""
                                    dockWindow.ctxPinned = !!slot.modelData.pinned
                                    dockWindow.ctxRunning = !!slot.modelData.running
                                    dockWindow.ctxGlobalX = dockWindow.x + dockPill.x
                                        + dockRow.x + slot.x + slot.width * 0.5
                                    dockWindow.ctxGlobalY = dockWindow.y + dockPill.y
                                        + dockRow.y + slot.y + slot.height * 0.5
                                    dockWindow.ctxOpen = true
                                    ctxAutoHideTimer.restart()
                                    return
                                }
                                dockWindow.ctxOpen = false
                                const tgt = slot.modelData.target || ""
                                const ar = slot.modelData.args || ""
                                const isRun = !!slot.modelData.running
                                Qt.callLater(function() {
                                    if (isRun) {
                                        WindowTracker.activateOrToggle(tgt)
                                    } else {
                                        AppLauncher.launch(tgt, ar)
                                    }
                                })
                            }
                        }
                    }

                    // --- Custom Draggable / Removable Separator (Phase 2b) ---
                    Item {
                        id: customSepBox
                        visible: slot.modelData.kind === "custom_sep"
                        anchors.fill: parent

                        Rectangle {
                            anchors.centerIn: parent
                            width: dockWindow.isVertical
                                ? (dockWindow.baseTileSize - 12)
                                : ((customSepArea.containsMouse || slot.isDraggingThis) ? 3 : 2)
                            height: dockWindow.isVertical
                                ? ((customSepArea.containsMouse || slot.isDraggingThis) ? 3 : 2)
                                : (dockWindow.baseTileSize - 12)
                            radius: 1.5
                            color: (customSepArea.containsMouse || slot.isDraggingThis)
                                ? "#0284C7" : "#94A3B8"
                        }

                        MouseArea {
                            id: customSepArea
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton) {
                                    previewShowTimer.stop()
                                    dockWindow.activePreviewTarget = ""
                                    dockWindow.activePreviewWindows = []
                                    dockWindow.ctxIsSeparator = true
                                    dockWindow.ctxPinnedIndex = slot.pIdx
                                    dockWindow.ctxName = "Separator"
                                    dockWindow.ctxTarget = ""
                                    dockWindow.ctxArgs = ""
                                    dockWindow.ctxPinned = true
                                    dockWindow.ctxRunning = false
                                    dockWindow.ctxGlobalX = dockWindow.x + dockPill.x
                                        + dockRow.x + slot.x + slot.width * 0.5
                                    dockWindow.ctxGlobalY = dockWindow.y + dockPill.y
                                        + dockRow.y + slot.y + slot.height * 0.5
                                    dockWindow.ctxOpen = true
                                    ctxAutoHideTimer.restart()
                                }
                            }
                        }
                    }

                    // --- Divider ---
                    Rectangle {
                        visible: slot.modelData.kind === "divider"
                        anchors.centerIn: parent
                        width: dockWindow.isVertical ? Math.round(dockWindow.baseTileSize * 0.56) : 3
                        height: dockWindow.isVertical ? 3 : Math.round(dockWindow.baseTileSize * 0.56)
                        radius: 2
                        color: dockWindow.isCapsule ? themeHub.barRimColor : "#CBD5E1"
                    }

                    // --- Solar Trash Bin Keycap ---
                    Item {
                        id: trashBox
                        visible: slot.modelData.kind === "trash"
                        x: dockWindow.isRight ? (parent.width - width) : (dockWindow.isLeft ? 0 : (parent.width - width) * 0.5)
                        y: dockWindow.isBottom ? (parent.height - height) : (dockWindow.isTop ? 0 : (parent.height - height) * 0.5)
                        width: slot.slotSize
                        height: slot.slotSize

                        readonly property bool hovered: trashArea.containsMouse
                        readonly property bool pressed: trashArea.pressed

                        Rectangle {
                            visible: !dockWindow.isCapsule && !dockWindow.circleIcons
                            anchors.fill: trashCap
                            anchors.topMargin: 2.5
                            anchors.bottomMargin: -2.5
                            radius: trashCap.radius
                            color: "#1A1B2E"
                            opacity: trashBox.pressed ? 0.0 : 0.9
                        }

                        Rectangle {
                            id: trashCap
                            width: parent.width
                            height: parent.height
                            x: trashBox.pressed
                                ? (dockWindow.isLeft ? -2 : (dockWindow.isRight ? 2 : 0))
                                : (trashBox.hovered ? (dockWindow.isLeft ? 2 : (dockWindow.isRight ? -2 : 0)) : 0)
                            y: trashBox.pressed
                                ? (dockWindow.isTop ? -2 : (dockWindow.isBottom ? 2 : 0))
                                : (trashBox.hovered ? (dockWindow.isTop ? 2 : (dockWindow.isBottom ? -2 : 0)) : 0)
                            radius: dockWindow.circleIcons
                                ? Math.round(Math.min(width, height) * 0.5)
                                : (13 + 5 * slot.wFactor)
                            color: dockWindow.isCapsule
                                ? (trashBox.hovered ? themeHub.barChipHover : themeHub.barBodyColor)
                                : (trashBox.hovered ? "#FEF3C7" : "#FFFFFF")
                            border.width: dockWindow.isCapsule ? (trashBox.hovered ? 2.5 : 2) : 2
                            border.color: dockWindow.isCapsule
                                ? (trashBox.hovered ? themeHub.accentA : themeHub.barRimColor)
                                : (trashBox.hovered ? "#D97706" : "#1A1B2E")

                            Image {
                                anchors.centerIn: parent
                                width: Math.round(parent.width * 0.48)
                                height: Math.round(parent.height * 0.48)
                                sourceSize.width: 48
                                sourceSize.height: 48
                                smooth: true
                                source: dockWindow.isCapsule
                                    ? "qrc:/qml/icons/trash-bin-trash-light.svg"
                                    : (TrashService.isEmpty ? "qrc:/qml/icons/trash-bin-trash-dark.svg" : "qrc:/qml/icons/trash-bin-trash-red.svg")
                            }

                            Rectangle {
                                visible: !TrashService.isEmpty
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: -3
                                width: Math.max(18, trashBadgeTxt.implicitWidth + 8)
                                height: 18
                                radius: 9
                                color: "#e0575b"
                                border.width: 2
                                border.color: dockWindow.isCapsule ? "#FFFFFF" : "#1A1B2E"

                                Text {
                                    id: trashBadgeTxt
                                    anchors.centerIn: parent
                                    text: TrashService.itemCount > 99 ? "99+" : (TrashService.itemCount > 9 ? "9+" : String(TrashService.itemCount))
                                    color: "#FFFFFF"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }
                        }

                        MouseArea {
                            id: trashArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton)
                                    TrashService.emptyBin()
                                else
                                    TrashService.openBin()
                            }
                        }
                    }

                    // --- SekaiPop Wide Inline Media Pill (Horizontal Dock) ---
                    Item {
                        id: wideMediaPill
                        visible: slot.modelData.kind === "media" && !dockWindow.isVertical
                        anchors.verticalCenter: parent.verticalCenter
                        width: dockWindow.mediaTileExtent
                        height: dockWindow.baseTileSize

                        readonly property bool activeRim: MediaService.isPlaying || wideBodyMa.containsMouse
                        readonly property real strokeW: dockWindow.isCapsule ? (activeRim ? 2.5 : 2.0) : 2.0
                        readonly property real pillRadius: dockWindow.isCapsule ? Math.round(height * 0.5) : 15
                        readonly property real innerRadius: Math.max(4, pillRadius - strokeW)
                        readonly property bool hasArt: wideMediaArtImg.status === Image.Ready
                        readonly property color inkCol: (hasArt || dockWindow.isCapsule) ? "#FFFFFF" : "#1A1B2E"
                        readonly property color subCol: (hasArt || dockWindow.isCapsule) ? Qt.rgba(1, 1, 1, 0.78) : "#64748B"
                        readonly property real trackProgress: (MediaService.durationSec > 0)
                            ? Math.max(0.0, Math.min(1.0, MediaService.positionSec / MediaService.durationSec))
                            : 0.0

                        // Base fill behind inner content
                        Rectangle {
                            anchors.fill: parent
                            radius: wideMediaPill.pillRadius
                            color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"
                        }

                        // All pill contents sit cleanly inside strokeW so they never overlap the border ring
                        Item {
                            id: wideInner
                            anchors.fill: parent
                            anchors.margins: wideMediaPill.strokeW

                            // Blurred full-bleed cover art backdrop
                            Item {
                                anchors.fill: parent
                                visible: wideBlurArtImg.status === Image.Ready

                                Item {
                                    id: wideBlurLayer
                                    anchors.fill: parent
                                    layer.enabled: visible && width > 4 && height > 4
                                    layer.smooth: true
                                    layer.textureSize: Qt.size(Math.max(32, Math.round(width)), Math.max(16, Math.round(height)))
                                    layer.effect: MultiEffect {
                                        blurEnabled: true
                                        blur: 0.72
                                        blurMax: 32
                                        autoPaddingEnabled: false
                                        maskEnabled: true
                                        maskSource: wideBlurMask
                                    }

                                    Image {
                                        id: wideBlurArtImg
                                        anchors.centerIn: parent
                                        width: parent.width * 1.4
                                        height: parent.height * 1.5
                                        asynchronous: true
                                        smooth: true
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize: Qt.size(160, 160)
                                        source: MediaService.hasSession ? MediaService.artUrl : ""
                                        opacity: MediaService.isPlaying ? 0.92 : 0.65
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        color: Qt.rgba(themeHub.barBodyColor.r, themeHub.barBodyColor.g, themeHub.barBodyColor.b, 0.44)
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        color: Qt.rgba(themeHub.accentA.r, themeHub.accentA.g, themeHub.accentA.b, 0.08)
                                    }
                                }

                                Item {
                                    id: wideBlurMask
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: wideBlurArtImg.status === Image.Ready && width > 4 && height > 4
                                    layer.smooth: true
                                    layer.textureSize: wideBlurLayer.layer.textureSize

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: wideMediaPill.innerRadius
                                        color: "black"
                                        antialiasing: true
                                    }
                                }
                            }

                            MouseArea {
                                id: wideBodyMa
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    if (mouse.button === Qt.RightButton)
                                        MediaService.next()
                                    else if (mouse.button === Qt.MiddleButton)
                                        MediaService.previous()
                                    else
                                        MediaService.playPause()
                                }
                            }

                            // Left Cover Art Disc (circleIcons: concentric circle) or Flush Left Art (squareIcons: curved left, square right)
                            Item {
                                id: wideCoverWrap
                                anchors.left: parent.left
                                anchors.leftMargin: dockWindow.circleIcons ? 2 : 0
                                anchors.verticalCenter: parent.verticalCenter
                                width: dockWindow.circleIcons ? Math.max(16, parent.height - 4) : parent.height
                                height: width
                                z: 1

                                Rectangle {
                                    visible: wideMediaArtImg.status !== Image.Ready
                                    anchors.fill: parent
                                    radius: dockWindow.circleIcons ? Math.round(height * 0.5) : 0
                                    color: dockWindow.isCapsule ? themeHub.barChipColor : "#E2E8F0"
                                }

                                Item {
                                    id: wideCoverLayer
                                    anchors.fill: parent
                                    layer.enabled: visible && width > 4 && height > 4
                                    layer.smooth: true
                                    layer.mipmap: true
                                    layer.textureSize: Qt.size(Math.max(24, Math.round(width * 2)), Math.max(24, Math.round(height * 2)))
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: wideCoverMask
                                    }

                                    Image {
                                        id: wideMediaArtImg
                                        anchors.fill: parent
                                        asynchronous: true
                                        smooth: true
                                        mipmap: true
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize: Qt.size(96, 96)
                                        source: MediaService.hasSession ? MediaService.artUrl : ""
                                        visible: status === Image.Ready
                                        opacity: MediaService.isPlaying ? 1.0 : 0.72
                                    }
                                }

                                Item {
                                    id: wideCoverMask
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: width > 4 && height > 4
                                    layer.smooth: true
                                    layer.textureSize: wideCoverLayer.layer.textureSize

                                    Item {
                                        anchors.fill: parent
                                        clip: true
                                        Rectangle {
                                            x: 0
                                            y: 0
                                            width: dockWindow.circleIcons
                                                ? parent.width
                                                : (parent.width + wideMediaPill.innerRadius)
                                            height: parent.height
                                            radius: dockWindow.circleIcons
                                                ? Math.round(Math.min(parent.width, parent.height) * 0.5)
                                                : wideMediaPill.innerRadius
                                            color: "black"
                                            antialiasing: true
                                        }
                                    }
                                }

                                Image {
                                    anchors.centerIn: parent
                                    visible: wideMediaArtImg.status !== Image.Ready
                                    width: Math.round(parent.width * 0.52)
                                    height: Math.round(parent.height * 0.52)
                                    sourceSize: Qt.size(36, 36)
                                    smooth: true
                                    source: (dockWindow.isCapsule || wideMediaPill.hasArt)
                                        ? "qrc:/qml/icons/music-note-light.svg"
                                        : "qrc:/qml/icons/music-note-dark.svg"
                                }
                            }

                            // Right Controls Row
                            Row {
                                id: wideMediaBtns
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4
                                z: 2

                                Rectangle {
                                    width: 22
                                    height: 22
                                    radius: 11
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: prevArea.containsMouse
                                        ? (dockWindow.isCapsule || wideMediaPill.hasArt ? Qt.rgba(1, 1, 1, 0.22) : "#E2E8F0")
                                        : "transparent"
                                    Image {
                                        anchors.centerIn: parent
                                        width: 12
                                        height: 12
                                        sourceSize: Qt.size(24, 24)
                                        smooth: true
                                        source: (dockWindow.isCapsule || wideMediaPill.hasArt)
                                            ? "qrc:/qml/icons/skip-previous-light.svg"
                                            : "qrc:/qml/icons/skip-previous-dark.svg"
                                    }
                                    MouseArea {
                                        id: prevArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: MediaService.previous()
                                    }
                                }

                                Rectangle {
                                    width: 26
                                    height: 26
                                    radius: 13
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: playArea.containsMouse ? themeHub.accentB : themeHub.accentA
                                    border.width: dockWindow.isCapsule ? 0 : 1.5
                                    border.color: "#1A1B2E"
                                    Image {
                                        anchors.centerIn: parent
                                        width: 13
                                        height: 13
                                        sourceSize: Qt.size(26, 26)
                                        smooth: true
                                        source: MediaService.isPlaying ? "qrc:/qml/icons/pause-dark.svg" : "qrc:/qml/icons/play-dark.svg"
                                    }
                                    MouseArea {
                                        id: playArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: MediaService.playPause()
                                    }
                                }

                                Rectangle {
                                    width: 22
                                    height: 22
                                    radius: 11
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: nextArea.containsMouse
                                        ? (dockWindow.isCapsule || wideMediaPill.hasArt ? Qt.rgba(1, 1, 1, 0.22) : "#E2E8F0")
                                        : "transparent"
                                    Image {
                                        anchors.centerIn: parent
                                        width: 12
                                        height: 12
                                        sourceSize: Qt.size(24, 24)
                                        smooth: true
                                        source: (dockWindow.isCapsule || wideMediaPill.hasArt)
                                            ? "qrc:/qml/icons/skip-next-light.svg"
                                            : "qrc:/qml/icons/skip-next-dark.svg"
                                    }
                                    MouseArea {
                                        id: nextArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: MediaService.next()
                                    }
                                }
                            }

                            // Middle Title + Artist + Progress Bar
                            Column {
                                anchors.left: wideCoverWrap.right
                                anchors.leftMargin: 8
                                anchors.right: wideMediaBtns.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                z: 2

                                Text {
                                    width: parent.width
                                    text: MediaService.title !== "" ? MediaService.title : "Now Playing"
                                    color: wideMediaPill.inkCol
                                    font.family: "Segoe UI"
                                    font.pixelSize: 11
                                    font.weight: Font.ExtraBold
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: MediaService.artist !== ""
                                    width: parent.width
                                    text: MediaService.artist
                                    color: wideMediaPill.subCol
                                    font.family: "Segoe UI"
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    visible: MediaService.durationSec > 0
                                    width: parent.width
                                    height: 3
                                    radius: 2
                                    color: (wideMediaPill.hasArt || dockWindow.isCapsule) ? Qt.rgba(1, 1, 1, 0.28) : "#CBD5E1"

                                    Rectangle {
                                        width: Math.round(parent.width * wideMediaPill.trackProgress)
                                        height: parent.height
                                        radius: parent.radius
                                        color: themeHub.accentB
                                    }
                                }
                            }
                        }

                        // Outer crisp border sibling overlay (never overlapped by blur or cover)
                        Rectangle {
                            anchors.fill: parent
                            radius: wideMediaPill.pillRadius
                            color: "transparent"
                            border.width: wideMediaPill.strokeW
                            border.color: wideMediaPill.activeRim
                                ? themeHub.accentA
                                : (dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E")
                            antialiasing: true
                            z: 10
                        }
                    }

                    // --- SekaiPop Vertical Circular Cover Media Key (Left/Right Dock) ---
                    Item {
                        id: vMediaBox
                        visible: slot.modelData.kind === "media" && dockWindow.isVertical
                        x: dockWindow.isRight ? (parent.width - width) : (dockWindow.isLeft ? 0 : (parent.width - width) * 0.5)
                        y: dockWindow.isBottom ? (parent.height - height) : (dockWindow.isTop ? 0 : (parent.height - height) * 0.5)
                        width: slot.slotSize
                        height: slot.slotSize

                        Rectangle {
                            id: vMediaCap
                            anchors.fill: parent
                            radius: dockWindow.circleIcons
                                ? Math.round(Math.min(width, height) * 0.5)
                                : (13 + 5 * slot.wFactor)
                            color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"

                            Item {
                                id: vMediaCoverLayer
                                anchors.fill: parent
                                anchors.margins: 3
                                layer.enabled: visible && width > 4 && height > 4
                                layer.smooth: true
                                layer.mipmap: true
                                layer.textureSize: Qt.size(Math.max(24, Math.round(width * 2)), Math.max(24, Math.round(height * 2)))
                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: vMediaCoverMask
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    color: dockWindow.isCapsule ? themeHub.barChipColor : "#E2E8F0"
                                }

                                Image {
                                    id: vMediaArtImg
                                    anchors.fill: parent
                                    asynchronous: true
                                    smooth: true
                                    mipmap: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize: Qt.size(120, 120)
                                    source: MediaService.hasSession ? MediaService.artUrl : ""
                                    visible: status === Image.Ready
                                    opacity: MediaService.isPlaying ? 1.0 : 0.72
                                }

                                Image {
                                    anchors.centerIn: parent
                                    visible: vMediaArtImg.status !== Image.Ready
                                    width: Math.round(parent.width * 0.52)
                                    height: Math.round(parent.height * 0.52)
                                    sourceSize: Qt.size(36, 36)
                                    smooth: true
                                    source: dockWindow.isCapsule ? "qrc:/qml/icons/music-note-light.svg" : "qrc:/qml/icons/music-note-dark.svg"
                                }
                            }

                            Item {
                                id: vMediaCoverMask
                                anchors.fill: vMediaCoverLayer
                                visible: false
                                layer.enabled: width > 4 && height > 4
                                layer.smooth: true
                                layer.textureSize: vMediaCoverLayer.layer.textureSize

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Math.max(4, vMediaCap.radius - 3)
                                    color: "black"
                                    antialiasing: true
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: vMediaCap.radius
                                color: "transparent"
                                border.width: dockWindow.isCapsule ? ((MediaService.isPlaying || vMediaMa.containsMouse) ? 2.5 : 2) : 2
                                border.color: (MediaService.isPlaying || vMediaMa.containsMouse)
                                    ? themeHub.accentA
                                    : (dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E")
                                antialiasing: true
                                z: 10
                            }

                            // Corner Play/Pause miniature badge (SekaiPop Dock.qml L3303)
                            Rectangle {
                                z: 11
                                x: dockWindow.circleIcons
                                    ? (parent.width * 0.5 + (parent.width * 0.5 - 4) * 0.7071 - width * 0.5)
                                    : (parent.width - width - 1)
                                y: dockWindow.circleIcons
                                    ? (parent.height * 0.5 + (parent.height * 0.5 - 4) * 0.7071 - height * 0.5)
                                    : (parent.height - height - 1)
                                width: 16
                                height: 16
                                radius: 8
                                color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"
                                border.width: 1.5
                                border.color: dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E"
                                antialiasing: true

                                Image {
                                    anchors.centerIn: parent
                                    width: 9
                                    height: 9
                                    sourceSize: Qt.size(18, 18)
                                    smooth: true
                                    source: dockWindow.isCapsule
                                        ? (MediaService.isPlaying ? "qrc:/qml/icons/pause-light.svg" : "qrc:/qml/icons/play-light.svg")
                                        : (MediaService.isPlaying ? "qrc:/qml/icons/pause-dark.svg" : "qrc:/qml/icons/play-dark.svg")
                                }
                            }
                        }

                        MouseArea {
                            id: vMediaMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mouse => {
                                if (mouse.button === Qt.RightButton)
                                    MediaService.next()
                                else if (mouse.button === Qt.MiddleButton)
                                    MediaService.previous()
                                else
                                    MediaService.playPause()
                            }
                        }
                    }

                    // --- Utility Tool Keycaps (Spotlight / Clipboard / Drop Shelf / Timer / Files) ---
                    Item {
                        id: utilToolBox
                        visible: slot.modelData.kind === "finder"
                            || slot.modelData.kind === "clipboard"
                            || slot.modelData.kind === "dropshelf"
                            || slot.modelData.kind === "timer"
                            || slot.modelData.kind === "files"
                        x: dockWindow.isRight ? (parent.width - width) : (dockWindow.isLeft ? 0 : (parent.width - width) * 0.5)
                        y: dockWindow.isBottom ? (parent.height - height) : (dockWindow.isTop ? 0 : (parent.height - height) * 0.5)
                        width: slot.slotSize
                        height: slot.slotSize

                        readonly property bool hovered: utilToolMa.containsMouse
                        readonly property bool pressed: utilToolMa.pressed
                        readonly property bool activeTool: (slot.modelData.kind === "finder" && themeHub.spotlightOpen)
                            || (slot.modelData.kind === "clipboard" && themeHub.clipboardOpen)
                            || (slot.modelData.kind === "dropshelf" && themeHub.dropShelfOpen)
                            || (slot.modelData.kind === "timer" && dockExtraCards.timerOpen)
                            || (slot.modelData.kind === "files" && dockExtraCards.filesOpen)

                        Rectangle {
                            visible: !dockWindow.isCapsule && !dockWindow.circleIcons
                            anchors.fill: utilCap
                            anchors.topMargin: 2.5
                            anchors.bottomMargin: -2.5
                            radius: utilCap.radius
                            color: "#1A1B2E"
                            opacity: utilToolBox.pressed ? 0.0 : 0.9
                        }

                        Rectangle {
                            id: utilCap
                            width: parent.width
                            height: parent.height
                            x: utilToolBox.pressed
                                ? (dockWindow.isLeft ? -2 : (dockWindow.isRight ? 2 : 0))
                                : (utilToolBox.hovered ? (dockWindow.isLeft ? 2 : (dockWindow.isRight ? -2 : 0)) : 0)
                            y: utilToolBox.pressed
                                ? (dockWindow.isTop ? -2 : (dockWindow.isBottom ? 2 : 0))
                                : (utilToolBox.hovered ? (dockWindow.isTop ? 2 : (dockWindow.isBottom ? -2 : 0)) : 0)
                            radius: dockWindow.circleIcons
                                ? Math.round(Math.min(width, height) * 0.5)
                                : (13 + 5 * slot.wFactor)
                            color: dockWindow.isCapsule
                                ? ((utilToolBox.activeTool || utilToolBox.hovered) ? themeHub.barChipHover : themeHub.barBodyColor)
                                : (utilToolBox.activeTool ? themeHub.accentA : (utilToolBox.hovered ? themeHub.hoverTint : "#FFFFFF"))
                            border.width: dockWindow.isCapsule ? ((utilToolBox.activeTool || utilToolBox.hovered) ? 2.5 : 2) : 2
                            border.color: (utilToolBox.activeTool || utilToolBox.hovered)
                                ? themeHub.accentA
                                : (dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E")

                            Image {
                                anchors.centerIn: parent
                                width: Math.round(parent.width * 0.48)
                                height: Math.round(parent.height * 0.48)
                                sourceSize.width: 48
                                sourceSize.height: 48
                                smooth: true
                                source: {
                                    const k = slot.modelData.kind
                                    if (dockWindow.isCapsule) {
                                        if (k === "finder") return "qrc:/qml/icons/magnifer-light.svg"
                                        if (k === "clipboard") return "qrc:/qml/icons/clipboard-text-light.svg"
                                        if (k === "timer") return "qrc:/qml/icons/clock-circle-light.svg"
                                        if (k === "files") return "qrc:/qml/icons/folder-with-files-light.svg"
                                        return "qrc:/qml/icons/inbox-archive-light.svg"
                                    }
                                    if (k === "finder") return "qrc:/qml/icons/magnifer-dark.svg"
                                    if (k === "clipboard") return "qrc:/qml/icons/clipboard-text-dark.svg"
                                    if (k === "timer") return "qrc:/qml/icons/clock-circle-dark.svg"
                                    if (k === "files") return "qrc:/qml/icons/folder-2-dark.svg"
                                    return "qrc:/qml/icons/inbox-archive-dark.svg"
                                }
                            }

                            // Drop Shelf item count badge
                            Rectangle {
                                visible: slot.modelData.kind === "dropshelf" && DropShelfService.count > 0
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: -3
                                width: Math.max(18, dsDockBadge.implicitWidth + 8)
                                height: 18
                                radius: 9
                                color: "#e0575b"
                                border.width: 2
                                border.color: dockWindow.isCapsule ? "#FFFFFF" : "#1A1B2E"
                                Text {
                                    id: dsDockBadge
                                    anchors.centerIn: parent
                                    text: DropShelfService.count > 9 ? "9+" : String(DropShelfService.count)
                                    font.family: "Segoe UI"
                                    font.pixelSize: 10
                                    font.bold: true
                                    color: "#FFFFFF"
                                }
                            }

                            // Running Timer / Pomodoro live pill badge
                            Rectangle {
                                visible: slot.modelData.kind === "timer" && dockExtraCards.anyTimerActive && dockExtraCards.timerBadgeText !== ""
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: -4
                                width: timerBadgeTxt.implicitWidth + 8
                                height: 14
                                radius: 7
                                color: themeHub.accentB
                                border.width: 1.5
                                border.color: "#1A1B2E"
                                Text {
                                    id: timerBadgeTxt
                                    anchors.centerIn: parent
                                    text: dockExtraCards.timerBadgeText
                                    font.family: "Consolas"
                                    font.pixelSize: 8
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                            }
                        }

                        MouseArea {
                            id: utilToolMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (slot.modelData.kind === "finder") {
                                    themeHub.clipboardOpen = false
                                    themeHub.dropShelfOpen = false
                                    dockExtraCards.timerOpen = false
                                    dockExtraCards.filesOpen = false
                                    themeHub.spotlightOpen = !themeHub.spotlightOpen
                                } else if (slot.modelData.kind === "clipboard") {
                                    themeHub.spotlightOpen = false
                                    themeHub.dropShelfOpen = false
                                    dockExtraCards.timerOpen = false
                                    dockExtraCards.filesOpen = false
                                    themeHub.clipboardOpen = !themeHub.clipboardOpen
                                } else if (slot.modelData.kind === "dropshelf") {
                                    themeHub.spotlightOpen = false
                                    themeHub.clipboardOpen = false
                                    dockExtraCards.timerOpen = false
                                    dockExtraCards.filesOpen = false
                                    themeHub.dropShelfOpen = !themeHub.dropShelfOpen
                                } else if (slot.modelData.kind === "timer") {
                                    themeHub.spotlightOpen = false
                                    themeHub.clipboardOpen = false
                                    themeHub.dropShelfOpen = false
                                    dockExtraCards.filesOpen = false
                                    dockExtraCards.timerOpen = !dockExtraCards.timerOpen
                                } else if (slot.modelData.kind === "files") {
                                    themeHub.spotlightOpen = false
                                    themeHub.clipboardOpen = false
                                    themeHub.dropShelfOpen = false
                                    dockExtraCards.timerOpen = false
                                    dockExtraCards.filesOpen = !dockExtraCards.filesOpen
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =======================================================================
    // PHASE 1c — Live DWM Window Preview Popup
    // =======================================================================
    PanelWindow {
        id: previewWindow
        visible: !topBarWindow.effectiveFullscreen && dockWindow.activePreviewWindows.length > 0
        clickThrough: false

        readonly property int tileW: 216
        readonly property int tileH: 152
        readonly property int cardPad: 12
        readonly property int cardShadow: 4
        readonly property int maxTiles: Math.min(4, dockWindow.activePreviewWindows.length)

        width: previewCard.width + cardShadow
        height: previewCard.height + cardShadow

        x: {
            const scrW = themeHub.screenW
            if (dockWindow.isLeft)
                return Math.min(scrW - width - 12, dockWindow.x + dockWindow.width - 4)
            if (dockWindow.isRight)
                return Math.max(12, dockWindow.x + 4 - width)
            const rawX = Math.round(dockWindow.hoveredIconGlobalX - width * 0.5)
            return Math.max(12, Math.min(scrW - width - 12, rawX))
        }
        y: {
            const scrH = themeHub.screenH
            if (dockWindow.isTop)
                return Math.min(scrH - height - 12, dockWindow.y + dockWindow.height - 4)
            if (dockWindow.isVertical) {
                const rawY = Math.round(dockWindow.hoveredIconGlobalY - height * 0.5)
                return Math.max(12, Math.min(scrH - height - 12, rawY))
            }
            return Math.max(12, dockWindow.y + 4 - height)
        }

        mask: [{ x: 0, y: 0, width: previewCard.width + cardShadow, height: previewCard.height + cardShadow }]

        HoverHandler {
            id: previewHover
            onHoveredChanged: {
                dockWindow.previewCardHovered = hovered
                if (hovered) {
                    previewHideTimer.stop()
                } else {
                    previewHideTimer.restart()
                }
            }
        }

        // Hard offset shadow
        Rectangle {
            x: previewWindow.cardShadow
            y: previewWindow.cardShadow
            width: previewCard.width
            height: previewCard.height
            radius: previewCard.radius
            color: dockWindow.isCapsule ? themeHub.barShadeColor : "#1A1B2E"
        }

        Rectangle {
            id: previewCard
            x: 0
            y: 0
            width: previewRow.implicitWidth + previewWindow.cardPad * 2
            height: previewWindow.tileH + previewWindow.cardPad * 2 + 24
            radius: 18
            color: dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E"

            Rectangle {
                anchors.fill: parent
                anchors.margins: 2.5
                radius: parent.radius - 2.5
                color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"

                Rectangle {
                    visible: !dockWindow.isCapsule
                    anchors.fill: parent
                    anchors.margins: 3
                    radius: parent.radius - 3
                    color: "#F1F5FF"
                }
            }

            // App header label
            Text {
                x: previewWindow.cardPad
                y: 8
                text: dockWindow.activePreviewName
                color: dockWindow.isCapsule ? themeHub.barInkColor : "#1A1B2E"
                font.family: "Segoe UI"
                font.pixelSize: 12
                font.bold: true
            }

            Row {
                id: previewRow
                x: previewWindow.cardPad
                y: 28
                spacing: 10

                Repeater {
                    model: dockWindow.activePreviewWindows.slice(0, 4)

                    delegate: Rectangle {
                        id: winTile
                        required property var modelData
                        width: previewWindow.tileW
                        height: previewWindow.tileH
                        radius: 12
                        color: tileHoverArea.containsMouse ? "#E0F2FE" : "#FFFFFF"
                        border.width: modelData.active ? 2 : 1.5
                        border.color: modelData.active ? "#0284C7" : "#1A1B2E"

                        // Title + window action buttons
                        Item {
                            id: titleBar
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 6
                            height: 22

                            Text {
                                anchors.left: parent.left
                                anchors.right: actionBtns.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                text: winTile.modelData.title || dockWindow.activePreviewName
                                color: "#1E293B"
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Row {
                                id: actionBtns
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                Rectangle {
                                    width: 18
                                    height: 18
                                    radius: 9
                                    color: minArea.containsMouse ? "#FEF3C7" : "#E2E8F0"
                                    border.width: 1
                                    border.color: "#1A1B2E"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "–"
                                        font.pixelSize: 11
                                        font.bold: true
                                        color: "#1A1B2E"
                                    }
                                    MouseArea {
                                        id: minArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const h = winTile.modelData.hwnd
                                            Qt.callLater(function() { WindowTracker.minimizeHwnd(h) })
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 18
                                    height: 18
                                    radius: 9
                                    color: closeArea.containsMouse ? "#FEE2E2" : "#E2E8F0"
                                    border.width: 1
                                    border.color: closeArea.containsMouse ? "#EF4444" : "#1A1B2E"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        font.pixelSize: 12
                                        font.bold: true
                                        color: closeArea.containsMouse ? "#B91C1C" : "#1A1B2E"
                                    }
                                    MouseArea {
                                        id: closeArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const h = winTile.modelData.hwnd
                                            Qt.callLater(function() { WindowTracker.closeHwnd(h) })
                                        }
                                    }
                                }
                            }
                        }

                        // Live DWM 60fps window stream
                        DwmThumbnail {
                            anchors.top: titleBar.bottom
                            anchors.topMargin: 4
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 6
                            sourceHwnd: winTile.modelData.hwnd || 0
                            active: previewWindow.visible
                        }

                        MouseArea {
                            id: tileHoverArea
                            anchors.top: titleBar.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                const h = winTile.modelData.hwnd
                                const isMid = (mouse.button === Qt.MiddleButton)
                                Qt.callLater(function() {
                                    if (isMid) {
                                        WindowTracker.closeHwnd(h)
                                    } else {
                                        WindowTracker.activateHwnd(h)
                                        dockWindow.activePreviewTarget = ""
                                        dockWindow.activePreviewWindows = []
                                    }
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    // --- Phase 2: Right-Click Dock Context Menu ---
    Timer {
        id: ctxAutoHideTimer
        interval: 1600
        onTriggered: {
            if (!ctxHoverHandler.hovered)
                dockWindow.ctxOpen = false
        }
    }

    PanelWindow {
        id: contextWindow
        visible: dockWindow.ctxOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        readonly property int menuW: 196
        readonly property var menuActions: {
            const list = []
            list.push({
                id: "launch",
                label: dockWindow.ctxRunning ? "New Window / Open" : "Open App",
                danger: false
            })
            list.push({
                id: "pin",
                label: dockWindow.ctxPinned ? "Unpin from Dock" : "Pin to Dock",
                danger: false
            })
            if (dockWindow.ctxRunning) {
                list.push({ id: "close", label: "Close Window", danger: true })
            }
            return list
        }

        width: menuW + cardShadow
        height: ctxCard.height + cardShadow

        x: {
            const scrW = themeHub.screenW
            if (dockWindow.isLeft)
                return Math.min(scrW - width - 12, dockWindow.x + dockWindow.width - 4)
            if (dockWindow.isRight)
                return Math.max(12, dockWindow.x + 4 - width)
            const rawX = Math.round(dockWindow.ctxGlobalX - width * 0.5)
            return Math.max(12, Math.min(scrW - width - 12, rawX))
        }
        y: {
            const scrH = themeHub.screenH
            if (dockWindow.isTop)
                return Math.min(scrH - height - 12, dockWindow.y + dockWindow.height - 4)
            if (dockWindow.isVertical) {
                const rawY = Math.round(dockWindow.ctxGlobalY - height * 0.5)
                return Math.max(12, Math.min(scrH - height - 12, rawY))
            }
            return Math.max(12, dockWindow.y + 4 - height)
        }

        mask: [{ x: 0, y: 0, width: menuW + cardShadow, height: ctxCard.height + cardShadow }]

        // Hard sticker drop shadow
        Rectangle {
            x: contextWindow.cardShadow
            y: contextWindow.cardShadow
            width: contextWindow.menuW
            height: ctxCard.height
            radius: 14
            color: dockWindow.isCapsule ? themeHub.barShadeColor : "#1A1B2E"
        }

        Rectangle {
            id: ctxCard
            x: 0
            y: 0
            width: contextWindow.menuW
            height: ctxCol.implicitHeight + 14
            radius: 14
            color: dockWindow.isCapsule ? themeHub.barBodyColor : "#FFFFFF"
            border.width: 2
            border.color: dockWindow.isCapsule ? themeHub.barRimColor : "#1A1B2E"

            HoverHandler {
                id: ctxHoverHandler
                onHoveredChanged: {
                    if (hovered)
                        ctxAutoHideTimer.stop()
                    else
                        ctxAutoHideTimer.restart()
                }
            }

            Column {
                id: ctxCol
                x: 8
                y: 7
                width: parent.width - 16
                spacing: 4

                // Header with app name + dismiss x
                Item {
                    width: parent.width
                    height: 24

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.right: ctxDismissBtn.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: dockWindow.ctxName
                        font.family: "Segoe UI"
                        font.pixelSize: 12
                        font.bold: true
                        color: dockWindow.isCapsule ? themeHub.barInkColor : "#1E293B"
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: ctxDismissBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 20
                        height: 20
                        radius: 6
                        color: ctxDismissArea.containsMouse ? (dockWindow.isCapsule ? themeHub.barChipHover : "#F1F5F9") : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            font.pixelSize: 13
                            font.bold: true
                            color: dockWindow.isCapsule ? themeHub.barMutedInk : "#64748B"
                        }
                        MouseArea {
                            id: ctxDismissArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: dockWindow.ctxOpen = false
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: dockWindow.isCapsule ? themeHub.barRimColor : "#E2E8F0"
                }

                Repeater {
                    model: contextWindow.menuActions
                    delegate: Rectangle {
                        id: menuBtn
                        required property var modelData
                        width: parent.width
                        height: 30
                        radius: 8
                        color: menuBtnArea.containsMouse
                            ? (modelData.danger ? (dockWindow.isCapsule ? "#451A22" : "#FEE2E2") : (dockWindow.isCapsule ? themeHub.barChipHover : "#E0F2FE"))
                            : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: menuBtn.modelData.label
                            font.family: "Segoe UI"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: menuBtn.modelData.danger
                                ? (menuBtnArea.containsMouse ? "#F87171" : "#EF4444")
                                : (dockWindow.isCapsule ? themeHub.barInkColor : (menuBtnArea.containsMouse ? "#0369A1" : "#1E293B"))
                        }

                        MouseArea {
                            id: menuBtnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                const act = menuBtn.modelData.id
                                const tgt = dockWindow.ctxTarget
                                const nm = dockWindow.ctxName
                                const ar = dockWindow.ctxArgs
                                dockWindow.ctxOpen = false
                                if (act === "launch") {
                                    AppLauncher.launch(tgt, ar)
                                } else if (act === "pin") {
                                    if (dockWindow.ctxPinned) {
                                        AppLauncher.removePinnedByTarget(tgt)
                                    } else {
                                        AppLauncher.addPinnedApp(nm, tgt, ar)
                                    }
                                } else if (act === "add_sep") {
                                    AppLauncher.insertSeparatorAt(dockWindow.ctxPinnedIndex + 1)
                                } else if (act === "remove_sep") {
                                    AppLauncher.removePinnedApp(dockWindow.ctxPinnedIndex)
                                } else if (act === "close") {
                                    const wins = WindowTracker.windowsForTarget(tgt) || []
                                    for (let i = 0; i < wins.length; ++i) {
                                        WindowTracker.closeHwnd(wins[i].hwnd)
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
    // PHASE 4 — Slim Unified SekaiPop TopBar (28px) + AppBar WorkArea Reserve
    // =========================================================================
    PanelWindow {
        id: topBarWindow
        visible: !GameModeService.active
        readonly property bool effectiveFullscreen: topBarWindow.fullscreenActive || GameModeService.active

        readonly property string barEdge: themeHub.barEdge
        readonly property bool barVertical: themeHub.barVertical
        readonly property bool barTop: barEdge === "top"
        readonly property bool barBottom: barEdge === "bottom"
        readonly property bool barLeft: barEdge === "left"
        readonly property bool barRight: barEdge === "right"
        readonly property int stripThickness: themeHub.barStripThickness

        readonly property int targetX: barRight ? Math.max(0, themeHub.screenW - stripThickness) : 0
        readonly property int targetY: barBottom ? Math.max(0, themeHub.screenH - stripThickness) : 0
        readonly property int targetW: barVertical ? stripThickness : themeHub.screenW
        readonly property int targetH: barVertical ? themeHub.screenH : stripThickness

        function syncBarGeometry() {
            topBarWindow.setPanelGeometry(targetX, targetY, targetW, targetH)
        }

        Timer {
            id: barGeoGuardTimer
            interval: 16
            repeat: false
            onTriggered: topBarWindow.syncBarGeometry()
        }

        Component.onCompleted: syncBarGeometry()
        onTargetXChanged: syncBarGeometry()
        onTargetYChanged: syncBarGeometry()
        onTargetWChanged: syncBarGeometry()
        onTargetHChanged: syncBarGeometry()
        onScreenChanged: barGeoGuardTimer.restart()
        onVisibleChanged: if (visible) barGeoGuardTimer.restart()
        onXChanged: if (visible && x !== targetX) barGeoGuardTimer.restart()
        onYChanged: if (visible && y !== targetY) barGeoGuardTimer.restart()
        onWidthChanged: if (visible && width !== targetW) barGeoGuardTimer.restart()
        onHeightChanged: if (visible && height !== targetH) barGeoGuardTimer.restart()

        reserveTopBar: !themeHub.barAutoHide && !topBarWindow.fullscreenActive
        reserveEdge: barEdge
        reserveHeight: (themeHub.barAutoHide || topBarWindow.fullscreenActive) ? 0 : stripThickness
        clickThrough: topBarWindow.fullscreenActive

        property string timeText: ""
        property string dateText: ""
        property bool mediaPopupOpen: false
        property double mediaPopupClosedAt: 0
        property bool trayPopupOpen: false
        property double trayPopupClosedAt: 0
        property bool quickPanelOpen: false
        property double quickPanelClosedAt: 0
        property bool calendarOpen: false
        property double calendarClosedAt: 0
        property bool wifiPopupOpen: false
        property double wifiPopupClosedAt: 0
        property bool btPopupOpen: false
        property double btPopupClosedAt: 0
        property bool volumePopupOpen: false
        property double volumePopupClosedAt: 0
        property bool weatherPopupOpen: false
        property double weatherPopupClosedAt: 0
        property bool resourcePopupOpen: false
        property double resourcePopupClosedAt: 0
        property bool batteryPopupOpen: false
        property double batteryPopupClosedAt: 0
        readonly property bool phoneMode: themeHub.phoneMode
        readonly property bool anyPopupOpen: mediaPopupOpen || trayPopupOpen || quickPanelOpen || calendarOpen || wifiPopupOpen || btPopupOpen || volumePopupOpen || weatherPopupOpen || resourcePopupOpen || batteryPopupOpen
        readonly property bool barEdgeOverlap: barBottom ? WindowTracker.dockOverlap
            : (barLeft ? WindowTracker.leftOverlap
                : (barRight ? WindowTracker.rightOverlap : WindowTracker.topOverlap))
        readonly property bool barEdgeHovered: barBottom ? WindowTracker.bottomEdgeHovered
            : (barLeft ? WindowTracker.leftEdgeHovered
                : (barRight ? WindowTracker.rightEdgeHovered : WindowTracker.topEdgeHovered))
        readonly property bool autoHideTriggered: themeHub.barAutoHide
                                                  && barEdgeOverlap
                                                  && !topBarHover.hovered
                                                  && !barEdgeHovered
                                                  && !anyPopupOpen
        property real topHideProgress: (topBarWindow.fullscreenActive || topBarWindow.autoHideTriggered) ? 1.0 : 0.0

        Connections {
            target: SystemControl
            function onQuickPanelToggleRequested() {
                if (themeHub.settingsOpen) {
                    themeHub.settingsOpen = false
                    topBarWindow.quickPanelClosedAt = Date.now()
                    topBarWindow.quickPanelOpen = false
                    return
                }
                if (!topBarWindow.quickPanelOpen && (Date.now() - topBarWindow.quickPanelClosedAt) < 120)
                    return
                if (topBarWindow.quickPanelOpen)
                    topBarWindow.quickPanelClosedAt = Date.now()
                topBarWindow.quickPanelOpen = !topBarWindow.quickPanelOpen
            }
        }
        Behavior on topHideProgress {
            NumberAnimation {
                duration: 220
                easing.type: (topBarWindow.fullscreenActive || topBarWindow.autoHideTriggered) ? Easing.InCubic : Easing.OutCubic
            }
        }
        property real barPresetSlide: 0
        NumberAnimation {
            id: barPresetOut
            target: topBarWindow
            property: "barPresetSlide"
            to: 1.0
            duration: themeHub.motionOutMs
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            id: barPresetIn
            target: topBarWindow
            property: "barPresetSlide"
            to: 0.0
            duration: themeHub.motionInMs
            easing.type: Easing.OutBack
            easing.overshoot: 1.1
            onFinished: topBarWindow.syncBarGeometry()
        }
        Connections {
            target: themeHub
            function onMotionBarOutChanged() {
                if (themeHub.motionBarOut) {
                    barPresetIn.stop()
                    barPresetOut.restart()
                } else {
                    barPresetOut.stop()
                    barPresetIn.restart()
                }
            }
        }
        readonly property real effectiveTopHide: Math.max(topHideProgress, barPresetSlide)
        readonly property real topHideOffsetX: barVertical ? (barLeft ? -effectiveTopHide * 72 : effectiveTopHide * 72) : 0
        readonly property real topHideOffsetY: barVertical ? 0 : (barBottom ? effectiveTopHide * 38 : -effectiveTopHide * 38)

        function barPopupX(popW, anchorX) {
            const scrW = themeHub.screenW
            if (barLeft)
                return Math.min(scrW - popW - 8, stripThickness + 6)
            if (barRight)
                return Math.max(8, scrW - stripThickness - popW - 6)
            return Math.max(8, Math.min(scrW - popW - 8, anchorX))
        }
        function barPopupY(popH, anchorY) {
            const scrH = themeHub.screenH
            if (barBottom)
                return Math.max(8, scrH - stripThickness - popH - 4)
            if (barTop)
                return Math.min(scrH - popH - 8, stripThickness + 4)
            return Math.max(8, Math.min(scrH - popH - 8, anchorY))
        }

        blurBehind: themeHub.barStyle !== "transparent" && !topBarWindow.fullscreenActive && topBarWindow.effectiveTopHide < 0.95
        blurRadius: 0
        blurInsetX: 0
        blurInsetY: 0
        blurInsetRight: 0
        blurInsetBottom: 0
        blurTint: themeHub.barStyle === "blur"
                  ? Qt.rgba(14/255, 18/255, 30/255, 0.35)
                  : Qt.rgba(16/255, 20/255, 36/255, 0.84)

        mask: {
            if (topBarWindow.fullscreenActive)
                return []
            if (topBarWindow.effectiveTopHide > 0.95) {
                if (!themeHub.barAutoHide)
                    return []
                return barVertical
                    ? [{ x: barLeft ? 0 : Math.max(0, topBarWindow.width - 3), y: 0, width: 3, height: Math.max(1, topBarWindow.height) }]
                    : [{ x: 0, y: barBottom ? Math.max(0, topBarWindow.height - 3) : 0, width: Math.max(1, topBarWindow.width), height: 3 }]
            }
            if (themeHub.barStyle === "transparent" && !topBarWindow.barVertical) {
                const rects = []
                const bx = barFrame.x + horizontalBarContent.x
                const by = barFrame.y + horizontalBarContent.y
                if (leftIslandBg.visible && leftIslandBg.width > 0)
                    rects.push({ x: Math.round(bx + leftIslandBg.x), y: Math.round(by + leftIslandBg.y), width: Math.round(leftIslandBg.width), height: Math.round(leftIslandBg.height + 3) })
                if (centerIslandBg.visible && centerIslandBg.width > 0)
                    rects.push({ x: Math.round(bx + centerIslandBg.x), y: Math.round(by + centerIslandBg.y), width: Math.round(centerIslandBg.width), height: Math.round(centerIslandBg.height + 3) })
                if (rightIslandBg.visible && rightIslandBg.width > 0)
                    rects.push({ x: Math.round(bx + rightIslandBg.x), y: Math.round(by + rightIslandBg.y), width: Math.round(rightIslandBg.width), height: Math.round(rightIslandBg.height + 3) })
                if (rects.length > 0)
                    return rects
            }
            return null
        }

        Timer {
            interval: 1000
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                const d = new Date()
                const hh = String(d.getHours()).padStart(2, "0")
                const mm = String(d.getMinutes()).padStart(2, "0")
                const days = ["CN", "T2", "T3", "T4", "T5", "T6", "T7"]
                const dd = String(d.getDate()).padStart(2, "0")
                const mo = String(d.getMonth() + 1).padStart(2, "0")
                topBarWindow.timeText = hh + ":" + mm
                topBarWindow.dateText = days[d.getDay()] + " " + dd + "/" + mo
            }
        }

        Item {
            id: topBarRoot
            anchors.fill: parent

            HoverHandler {
                id: topBarHover
            }

            // Styled Bar frame (supports Top / Bottom horizontal & Left / Right slim vertical)
            Rectangle {
                id: barFrame
                x: topBarWindow.topHideOffsetX
                y: topBarWindow.topHideOffsetY
                width: topBarRoot.width
                height: topBarWindow.barVertical ? topBarRoot.height : topBarWindow.stripThickness
                radius: 0
                color: (themeHub.barStyle === "transparent" || themeHub.barStyle === "blur")
                    ? "transparent"
                    : themeHub.barBodyColor
                border.width: 0
                antialiasing: true

                Rectangle {
                    visible: themeHub.barStyle === "straight"
                    x: topBarWindow.barVertical ? (topBarWindow.barRight ? 0 : (parent.width - width)) : 0
                    y: topBarWindow.barVertical ? 0 : (topBarWindow.barBottom ? 0 : (parent.height - height))
                    width: topBarWindow.barVertical ? 2 : parent.width
                    height: topBarWindow.barVertical ? parent.height : 2
                    color: themeHub.barRimColor
                }

                // =============================================================
                // Horizontal Bar: 3-Zone SekaiPop Layout (Left / Center / Right)
                // =============================================================
                Item {
                    id: horizontalBarContent
                    visible: !topBarWindow.barVertical
                    anchors.fill: parent
                    anchors.leftMargin: themeHub.barStyle === "transparent" ? 12 : 6
                    anchors.rightMargin: themeHub.barStyle === "transparent" ? 12 : 6

                    // SekaiPop-authentic floating comic pill islands (Transparent mode)
                    Rectangle {
                        visible: leftIslandBg.visible
                        x: leftIslandBg.x
                        y: leftIslandBg.y + 2
                        width: leftIslandBg.width
                        height: leftIslandBg.height
                        radius: leftIslandBg.radius
                        color: "#1A1B2E"
                        antialiasing: true
                    }
                    Rectangle {
                        id: leftIslandBg
                        visible: themeHub.barStyle === "transparent" && leftContentRow.width > 4
                        x: leftContentRow.x - 6
                        y: (parent.height - 28) * 0.5 - 1
                        width: leftContentRow.width + 12
                        height: 28
                        radius: 14
                        color: themeHub.phoneDarkMode ? "#1A1F35" : "#FFFFFF"
                        border.width: 2.5
                        border.color: "#1A1B2E"
                        antialiasing: true
                    }

                    Rectangle {
                        visible: centerIslandBg.visible
                        x: centerIslandBg.x
                        y: centerIslandBg.y + 2
                        width: centerIslandBg.width
                        height: centerIslandBg.height
                        radius: centerIslandBg.radius
                        color: "#1A1B2E"
                        antialiasing: true
                    }
                    Rectangle {
                        id: centerIslandBg
                        visible: themeHub.barStyle === "transparent" && centerContentRow.width > 4
                        x: centerContentRow.x - 6
                        y: (parent.height - 28) * 0.5 - 1
                        width: centerContentRow.width + 12
                        height: 28
                        radius: 14
                        color: themeHub.phoneDarkMode ? "#1A1F35" : "#FFFFFF"
                        border.width: 2.5
                        border.color: "#1A1B2E"
                        antialiasing: true
                    }

                    Rectangle {
                        visible: rightIslandBg.visible
                        x: rightIslandBg.x
                        y: rightIslandBg.y + 2
                        width: rightIslandBg.width
                        height: rightIslandBg.height
                        radius: rightIslandBg.radius
                        color: "#1A1B2E"
                        antialiasing: true
                    }
                    Rectangle {
                        id: rightIslandBg
                        visible: themeHub.barStyle === "transparent" && rightContentRow.width > 4
                        x: rightContentRow.x - 6
                        y: (parent.height - 28) * 0.5 - 1
                        width: rightContentRow.width + 12
                        height: 28
                        radius: 14
                        color: themeHub.phoneDarkMode ? "#1A1F35" : "#FFFFFF"
                        border.width: 2.5
                        border.color: "#1A1B2E"
                        antialiasing: true
                    }

                    // --- Left Zone: Active App Pill + Media Pill + Active Title ---
                    Row {
                        id: leftContentRow
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        spacing: 6

                        Rectangle {
                            id: appBadgeRect
                            visible: themeHub.barShowActiveWindow
                            anchors.verticalCenter: parent.verticalCenter
                            width: appNameTxt.implicitWidth + 16
                            height: 22
                            radius: 11
                            color: themeHub.accentA

                            Text {
                                id: appNameTxt
                                anchors.centerIn: parent
                                text: WindowTracker.activeAppName || "Desktop"
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.weight: Font.Bold
                                color: themeHub.darkInk
                            }
                        }

                        // SekaiPop MediaPill (unified rounded capsule + inline PillVisualizer)
                        Rectangle {
                            id: mediaPill
                            anchors.verticalCenter: parent.verticalCenter
                            visible: themeHub.barShowMedia
                            width: Math.max(146, Math.min(284, 6 + mediaArtBox.width + 5 + mediaDivider.width + 20 + mediaSingleLineTxt.implicitWidth + (pillVizH.visible ? 26 : 0)))
                            height: 22
                            radius: 11
                            color: themeHub.darkInk
                            scale: mediaPillArea.pressed ? 0.97 : 1.0

                            Behavior on width {
                                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                            }
                            Behavior on scale {
                                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                            }

                            Rectangle {
                                id: mediaPillFill
                                anchors.fill: parent
                                anchors.margins: 1.5
                                radius: 9.5
                                clip: true
                                gradient: Gradient {
                                    orientation: Gradient.Vertical
                                    GradientStop { position: 0.0; color: themeHub.accentB }
                                    GradientStop { position: 1.0; color: themeHub.accentA }
                                }

                                Item {
                                    id: mediaArtBox
                                    anchors.left: parent.left
                                    anchors.leftMargin: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 15
                                    height: 15
                                    clip: true
                                    opacity: (MediaService.hasSession && !MediaService.isPlaying) ? 0.55 : 1.0
                                    Behavior on opacity { NumberAnimation { duration: 150 } }

                                    Image {
                                        anchors.centerIn: parent
                                        visible: mediaPillCover.status !== Image.Ready
                                        width: 12
                                        height: 12
                                        sourceSize.width: 24
                                        sourceSize.height: 24
                                        smooth: true
                                        source: "qrc:/qml/icons/music-note-dark.svg"
                                    }

                                    Image {
                                        id: mediaPillCover
                                        anchors.fill: parent
                                        source: MediaService.hasSession ? MediaService.artUrl : ""
                                        sourceSize.width: 30
                                        sourceSize.height: 30
                                        fillMode: Image.PreserveAspectCrop
                                        clip: true
                                        asynchronous: true
                                        smooth: true
                                        mipmap: true
                                        cache: false
                                        visible: status === Image.Ready
                                    }
                                }

                                Rectangle {
                                    id: mediaDivider
                                    anchors.left: mediaArtBox.right
                                    anchors.leftMargin: 4
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: 1.5
                                    color: themeHub.darkInk
                                }

                                PillVisualizer {
                                    id: pillVizH
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    style: themeHub.barMediaVizStyle
                                    active: MediaService.hasSession && MediaService.isPlaying
                                    inkColor: themeHub.darkInk
                                    peakColor: "#FFFFFF"
                                }

                                Item {
                                    anchors.left: mediaDivider.right
                                    anchors.right: pillVizH.visible ? pillVizH.left : parent.right
                                    anchors.leftMargin: 7
                                    anchors.rightMargin: 6
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    clip: true

                                    Text {
                                        id: mediaSingleLineTxt
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                        opacity: (MediaService.hasSession && !MediaService.isPlaying) ? 0.55 : 1.0
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                        text: {
                                            if (!MediaService.hasSession)
                                                return "Nothing Playing"
                                            const t = MediaService.title || "Playing"
                                            const a = (MediaService.artist || "").trim()
                                            return a !== "" ? (t + "  ·  " + a) : t
                                        }
                                        font.family: "Segoe UI"
                                        font.pixelSize: 10
                                        font.weight: Font.Bold
                                        color: themeHub.darkInk
                                    }
                                }
                            }

                            Rectangle {
                                z: 5
                                anchors.fill: parent
                                radius: parent.radius
                                color: "transparent"
                                border.width: 1.5
                                border.color: themeHub.darkInk
                                antialiasing: true
                            }

                            MouseArea {
                                id: mediaPillArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                onEntered: barExtraPopups.showTip("Media Player (L: Popup · M: Play/Pause · R: Next)", topBarWindow.x + barFrame.x + leftContentRow.x + mediaPill.x + mediaPill.width * 0.5, topBarWindow.y + barFrame.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: mouse => {
                                    barExtraPopups.hideTip()
                                    if (mouse.button === Qt.LeftButton) {
                                        if (!topBarWindow.mediaPopupOpen && (Date.now() - topBarWindow.mediaPopupClosedAt) < 220)
                                            return
                                        topBarWindow.mediaPopupOpen = !topBarWindow.mediaPopupOpen
                                    } else if (mouse.button === Qt.RightButton) {
                                        MediaService.next()
                                    } else if (mouse.button === Qt.MiddleButton) {
                                        MediaService.playPause()
                                    }
                                }
                            }
                        }

                        // Window title smoothly clipped before the centered clock/weather island
                        Text {
                            id: activeWinTitleTxt
                            readonly property real availW: centerContentRow.x - leftContentRow.x
                                - (appBadgeRect.visible ? (appBadgeRect.width + 6) : 0)
                                - (mediaPill.visible ? (mediaPill.width + 6) : 0) - 16
                            anchors.verticalCenter: parent.verticalCenter
                            visible: themeHub.barShowActiveWindow && (WindowTracker.activeWindowTitle || "") !== "" && availW >= 42
                            text: WindowTracker.activeWindowTitle || ""
                            width: Math.min(implicitWidth, Math.max(0, availW))
                            elide: Text.ElideRight
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            color: (themeHub.barStyle === "transparent" && !themeHub.phoneDarkMode) ? "#334155" : themeHub.barMutedInk
                        }
                    }

                    // --- Center Zone: Clean Weather + Clock/Date Hub ---
                    Row {
                        id: centerContentRow
                        anchors.centerIn: parent
                        spacing: 6

                        Rectangle {
                            id: barWeatherPill
                            visible: themeHub.barShowWeather
                            anchors.verticalCenter: parent.verticalCenter
                            width: barWeatherRow.implicitWidth + 14
                            height: 22
                            radius: 11
                            color: topBarWindow.weatherPopupOpen ? themeHub.accentB : (barWeatherMouse.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                            Row {
                                id: barWeatherRow
                                anchors.centerIn: parent
                                spacing: 4
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 12; height: 12
                                    sourceSize.width: 24; sourceSize.height: 24
                                    smooth: true
                                    source: topBarWindow.weatherPopupOpen
                                        ? (WeatherService.isDay ? "qrc:/qml/icons/sun-dark.svg" : "qrc:/qml/icons/moon-dark.svg")
                                        : (WeatherService.isDay ? "qrc:/qml/icons/sun-light.svg" : "qrc:/qml/icons/moon-light.svg")
                                }
                                Text {
                                    id: barWeatherTxt
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: themeHub.formatTemp(WeatherService.temperature) + "°"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    color: topBarWindow.weatherPopupOpen ? themeHub.darkInk : themeHub.barInkColor
                                }
                            }

                            MouseArea {
                                id: barWeatherMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip((WeatherService.city || "Weather") + " · Click for Forecast", topBarWindow.x + barFrame.x + centerContentRow.x + barWeatherPill.x + barWeatherPill.width * 0.5, topBarWindow.y + barFrame.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: mouse => {
                                    barExtraPopups.hideTip()
                                    if (mouse.button === Qt.RightButton) {
                                        WeatherService.refresh()
                                    } else {
                                        if (!topBarWindow.weatherPopupOpen && (Date.now() - topBarWindow.weatherPopupClosedAt) < 220)
                                            return
                                        topBarWindow.weatherPopupOpen = !topBarWindow.weatherPopupOpen
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: clockPill
                            visible: themeHub.barShowClock
                            anchors.verticalCenter: parent.verticalCenter
                            width: clockRow.implicitWidth + 16
                            height: 22
                            radius: 11
                            color: topBarWindow.calendarOpen
                                ? themeHub.accentB
                                : (clockPillMouse.containsMouse ? themeHub.hoverTint : themeHub.accentA)

                            Row {
                                id: clockRow
                                anchors.centerIn: parent
                                spacing: 5

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: topBarWindow.dateText
                                    font.family: "Segoe UI"
                                    font.pixelSize: 10
                                    font.weight: Font.DemiBold
                                    color: themeHub.darkInk
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "·"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    color: themeHub.darkInk
                                    opacity: 0.65
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: topBarWindow.timeText
                                    font.family: "Segoe UI"
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    color: themeHub.darkInk
                                }
                            }

                            MouseArea {
                                id: clockPillMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("Calendar & Schedule", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.calendarOpen && (Date.now() - topBarWindow.calendarClosedAt) < 220)
                                        return
                                    topBarWindow.calendarOpen = !topBarWindow.calendarOpen
                                }
                            }
                        }
                    }

                    // --- Right Zone: Grouped Utilities, Telemetry, Tray, StatusPill, Bell ---
                    Row {
                        id: rightContentRow
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        spacing: 6

                        // Grouped Utilities Pill (Settings/Theme, Edit Mode, Spotlight, Clipboard, DropShelf)
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: utilPillRow.implicitWidth + 6
                            height: 22
                            radius: 11
                            color: themeHub.barChipColor

                            Row {
                                id: utilPillRow
                                anchors.centerIn: parent
                                spacing: 2

                                // Theme / Settings (icon-only, matching SekaiPop)
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20
                                    height: 18
                                    radius: 9
                                    color: themeHub.settingsOpen ? themeHub.accentA : (bandPillMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent
                                        width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.settingsOpen ? "qrc:/qml/icons/palette-dark.svg" : "qrc:/qml/icons/palette-light.svg"
                                    }
                                    MouseArea {
                                        id: bandPillMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Settings & Theme", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.settingsOpen && (Date.now() - themeHub.settingsClosedAt) < 220)
                                                return
                                            themeHub.spotlightOpen = false
                                            themeHub.clipboardOpen = false
                                            themeHub.settingsOpen = !themeHub.settingsOpen
                                        }
                                    }
                                }

                                // Edit Desktop (Solar Pen icon)
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 18; radius: 9
                                    color: themeHub.editMode ? themeHub.accentB : (editPillMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent
                                        width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.editMode ? "qrc:/qml/icons/pen-dark.svg" : "qrc:/qml/icons/pen-light.svg"
                                    }
                                    MouseArea {
                                        id: editPillMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip(themeHub.editMode ? "Exit Desktop Edit Mode" : "Edit Desktop Layout", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: { barExtraPopups.hideTip(); themeHub.setEditMode(!themeHub.editMode) }
                                    }
                                }

                                // Spotlight Search
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 18; radius: 9
                                    color: themeHub.spotlightOpen ? themeHub.accentA : (spotPillMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent
                                        width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.spotlightOpen ? "qrc:/qml/icons/magnifer-dark.svg" : "qrc:/qml/icons/magnifer-light.svg"
                                    }
                                    MouseArea {
                                        id: spotPillMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Spotlight Launcher (Alt+Space)", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.spotlightOpen && (Date.now() - themeHub.spotlightClosedAt) < 220)
                                                return
                                            themeHub.settingsOpen = false
                                            themeHub.clipboardOpen = false
                                            themeHub.spotlightOpen = !themeHub.spotlightOpen
                                        }
                                    }
                                }

                                // Clipboard History
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 18; radius: 9
                                    color: themeHub.clipboardOpen ? themeHub.accentA : (clipPillMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent
                                        width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.clipboardOpen ? "qrc:/qml/icons/clipboard-text-dark.svg" : "qrc:/qml/icons/clipboard-text-light.svg"
                                    }
                                    MouseArea {
                                        id: clipPillMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Clipboard History (Ctrl+Alt+V)", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.clipboardOpen && (Date.now() - themeHub.clipboardClosedAt) < 220)
                                                return
                                            themeHub.settingsOpen = false
                                            themeHub.spotlightOpen = false
                                            themeHub.clipboardOpen = !themeHub.clipboardOpen
                                        }
                                    }
                                }

                                // Drop Shelf
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: DropShelfService.count > 0 ? (shelfPillRow.implicitWidth + 8) : 20
                                    height: 18; radius: 9
                                    color: themeHub.dropShelfOpen ? themeHub.accentB : (shelfPillMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Row {
                                        id: shelfPillRow
                                        anchors.centerIn: parent
                                        spacing: 3
                                        Image {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                            source: themeHub.dropShelfOpen ? "qrc:/qml/icons/folder-with-files-dark.svg" : "qrc:/qml/icons/folder-with-files-light.svg"
                                        }
                                        Text {
                                            visible: DropShelfService.count > 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "" + DropShelfService.count
                                            font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Bold
                                            color: themeHub.dropShelfOpen ? themeHub.darkInk : themeHub.accentB
                                        }
                                    }
                                    MouseArea {
                                        id: shelfPillMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Drop Shelf Files (" + DropShelfService.count + ")", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.dropShelfOpen && (Date.now() - themeHub.dropShelfClosedAt) < 220)
                                                return
                                            themeHub.dropShelfOpen = !themeHub.dropShelfOpen
                                        }
                                    }
                                }
                            }
                        }

                        // Grouped Telemetry Pill (click for live ResourcePopup charts & processes)
                        Rectangle {
                            id: hStatsPill
                            visible: themeHub.barShowStats
                            anchors.verticalCenter: parent.verticalCenter
                            width: statsGroupRow.implicitWidth + 14
                            height: 22
                            radius: 11
                            color: topBarWindow.resourcePopupOpen ? themeHub.accentB : (statsGroupMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                            Row {
                                id: statsGroupRow
                                anchors.centerIn: parent
                                spacing: 6

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "CPU " + (WindowTracker.cpuTemp >= 0 ? (WindowTracker.cpuTemp + "°") : (WindowTracker.cpuUsage + "%"))
                                    font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold
                                    color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : (WindowTracker.cpuTemp >= 80 ? "#FCA5A5" : "#7DD3FC")
                                }
                                Text {
                                    visible: WindowTracker.gpuTemp >= 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "·"
                                    font.family: "Segoe UI"; font.pixelSize: 10
                                    color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : themeHub.barMutedInk
                                }
                                Text {
                                    visible: WindowTracker.gpuTemp >= 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "GPU " + WindowTracker.gpuTemp + "°"
                                    font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold
                                    color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : (WindowTracker.gpuTemp >= 80 ? "#FCA5A5" : "#C4B5FD")
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "·"
                                    font.family: "Segoe UI"; font.pixelSize: 10
                                    color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : themeHub.barMutedInk
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "RAM " + WindowTracker.ramUsage + "%"
                                    font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold
                                    color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : "#F9A8D4"
                                }
                            }

                            MouseArea {
                                id: statsGroupMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("System Resources (CPU " + WindowTracker.cpuUsage + "% · " + (WindowTracker.ramDetailText || "RAM") + ")", topBarWindow.x + barFrame.x + rightContentRow.x + hStatsPill.x + hStatsPill.width * 0.5, topBarWindow.y + barFrame.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.resourcePopupOpen && (Date.now() - topBarWindow.resourcePopupClosedAt) < 220)
                                        return
                                    topBarWindow.resourcePopupOpen = !topBarWindow.resourcePopupOpen
                                }
                            }
                        }

                        // Laptop Battery Indicator Pill (auto-hidden on desktops with no battery)
                        Rectangle {
                            id: hBatPill
                            visible: WindowTracker.hasBattery && themeHub.barShowBattery
                            anchors.verticalCenter: parent.verticalCenter
                            width: hBatRow.implicitWidth + 12
                            height: 22
                            radius: 11
                            color: topBarWindow.batteryPopupOpen ? themeHub.accentA : (hBatMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                            Row {
                                id: hBatRow
                                anchors.centerIn: parent
                                spacing: 3
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: WindowTracker.batteryCharging ? "⚡" : "🔋"
                                    font.pixelSize: 10
                                    color: topBarWindow.batteryPopupOpen ? themeHub.darkInk : (WindowTracker.batteryCharging ? "#34D399" : themeHub.barInkColor)
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: WindowTracker.batteryPercent + "%"
                                    font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold
                                    color: topBarWindow.batteryPopupOpen
                                        ? themeHub.darkInk
                                        : (WindowTracker.batteryPercent <= 20 ? "#FCA5A5" : (WindowTracker.batteryCharging ? "#6EE7B7" : themeHub.barInkColor))
                                }
                            }

                            MouseArea {
                                id: hBatMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip(WindowTracker.batteryTimeText || "Battery", topBarWindow.x + barFrame.x + rightContentRow.x + hBatPill.x + hBatPill.width * 0.5, topBarWindow.y + barFrame.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.batteryPopupOpen && (Date.now() - topBarWindow.batteryPopupClosedAt) < 220)
                                        return
                                    topBarWindow.batteryPopupOpen = !topBarWindow.batteryPopupOpen
                                }
                            }
                        }

                        // System Tray Circle (triangle icon + unread dot, no cluttered text)
                        Rectangle {
                            id: trayPill
                            visible: themeHub.barShowTray
                            anchors.verticalCenter: parent.verticalCenter
                            width: 22
                            height: 22
                            radius: 11
                            color: topBarWindow.trayPopupOpen ? themeHub.accentA : (trayPillMouse.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                            Image {
                                anchors.centerIn: parent
                                width: 10; height: 10
                                sourceSize.width: 20; sourceSize.height: 20
                                smooth: true
                                source: topBarWindow.trayPopupOpen
                                    ? "qrc:/qml/icons/alt-arrow-down-dark.svg"
                                    : "qrc:/qml/icons/alt-arrow-up-light.svg"
                            }

                            Rectangle {
                                visible: TrayService.items.length > 0 && !topBarWindow.trayPopupOpen
                                anchors.right: parent.right; anchors.top: parent.top
                                width: 5; height: 5; radius: 2.5
                                color: themeHub.accentA
                            }

                            MouseArea {
                                id: trayPillMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("System Tray (" + TrayService.items.length + ")", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.trayPopupOpen && (Date.now() - topBarWindow.trayPopupClosedAt) < 220)
                                        return
                                    if (!topBarWindow.trayPopupOpen)
                                        TrayService.refresh()
                                    topBarWindow.trayPopupOpen = !topBarWindow.trayPopupOpen
                                }
                            }
                        }

                        // SekaiPop Grouped StatusPill ([ Wi-Fi | Bluetooth | Volume ] inside ONE pill)
                        Rectangle {
                            id: hStatusPill
                            anchors.verticalCenter: parent.verticalCenter
                            width: hStatusRow.implicitWidth + 6
                            height: 22
                            radius: 11
                            color: themeHub.barChipColor

                            Row {
                                id: hStatusRow
                                anchors.centerIn: parent
                                spacing: 2

                                // Wi-Fi / Ethernet segment
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22; height: 18; radius: 9
                                    color: topBarWindow.wifiPopupOpen ? themeHub.accentA : (wifiPillMouse.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent
                                        width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                        source: topBarWindow.wifiPopupOpen
                                            ? (SystemControl.networkType === "Wi-Fi" ? "qrc:/qml/icons/wifi-dark.svg" : "qrc:/qml/icons/network-dark.svg")
                                            : (SystemControl.networkType === "Wi-Fi" ? "qrc:/qml/icons/wifi-light.svg" : "qrc:/qml/icons/network-light.svg")
                                    }
                                    MouseArea {
                                        id: wifiPillMouse
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Network (" + (SystemControl.networkName || SystemControl.networkType) + ")", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!topBarWindow.wifiPopupOpen && (Date.now() - topBarWindow.wifiPopupClosedAt) < 220)
                                                return
                                            if (!topBarWindow.wifiPopupOpen) {
                                                SystemControl.refresh()
                                                SystemControl.refreshWifi()
                                            }
                                            topBarWindow.wifiPopupOpen = !topBarWindow.wifiPopupOpen
                                        }
                                    }
                                }

                                // Bluetooth segment
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 18; radius: 9
                                    color: topBarWindow.btPopupOpen ? themeHub.accentA : (btPillMouse.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent
                                        width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                        opacity: SystemControl.bluetoothEnabled ? 1.0 : 0.45
                                        source: topBarWindow.btPopupOpen ? "qrc:/qml/icons/bt-dark.svg" : "qrc:/qml/icons/bt-light.svg"
                                    }
                                    MouseArea {
                                        id: btPillMouse
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Bluetooth (" + (SystemControl.bluetoothEnabled ? "ON" : "OFF") + ")", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!topBarWindow.btPopupOpen && (Date.now() - topBarWindow.btPopupClosedAt) < 220)
                                                return
                                            if (!topBarWindow.btPopupOpen)
                                                SystemControl.refreshBluetooth()
                                            topBarWindow.btPopupOpen = !topBarWindow.btPopupOpen
                                        }
                                    }
                                }

                                // Volume segment (wheel = master vol, right click = mute, left click = Mixer)
                                Rectangle {
                                    id: volPill
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: hVolRow.implicitWidth + 10; height: 18; radius: 9
                                    color: topBarWindow.volumePopupOpen ? themeHub.accentB : (volPillMouse.containsMouse ? themeHub.barChipHover : "transparent")
                                    Row {
                                        id: hVolRow
                                        anchors.centerIn: parent
                                        spacing: 3
                                        Image {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                            opacity: AudioService.masterMuted ? 0.55 : 0.85
                                            source: topBarWindow.volumePopupOpen
                                                ? (AudioService.masterMuted ? "qrc:/qml/icons/volume-cross-dark.svg" : "qrc:/qml/icons/volume-loud-dark.svg")
                                                : (AudioService.masterMuted ? "qrc:/qml/icons/volume-cross-light.svg" : "qrc:/qml/icons/volume-loud-light.svg")
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: AudioService.masterMuted ? "X" : (AudioService.masterVolume + "%")
                                            font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold
                                            color: topBarWindow.volumePopupOpen
                                                ? themeHub.darkInk
                                                : (AudioService.masterMuted ? "#FCD34D" : themeHub.barInkColor)
                                        }
                                    }
                                    MouseArea {
                                        id: volPillMouse
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onEntered: barExtraPopups.showTip("Volume " + (AudioService.masterMuted ? "Muted" : AudioService.masterVolume + "%") + " · Scroll to Adjust", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: mouse => {
                                            barExtraPopups.hideTip()
                                            if (mouse.button === Qt.RightButton) {
                                                AudioService.toggleMasterMute()
                                            } else {
                                                if (!topBarWindow.volumePopupOpen && (Date.now() - topBarWindow.volumePopupClosedAt) < 220)
                                                    return
                                                if (!topBarWindow.volumePopupOpen) {
                                                    AudioService.refreshSessions()
                                                    AudioService.refreshOutputDevices()
                                                }
                                                topBarWindow.volumePopupOpen = !topBarWindow.volumePopupOpen
                                            }
                                        }
                                        onWheel: wheel => {
                                            AudioService.setMasterVolume(AudioService.masterVolume + (wheel.angleDelta.y > 0 ? 4 : -4))
                                            wheel.accepted = true
                                        }
                                    }
                                }
                            }
                        }

                        // Notifications / QuickPanel Bell Circle (Solar Bell + unread badge)
                        Item {
                            id: qpPill
                            anchors.verticalCenter: parent.verticalCenter
                            width: 24
                            height: 24

                            Rectangle {
                                anchors.centerIn: parent
                                width: 22; height: 22; radius: 11
                                color: topBarWindow.quickPanelOpen ? themeHub.accentA : (qpPillMouse.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                                Image {
                                    anchors.centerIn: parent
                                    width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                    source: topBarWindow.quickPanelOpen ? "qrc:/qml/icons/bell-dark.svg" : "qrc:/qml/icons/bell-light.svg"
                                }
                            }

                            Rectangle {
                                visible: NotificationService.count > 0
                                anchors.right: parent.right
                                anchors.top: parent.top
                                width: Math.max(13, qpCountTxt.implicitWidth + 5)
                                height: 13
                                radius: 6.5
                                color: "#E11D48"
                                border.width: 1; border.color: themeHub.darkInk
                                Text {
                                    id: qpCountTxt
                                    anchors.centerIn: parent
                                    text: NotificationService.count > 9 ? "9+" : String(NotificationService.count)
                                    font.family: "Segoe UI"; font.pixelSize: 8; font.weight: Font.Bold
                                    color: "#FFFFFF"
                                }
                            }

                            MouseArea {
                                id: qpPillMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("Quick Panel & Notifications (Ctrl+Alt+A)", topBarWindow.x + mapToItem(null, width * 0.5, 0).x, topBarWindow.y + barFrame.height * 0.5)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.quickPanelOpen && (Date.now() - topBarWindow.quickPanelClosedAt) < 220)
                                        return
                                    if (!topBarWindow.quickPanelOpen) {
                                        AudioService.refreshSessions()
                                        AudioService.refreshOutputDevices()
                                        SystemControl.refresh()
                                        SystemControl.refreshWifi()
                                        SystemControl.refreshBluetooth()
                                        NotificationService.refresh()
                                    }
                                    topBarWindow.quickPanelOpen = !topBarWindow.quickPanelOpen
                                }
                            }
                        }
                    }
                }

                // =============================================================
                // Vertical Side-Bar: 3-Zone SekaiPop Capsule Stack (Top / Center / Bottom)
                // =============================================================
                Item {
                    id: verticalBarContent
                    visible: topBarWindow.barVertical
                    anchors.fill: parent
                    anchors.margins: 4

                    // --- Top Zone: Active App Pill + Pure Media Squircle ---
                    Column {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 5

                        Rectangle {
                            visible: themeHub.barShowActiveWindow
                            width: parent.width
                            height: 22
                            radius: 11
                            color: themeHub.accentA
                            Text {
                                anchors.fill: parent
                                anchors.margins: 3
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                text: WindowTracker.activeAppName || "Desk"
                                font.family: "Segoe UI"
                                font.pixelSize: 8
                                font.weight: Font.Black
                                color: themeHub.darkInk
                            }
                        }

                        // SekaiPop-style Pure Vertical Media Square/Circle (art-only when playing, Solar music note when idle)
                        Rectangle {
                            visible: themeHub.barShowMedia
                            width: parent.width
                            height: width
                            radius: 12
                            color: themeHub.darkInk
                            scale: vBarMediaMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: 90 } }

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 1.5
                                radius: 10.5
                                clip: true
                                gradient: Gradient {
                                    orientation: Gradient.Vertical
                                    GradientStop { position: 0.0; color: MediaService.hasSession ? themeHub.accentB : themeHub.barChipColor }
                                    GradientStop { position: 1.0; color: MediaService.hasSession ? themeHub.accentA : themeHub.barChipColor }
                                }

                                Item {
                                    anchors.fill: parent
                                    opacity: (MediaService.hasSession && !MediaService.isPlaying) ? 0.55 : 1.0
                                    Behavior on opacity { NumberAnimation { duration: 150 } }

                                    Image {
                                        anchors.centerIn: parent
                                        visible: vBarMediaCover.status !== Image.Ready
                                        width: 16; height: 16
                                        sourceSize.width: 32; sourceSize.height: 32
                                        smooth: true
                                        source: MediaService.hasSession ? "qrc:/qml/icons/music-note-dark.svg" : "qrc:/qml/icons/music-note-light.svg"
                                    }
                                    Image {
                                        id: vBarMediaCover
                                        anchors.fill: parent
                                        source: MediaService.hasSession ? MediaService.artUrl : ""
                                        sourceSize.width: 64; sourceSize.height: 64
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true; smooth: true; mipmap: true; cache: false
                                        visible: status === Image.Ready
                                    }
                                }
                            }

                            Rectangle {
                                z: 5
                                anchors.fill: parent
                                radius: parent.radius
                                color: "transparent"
                                border.width: 1.5
                                border.color: MediaService.hasSession ? themeHub.accentA : themeHub.barRimColor
                                antialiasing: true
                            }

                            MouseArea {
                                id: vBarMediaMa
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                onClicked: mouse => {
                                    if (mouse.button === Qt.LeftButton) {
                                        if (!topBarWindow.mediaPopupOpen && (Date.now() - topBarWindow.mediaPopupClosedAt) < 220)
                                            return
                                        topBarWindow.mediaPopupOpen = !topBarWindow.mediaPopupOpen
                                    } else if (mouse.button === Qt.RightButton) {
                                        MediaService.next()
                                    } else if (mouse.button === Qt.MiddleButton) {
                                        MediaService.playPause()
                                    }
                                }
                            }
                        }
                    }

                    // --- Center Zone: Telemetry Capsule + Clock Circle + Date Circle ---
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 4

                        // Grouped Telemetry Pill (click for ResourcePopup)
                        Rectangle {
                            visible: themeHub.barShowStats
                            width: parent.width
                            height: vStatsCol.implicitHeight + 10
                            radius: 17
                            color: topBarWindow.resourcePopupOpen ? themeHub.accentB : (vStatsMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                            Column {
                                id: vStatsCol
                                anchors.centerIn: parent
                                spacing: 2

                                Column {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: -3
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "CPU"; font.family: "Consolas"; font.pixelSize: 7; font.weight: Font.Bold; color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : themeHub.barMutedInk }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: WindowTracker.cpuTemp >= 0 ? (WindowTracker.cpuTemp + "°") : (WindowTracker.cpuUsage + "%"); font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : (WindowTracker.cpuTemp >= 80 ? "#FCA5A5" : "#7DD3FC") }
                                }
                                Column {
                                    visible: WindowTracker.gpuTemp >= 0
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: -3
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "GPU"; font.family: "Consolas"; font.pixelSize: 7; font.weight: Font.Bold; color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : themeHub.barMutedInk }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: WindowTracker.gpuTemp + "°"; font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : (WindowTracker.gpuTemp >= 80 ? "#FCA5A5" : "#C4B5FD") }
                                }
                                Column {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: -3
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "RAM"; font.family: "Consolas"; font.pixelSize: 7; font.weight: Font.Bold; color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : themeHub.barMutedInk }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: WindowTracker.ramUsage + "%"; font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black; color: topBarWindow.resourcePopupOpen ? themeHub.darkInk : "#F9A8D4" }
                                }
                            }

                            MouseArea {
                                id: vStatsMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("System Resources (CPU " + WindowTracker.cpuUsage + "% · " + (WindowTracker.ramDetailText || "RAM") + ")", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.resourcePopupOpen && (Date.now() - topBarWindow.resourcePopupClosedAt) < 220)
                                        return
                                    topBarWindow.resourcePopupOpen = !topBarWindow.resourcePopupOpen
                                }
                            }
                        }

                        // Vertical Battery Pill (Laptops only)
                        Rectangle {
                            visible: WindowTracker.hasBattery && themeHub.barShowBattery
                            width: parent.width; height: 28; radius: 14
                            color: topBarWindow.batteryPopupOpen ? themeHub.accentA : (vBatMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)
                            Text {
                                anchors.centerIn: parent
                                text: (WindowTracker.batteryCharging ? "⚡" : "") + WindowTracker.batteryPercent + "%"
                                font.family: "Consolas"; font.pixelSize: 9; font.weight: Font.Black
                                color: topBarWindow.batteryPopupOpen ? themeHub.darkInk : themeHub.barInkColor
                            }
                            MouseArea {
                                id: vBatMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip(WindowTracker.batteryTimeText || "Battery", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.batteryPopupOpen && (Date.now() - topBarWindow.batteryPopupClosedAt) < 220)
                                        return
                                    topBarWindow.batteryPopupOpen = !topBarWindow.batteryPopupOpen
                                }
                            }
                        }

                        // Clock Circle (centered HH:mm, matches SekaiPop round clock chip)
                        Rectangle {
                            visible: themeHub.barShowClock
                            width: parent.width
                            height: 34
                            radius: 17
                            color: topBarWindow.calendarOpen
                                ? themeHub.accentB
                                : (vClockMa.containsMouse ? themeHub.hoverTint : themeHub.accentA)

                            Column {
                                anchors.centerIn: parent
                                spacing: -2
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: topBarWindow.timeText.split(":")[0] || "00"
                                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black
                                    color: themeHub.darkInk
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: topBarWindow.timeText.split(":")[1] || "00"
                                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black
                                    color: themeHub.darkInk
                                }
                            }

                            MouseArea {
                                id: vClockMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("Calendar & Schedule", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.calendarOpen && (Date.now() - topBarWindow.calendarClosedAt) < 220) return
                                    topBarWindow.calendarOpen = !topBarWindow.calendarOpen
                                }
                            }
                        }

                        // Date Circle (matches SekaiPop round Oct / 17 chip)
                        Rectangle {
                            visible: themeHub.barShowClock
                            width: parent.width
                            height: 34
                            radius: 17
                            color: topBarWindow.calendarOpen
                                ? themeHub.accentB
                                : (vDateMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)

                            Column {
                                anchors.centerIn: parent
                                spacing: -2
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: topBarWindow.dateText.split(" ")[0] || ""
                                    font.family: "Segoe UI"; font.pixelSize: 9; font.weight: Font.Bold
                                    color: topBarWindow.calendarOpen ? themeHub.darkInk : themeHub.barMutedInk
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: topBarWindow.dateText.replace(/^[A-Z0-9]+\s+/, "")
                                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black
                                    color: topBarWindow.calendarOpen ? themeHub.darkInk : themeHub.barInkColor
                                }
                            }

                            MouseArea {
                                id: vDateMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("Calendar & Schedule", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.calendarOpen && (Date.now() - topBarWindow.calendarClosedAt) < 220) return
                                    topBarWindow.calendarOpen = !topBarWindow.calendarOpen
                                }
                            }
                        }
                    }

                    // --- Bottom Zone: Grouped Utilities Pill, Tray, StatusPill, Weather, Bell ---
                    Column {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 4

                        // Grouped Utilities Pill (Settings, Edit pen, Search, Clip, Shelf)
                        Rectangle {
                            width: parent.width
                            height: vUtilCol.implicitHeight + 8
                            radius: 17
                            color: themeHub.barChipColor

                            Column {
                                id: vUtilCol
                                anchors.centerIn: parent
                                spacing: 2

                                Rectangle {
                                    width: 30; height: 19; radius: 9.5
                                    color: themeHub.settingsOpen ? themeHub.accentA : (vSetMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.settingsOpen ? "qrc:/qml/icons/palette-dark.svg" : "qrc:/qml/icons/palette-light.svg"
                                    }
                                    MouseArea {
                                        id: vSetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Settings & Theme", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.settingsOpen && (Date.now() - themeHub.settingsClosedAt) < 220) return
                                            themeHub.spotlightOpen = false; themeHub.clipboardOpen = false
                                            themeHub.settingsOpen = !themeHub.settingsOpen
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 30; height: 19; radius: 9.5
                                    color: themeHub.editMode ? themeHub.accentB : (vEditMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.editMode ? "qrc:/qml/icons/pen-dark.svg" : "qrc:/qml/icons/pen-light.svg"
                                    }
                                    MouseArea {
                                        id: vEditMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip(themeHub.editMode ? "Exit Desktop Edit Mode" : "Edit Desktop Layout", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: { barExtraPopups.hideTip(); themeHub.setEditMode(!themeHub.editMode) }
                                    }
                                }

                                Rectangle {
                                    width: 30; height: 19; radius: 9.5
                                    color: themeHub.spotlightOpen ? themeHub.accentA : (vSpotMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.spotlightOpen ? "qrc:/qml/icons/magnifer-dark.svg" : "qrc:/qml/icons/magnifer-light.svg"
                                    }
                                    MouseArea {
                                        id: vSpotMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Spotlight Launcher (Alt+Space)", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.spotlightOpen && (Date.now() - themeHub.spotlightClosedAt) < 220) return
                                            themeHub.settingsOpen = false; themeHub.clipboardOpen = false
                                            themeHub.spotlightOpen = !themeHub.spotlightOpen
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 30; height: 19; radius: 9.5
                                    color: themeHub.clipboardOpen ? themeHub.accentA : (vClipMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.clipboardOpen ? "qrc:/qml/icons/clipboard-text-dark.svg" : "qrc:/qml/icons/clipboard-text-light.svg"
                                    }
                                    MouseArea {
                                        id: vClipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Clipboard History (Ctrl+Alt+V)", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.clipboardOpen && (Date.now() - themeHub.clipboardClosedAt) < 220) return
                                            themeHub.settingsOpen = false; themeHub.spotlightOpen = false
                                            themeHub.clipboardOpen = !themeHub.clipboardOpen
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 30; height: 19; radius: 9.5
                                    color: themeHub.dropShelfOpen ? themeHub.accentB : (vShelfMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                        source: themeHub.dropShelfOpen ? "qrc:/qml/icons/folder-with-files-dark.svg" : "qrc:/qml/icons/folder-with-files-light.svg"
                                    }
                                    Rectangle {
                                        visible: DropShelfService.count > 0
                                        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 2
                                        width: 5; height: 5; radius: 2.5; color: themeHub.accentB
                                    }
                                    MouseArea {
                                        id: vShelfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Drop Shelf Files (" + DropShelfService.count + ")", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!themeHub.dropShelfOpen && (Date.now() - themeHub.dropShelfClosedAt) < 220) return
                                            themeHub.dropShelfOpen = !themeHub.dropShelfOpen
                                        }
                                    }
                                }
                            }
                        }

                        // Tray Pill (icon-only arrow + unread dot)
                        Rectangle {
                            visible: themeHub.barShowTray
                            width: parent.width; height: 22; radius: 11
                            color: topBarWindow.trayPopupOpen ? themeHub.accentA : (vTrayMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)
                            Image {
                                anchors.centerIn: parent; width: 10; height: 10; sourceSize.width: 20; sourceSize.height: 20; smooth: true
                                source: topBarWindow.trayPopupOpen ? "qrc:/qml/icons/alt-arrow-down-dark.svg" : "qrc:/qml/icons/alt-arrow-up-light.svg"
                            }
                            Rectangle {
                                visible: TrayService.items.length > 0 && !topBarWindow.trayPopupOpen
                                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 4
                                width: 4; height: 4; radius: 2; color: themeHub.accentA
                            }
                            MouseArea {
                                id: vTrayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("System Tray (" + TrayService.items.length + ")", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.trayPopupOpen && (Date.now() - topBarWindow.trayPopupClosedAt) < 220) return
                                    if (!topBarWindow.trayPopupOpen) TrayService.refresh()
                                    topBarWindow.trayPopupOpen = !topBarWindow.trayPopupOpen
                                }
                            }
                        }

                        // SekaiPop Grouped Vertical StatusPill (Wi-Fi / BT / Volume inside ONE pill)
                        Rectangle {
                            width: parent.width
                            height: vStatusCol.implicitHeight + 8
                            radius: 17
                            color: themeHub.barChipColor

                            Column {
                                id: vStatusCol
                                anchors.centerIn: parent
                                spacing: 2

                                Rectangle {
                                    width: 30; height: 21; radius: 10.5
                                    color: topBarWindow.wifiPopupOpen ? themeHub.accentA : (vWifiMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                        source: topBarWindow.wifiPopupOpen
                                            ? (SystemControl.networkType === "Wi-Fi" ? "qrc:/qml/icons/wifi-dark.svg" : "qrc:/qml/icons/network-dark.svg")
                                            : (SystemControl.networkType === "Wi-Fi" ? "qrc:/qml/icons/wifi-light.svg" : "qrc:/qml/icons/network-light.svg")
                                    }
                                    MouseArea {
                                        id: vWifiMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Network (" + (SystemControl.networkName || SystemControl.networkType) + ")", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!topBarWindow.wifiPopupOpen && (Date.now() - topBarWindow.wifiPopupClosedAt) < 220) return
                                            if (!topBarWindow.wifiPopupOpen) { SystemControl.refresh(); SystemControl.refreshWifi() }
                                            topBarWindow.wifiPopupOpen = !topBarWindow.wifiPopupOpen
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 30; height: 20; radius: 10
                                    color: topBarWindow.btPopupOpen ? themeHub.accentA : (vBtMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Image {
                                        anchors.centerIn: parent; width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                        opacity: SystemControl.bluetoothEnabled ? 1.0 : 0.45
                                        source: topBarWindow.btPopupOpen ? "qrc:/qml/icons/bt-dark.svg" : "qrc:/qml/icons/bt-light.svg"
                                    }
                                    MouseArea {
                                        id: vBtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: barExtraPopups.showTip("Bluetooth (" + (SystemControl.bluetoothEnabled ? "ON" : "OFF") + ")", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: {
                                            barExtraPopups.hideTip()
                                            if (!topBarWindow.btPopupOpen && (Date.now() - topBarWindow.btPopupClosedAt) < 220) return
                                            if (!topBarWindow.btPopupOpen) SystemControl.refreshBluetooth()
                                            topBarWindow.btPopupOpen = !topBarWindow.btPopupOpen
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 30; height: 27; radius: 13
                                    color: topBarWindow.volumePopupOpen ? themeHub.accentB : (vVolMa.containsMouse ? themeHub.barChipHover : "transparent")
                                    Column {
                                        anchors.centerIn: parent; spacing: 0
                                        Image {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                            opacity: AudioService.masterMuted ? 0.55 : 0.85
                                            source: topBarWindow.volumePopupOpen
                                                ? (AudioService.masterMuted ? "qrc:/qml/icons/volume-cross-dark.svg" : "qrc:/qml/icons/volume-loud-dark.svg")
                                                : (AudioService.masterMuted ? "qrc:/qml/icons/volume-cross-light.svg" : "qrc:/qml/icons/volume-loud-light.svg")
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: AudioService.masterMuted ? "X" : (AudioService.masterVolume + "%")
                                            font.family: "Consolas"; font.pixelSize: 8; font.weight: Font.Black
                                            color: topBarWindow.volumePopupOpen ? themeHub.darkInk : (AudioService.masterMuted ? "#FCD34D" : themeHub.barInkColor)
                                        }
                                    }
                                    MouseArea {
                                        id: vVolMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onEntered: barExtraPopups.showTip("Volume " + (AudioService.masterMuted ? "Muted" : AudioService.masterVolume + "%") + " · Scroll to Adjust", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                        onExited: barExtraPopups.hideTip()
                                        onClicked: mouse => {
                                            barExtraPopups.hideTip()
                                            if (mouse.button === Qt.RightButton) AudioService.toggleMasterMute()
                                            else {
                                                if (!topBarWindow.volumePopupOpen && (Date.now() - topBarWindow.volumePopupClosedAt) < 220) return
                                                if (!topBarWindow.volumePopupOpen) { AudioService.refreshSessions(); AudioService.refreshOutputDevices() }
                                                topBarWindow.volumePopupOpen = !topBarWindow.volumePopupOpen
                                            }
                                        }
                                        onWheel: wheel => {
                                            AudioService.setMasterVolume(AudioService.masterVolume + (wheel.angleDelta.y > 0 ? 4 : -4))
                                            wheel.accepted = true
                                        }
                                    }
                                }
                            }
                        }

                        // Weather Pill (Solar Sun/Moon + Temp -> WeatherPopup)
                        Rectangle {
                            visible: themeHub.barShowWeather
                            width: parent.width; height: 32; radius: 16
                            color: topBarWindow.weatherPopupOpen ? themeHub.accentB : (vWeatherMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)
                            Column {
                                anchors.centerIn: parent; spacing: 0
                                Image {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 11; height: 11; sourceSize.width: 22; sourceSize.height: 22; smooth: true
                                    source: topBarWindow.weatherPopupOpen
                                        ? (WeatherService.isDay ? "qrc:/qml/icons/sun-dark.svg" : "qrc:/qml/icons/moon-dark.svg")
                                        : (WeatherService.isDay ? "qrc:/qml/icons/sun-light.svg" : "qrc:/qml/icons/moon-light.svg")
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: themeHub.formatTemp(WeatherService.temperature) + "°"
                                    font.family: "Segoe UI"; font.pixelSize: 9; font.weight: Font.Bold
                                    color: topBarWindow.weatherPopupOpen ? themeHub.darkInk : themeHub.barInkColor
                                }
                            }
                            MouseArea {
                                id: vWeatherMa; anchors.fill: parent; hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip((WeatherService.city || "Weather") + " · Click for Forecast", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: mouse => {
                                    barExtraPopups.hideTip()
                                    if (mouse.button === Qt.RightButton) {
                                        WeatherService.refresh()
                                    } else {
                                        if (!topBarWindow.weatherPopupOpen && (Date.now() - topBarWindow.weatherPopupClosedAt) < 220)
                                            return
                                        topBarWindow.weatherPopupOpen = !topBarWindow.weatherPopupOpen
                                    }
                                }
                            }
                        }

                        // Notifications / QuickPanel Bell Circle (Solar Bell + floating unread badge)
                        Item {
                            width: parent.width
                            height: 34

                            Rectangle {
                                anchors.centerIn: parent
                                width: 34; height: 34; radius: 17
                                color: topBarWindow.quickPanelOpen ? themeHub.accentA : (vQpMa.containsMouse ? themeHub.barChipHover : themeHub.barChipColor)
                                Image {
                                    anchors.centerIn: parent
                                    width: 15; height: 15; sourceSize.width: 30; sourceSize.height: 30; smooth: true
                                    source: topBarWindow.quickPanelOpen ? "qrc:/qml/icons/bell-dark.svg" : "qrc:/qml/icons/bell-light.svg"
                                }
                            }

                            Rectangle {
                                visible: NotificationService.count > 0
                                anchors.right: parent.right
                                anchors.top: parent.top
                                width: Math.max(14, vQpCountTxt.implicitWidth + 5)
                                height: 14
                                radius: 7
                                color: "#E11D48"
                                border.width: 1.5; border.color: themeHub.darkInk
                                Text {
                                    id: vQpCountTxt
                                    anchors.centerIn: parent
                                    text: NotificationService.count > 9 ? "9+" : String(NotificationService.count)
                                    font.family: "Segoe UI"; font.pixelSize: 8; font.weight: Font.Bold
                                    color: "#FFFFFF"
                                }
                            }

                            MouseArea {
                                id: vQpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: barExtraPopups.showTip("Quick Panel & Notifications (Ctrl+Alt+A)", topBarWindow.x + barFrame.width * 0.5, topBarWindow.y + mapToItem(null, 0, height * 0.5).y)
                                onExited: barExtraPopups.hideTip()
                                onClicked: {
                                    barExtraPopups.hideTip()
                                    if (!topBarWindow.quickPanelOpen && (Date.now() - topBarWindow.quickPanelClosedAt) < 220) return
                                    if (!topBarWindow.quickPanelOpen) {
                                        AudioService.refreshSessions(); AudioService.refreshOutputDevices()
                                        SystemControl.refresh(); SystemControl.refreshWifi()
                                        SystemControl.refreshBluetooth(); NotificationService.refresh()
                                    }
                                    topBarWindow.quickPanelOpen = !topBarWindow.quickPanelOpen
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // SekaiPop MediaPopup Card (click MediaPill to open)
    // =========================================================================
    PanelWindow {
        id: mediaPopupWindow
        visible: topBarWindow.mediaPopupOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        readonly property int pad: 14
        readonly property int innerW: 344
        readonly property int coverSize: 82

        property bool scrubbing: false
        property real scrubFrac: 0
        property real settleFrac: -1
        property bool showLeft: false
        property real livePos: MediaService.positionSec

        Connections {
            target: MediaService
            function onTimelineChanged() {
                if (!mediaPopupWindow.scrubbing)
                    mediaPopupWindow.livePos = MediaService.positionSec
            }
            function onMediaChanged() {
                mediaPopupWindow.settleFrac = -1
                mediaPopupWindow.livePos = MediaService.positionSec
            }
        }

        Timer {
            interval: 1000
            repeat: true
            running: mediaPopupWindow.visible && MediaService.hasSession && MediaService.isPlaying && !mediaPopupWindow.scrubbing
            onTriggered: {
                if (MediaService.durationSec > 0)
                    mediaPopupWindow.livePos = Math.min(MediaService.durationSec, mediaPopupWindow.livePos + 1.0)
                else
                    mediaPopupWindow.livePos = mediaPopupWindow.livePos + 1.0
            }
        }
        Timer {
            id: mediaSettleTimer
            interval: 1200
            onTriggered: mediaPopupWindow.settleFrac = -1
        }

        readonly property bool hasLen: MediaService.hasSession && MediaService.durationSec > 0
        readonly property real frac: scrubbing ? scrubFrac
            : (settleFrac >= 0 ? settleFrac : (hasLen ? Math.max(0, Math.min(1, livePos / MediaService.durationSec)) : 0))
        readonly property real shownSec: hasLen ? frac * MediaService.durationSec : livePos

        function fmtSec(s) {
            const tot = Math.max(0, Math.floor(s))
            const h = Math.floor(tot / 3600)
            const m = Math.floor((tot % 3600) / 60)
            const sec = tot % 60
            const pad2 = n => (n < 10 ? "0" + n : "" + n)
            return h > 0 ? (h + ":" + pad2(m) + ":" + pad2(sec)) : (m + ":" + pad2(sec))
        }

        function appDisplayName() {
            const raw = MediaService.sourceApp || ""
            const low = raw.toLowerCase()
            if (low.indexOf("firefox") !== -1 || low.indexOf("308046b0af4a39cb") !== -1) return "FIREFOX"
            if (low.indexOf("spotify") !== -1) return "SPOTIFY"
            if (low.indexOf("chrome") !== -1) return "CHROME"
            if (low.indexOf("msedge") !== -1 || low.indexOf("edge") !== -1) return "EDGE"
            if (low.indexOf("vlc") !== -1) return "VLC"
            if (raw === "") return "MEDIA"
            const base = raw.split("!").pop().replace(/\.exe$/i, "")
            return base.slice(0, 14).toUpperCase()
        }

        width: innerW + pad * 2 + cardShadow
        height: popupStack.implicitHeight + pad * 2 + cardShadow

        x: topBarWindow.barPopupX(width, topBarWindow.anchors.margins.left + leftContentRow.x + appBadgeRect.width + 6)
        y: topBarWindow.barPopupY(height, 44)

        property double openedAt: 0
        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                focusActivate()
            }
        }
        onWindowDeactivated: {
            if (topBarWindow.mediaPopupOpen) {
                topBarWindow.mediaPopupClosedAt = Date.now()
                topBarWindow.mediaPopupOpen = false
            }
        }
        Timer {
            interval: 60
            repeat: true
            running: mediaPopupWindow.visible
            onTriggered: {
                if ((Date.now() - mediaPopupWindow.openedAt) > 220 && mediaPopupWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.mediaPopupClosedAt = Date.now()
                    topBarWindow.mediaPopupOpen = false
                }
            }
        }

        // Hard offset shadow
        Rectangle {
            x: mediaPopupFrame.x + mediaPopupWindow.cardShadow
            y: mediaPopupFrame.y + mediaPopupWindow.cardShadow
            width: mediaPopupFrame.width
            height: mediaPopupFrame.height
            radius: mediaPopupFrame.radius
            color: "#1A1B2E"
        }

        // Main SekaiPopup frame
        Rectangle {
            id: mediaPopupFrame
            x: 0
            y: 0
            width: mediaPopupWindow.innerW + mediaPopupWindow.pad * 2
            height: popupStack.implicitHeight + mediaPopupWindow.pad * 2
            radius: 20
            color: themeHub.phoneBorder

            Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: parent.radius - 2
                color: themeHub.phoneCardBg

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 3
                    radius: parent.radius - 3
                    color: themeHub.phoneScreenBg
                }
            }

            Column {
                id: popupStack
                x: mediaPopupWindow.pad
                y: mediaPopupWindow.pad
                width: mediaPopupWindow.innerW
                spacing: 12

                // Multi-player tabs (only shown when > 1 GSMTC session exists)
                Row {
                    id: mediaTabRow
                    visible: MediaService.players && MediaService.players.length > 1
                    width: parent.width
                    spacing: 6

                    Repeater {
                        model: MediaService.players || []
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool isCurrent: modelData.id === MediaService.sourceApp
                            width: tabLbl.implicitWidth + 18
                            height: 24
                            radius: 10
                            color: isCurrent ? themeHub.accentA : themeHub.phoneCardBg
                            border.width: 1.5
                            border.color: isCurrent ? "#1A1B2E" : themeHub.phoneBorder

                            Text {
                                id: tabLbl
                                anchors.centerIn: parent
                                text: modelData.label || "Media"
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.weight: Font.Bold
                                color: isCurrent ? "#1A1B2E" : themeHub.phoneInk
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!isCurrent && modelData.id) {
                                        const sid = modelData.id
                                        Qt.callLater(function() { MediaService.selectSession(sid) })
                                    }
                                }
                            }
                        }
                    }
                }

                // ===== SekaiPlate: Tilted Cover Jacket + App + State Chip + Title/Artist =====
                Item {
                    id: sekaiPlateWrap
                    width: popupStack.width
                    height: 114

                    // Plate hard shadow
                    Rectangle {
                        x: 3
                        y: 3
                        width: sekaiPlate.width
                        height: sekaiPlate.height
                        radius: sekaiPlate.radius
                        color: "#1A1B2E"
                    }

                    Rectangle {
                        id: sekaiPlate
                        width: parent.width - 3
                        height: 110
                        radius: 16
                        color: "#1A1B2E"

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: parent.radius - 2
                            color: "#FFFFFF"

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 2
                                radius: parent.radius - 2
                                gradient: Gradient {
                                    orientation: Gradient.Vertical
                                    GradientStop { position: 0.0; color: themeHub.accentB }
                                    GradientStop { position: 1.0; color: themeHub.accentA }
                                }
                            }
                        }

                        // Tilted Cover Art Keycap (raised when playing, pressed when paused)
                        Item {
                            id: jacketBox
                            x: 13
                            y: 13
                            width: mediaPopupWindow.coverSize
                            height: mediaPopupWindow.coverSize + 3
                            rotation: -4
                            transformOrigin: Item.Center

                            readonly property bool isPressed: jacketMouse.pressed || !MediaService.isPlaying

                            // Keycap shadow
                            Rectangle {
                                x: 0
                                y: 3
                                width: jacketBox.width
                                height: mediaPopupWindow.coverSize
                                radius: 16
                                color: "#1A1B2E"
                            }

                            Rectangle {
                                id: jacketCap
                                x: 0
                                y: jacketBox.isPressed ? 3 : 0
                                width: jacketBox.width
                                height: mediaPopupWindow.coverSize
                                radius: 16
                                color: "#1A1B2E"

                                Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    radius: parent.radius - 2
                                    color: "#FFFFFF"

                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: 2
                                        radius: parent.radius - 2
                                        color: "#E2E8F0"
                                        clip: true

                                        Image {
                                            anchors.centerIn: parent
                                            visible: popupCoverImg.status !== Image.Ready
                                            width: 30
                                            height: 30
                                            sourceSize.width: 60
                                            sourceSize.height: 60
                                            smooth: true
                                            opacity: 0.65
                                            source: "qrc:/qml/icons/music-note-dark.svg"
                                        }

                                        Image {
                                            id: popupCoverImg
                                            anchors.fill: parent
                                            source: MediaService.hasSession ? MediaService.artUrl : ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            smooth: true
                                            mipmap: true
                                            cache: false
                                        }

                                        // Hover overlay
                                        Rectangle {
                                            anchors.fill: parent
                                            color: "#55000000"
                                            opacity: jacketMouse.containsMouse && MediaService.hasSession ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 120 } }

                                            Text {
                                                anchors.centerIn: parent
                                                text: MediaService.isPlaying ? "⏸" : "▶"
                                                font.family: "Segoe UI Symbol"
                                                font.pixelSize: 24
                                                color: "#FFFFFF"
                                            }
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                id: jacketMouse
                                anchors.fill: parent
                                enabled: MediaService.hasSession
                                hoverEnabled: true
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: MediaService.playPause()
                            }
                        }

                        // App badge (top-right area)
                        Row {
                            x: mediaPopupWindow.coverSize + 28
                            y: 13
                            spacing: 6

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 7
                                height: 7
                                rotation: 45
                                color: "#FFFFFF"
                                border.width: 1.5
                                border.color: "#1A1B2E"
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: mediaPopupWindow.appDisplayName()
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.weight: Font.ExtraBold
                                font.letterSpacing: 1.2
                                color: "#1A1B2E"
                                opacity: 0.85
                            }
                        }

                        // Tilted State Chip (PLAYING / PAUSED / IDLE)
                        Rectangle {
                            id: stateChip
                            x: sekaiPlate.width - width - 11
                            y: 7
                            width: stateChipRow.implicitWidth + 18
                            height: 24
                            radius: 9
                            color: "#FFFFFF"
                            border.width: 2
                            border.color: "#1A1B2E"
                            rotation: 3
                            transformOrigin: Item.Center

                            Row {
                                id: stateChipRow
                                anchors.centerIn: parent
                                spacing: 5

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6
                                    height: 6
                                    rotation: 45
                                    color: MediaService.isPlaying ? "#10B981" : "#94A3B8"
                                    border.width: 1
                                    border.color: "#1A1B2E"
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: MediaService.isPlaying ? "PLAYING" : (MediaService.hasSession ? "PAUSED" : "IDLE")
                                    font.family: "Segoe UI"
                                    font.pixelSize: 10
                                    font.weight: Font.ExtraBold
                                    font.letterSpacing: 0.8
                                    color: "#1A1B2E"
                                }
                            }
                        }

                        // Song Title & Artist / Album
                        Column {
                            x: mediaPopupWindow.coverSize + 28
                            y: 38
                            width: sekaiPlate.width - x - 12
                            spacing: 3

                            Text {
                                width: parent.width
                                text: MediaService.hasSession ? (MediaService.title || "Playing") : "Nothing playing"
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                lineHeight: 0.98
                                font.family: "Segoe UI"
                                font.pixelSize: 15
                                font.weight: Font.ExtraBold
                                color: "#1A1B2E"
                            }

                            Text {
                                width: parent.width
                                text: {
                                    if (!MediaService.hasSession)
                                        return "Start a song or video"
                                    const a = MediaService.artist || ""
                                    const alb = MediaService.album || ""
                                    if (a !== "" && alb !== "") return a + "  ·  " + alb
                                    return a !== "" ? a : (alb !== "" ? alb : mediaPopupWindow.appDisplayName())
                                }
                                elide: Text.ElideRight
                                font.family: "Segoe UI"
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                color: "#1E293B"
                                opacity: 0.85
                            }
                        }
                    }
                }

                // ===== Seek Lane: [elapsed] ====<>---- [length] =====
                Item {
                    id: seekLane
                    width: popupStack.width
                    height: 30
                    opacity: mediaPopupWindow.hasLen ? 1.0 : 0.45

                    // Elapsed chip (tilted -3)
                    Rectangle {
                        x: 0
                        y: mediaPopupWindow.scrubbing ? 2 : 0
                        width: 58
                        height: 28
                        radius: 10
                        color: themeHub.phoneCardBg
                        border.width: 2
                        border.color: themeHub.phoneBorder
                        rotation: -3

                        Text {
                            anchors.centerIn: parent
                            text: mediaPopupWindow.hasLen ? mediaPopupWindow.fmtSec(mediaPopupWindow.shownSec) : "--:--"
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            font.weight: Font.ExtraBold
                            color: themeHub.phoneInk
                        }
                    }

                    // Groove + Trail + Diamond Playhead
                    Item {
                        id: seekTrack
                        x: 66
                        width: seekLane.width - 132
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter

                        readonly property real headSize: 13
                        readonly property real headX: Math.min(seekTrack.width - headSize, Math.max(0, seekTrack.width * mediaPopupWindow.frac - headSize / 2))

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 11
                            radius: 5.5
                            color: themeHub.phonePillBg
                            border.width: 2
                            border.color: themeHub.phoneBorder
                        }

                        Rectangle {
                            x: 2
                            anchors.verticalCenter: parent.verticalCenter
                            height: 7
                            radius: 3.5
                            width: Math.max(0, seekTrack.headX + seekTrack.headSize / 2 - 2)
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: themeHub.accentB }
                                GradientStop { position: 1.0; color: themeHub.accentA }
                            }
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            x: seekTrack.headX
                            width: seekTrack.headSize
                            height: seekTrack.headSize
                            radius: 3
                            rotation: 45
                            color: themeHub.accentA
                            border.width: 2
                            border.color: "#1A1B2E"
                            scale: mediaPopupWindow.scrubbing ? 1.3 : (seekMouse.containsMouse ? 1.15 : 1.0)
                            Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutBack } }
                        }

                        MouseArea {
                            id: seekMouse
                            anchors.fill: parent
                            enabled: mediaPopupWindow.hasLen && MediaService.canSeek
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

                            function fracAt(mx) {
                                return Math.max(0, Math.min(1, mx / Math.max(1, width)))
                            }
                            onPressed: mouse => {
                                mediaPopupWindow.scrubFrac = fracAt(mouse.x)
                                mediaPopupWindow.scrubbing = true
                            }
                            onPositionChanged: mouse => {
                                if (pressed)
                                    mediaPopupWindow.scrubFrac = fracAt(mouse.x)
                            }
                            onReleased: mouse => {
                                if (mediaPopupWindow.scrubbing) {
                                    const f = fracAt(mouse.x)
                                    mediaPopupWindow.settleFrac = f
                                    const targetSec = f * MediaService.durationSec
                                    mediaPopupWindow.livePos = targetSec
                                    MediaService.seek(targetSec)
                                    mediaSettleTimer.restart()
                                }
                                mediaPopupWindow.scrubbing = false
                            }
                            onCanceled: mediaPopupWindow.scrubbing = false
                        }
                    }

                    // Total / Remaining chip (tilted +3, click to toggle)
                    Rectangle {
                        x: seekLane.width - width
                        y: totalChipMouse.pressed && mediaPopupWindow.hasLen ? 2 : 0
                        width: 58
                        height: 28
                        radius: 10
                        color: totalChipMouse.containsMouse && mediaPopupWindow.hasLen ? themeHub.hoverTint : themeHub.phoneCardBg
                        border.width: 2
                        border.color: totalChipMouse.containsMouse && mediaPopupWindow.hasLen ? "#1A1B2E" : themeHub.phoneBorder
                        rotation: 3

                        Text {
                            anchors.centerIn: parent
                            text: {
                                if (!mediaPopupWindow.hasLen) return "--:--"
                                if (mediaPopupWindow.showLeft) {
                                    const rem = Math.max(0, MediaService.durationSec - mediaPopupWindow.shownSec)
                                    return "-" + mediaPopupWindow.fmtSec(rem)
                                }
                                return mediaPopupWindow.fmtSec(MediaService.durationSec)
                            }
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            font.weight: Font.ExtraBold
                            color: totalChipMouse.containsMouse && mediaPopupWindow.hasLen ? "#1A1B2E" : themeHub.phoneInk
                        }

                        MouseArea {
                            id: totalChipMouse
                            anchors.fill: parent
                            enabled: mediaPopupWindow.hasLen
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: mediaPopupWindow.showLeft = !mediaPopupWindow.showLeft
                        }
                    }
                }

                // ===== Transport Keys: [ prev ] [ > Play / || Pause ] [ next ] [ close ] =====
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    // Prev key
                    Item {
                        width: 56
                        height: 40
                        opacity: MediaService.hasSession && MediaService.canPrev ? 1.0 : 0.45

                        Rectangle { x: 2; y: 2; width: 54; height: 38; radius: 12; color: "#1A1B2E" }
                        Rectangle {
                            x: prevKeyArea.pressed ? 2 : 0
                            y: prevKeyArea.pressed ? 2 : 0
                            width: 54
                            height: 38
                            radius: 12
                            color: prevKeyArea.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                            border.width: 2
                            border.color: prevKeyArea.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                            Image {
                                anchors.centerIn: parent
                                width: 16
                                height: 16
                                sourceSize.width: 32
                                sourceSize.height: 32
                                smooth: true
                                source: (!prevKeyArea.containsMouse && themeHub.phoneDarkMode)
                                    ? "qrc:/qml/icons/skip-previous-light.svg"
                                    : "qrc:/qml/icons/skip-previous-dark.svg"
                            }
                        }
                        MouseArea {
                            id: prevKeyArea
                            anchors.fill: parent
                            enabled: MediaService.hasSession && MediaService.canPrev
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: MediaService.previous()
                        }
                    }

                    // Primary Play/Pause key
                    Item {
                        width: 112
                        height: 40
                        opacity: MediaService.hasSession ? 1.0 : 0.55

                        Rectangle { x: 2; y: 2; width: 110; height: 38; radius: 12; color: "#1A1B2E" }
                        Rectangle {
                            x: playKeyArea.pressed ? 2 : 0
                            y: playKeyArea.pressed ? 2 : 0
                            width: 110
                            height: 38
                            radius: 12
                            border.width: 2
                            border.color: "#1A1B2E"
                            gradient: Gradient {
                                orientation: Gradient.Vertical
                                GradientStop { position: 0.0; color: themeHub.accentB }
                                GradientStop { position: 1.0; color: themeHub.accentA }
                            }
                            Row {
                                anchors.centerIn: parent
                                spacing: 6
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 14
                                    height: 14
                                    sourceSize.width: 28
                                    sourceSize.height: 28
                                    smooth: true
                                    source: MediaService.isPlaying ? "qrc:/qml/icons/pause-dark.svg" : "qrc:/qml/icons/play-dark.svg"
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: MediaService.isPlaying ? "Pause" : "Play"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 13
                                    font.weight: Font.ExtraBold
                                    color: "#1A1B2E"
                                }
                            }
                        }
                        MouseArea {
                            id: playKeyArea
                            anchors.fill: parent
                            enabled: MediaService.hasSession
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: MediaService.playPause()
                        }
                    }

                    // Next key
                    Item {
                        width: 56
                        height: 40
                        opacity: MediaService.hasSession && MediaService.canNext ? 1.0 : 0.45

                        Rectangle { x: 2; y: 2; width: 54; height: 38; radius: 12; color: "#1A1B2E" }
                        Rectangle {
                            x: nextKeyArea.pressed ? 2 : 0
                            y: nextKeyArea.pressed ? 2 : 0
                            width: 54
                            height: 38
                            radius: 12
                            color: nextKeyArea.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                            border.width: 2
                            border.color: nextKeyArea.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                            Image {
                                anchors.centerIn: parent
                                width: 16
                                height: 16
                                sourceSize.width: 32
                                sourceSize.height: 32
                                smooth: true
                                source: (!nextKeyArea.containsMouse && themeHub.phoneDarkMode)
                                    ? "qrc:/qml/icons/skip-next-light.svg"
                                    : "qrc:/qml/icons/skip-next-dark.svg"
                            }
                        }
                        MouseArea {
                            id: nextKeyArea
                            anchors.fill: parent
                            enabled: MediaService.hasSession && MediaService.canNext
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: MediaService.next()
                        }
                    }

                    // Close popup key
                    Item {
                        width: 40
                        height: 40

                        Rectangle { x: 2; y: 2; width: 38; height: 38; radius: 12; color: "#1A1B2E" }
                        Rectangle {
                            x: closeKeyArea.pressed ? 2 : 0
                            y: closeKeyArea.pressed ? 2 : 0
                            width: 38
                            height: 38
                            radius: 12
                            color: closeKeyArea.containsMouse ? "#FEE2E2" : themeHub.phoneCardBg
                            border.width: 2
                            border.color: closeKeyArea.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                font.family: "Segoe UI"
                                font.pixelSize: 13
                                font.weight: Font.Bold
                                color: closeKeyArea.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                            }
                        }
                        MouseArea {
                            id: closeKeyArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: topBarWindow.mediaPopupOpen = false
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // System Tray Popup (TopBar Tray ▲)
    // =========================================================================
    PanelWindow {
        id: trayPopupWindow
        visible: topBarWindow.trayPopupOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        readonly property int cardW: 248
        property double openedAt: 0
        property bool quitArmed: false

        Timer {
            id: trayQuitResetTimer
            interval: 3500
            onTriggered: trayPopupWindow.quitArmed = false
        }

        width: cardW + cardShadow
        height: Math.max(118, trayCol.implicitHeight + 24) + cardShadow
        x: topBarWindow.barPopupX(width, topBarWindow.anchors.margins.left + rightContentRow.x + trayPill.x + Math.round((trayPill.width - cardW) * 0.5))
        y: topBarWindow.barPopupY(height, themeHub.screenH - height - 60)

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                TrayService.refresh()
                focusActivate()
            } else {
                quitArmed = false
                trayQuitResetTimer.stop()
            }
        }
        Timer {
            interval: 60
            repeat: true
            running: trayPopupWindow.visible
            onTriggered: {
                if ((Date.now() - trayPopupWindow.openedAt) > 220 && trayPopupWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.trayPopupClosedAt = Date.now()
                    topBarWindow.trayPopupOpen = false
                }
            }
        }

        Rectangle {
            x: trayPopupFrame.x + trayPopupWindow.cardShadow
            y: trayPopupFrame.y + trayPopupWindow.cardShadow
            width: trayPopupFrame.width
            height: trayPopupFrame.height
            radius: trayPopupFrame.radius
            color: "#1A1B2E"
        }

        Rectangle {
            id: trayPopupFrame
            x: 0
            y: 0
            width: trayPopupWindow.cardW
            height: Math.max(118, trayCol.implicitHeight + 24)
            radius: 16
            color: themeHub.phoneBorder

            Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: parent.radius - 2
                color: themeHub.phoneCardBg
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: parent.radius - 2
                    color: themeHub.phoneScreenBg
                }
            }

            Column {
                id: trayCol
                x: 12
                y: 12
                width: trayPopupFrame.width - 24
                spacing: 6

                Text {
                    text: "SYSTEM TRAY (" + TrayService.items.length + ")"
                    font.family: "Segoe UI"
                    font.pixelSize: 10
                    font.weight: Font.ExtraBold
                    font.letterSpacing: 1
                    color: themeHub.phoneMutedInk
                }

                Text {
                    visible: TrayService.items.length === 0
                    width: parent.width
                    text: "No Windows tray icons found.\n(Explorer taskbar tray inactive)"
                    wrapMode: Text.Wrap
                    font.family: "Segoe UI"
                    font.pixelSize: 11
                    color: themeHub.phoneMutedInk
                }

                Flickable {
                    width: parent.width
                    height: Math.min(360, trayListCol.implicitHeight)
                    contentWidth: width
                    contentHeight: trayListCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: trayListCol
                        width: parent.width
                        spacing: 6

                        Repeater {
                            model: TrayService.items
                            delegate: Rectangle {
                                required property var modelData
                                width: trayListCol.width
                                height: 30
                                radius: 9
                                color: trayRowArea.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                                border.width: 1.5
                                border.color: trayRowArea.containsMouse ? "#1A1B2E" : themeHub.phoneBorder

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 8

                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 16
                                        height: 16
                                        source: modelData.iconUrl || ""
                                        smooth: true
                                        mipmap: true
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 28
                                        maximumLineCount: 1
                                        elide: Text.ElideRight
                                        text: (modelData.tip || "Tray App").replace(/\r?\n+/g, " · ")
                                        font.family: "Segoe UI"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: trayRowArea.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                                    }
                                }

                                MouseArea {
                                    id: trayRowArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: mouse => {
                                        const idx = modelData.index
                                        const isRight = (mouse.button === Qt.RightButton)
                                        topBarWindow.trayPopupOpen = false
                                        Qt.callLater(function() { TrayService.activateItem(idx, isRight) })
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 1.5
                    color: themeHub.phoneBorder
                }

                Row {
                    width: parent.width
                    height: 28
                    spacing: 6

                    Rectangle {
                        width: (parent.width - 6) * 0.5
                        height: 28
                        radius: 9
                        color: traySettingsMa.containsMouse ? themeHub.accentB : themeHub.phoneCardBg
                        border.width: 1.5
                        border.color: traySettingsMa.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                        Row {
                            anchors.centerIn: parent
                            spacing: 5
                            Image {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 13; height: 13
                                source: (!traySettingsMa.containsMouse && themeHub.phoneDarkMode)
                                    ? "qrc:/qml/icons/settings-light.svg"
                                    : "qrc:/qml/icons/settings-dark.svg"
                                smooth: true
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Settings"
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.weight: Font.Bold
                                color: traySettingsMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                            }
                        }
                        MouseArea {
                            id: traySettingsMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                topBarWindow.trayPopupOpen = false
                                themeHub.openSettings("")
                            }
                        }
                    }

                    Rectangle {
                        width: (parent.width - 6) * 0.5
                        height: 28
                        radius: 9
                        color: trayPopupWindow.quitArmed
                            ? "#FB7185"
                            : (trayQuitMa.containsMouse ? "#FECDD3" : "#FFE4E6")
                        border.width: 1.5
                        border.color: "#1A1B2E"
                        Row {
                            anchors.centerIn: parent
                            spacing: 5
                            Image {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 13; height: 13
                                source: "qrc:/qml/icons/power-dark.svg"
                                smooth: true
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: trayPopupWindow.quitArmed ? "Confirm?" : "Quit"
                                font.family: "Segoe UI"
                                font.pixelSize: 11
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }
                        }
                        MouseArea {
                            id: trayQuitMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!trayPopupWindow.quitArmed) {
                                    trayPopupWindow.quitArmed = true
                                    trayQuitResetTimer.restart()
                                } else {
                                    trayQuitResetTimer.stop()
                                    topBarWindow.trayPopupOpen = false
                                    SystemControl.quitApp()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // Phase 4: SekaiPop 2.5D Tilted Smartphone Control Center (Bottom-Up Pop + 3D Tilt)
    // =========================================================================
    PanelWindow {
        id: quickPanelWindow
        visible: !topBarWindow.effectiveFullscreen && (topBarWindow.quickPanelOpen || stageLift < hiddenLift || notifAlertPeek || themeHub.settingsOpen || flipProgress > 0.001 || flipPrepTimer.running || flipAnim.running || flipRingAnim.running || settingsEnterAnim.running || settingsExitAnim.running)
        clickThrough: !panelWanted && !settingsWanted && !notifAlertPeek
        color: "transparent"

        // PhoneMath (4x4 perspective matrix helpers, pure JS)
        function pmMul(a, b) {
            const r = new Array(16)
            for (let i = 0; i < 4; i++) {
                for (let j = 0; j < 4; j++) {
                    let s = 0
                    for (let k = 0; k < 4; k++)
                        s += a[i * 4 + k] * b[k * 4 + j]
                    r[i * 4 + j] = s
                }
            }
            return r
        }
        function pmTrans(x, y, z) {
            return [1, 0, 0, x,  0, 1, 0, y,  0, 0, 1, z,  0, 0, 0, 1]
        }
        function pmRotX(deg) {
            const r = deg * Math.PI / 180, c = Math.cos(r), s = Math.sin(r)
            return [1, 0, 0, 0,  0, c, -s, 0,  0, s, c, 0,  0, 0, 0, 1]
        }
        function pmRotY(deg) {
            const r = deg * Math.PI / 180, c = Math.cos(r), s = Math.sin(r)
            return [c, 0, s, 0,  0, 1, 0, 0,  -s, 0, c, 0,  0, 0, 0, 1]
        }
        function pmRotZ(deg) {
            const r = deg * Math.PI / 180, c = Math.cos(r), s = Math.sin(r)
            return [c, -s, 0, 0,  s, c, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1]
        }
        function pmPersp(d) {
            return [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, -1 / d, 1]
        }
        function pmFlatZ() {
            return [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 0, 0,  0, 0, 0, 1]
        }
        function pmApply(m, x, y, z) {
            const X = m[0] * x + m[1] * y + m[2] * z + m[3]
            const Y = m[4] * x + m[5] * y + m[6] * z + m[7]
            const W = m[12] * x + m[13] * y + m[14] * z + m[15]
            return { x: X / W, y: Y / W }
        }
        function pmZOffset(m, z) {
            return [m[0], m[1], m[2], m[3] + z * m[2],
                    m[4], m[5], m[6], m[7] + z * m[6],
                    m[8], m[9], m[10], m[11] + z * m[10],
                    m[12], m[13], m[14], m[15] + z * m[14]]
        }
        function pmBuildPose(W, H, T, R, yaw, pitch, d, pad) {
            const rot = pmMul(pmRotY(-yaw), pmRotX(pitch))
            const c = pmMul(pmPersp(d), pmMul(rot, pmTrans(-W / 2, -H / 2, T / 2)))
            const pts = []
            const cs = [[R, R, Math.PI], [W - R, R, 1.5 * Math.PI],
                        [W - R, H - R, 0], [R, H - R, 0.5 * Math.PI]]
            for (let ci = 0; ci < cs.length; ci++) {
                for (let i = 0; i <= 6; i++) {
                    const a = cs[ci][2] + (i / 6) * Math.PI / 2
                    pts.push([cs[ci][0] + R * Math.cos(a), cs[ci][1] + R * Math.sin(a)])
                }
            }
            let minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9
            for (let zi = 0; zi < 2; zi++) {
                const z = zi === 0 ? 0 : -T
                for (let i = 0; i < pts.length; i++) {
                    const p = pmApply(c, pts[i][0], pts[i][1], z)
                    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x)
                    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y)
                }
            }
            const off = pmTrans(-minX + pad, -minY + pad, 0)
            return {
                base: pmMul(pmFlatZ(), pmMul(off, c)),
                w: maxX - minX + 2 * pad,
                h: maxY - minY + 2 * pad,
                minX: minX,
                minY: minY,
                pad: pad
            }
        }
        function pmBaseFor(W, H, T, yaw, pitch, roll, d, rest) {
            const rot = pmMul(pmRotY(-yaw), pmMul(pmRotX(pitch), pmRotZ(roll)))
            const c = pmMul(pmPersp(d), pmMul(rot, pmTrans(-W / 2, -H / 2, T / 2)))
            const off = pmTrans(-rest.minX + rest.pad, -rest.minY + rest.pad, 0)
            return pmMul(pmFlatZ(), pmMul(off, c))
        }
        function pmBaseForCenter(W, H, T, yaw, pitch, roll, d) {
            const rot = pmMul(pmRotY(-yaw), pmMul(pmRotX(pitch), pmRotZ(roll)))
            return pmMul(pmFlatZ(), pmMul(pmPersp(d), pmMul(rot, pmTrans(-W / 2, -H / 2, T / 2))))
        }
        function toQtMat(m) {
            return Qt.matrix4x4(m[0], m[1], m[2], m[3],
                                m[4], m[5], m[6], m[7],
                                m[8], m[9], m[10], m[11],
                                m[12], m[13], m[14], m[15])
        }
        // FlipMath (exact SekaiPop FlipMath.js parity)
        function fmClamp01(v) {
            return v < 0 ? 0 : (v > 1 ? 1 : v)
        }
        function fmLerp(a, b, t) {
            return a + (b - a) * t
        }
        function fmSmooth(a, b, v) {
            const t = fmClamp01((v - a) / (b - a))
            return t * t * (3 - 2 * t)
        }
        function fmDip(p, depth) {
            return 1.0 - depth * Math.sin(Math.PI * fmClamp01(p))
        }
        function fmQuickScale(p, qFit, sFit, depth) {
            return fmLerp(qFit, 1.16 * sFit, p) * fmDip(p, depth)
        }
        function fmQuickAlpha(p) {
            return 1.0 - fmSmooth(0.35, 0.92, p)
        }
        function fmSettingsAlpha(p) {
            return fmSmooth(0.02, 0.55, p)
        }
        function formatRate(bps) {
            const v = Number(bps) || 0
            if (v >= 1048576) return (v / 1048576).toFixed(1) + " MB/s"
            if (v >= 1024) return Math.round(v / 1024) + " KB/s"
            return Math.round(v) + " B/s"
        }

        // Design-space constants matching SekaiPop PhoneBody (654x1214) & SettingsStage (1440x760)
        readonly property real faceW: 654
        readonly property real faceH: 1214
        readonly property real cornerR: 100
        readonly property real rimW: 10
        readonly property real bezelW: 16
        readonly property real screenInset: rimW + bezelW
        readonly property real thickness: topBarWindow.phoneMode ? 92 : 0
        readonly property real poseYaw: topBarWindow.phoneMode ? 33 : 0
        readonly property real posePitch: topBarWindow.phoneMode ? 18 : 0
        readonly property real tiltRoll: topBarWindow.phoneMode ? 12 : 0
        readonly property real tiltPitch: topBarWindow.phoneMode ? 10 : 0
        readonly property real tiltYaw: topBarWindow.phoneMode ? -6 : 0
        readonly property real curPersp: 3400 + 2600 * fmClamp01(flipProgress)
        readonly property var phonePose: pmBuildPose(faceW, faceH, thickness, cornerR, poseYaw, posePitch, 3400, 14)
        readonly property real fitScale: Math.min(
            topBarWindow.phoneMode ? 0.64 : 0.68,
            Math.max(0.40, (themeHub.screenH - 96) / Math.max(1214, phonePose.h))
        )

        readonly property int phoneBoxW: Math.ceil(phonePose.w * fitScale) + 18
        readonly property int phoneBoxH: Math.ceil(phonePose.h * fitScale) + 10
        readonly property int railPad: 74
        readonly property real bounce: 26
        readonly property real headroom: 32
        readonly property int bottomPad: 18
        readonly property real enterFrom: phoneBoxH + bottomPad + 2
        readonly property real exitTail: Math.ceil(phoneBoxH * 0.3)
        readonly property real hiddenLift: enterFrom + exitTail

        // Landscape Settings Chassis constants (1440x760 rotated 90 deg CCW from portrait)
        readonly property real landW: 1440
        readonly property real landH: 760
        readonly property real landCornerR: 92
        readonly property real landThickness: topBarWindow.phoneMode ? 135 : 0
        readonly property real landYaw: topBarWindow.phoneMode ? 24 : 0
        readonly property real landPitch: topBarWindow.phoneMode ? 12 : 0
        readonly property real landTiltYaw: topBarWindow.phoneMode ? -22 : 0
        readonly property real landTiltPitch: topBarWindow.phoneMode ? 14 : 0
        readonly property real landTiltRoll: topBarWindow.phoneMode ? 7 : 0
        readonly property real landPopFrom: 0.55
        readonly property real landScale: Math.min(0.76, Math.max(0.42, Math.min((themeHub.screenW - 96) / landW, (themeHub.screenH - 84) / landH)))
        readonly property int portWinW: phoneBoxW + railPad * 2
        readonly property int portWinH: phoneBoxH + headroom + bottomPad
        readonly property int portWinX: Math.round((themeHub.screenW - portWinW) * 0.5)
        readonly property int portWinY: Math.max(0, themeHub.screenH - portWinH)

        readonly property real flipDip: 0.12
        readonly property int flipMs: 200
        readonly property real flipWobble: 2.5
        readonly property int flipRingMs: 380

        property real flipProgress: 0.0
        property real flipWob: 0.0
        property real ringSign: -1.0
        property real sPop: 1.0
        property real sAlpha: 1.0
        property real sTilt: 0.0
        property real flipTarget: 0.0
        property bool settingsOpenedFromQuick: false
        property bool standaloneSettings: false
        readonly property bool flipping: flipPrepTimer.running || flipAnim.running
        readonly property bool settingsAnimating: settingsEnterAnim.running || settingsExitAnim.running
        readonly property bool inLandscapeStage: themeHub.settingsOpen || flipProgress > 0.001 || flipping || flipRingAnim.running || settingsAnimating

        property real powerShiftX: powerMenuOpen ? Math.round(railPad * 0.4) : railPad
        Behavior on powerShiftX { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
        readonly property real portStageX: portWinX + powerShiftX
        readonly property real portOx: -phonePose.minX + phonePose.pad
        readonly property real portOy: -phonePose.minY + phonePose.pad
        readonly property real portCenterX: portStageX + 4 + portOx * fitScale
        readonly property real portCenterY: portWinY + headroom + 4 + stageLift + portOy * fitScale
        readonly property real landCenterX: themeHub.screenW * 0.5
        readonly property real landCenterY: themeHub.screenH * 0.5
        readonly property real curCenterX: portCenterX + (landCenterX - portCenterX) * flipProgress
        readonly property real curCenterY: portCenterY + (landCenterY - portCenterY) * flipProgress
        readonly property real curQuickScale: fmQuickScale(flipProgress, fitScale, landScale, flipDip)
        readonly property real curQuickAlpha: fmQuickAlpha(flipProgress)
        readonly property real curSettingsAlpha: sAlpha * fmSettingsAlpha(flipProgress)
        readonly property real curLandScale: (curQuickScale / 1.16) * (landPopFrom + (1.0 - landPopFrom) * sPop)
        readonly property real curYaw: poseYaw + (landYaw - poseYaw) * flipProgress
        readonly property real curPitch: posePitch + (landPitch - posePitch) * flipProgress
        readonly property real wobRoll: topBarWindow.phoneMode ? flipWob : 0.0
        readonly property real wobPitch: topBarWindow.phoneMode ? (flipWob * 0.5) : 0.0

        readonly property var liveBase: pmBaseFor(
            faceW, faceH, thickness,
            curYaw + stageTilt * tiltYaw,
            curPitch + stageTilt * tiltPitch + wobPitch,
            stageTilt * tiltRoll - 90.0 * flipProgress + wobRoll,
            curPersp,
            phonePose
        )

        property real stageLift: hiddenLift
        property real stageTilt: 1.0
        property real exitPeak: 0
        property int exitPeakMs: 130
        readonly property bool animating: enterAnim.running || exitAnim.running
        readonly property bool panelWanted: topBarWindow.quickPanelOpen && !topBarWindow.fullscreenActive
        readonly property bool settingsWanted: themeHub.settingsOpen && !topBarWindow.fullscreenActive

        // Part 2 Phone Polish: Buzz shake, OutBack power press, Live Phone Peek & Straight-on Wallpapers
        property real buzzX: 0.0
        property bool powerSidePressed: false
        property real powerStick: powerSidePressed ? 4.0 : (powerMenuOpen ? 10.0 : 16.0)
        Behavior on powerStick { NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }

        property bool notifAlertPeek: false
        property var alertNotifItem: null
        property bool alertHovered: false
        readonly property real peekLiftTarget: Math.max(40, enterFrom - 255)

        readonly property real targetStraight: themeHub.landscapeContent === "wallpapers" ? 1.0 : 0.0
        property real straightK: targetStraight
        Behavior on straightK { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
        readonly property real targetContent: themeHub.landscapeContent === "wallpapers" ? 1.0 : 0.0
        property real contentK: targetContent
        Behavior on contentK { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }

        property double openedAt: 0
        property bool pickingFile: false
        property bool powerMenuOpen: false
        property string bottomTab: "notifications" // "notifications" | "display"
        property string subDialog: ""              // "" | "wifi" | "bt"
        property int selectedMonitorIdx: 0

        // Single persistent full-screen overlay window: zero Win32 resize/jump during Portrait <-> Landscape flip
        x: 0
        y: 0
        width: themeHub.screenW
        height: themeHub.screenH

        mask: (panelWanted || settingsWanted || inLandscapeStage || exitAnim.running || settingsExitAnim.running || (!notifAlertPeek && stageLift < hiddenLift))
            ? null
            : (notifAlertPeek
                ? [
                    {
                        x: Math.max(0, portWinX),
                        y: Math.max(0, themeHub.screenH - 300),
                        width: portWinW,
                        height: 300
                    }
                  ]
                : [
                    {
                        x: 0,
                        y: 0,
                        width: 1,
                        height: 1
                    }
                  ])

        onVisibleChanged: {
            SystemControl.setNetSpeedActive(visible)
        }

        onWindowDeactivated: {
            if (!panelWanted && !settingsWanted)
                return
            if (pickingFile)
                return
            if ((Date.now() - openedAt) < 250)
                return
            topBarWindow.quickPanelClosedAt = Date.now()
            topBarWindow.quickPanelOpen = false
            if (themeHub.settingsOpen)
                themeHub.settingsOpen = false
        }

        function triggerBuzz() {
            buzzAnim.restart()
        }

        function dismissNotifPeek() {
            alertAutoHideTimer.stop()
            if (panelWanted || inLandscapeStage) {
                notifAlertPeek = false
                alertNotifItem = null
                return
            }
            if (!notifAlertPeek)
                return
            notifPeekEnterAnim.stop()
            notifPeekExitAnim.restart()
        }

        function dismissImmediatelyForLauncher() {
            flipPrepTimer.stop()
            flipAnim.stop()
            flipRingAnim.stop()
            enterAnim.stop()
            exitAnim.stop()
            settingsEnterAnim.stop()
            settingsExitAnim.stop()
            buzzAnim.stop()
            notifPeekEnterAnim.stop()
            notifPeekExitAnim.stop()
            alertAutoHideTimer.stop()
            buzzX = 0.0
            notifAlertPeek = false
            alertNotifItem = null
            settingsOpenedFromQuick = false
            standaloneSettings = false
            powerMenuOpen = false
            subDialog = ""
            themeHub.landscapeContent = "settings"
            flipProgress = 0.0
            flipWob = 0.0
            sPop = 1.0
            sAlpha = 1.0
            sTilt = 0.0
            stageLift = hiddenLift
            stageTilt = 1.0
            topBarWindow.quickPanelClosedAt = Date.now()
            topBarWindow.quickPanelOpen = false
            themeHub.settingsOpen = false
        }

        Connections {
            target: themeHub
            function onSpotlightOpenChanged() {
                if (themeHub.spotlightOpen && (topBarWindow.quickPanelOpen || themeHub.settingsOpen || quickPanelWindow.visible))
                    quickPanelWindow.dismissImmediatelyForLauncher()
            }
        }

        Connections {
            target: NotificationService
            function onNewNotificationReceived(item) {
                if (!item || themeHub.notifyStyle !== "phone")
                    return
                if (themeHub.notifyQuietFullscreen && topBarWindow.fullscreenActive)
                    return
                if (quickPanelWindow.inLandscapeStage)
                    return
                quickPanelWindow.alertNotifItem = item
                if (quickPanelWindow.panelWanted) {
                    quickPanelWindow.triggerBuzz()
                    return
                }
                exitAnim.stop()
                notifPeekExitAnim.stop()
                quickPanelWindow.standaloneSettings = false
                quickPanelWindow.flipProgress = 0.0
                quickPanelWindow.sPop = 1.0
                quickPanelWindow.sAlpha = 1.0
                quickPanelWindow.sTilt = 0.0
                quickPanelWindow.stageTilt = 0.0
                if (quickPanelWindow.stageLift > quickPanelWindow.enterFrom)
                    quickPanelWindow.stageLift = quickPanelWindow.enterFrom
                quickPanelWindow.notifAlertPeek = true
                notifPeekEnterAnim.restart()
                quickPanelWindow.triggerBuzz()
                alertAutoHideTimer.restart()
            }
        }

        SequentialAnimation {
            id: buzzAnim
            NumberAnimation { target: quickPanelWindow; property: "buzzX"; to: 14; duration: 42; easing.type: Easing.OutQuad }
            NumberAnimation { target: quickPanelWindow; property: "buzzX"; to: -12; duration: 48; easing.type: Easing.InOutQuad }
            NumberAnimation { target: quickPanelWindow; property: "buzzX"; to: 9; duration: 48; easing.type: Easing.InOutQuad }
            NumberAnimation { target: quickPanelWindow; property: "buzzX"; to: -6; duration: 44; easing.type: Easing.InOutQuad }
            NumberAnimation { target: quickPanelWindow; property: "buzzX"; to: 3; duration: 38; easing.type: Easing.InOutQuad }
            NumberAnimation { target: quickPanelWindow; property: "buzzX"; to: 0; duration: 34; easing.type: Easing.OutQuad }
        }

        NumberAnimation {
            id: notifPeekEnterAnim
            target: quickPanelWindow
            property: "stageLift"
            to: quickPanelWindow.peekLiftTarget
            duration: 320
            easing.type: Easing.OutBack
            easing.overshoot: 1.05
        }

        NumberAnimation {
            id: notifPeekExitAnim
            target: quickPanelWindow
            property: "stageLift"
            to: quickPanelWindow.hiddenLift
            duration: 240
            easing.type: Easing.InCubic
            onFinished: {
                if (!quickPanelWindow.panelWanted && !quickPanelWindow.inLandscapeStage && quickPanelWindow.stageLift >= quickPanelWindow.hiddenLift - 2) {
                    quickPanelWindow.notifAlertPeek = false
                    quickPanelWindow.alertNotifItem = null
                    quickPanelWindow.stageTilt = 1.0
                }
            }
        }

        Timer {
            id: alertAutoHideTimer
            interval: 4600
            repeat: false
            onTriggered: {
                if (quickPanelWindow.alertHovered) {
                    restart()
                } else {
                    quickPanelWindow.dismissNotifPeek()
                }
            }
        }

        function turnTo(targetFlip) {
            flipRingAnim.stop()
            flipAnim.stop()
            flipTarget = targetFlip
            flipPrepTimer.ticks = 0
            flipPrepTimer.restart()
        }

        onSettingsWantedChanged: {
            if (settingsWanted) {
                settingsExitAnim.stop()
                flipPrepTimer.stop()
                flipAnim.stop()
                flipRingAnim.stop()
                flipWob = 0.0
                powerMenuOpen = false
                subDialog = ""
                openedAt = Date.now()
                AudioService.refreshSessions()
                AudioService.refreshOutputDevices()
                SystemControl.refresh()
                SystemControl.refreshWifi()
                SystemControl.refreshBluetooth()
                NotificationService.refresh()
                WeatherService.refresh()
                const wasQuickOpen = topBarWindow.quickPanelOpen && stageLift < enterFrom * 0.55
                settingsOpenedFromQuick = wasQuickOpen
                if (wasQuickOpen) {
                    standaloneSettings = false
                    enterAnim.stop()
                    exitAnim.stop()
                    stageLift = 0
                    stageTilt = 0
                    sPop = 1.0
                    sAlpha = 1.0
                    sTilt = 0.0
                    turnTo(1.0)
                } else {
                    standaloneSettings = true
                    topBarWindow.quickPanelOpen = false
                    stageLift = hiddenLift
                    flipProgress = 1.0
                    sPop = 0.0
                    sTilt = 1.0
                    sAlpha = 0.0
                    settingsEnterAnim.restart()
                }
                focusActivate()
                qpKeyCatcher.forceActiveFocus()
            } else {
                flipPrepTimer.stop()
                flipAnim.stop()
                flipRingAnim.stop()
                settingsEnterAnim.stop()
                if (topBarWindow.fullscreenActive) {
                    themeHub.settingsOpen = false
                    topBarWindow.quickPanelOpen = false
                    flipProgress = 0.0
                    flipWob = 0.0
                    sPop = 1.0
                    sAlpha = 1.0
                    sTilt = 0.0
                    standaloneSettings = false
                    settingsOpenedFromQuick = false
                    stageLift = hiddenLift
                    return
                }
                if (settingsOpenedFromQuick && topBarWindow.quickPanelOpen) {
                    standaloneSettings = false
                    openedAt = Date.now()
                    sPop = 1.0
                    sAlpha = 1.0
                    sTilt = 0.0
                    stageLift = 0
                    stageTilt = 0
                    turnTo(0.0)
                    focusActivate()
                    qpKeyCatcher.forceActiveFocus()
                } else {
                    flipPrepTimer.stop()
                    flipAnim.stop()
                    flipRingAnim.stop()
                    if (flipProgress > 0.5) {
                        flipProgress = 1.0
                        settingsExitAnim.restart()
                    } else {
                        flipProgress = 0.0
                        flipWob = 0.0
                        settingsOpenedFromQuick = false
                        standaloneSettings = false
                        if (!panelWanted) {
                            stageLift = hiddenLift
                            stageTilt = 1.0
                        }
                    }
                }
            }
        }

        onPanelWantedChanged: {
            if (panelWanted) {
                exitAnim.stop()
                notifPeekEnterAnim.stop()
                notifPeekExitAnim.stop()
                alertAutoHideTimer.stop()
                notifAlertPeek = false
                alertNotifItem = null
                openedAt = Date.now()
                powerMenuOpen = false
                subDialog = ""
                AudioService.refreshSessions()
                AudioService.refreshOutputDevices()
                SystemControl.refresh()
                SystemControl.refreshWifi()
                SystemControl.refreshBluetooth()
                NotificationService.refresh()
                if (themeHub.settingsOpen)
                    return
                standaloneSettings = false
                if (stageLift > enterFrom)
                    stageLift = enterFrom
                enterAnim.restart()
                focusActivate()
                qpKeyCatcher.forceActiveFocus()
            } else {
                enterAnim.stop()
                notifPeekEnterAnim.stop()
                notifPeekExitAnim.stop()
                alertAutoHideTimer.stop()
                notifAlertPeek = false
                alertNotifItem = null
                powerMenuOpen = false
                subDialog = ""
                if (topBarWindow.fullscreenActive) {
                    topBarWindow.quickPanelOpen = false
                    stageLift = hiddenLift
                    stageTilt = 1.0
                    return
                }
                if (themeHub.settingsOpen)
                    return
                if (stageLift >= hiddenLift)
                    return
                flipPrepTimer.stop()
                flipAnim.stop()
                flipRingAnim.stop()
                flipProgress = 0.0
                flipWob = 0.0
                settingsOpenedFromQuick = false
                standaloneSettings = false
                const rising = stageLift > 20
                exitPeak = rising ? stageLift : -bounce * 0.7
                exitPeakMs = rising ? 1 : 130
                exitAnim.restart()
            }
        }

        Timer {
            id: flipPrepTimer
            interval: 16
            repeat: true
            property int ticks: 0
            onTriggered: {
                ticks++
                if (ticks < 2)
                    return
                stop()
                quickPanelWindow.ringSign = quickPanelWindow.flipTarget > 0.5 ? -1.0 : 1.0
                flipAnim.to = quickPanelWindow.flipTarget
                flipAnim.restart()
                flipRingAnim.restart()
            }
        }

        SequentialAnimation {
            id: flipRingAnim
            PauseAnimation {
                duration: Math.round(quickPanelWindow.flipMs * 0.62)
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "flipWob"
                to: quickPanelWindow.ringSign * quickPanelWindow.flipWobble
                duration: Math.round(quickPanelWindow.flipRingMs * 0.42)
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "flipWob"
                to: -quickPanelWindow.ringSign * quickPanelWindow.flipWobble * 0.1
                duration: Math.round(quickPanelWindow.flipRingMs * 0.38)
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "flipWob"
                to: 0.0
                duration: Math.round(quickPanelWindow.flipRingMs * 0.2)
                easing.type: Easing.InOutSine
            }
        }

        NumberAnimation {
            id: flipAnim
            target: quickPanelWindow
            property: "flipProgress"
            duration: quickPanelWindow.flipMs
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.30, 0.0, 0.20, 1.0, 1.0, 1.0]
            onFinished: {
                if (!themeHub.settingsOpen && quickPanelWindow.flipProgress < 0.05) {
                    quickPanelWindow.flipProgress = 0.0
                    quickPanelWindow.settingsOpenedFromQuick = false
                    quickPanelWindow.standaloneSettings = false
                    themeHub.landscapeContent = "settings"
                    if (quickPanelWindow.panelWanted) {
                        quickPanelWindow.openedAt = Date.now()
                        quickPanelWindow.focusActivate()
                        qpKeyCatcher.forceActiveFocus()
                    }
                } else if (themeHub.settingsOpen) {
                    quickPanelWindow.focusActivate()
                    qpKeyCatcher.forceActiveFocus()
                }
            }
        }

        ParallelAnimation {
            id: settingsEnterAnim
            NumberAnimation {
                target: quickPanelWindow
                property: "sPop"
                to: 1.0
                duration: 560
                easing.type: Easing.OutBack
                easing.overshoot: 1.5
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "sTilt"
                to: 0.0
                duration: 900
                easing.type: Easing.OutElastic
                easing.amplitude: 1.0
                easing.period: 0.45
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "sAlpha"
                to: 1.0
                duration: 140
                easing.type: Easing.OutQuad
            }
        }

        ParallelAnimation {
            id: settingsExitAnim
            onFinished: {
                if (!themeHub.settingsOpen) {
                    quickPanelWindow.flipProgress = 0.0
                    quickPanelWindow.flipWob = 0.0
                    quickPanelWindow.sPop = 1.0
                    quickPanelWindow.sAlpha = 1.0
                    quickPanelWindow.sTilt = 0.0
                    quickPanelWindow.settingsOpenedFromQuick = false
                    quickPanelWindow.standaloneSettings = false
                    themeHub.landscapeContent = "settings"
                    if (!quickPanelWindow.panelWanted) {
                        quickPanelWindow.stageLift = quickPanelWindow.hiddenLift
                        quickPanelWindow.stageTilt = 1.0
                    }
                }
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "sPop"
                to: 0.0
                duration: 340
                easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "sAlpha"
                to: 0.0
                duration: 290
                easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "sTilt"
                to: 0.8
                duration: 340
                easing.type: Easing.InOutQuad
            }
        }

        ParallelAnimation {
            id: enterAnim
            SequentialAnimation {
                NumberAnimation {
                    target: quickPanelWindow
                    property: "stageLift"
                    to: -quickPanelWindow.bounce
                    duration: 340
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: quickPanelWindow
                    property: "stageLift"
                    to: 0
                    duration: 170
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: quickPanelWindow
                    property: "stageLift"
                    to: -quickPanelWindow.bounce * 0.14
                    duration: 110
                    easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: quickPanelWindow
                    property: "stageLift"
                    to: 0
                    duration: 110
                    easing.type: Easing.InQuad
                }
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "stageTilt"
                to: 0
                duration: 820
                easing.type: Easing.OutElastic
                easing.amplitude: 1.0
                easing.period: 0.4
            }
        }

        ParallelAnimation {
            id: exitAnim
            SequentialAnimation {
                NumberAnimation {
                    target: quickPanelWindow
                    property: "stageLift"
                    to: quickPanelWindow.exitPeak
                    duration: quickPanelWindow.exitPeakMs
                    easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: quickPanelWindow
                    property: "stageLift"
                    to: quickPanelWindow.hiddenLift
                    duration: 340
                    easing.type: Easing.InCubic
                }
            }
            NumberAnimation {
                target: quickPanelWindow
                property: "stageTilt"
                to: 1.0
                duration: 440
                easing.type: Easing.InQuad
            }
        }

        Timer {
            id: outsideClickWatcher
            interval: 20
            repeat: true
            running: quickPanelWindow.panelWanted && !quickPanelWindow.pickingFile && !quickPanelWindow.inLandscapeStage
            onTriggered: {
                if ((Date.now() - quickPanelWindow.openedAt) > 220 && quickPanelWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.quickPanelClosedAt = Date.now()
                    topBarWindow.quickPanelOpen = false
                }
            }
        }

        Item {
            id: qpKeyCatcher
            focus: quickPanelWindow.panelWanted || quickPanelWindow.settingsWanted
            Keys.onEscapePressed: event => {
                if (themeHub.settingsOpen) {
                    if (themeHub.landscapeContent === "wallpapers") {
                        themeHub.landscapeContent = "settings"
                    } else if (themeHub.settingsSection !== "") {
                        themeHub.settingsSection = ""
                    } else {
                        themeHub.settingsOpen = false
                    }
                } else if (quickPanelWindow.subDialog !== "") {
                    quickPanelWindow.subDialog = ""
                } else if (quickPanelWindow.powerMenuOpen) {
                    quickPanelWindow.powerMenuOpen = false
                } else {
                    topBarWindow.quickPanelClosedAt = Date.now()
                    topBarWindow.quickPanelOpen = false
                }
                event.accepted = true
            }
        }

        // Power Menu Pill Rail (pops out beside the phone's side Power button)
        Item {
            id: powerRail
            x: quickPanelWindow.portStageX + quickPanelWindow.phoneBoxW + 4
            y: Math.max(40, Math.min(themeHub.screenH - height - 20, quickPanelWindow.portWinY + quickPanelWindow.headroom + Math.round(280 * quickPanelWindow.fitScale) + quickPanelWindow.stageLift))
            width: 70
            height: 406
            visible: opacity > 0.01 && !quickPanelWindow.inLandscapeStage
            opacity: (quickPanelWindow.powerMenuOpen && !quickPanelWindow.inLandscapeStage) ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: quickPanelWindow.powerMenuOpen ? 120 : 200 } }
            z: 20

            property bool quitArmed: false
            property int hoveredIdx: -1
            property int shownHoverIdx: 0
            readonly property var fullLabels: [
                "Lock Screen",
                "Sleep PC",
                "Hibernate PC",
                "Sign Out",
                "Restart PC",
                "Shut Down PC",
                "Quit SekaiDesk"
            ]

            onHoveredIdxChanged: {
                if (hoveredIdx >= 0)
                    shownHoverIdx = hoveredIdx
            }

            Timer {
                id: railQuitResetTimer
                interval: 3500
                onTriggered: powerRail.quitArmed = false
            }

            Connections {
                target: quickPanelWindow
                function onPowerMenuOpenChanged() {
                    if (!quickPanelWindow.powerMenuOpen) {
                        powerRail.quitArmed = false
                        powerRail.hoveredIdx = -1
                        railQuitResetTimer.stop()
                    }
                }
            }

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                Repeater {
                    model: [
                        { label: "Lock",     icon: "qrc:/qml/icons/lock-dark.svg",         col: "#E0F2FE", act: "lock" },
                        { label: "Sleep",    icon: "qrc:/qml/icons/moon-sleep-dark.svg",   col: "#EDE9FE", act: "sleep" },
                        { label: "Hibern.",  icon: "qrc:/qml/icons/snowflake-dark.svg",    col: "#E0E7FF", act: "hibernate" },
                        { label: "Sign Out", icon: "qrc:/qml/icons/logout-dark.svg",       col: "#FEF3C7", act: "signout" },
                        { label: "Restart",  icon: "qrc:/qml/icons/restart-dark.svg",      col: "#FFEDD5", act: "restart" },
                        { label: "Shut Dn",  icon: "qrc:/qml/icons/power-dark.svg",        col: "#FFE4E6", act: "shutdown" },
                        { label: "Quit App", icon: "qrc:/qml/icons/close-circle-dark.svg", col: "#FECDD3", act: "quitapp" }
                    ]
                    delegate: Item {
                        id: railBtn
                        required property var modelData
                        required property int index
                        readonly property bool isQuitArmed: modelData.act === "quitapp" && powerRail.quitArmed

                        width: 66
                        height: 48

                        property real popT: quickPanelWindow.powerMenuOpen ? 1.0 : 0.0
                        opacity: popT
                        transform: [
                            Scale {
                                origin.x: 33; origin.y: 24
                                xScale: 0.4 + 0.6 * railBtn.popT
                                yScale: 0.4 + 0.6 * railBtn.popT
                            },
                            Translate {
                                x: (1.0 - railBtn.popT) * -36
                            }
                        ]

                        SequentialAnimation {
                            id: railPopIn
                            PauseAnimation { duration: railBtn.index * 30 }
                            NumberAnimation {
                                target: railBtn; property: "popT"; to: 1.0; duration: 300
                                easing.type: Easing.OutBack; easing.overshoot: 1.6
                            }
                        }
                        SequentialAnimation {
                            id: railPopOut
                            PauseAnimation { duration: (6 - railBtn.index) * 20 }
                            NumberAnimation {
                                target: railBtn; property: "popT"; to: 0.0; duration: 140
                                easing.type: Easing.InCubic
                            }
                        }

                        Connections {
                            target: quickPanelWindow
                            function onPowerMenuOpenChanged() {
                                if (quickPanelWindow.powerMenuOpen) {
                                    railPopOut.stop()
                                    railPopIn.restart()
                                } else {
                                    railPopIn.stop()
                                    railPopOut.restart()
                                }
                            }
                        }

                        Rectangle {
                            x: 3; y: 3; width: 62; height: 44; radius: 14; color: "#1A1B2E"
                        }
                        Rectangle {
                            x: pBtnMa.pressed ? 2 : 0
                            y: pBtnMa.pressed ? 2 : 0
                            width: 62; height: 44; radius: 14
                            color: railBtn.isQuitArmed
                                ? "#FB7185"
                                : (pBtnMa.containsMouse ? themeHub.accentB : modelData.col)
                            border.width: 2.5; border.color: "#1A1B2E"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Image { anchors.horizontalCenter: parent.horizontalCenter; width: 16; height: 16; source: modelData.icon; smooth: true }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: railBtn.isQuitArmed ? "Sure?" : modelData.label
                                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E"
                                }
                            }
                            MouseArea {
                                id: pBtnMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onContainsMouseChanged: {
                                    if (containsMouse)
                                        powerRail.hoveredIdx = railBtn.index
                                    else if (powerRail.hoveredIdx === railBtn.index)
                                        powerRail.hoveredIdx = -1
                                }
                                onClicked: {
                                    if (modelData.act === "quitapp") {
                                        if (!powerRail.quitArmed) {
                                            powerRail.quitArmed = true
                                            railQuitResetTimer.restart()
                                            return
                                        }
                                        railQuitResetTimer.stop()
                                        powerRail.quitArmed = false
                                        topBarWindow.quickPanelOpen = false
                                        SystemControl.quitApp()
                                        return
                                    }
                                    topBarWindow.quickPanelOpen = false
                                    if (modelData.act === "lock") SystemControl.lockScreen()
                                    else if (modelData.act === "sleep") SystemControl.sleepPc()
                                    else if (modelData.act === "hibernate") SystemControl.hibernatePc()
                                    else if (modelData.act === "signout") SystemControl.signOut()
                                    else if (modelData.act === "restart") SystemControl.restartPc()
                                    else if (modelData.act === "shutdown") SystemControl.shutdownPc()
                                }
                            }
                        }
                    }
                }
            }

            // Floating SekaiPop tooltip label beside hovered pill
            Item {
                id: powerRailTip
                x: 74
                y: powerRail.shownHoverIdx * 56 + 24 - height * 0.5
                width: railTipTxt.implicitWidth + 24
                height: 36
                opacity: (quickPanelWindow.powerMenuOpen && powerRail.hoveredIdx >= 0) ? 1.0 : 0.0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 90 } }

                Rectangle {
                    x: 3; y: 3
                    width: parent.width; height: parent.height
                    radius: 12; color: "#1A1B2E"
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 12
                    color: (powerRail.shownHoverIdx === 6 && powerRail.quitArmed) ? "#FFE4E6" : "#FFFFFF"
                    border.width: 2.5; border.color: "#1A1B2E"
                    Text {
                        id: railTipTxt
                        anchors.centerIn: parent
                        text: (powerRail.shownHoverIdx === 6 && powerRail.quitArmed)
                              ? "Click again to Quit SekaiDesk"
                              : (powerRail.fullLabels[powerRail.shownHoverIdx] || "")
                        font.family: "Segoe UI"
                        font.pixelSize: 13
                        font.weight: Font.Black
                        color: "#1A1B2E"
                    }
                }
            }
        }

        // Phone Chassis Stage (slides up from bottom with SekaiPop spring & cross-fades cleanly during FlipMath turn)
        Item {
            id: phoneStage
            visible: !quickPanelWindow.standaloneSettings && quickPanelWindow.curQuickAlpha > 0.001 && (quickPanelWindow.panelWanted || quickPanelWindow.notifAlertPeek || quickPanelWindow.stageLift < quickPanelWindow.hiddenLift || quickPanelWindow.flipProgress > 0.001)
            opacity: quickPanelWindow.curQuickAlpha
            enabled: !themeHub.settingsOpen
            anchors.fill: parent

            // Full-screen transparent backdrop dismisses Portrait Phone on 1st empty-zone click
            MouseArea {
                anchors.fill: parent
                enabled: quickPanelWindow.panelWanted
                onClicked: {
                    topBarWindow.quickPanelClosedAt = Date.now()
                    topBarWindow.quickPanelOpen = false
                    if (themeHub.settingsOpen)
                        themeHub.settingsOpen = false
                }
            }

            // Scaled 2.5D Phone Body (654x1214 design space scaled by curQuickScale around center pivot)
            Item {
                id: phoneRoot
                x: ((!topBarWindow.phoneMode && !quickPanelWindow.flipping)
                    ? Math.round(quickPanelWindow.curCenterX - quickPanelWindow.portOx)
                    : (quickPanelWindow.curCenterX - quickPanelWindow.portOx)) + quickPanelWindow.buzzX
                y: (!topBarWindow.phoneMode && !quickPanelWindow.flipping)
                    ? Math.round(quickPanelWindow.curCenterY - quickPanelWindow.portOy)
                    : (quickPanelWindow.curCenterY - quickPanelWindow.portOy)
                width: quickPanelWindow.phonePose.w
                height: quickPanelWindow.phonePose.h
                transform: Scale {
                    origin.x: quickPanelWindow.portOx; origin.y: quickPanelWindow.portOy
                    xScale: quickPanelWindow.curQuickScale
                    yScale: quickPanelWindow.curQuickScale
                }

                // Soft grounded 9-slice shadow behind phone
                BorderImage {
                    visible: topBarWindow.phoneMode
                    source: "qrc:/qml/assets/phone-shadow.png"
                    border { left: 72; top: 72; right: 72; bottom: 72 }
                    x: -26; y: -16
                    width: quickPanelWindow.faceW + 64
                    height: quickPanelWindow.faceH + 64
                    opacity: 0.85
                    smooth: true
                    transform: Matrix4x4 {
                        matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmZOffset(quickPanelWindow.liveBase, -quickPanelWindow.thickness - 4))
                    }
                }

                // 1) Solid 3D Extruded Side Wall (38 depth slices from back to front)
                Repeater {
                    model: topBarWindow.phoneMode ? 38 : 0
                    delegate: Rectangle {
                        required property int index
                        readonly property real depth: (38 - index) / 38.0
                        width: quickPanelWindow.faceW
                        height: quickPanelWindow.faceH
                        radius: quickPanelWindow.cornerR
                        antialiasing: depth < 0.22
                        color: {
                            if (depth < 0.08) return "#8E92B8"
                            if (depth < 0.22) return "#5D6184"
                            if (depth < 0.55) return "#3D405B"
                            return "#24263A"
                        }
                        transform: Matrix4x4 {
                            matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmZOffset(quickPanelWindow.liveBase, -depth * quickPanelWindow.thickness))
                        }
                    }
                }

                // 2) Right-Edge Side Buttons (Interactive Power Button + Broad Volume Rocker)
                Item {
                    visible: topBarWindow.phoneMode
                    width: quickPanelWindow.thickness
                    height: quickPanelWindow.faceH
                    transform: Matrix4x4 {
                        matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmMul(quickPanelWindow.liveBase, [
                            0, 0, 0, quickPanelWindow.faceW,
                            0, 1, 0, 0,
                            -1, 0, 0, 0,
                            0, 0, 0, 1
                        ]))
                    }

                    // Lower Volume Rocker
                    Rectangle {
                        x: quickPanelWindow.thickness * 0.24
                        y: 704
                        width: quickPanelWindow.thickness * 0.44
                        height: 168
                        radius: width * 0.5
                        color: "#5D6184"
                        border.width: 2
                        border.color: "#1A1B2E"
                        antialiasing: true
                    }
                }

                // Protruding 3D Power Button Stack (animated inward press!)
                Repeater {
                    model: topBarWindow.phoneMode ? 6 : 0
                    delegate: Item {
                        id: pwrBtnSlice
                        required property int index
                        readonly property bool isCap: index === 5
                        readonly property real stick: quickPanelWindow.powerStick
                        width: quickPanelWindow.thickness
                        height: quickPanelWindow.faceH
                        transform: Matrix4x4 {
                            matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmMul(quickPanelWindow.liveBase, [
                                0, 0, 0, quickPanelWindow.faceW + (index + 1) * pwrBtnSlice.stick / 6.0,
                                0, 1, 0, 0,
                                -1, 0, 0, 0,
                                0, 0, 0, 1
                            ]))
                        }
                        Rectangle {
                            x: quickPanelWindow.thickness * 0.32
                            y: 338
                            width: quickPanelWindow.thickness * 0.28
                            height: 150
                            radius: width * 0.5
                            color: !pwrBtnSlice.isCap ? "#3D405B" : (pwrSideMa.pressed ? themeHub.accentA : (quickPanelWindow.powerMenuOpen || pwrSideMa.containsMouse ? themeHub.accentB : "#9DA3C9"))
                            border.width: pwrBtnSlice.isCap ? 2 : 0
                            border.color: "#1A1B2E"
                            antialiasing: true

                            MouseArea {
                                id: pwrSideMa
                                enabled: pwrBtnSlice.isCap
                                anchors.fill: parent
                                anchors.margins: -14
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressedChanged: quickPanelWindow.powerSidePressed = pressed
                                onClicked: quickPanelWindow.powerMenuOpen = !quickPanelWindow.powerMenuOpen
                            }
                        }
                    }
                }

                // 3) Bottom Edge USB-C Port & Speaker Holes
                Item {
                    visible: topBarWindow.phoneMode
                    width: quickPanelWindow.faceW
                    height: quickPanelWindow.thickness
                    transform: Matrix4x4 {
                        matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmMul(quickPanelWindow.liveBase, [
                            1, 0, 0, 0,
                            0, 0, 0, quickPanelWindow.faceH,
                            0, -1, 0, 0,
                            0, 0, 0, 1
                        ]))
                    }
                    Rectangle {
                        x: quickPanelWindow.faceW * 0.5 - 46
                        y: quickPanelWindow.thickness * 0.5 - quickPanelWindow.thickness * 0.20
                        width: 92; height: quickPanelWindow.thickness * 0.40; radius: height * 0.5
                        color: "#131422"
                    }
                    Repeater {
                        model: 5
                        delegate: Rectangle {
                            required property int index
                            width: 22; height: 22; radius: 11
                            x: quickPanelWindow.faceW * 0.5 + 78 + index * 30
                            y: quickPanelWindow.thickness * 0.5 - 11
                            color: "#131422"
                        }
                    }
                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            required property int index
                            width: 22; height: 22; radius: 11
                            x: quickPanelWindow.faceW * 0.5 - 100 - index * 30
                            y: quickPanelWindow.thickness * 0.5 - 11
                            color: "#131422"
                        }
                    }
                }

                // Flat-mode side Power Tab when 2.5D is off
                Rectangle {
                    visible: !topBarWindow.phoneMode
                    x: quickPanelWindow.faceW - 4
                    y: 338
                    width: 20; height: 150; radius: 8
                    color: quickPanelWindow.powerMenuOpen || flatPwrMa.containsMouse ? themeHub.accentB : "#9DA3C9"
                    border.width: 3; border.color: "#1A1B2E"
                    transform: Matrix4x4 {
                        matrix: quickPanelWindow.toQtMat(quickPanelWindow.liveBase)
                    }
                    MouseArea {
                        id: flatPwrMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: quickPanelWindow.powerMenuOpen = !quickPanelWindow.powerMenuOpen
                    }
                }

                // 4) Front Screen Plane (razor-sharp direct vector in 2D; supersampled FBO in 2.5D/flip)
                Item {
                    id: phoneFrontFace
                    width: quickPanelWindow.faceW
                    height: quickPanelWindow.faceH
                    transform: Matrix4x4 {
                        matrix: quickPanelWindow.toQtMat(quickPanelWindow.liveBase)
                    }
                    readonly property bool useLayer: topBarWindow.phoneMode || quickPanelWindow.flipProgress > 0.001 || quickPanelWindow.flipping
                    readonly property real dpr: Math.max(1.0, Screen.devicePixelRatio || 1.0)
                    readonly property real texScale: Math.min(2.5, Math.max(1.5, quickPanelWindow.curQuickScale * dpr * 2.0))
                    layer.enabled: useLayer
                    layer.smooth: true
                    layer.samples: (quickPanelWindow.flipping || quickPanelWindow.animating || quickPanelWindow.notifAlertPeek) ? 1 : 4
                    layer.textureSize: Qt.size(Math.ceil(width * texScale), Math.ceil(height * texScale))

                    // Eat clicks on empty areas of the phone body so backdrop doesn't dismiss it
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {}
                    }

                    // Outer metal rim + specular highlight
                    Rectangle {
                        anchors.fill: parent
                        radius: quickPanelWindow.cornerR
                        color: "#555473"
                        border.width: 3
                        border.color: "#1A1B2E"
                        antialiasing: true
                    }
                    Rectangle {
                        anchors.fill: parent; anchors.margins: 3
                        radius: quickPanelWindow.cornerR - 3
                        color: "transparent"
                        border.width: 2; border.color: "#88FFFFFF"
                        antialiasing: true
                    }
                    // Dark glass bezel
                    Rectangle {
                        anchors.fill: parent; anchors.margins: quickPanelWindow.rimW
                        radius: quickPanelWindow.cornerR - quickPanelWindow.rimW
                        color: "#1A1B2E"
                        antialiasing: true
                    }
                    // Inner phone screen background
                    Rectangle {
                        id: phoneScreenBg
                        anchors.fill: parent; anchors.margins: quickPanelWindow.screenInset
                        radius: quickPanelWindow.cornerR - quickPanelWindow.screenInset
                        color: themeHub.phoneScreenBg
                        clip: true
                        antialiasing: true
                    }

                    // === SCREEN CONTENT (654 x 1214 design space) ===
                    Item {
                        id: phoneScreenContent
                        anchors.fill: parent

                        // ---- Banner Header Card ----
                        Item {
                            id: qpBannerBox
                            x: 28; y: 28; width: 598; height: 222

                            // Gradient fallback when no banner image is set
                            Rectangle {
                                anchors.fill: parent
                                topLeftRadius: 72; topRightRadius: 72
                                bottomLeftRadius: 42; bottomRightRadius: 42
                                border.width: 3; border.color: "#1A1B2E"
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: themeHub.accentA }
                                    GradientStop { position: 1.0; color: themeHub.accentB }
                                }
                                visible: themeHub.quickPanelBannerUrl === ""
                            }

                            // Rounded-clipped custom banner image via Canvas
                            Canvas {
                                id: qpBannerCanvas
                                anchors.fill: parent
                                visible: themeHub.quickPanelBannerUrl !== ""
                                property string src: themeHub.quickPanelBannerUrl
                                onSrcChanged: {
                                    if (src !== "")
                                        loadImage(src)
                                    requestPaint()
                                }
                                onImageLoaded: requestPaint()
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    if (src === "" || !isImageLoaded(src))
                                        return
                                    ctx.save()
                                    ctx.beginPath()
                                    ctx.moveTo(72, 0)
                                    ctx.lineTo(width - 72, 0)
                                    ctx.quadraticCurveTo(width, 0, width, 72)
                                    ctx.lineTo(width, height - 42)
                                    ctx.quadraticCurveTo(width, height, width - 42, height)
                                    ctx.lineTo(42, height)
                                    ctx.quadraticCurveTo(0, height, 0, height - 42)
                                    ctx.lineTo(0, 72)
                                    ctx.quadraticCurveTo(0, 0, 72, 0)
                                    ctx.closePath()
                                    ctx.clip()
                                    ctx.drawImage(src, 0, 0, width, height)
                                    ctx.fillStyle = "rgba(26, 27, 46, 0.28)"
                                    ctx.fillRect(0, 0, width, height)
                                    ctx.restore()
                                }
                            }

                            // Click banner to pick custom wallpaper
                            MouseArea {
                                id: qpBannerMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    quickPanelWindow.pickingFile = true
                                    const url = SystemControl.pickImageFile("Select Phone Banner Image")
                                    quickPanelWindow.pickingFile = false
                                    if (url !== "")
                                        themeHub.setQuickPanelBanner(url)
                                    quickPanelWindow.focusActivate()
                                }
                            }

                            // Clock + Date (Top-Left on banner)
                            Column {
                                x: 32; y: 20; spacing: -2
                                Text {
                                    text: topBarWindow.timeText
                                    font.family: "Segoe UI"
                                    font.pixelSize: 28
                                    font.weight: Font.Black
                                    color: themeHub.quickPanelBannerUrl !== "" ? "#FFFFFF" : "#1A1B2E"
                                    style: themeHub.quickPanelBannerUrl !== "" ? Text.Outline : Text.Normal
                                    styleColor: "#1A1B2E"
                                }
                                Text {
                                    text: topBarWindow.dateText
                                    font.family: "Segoe UI"
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                    color: themeHub.quickPanelBannerUrl !== "" ? "#FFFFFF" : "#1A1B2E"
                                    style: themeHub.quickPanelBannerUrl !== "" ? Text.Outline : Text.Normal
                                    styleColor: "#1A1B2E"
                                }
                            }

                            // Live Net Speed (Top-Right on banner)
                            Column {
                                anchors.right: parent.right; anchors.rightMargin: 30; y: 22; spacing: 0
                                Text {
                                    anchors.right: parent.right
                                    text: "▼ " + quickPanelWindow.formatRate(SystemControl.downloadBps)
                                    font.family: "Consolas"
                                    font.pixelSize: 17
                                    font.weight: Font.Black
                                    color: themeHub.quickPanelBannerUrl !== "" ? "#FFFFFF" : "#1A1B2E"
                                    style: themeHub.quickPanelBannerUrl !== "" ? Text.Outline : Text.Normal
                                    styleColor: "#1A1B2E"
                                }
                                Text {
                                    anchors.right: parent.right
                                    text: "▲ " + quickPanelWindow.formatRate(SystemControl.uploadBps)
                                    font.family: "Consolas"
                                    font.pixelSize: 16
                                    font.weight: Font.Bold
                                    color: themeHub.quickPanelBannerUrl !== "" ? "#E2E8F0" : "#1A1B2E"
                                    style: themeHub.quickPanelBannerUrl !== "" ? Text.Outline : Text.Normal
                                    styleColor: "#1A1B2E"
                                }
                            }

                            // Banner Hover Change / Reset pills
                            Row {
                                visible: qpBannerMa.containsMouse || qpBannerResetMa.containsMouse
                                anchors.right: parent.right; anchors.bottom: parent.bottom
                                anchors.rightMargin: 20; anchors.bottomMargin: 14
                                spacing: 8
                                Rectangle {
                                    width: 90; height: 34; radius: 17
                                    color: "#FFFFFF"; border.width: 2.5; border.color: "#1A1B2E"
                                    Text { anchors.centerIn: parent; text: "Banner"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                }
                                Rectangle {
                                    visible: themeHub.quickPanelBannerUrl !== ""
                                    width: 34; height: 34; radius: 17
                                    color: "#FFE4E6"; border.width: 2.5; border.color: "#1A1B2E"
                                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 18; font.weight: Font.Black; color: "#D92652" }
                                    MouseArea {
                                        id: qpBannerResetMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: themeHub.setQuickPanelBanner("")
                                    }
                                }
                            }
                        }

                        // ---- Circular Avatar overlapping bottom-left of banner ----
                        Item {
                            id: qpAvatarBox
                            x: 58; y: 182; width: 116; height: 116

                            Rectangle {
                                anchors.fill: parent; radius: 58
                                color: themeHub.accentB
                                border.width: 4; border.color: "#1A1B2E"
                            }
                            Rectangle {
                                anchors.fill: parent; anchors.margins: 4; radius: 54
                                color: "transparent"
                                border.width: 4; border.color: "#FFFFFF"
                                z: 5
                            }

                            Text {
                                visible: themeHub.quickPanelAvatarUrl === ""
                                anchors.centerIn: parent
                                text: (WindowTracker.userName || "Y").charAt(0).toUpperCase()
                                font.family: "Segoe UI"
                                font.pixelSize: 44
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }

                            Canvas {
                                id: qpAvatarCanvas
                                anchors.fill: parent; anchors.margins: 6
                                visible: themeHub.quickPanelAvatarUrl !== ""
                                property string src: themeHub.quickPanelAvatarUrl
                                onSrcChanged: {
                                    if (src !== "")
                                        loadImage(src)
                                    requestPaint()
                                }
                                onImageLoaded: requestPaint()
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    if (src === "" || !isImageLoaded(src))
                                        return
                                    ctx.save()
                                    ctx.beginPath()
                                    ctx.arc(width * 0.5, height * 0.5, width * 0.5, 0, Math.PI * 2)
                                    ctx.clip()
                                    ctx.drawImage(src, 0, 0, width, height)
                                    ctx.restore()
                                }
                            }

                            MouseArea {
                                id: qpAvatarMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    quickPanelWindow.pickingFile = true
                                    const url = SystemControl.pickImageFile("Select Phone Avatar Image")
                                    quickPanelWindow.pickingFile = false
                                    if (url !== "")
                                        themeHub.setQuickPanelAvatar(url)
                                    quickPanelWindow.focusActivate()
                                }
                            }

                            Rectangle {
                                visible: themeHub.quickPanelAvatarUrl !== "" && (qpAvatarMa.containsMouse || qpAvResetMa.containsMouse)
                                anchors.right: parent.right; anchors.bottom: parent.bottom
                                width: 32; height: 32; radius: 16
                                color: "#FFE4E6"; border.width: 2.5; border.color: "#1A1B2E"; z: 8
                                Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 16; font.weight: Font.Black; color: "#D92652" }
                                MouseArea {
                                    id: qpAvResetMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: themeHub.setQuickPanelAvatar("")
                                }
                            }
                        }

                        // ---- User@Host Identity ----
                        Text {
                            x: 46; y: 304; width: 210; elide: Text.ElideRight
                            text: (WindowTracker.userName || "user") + "@" + (WindowTracker.machineName || "pc")
                            font.family: "Segoe UI"
                            font.pixelSize: 21
                            font.weight: Font.Black
                            color: themeHub.phoneInk
                        }

                        // ---- 5 Header Square Pill Action Buttons (Settings / Refresh / Edit / Game / Power) ----
                        Row {
                            x: 264; y: 258; spacing: 6
                            Repeater {
                                model: [
                                    { label: "Settings", icon: "⚙",  svgIcon: "",                             act: "settings", active: false },
                                    { label: "Refresh",  icon: "↻",  svgIcon: "",                             act: "refresh",  active: false },
                                    { label: "Edit",     icon: "✎",  svgIcon: "",                             act: "edit",     active: themeHub.editMode },
                                    { label: GameModeService.autoDetect ? "Game ON" : "Game", icon: "🎮", svgIcon: "", act: "game", active: GameModeService.autoDetect },
                                    { label: "Power",    icon: "",   svgIcon: "qrc:/qml/icons/power-dark.svg", act: "power",    active: quickPanelWindow.powerMenuOpen }
                                ]
                                delegate: Item {
                                    required property var modelData
                                    readonly property bool isHighlight: modelData.active || hdrActMa.containsMouse
                                    width: 66; height: 68
                                    Rectangle { x: 3; y: 3; width: 62; height: 64; radius: 18; color: "#1A1B2E" }
                                    Rectangle {
                                        x: hdrActMa.pressed ? 3 : 0
                                        y: hdrActMa.pressed ? 2 : 0
                                        width: 62; height: 64; radius: 18
                                        color: isHighlight
                                            ? themeHub.accentB
                                            : (modelData.act === "power" ? "#FFE4E6" : themeHub.phoneCardBg)
                                        border.width: 3.5; border.color: isHighlight || modelData.act === "power" ? "#1A1B2E" : themeHub.phoneBorder
                                        Rectangle {
                                            anchors.fill: parent; anchors.margins: 4; radius: 14
                                            color: "transparent"; border.width: 2; border.color: themeHub.phoneDarkMode && !isHighlight && modelData.act !== "power" ? "#22FFFFFF" : "#99FFFFFF"
                                        }
                                        Column {
                                            anchors.centerIn: parent; spacing: 1
                                            Image {
                                                visible: modelData.svgIcon !== ""
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                width: 21; height: 21
                                                source: modelData.svgIcon
                                                smooth: true
                                            }
                                            Text {
                                                visible: modelData.svgIcon === ""
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: modelData.icon
                                                font.pixelSize: 21; font.weight: Font.Black
                                                color: isHighlight || modelData.act === "power" ? "#1A1B2E" : themeHub.phoneInk
                                            }
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: modelData.label
                                                font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Black
                                                color: isHighlight || modelData.act === "power" ? "#1A1B2E" : themeHub.phoneInk
                                            }
                                        }
                                        MouseArea {
                                            id: hdrActMa
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onClicked: function(mouse) {
                                                if (modelData.act === "game") {
                                                    if (mouse.button === Qt.RightButton)
                                                        themeHub.openSettings("system")
                                                    else
                                                        GameModeService.autoDetect = !GameModeService.autoDetect
                                                    return
                                                }
                                                if (mouse.button !== Qt.LeftButton)
                                                    return
                                                if (modelData.act === "settings") {
                                                    themeHub.openSettings("")
                                                } else if (modelData.act === "refresh") {
                                                    AudioService.refreshSessions()
                                                    AudioService.refreshOutputDevices()
                                                    SystemControl.refresh()
                                                    SystemControl.refreshWifi()
                                                    SystemControl.refreshBluetooth()
                                                    GameModeService.refreshRtssStatus()
                                                } else if (modelData.act === "edit") {
                                                    topBarWindow.quickPanelOpen = false
                                                    themeHub.setEditMode(true)
                                                } else if (modelData.act === "power") {
                                                    quickPanelWindow.powerMenuOpen = !quickPanelWindow.powerMenuOpen
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- 2-Column Toggles & Sliders Container ----
                        Rectangle {
                            id: qpControlsCard
                            x: 36; y: 348; width: 582; height: 422
                            radius: 36
                            color: themeHub.phoneDarkMode ? "#171B2E" : "#E8EDF7"
                            border.width: 3
                            border.color: themeHub.phoneBorder

                            Column {
                                x: 16; y: 16; width: parent.width - 32; spacing: 12

                                // Row 1: Network & Bluetooth (2-Column Thick-Bordered Tiles)
                                Row {
                                    width: parent.width; spacing: 14

                                    // Tile 1: Wi-Fi / Network
                                    Item {
                                        id: wifiTile
                                        width: 268; height: 74
                                        readonly property bool isOn: SystemControl.networkType !== "Offline" && (SystemControl.networkType !== "Wi-Fi" || SystemControl.wifiEnabled)
                                        readonly property bool darkOff: !isOn && themeHub.phoneDarkMode
                                        Rectangle { x: wifiTile.isOn ? 5 : 3; y: wifiTile.isOn ? 2 : 1; width: 263; height: 70; radius: 35; color: "#1A1B2E" }
                                        Rectangle {
                                            x: wifiTileMa.pressed ? 3 : 0
                                            y: wifiTileMa.pressed ? 2 : 0
                                            width: 263; height: 70; radius: 35
                                            border.width: wifiTile.isOn ? 4.5 : 3; border.color: wifiTile.isOn ? "#1A1B2E" : themeHub.phoneBorder
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: wifiTile.isOn ? themeHub.accentB : themeHub.phoneCardBg }
                                                GradientStop { position: 1.0; color: wifiTile.isOn ? themeHub.accentA : themeHub.phoneCardBg }
                                            }
                                            Rectangle {
                                                visible: wifiTile.isOn
                                                anchors.fill: parent; anchors.margins: 4; radius: 31
                                                color: "transparent"; border.width: 4; border.color: "#AAFFFFFF"
                                            }
                                            Row {
                                                anchors.left: parent.left; anchors.leftMargin: 18
                                                anchors.right: wifiMoreBtn.left; anchors.rightMargin: 6
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 10
                                                Image {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 26; height: 26; sourceSize.width: 48; sourceSize.height: 48; smooth: true
                                                    source: SystemControl.networkType === "Wi-Fi"
                                                        ? (wifiTile.darkOff ? "qrc:/qml/icons/wifi-light.svg" : "qrc:/qml/icons/wifi-dark.svg")
                                                        : (wifiTile.darkOff ? "qrc:/qml/icons/network-light.svg" : "qrc:/qml/icons/network-dark.svg")
                                                }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: parent.width - 36
                                                    Text { width: parent.width; elide: Text.ElideRight; text: SystemControl.networkType === "Offline" ? "Wi-Fi" : SystemControl.networkType; font.pixelSize: 19; font.weight: Font.Black; color: wifiTile.isOn ? "#1A1B2E" : themeHub.phoneInk }
                                                    Text { width: parent.width; elide: Text.ElideRight; text: SystemControl.localIp || (SystemControl.wifiEnabled ? "Connected" : "OFF"); font.pixelSize: 15; font.weight: Font.Bold; color: wifiTile.isOn ? "#BF1A1B2E" : themeHub.phoneMutedInk }
                                                }
                                            }
                                            MouseArea {
                                                id: wifiTileMa
                                                anchors.fill: parent
                                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: mouse => {
                                                    if (mouse.button === Qt.RightButton) {
                                                        SystemControl.refreshWifi()
                                                        quickPanelWindow.subDialog = "wifi"
                                                    } else {
                                                        SystemControl.toggleWifi()
                                                    }
                                                }
                                            }
                                            Rectangle {
                                                id: wifiMoreBtn
                                                anchors.right: parent.right; anchors.rightMargin: 12
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 28; height: 28; radius: 14
                                                color: wifiTile.darkOff ? themeHub.phoneSubBg : "#66FFFFFF"; border.width: 2; border.color: wifiTile.darkOff ? themeHub.phoneBorder : "#1A1B2E"
                                                Text { anchors.centerIn: parent; text: "▾"; font.pixelSize: 14; font.weight: Font.Black; color: wifiTile.darkOff ? themeHub.phoneInk : "#1A1B2E" }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { SystemControl.refreshWifi(); quickPanelWindow.subDialog = "wifi" }
                                                }
                                            }
                                        }
                                    }

                                    // Tile 2: Bluetooth
                                    Item {
                                        id: btTile
                                        width: 268; height: 74
                                        readonly property bool isOn: SystemControl.bluetoothSupported && SystemControl.bluetoothEnabled
                                        readonly property bool darkOff: !isOn && themeHub.phoneDarkMode
                                        Rectangle { x: btTile.isOn ? 5 : 3; y: btTile.isOn ? 2 : 1; width: 263; height: 70; radius: 35; color: "#1A1B2E" }
                                        Rectangle {
                                            x: btTileMa.pressed ? 3 : 0
                                            y: btTileMa.pressed ? 2 : 0
                                            width: 263; height: 70; radius: 35
                                            border.width: btTile.isOn ? 4.5 : 3; border.color: btTile.isOn ? "#1A1B2E" : themeHub.phoneBorder
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: btTile.isOn ? themeHub.accentB : themeHub.phoneCardBg }
                                                GradientStop { position: 1.0; color: btTile.isOn ? themeHub.accentA : themeHub.phoneCardBg }
                                            }
                                            Rectangle {
                                                visible: btTile.isOn
                                                anchors.fill: parent; anchors.margins: 4; radius: 31
                                                color: "transparent"; border.width: 4; border.color: "#AAFFFFFF"
                                            }
                                            Row {
                                                anchors.left: parent.left; anchors.leftMargin: 18
                                                anchors.right: btMoreBtn.left; anchors.rightMargin: 6
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 10
                                                Image {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 24; height: 24; sourceSize.width: 48; sourceSize.height: 48; smooth: true
                                                    source: btTile.darkOff ? "qrc:/qml/icons/bt-light.svg" : "qrc:/qml/icons/bt-dark.svg"
                                                }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: parent.width - 34
                                                    Text { width: parent.width; elide: Text.ElideRight; text: "Bluetooth"; font.pixelSize: 19; font.weight: Font.Black; color: btTile.isOn ? "#1A1B2E" : themeHub.phoneInk }
                                                    Text {
                                                        width: parent.width; elide: Text.ElideRight
                                                        text: !SystemControl.bluetoothSupported ? "Unavailable" : (btTile.isOn ? ("ON · " + SystemControl.bluetoothDevices.length + " dev") : "OFF")
                                                        font.pixelSize: 15; font.weight: Font.Bold; color: btTile.isOn ? "#BF1A1B2E" : themeHub.phoneMutedInk
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: btTileMa
                                                anchors.fill: parent
                                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: mouse => {
                                                    if (mouse.button === Qt.RightButton) {
                                                        SystemControl.refreshBluetooth()
                                                        quickPanelWindow.subDialog = "bt"
                                                    } else if (SystemControl.bluetoothSupported) {
                                                        SystemControl.toggleBluetooth()
                                                    }
                                                }
                                            }
                                            Rectangle {
                                                id: btMoreBtn
                                                anchors.right: parent.right; anchors.rightMargin: 12
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 28; height: 28; radius: 14
                                                color: btTile.darkOff ? themeHub.phoneSubBg : "#66FFFFFF"; border.width: 2; border.color: btTile.darkOff ? themeHub.phoneBorder : "#1A1B2E"
                                                Text { anchors.centerIn: parent; text: "▾"; font.pixelSize: 14; font.weight: Font.Black; color: btTile.darkOff ? themeHub.phoneInk : "#1A1B2E" }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { SystemControl.refreshBluetooth(); quickPanelWindow.subDialog = "bt" }
                                                }
                                            }
                                        }
                                    }
                                }

                                // Row 2: Dark Mode & Keep Awake (2-Column Thick-Bordered Tiles)
                                Row {
                                    width: parent.width; spacing: 14

                                    // Tile 3: Dark Mode
                                    Item {
                                        id: dmTile
                                        width: 268; height: 74
                                        readonly property bool isOn: SystemControl.darkMode
                                        readonly property bool darkOff: !isOn && themeHub.phoneDarkMode
                                        Rectangle { x: dmTile.isOn ? 5 : 3; y: dmTile.isOn ? 2 : 1; width: 263; height: 70; radius: 35; color: "#1A1B2E" }
                                        Rectangle {
                                            x: dmTileMa.pressed ? 3 : 0
                                            y: dmTileMa.pressed ? 2 : 0
                                            width: 263; height: 70; radius: 35
                                            border.width: dmTile.isOn ? 4.5 : 3; border.color: dmTile.isOn ? "#1A1B2E" : themeHub.phoneBorder
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: dmTile.isOn ? themeHub.accentB : themeHub.phoneCardBg }
                                                GradientStop { position: 1.0; color: dmTile.isOn ? themeHub.accentA : themeHub.phoneCardBg }
                                            }
                                            Rectangle {
                                                visible: dmTile.isOn
                                                anchors.fill: parent; anchors.margins: 4; radius: 31
                                                color: "transparent"; border.width: 4; border.color: "#AAFFFFFF"
                                            }
                                            Row {
                                                anchors.left: parent.left; anchors.leftMargin: 18
                                                anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                                Image {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 24; height: 24; sourceSize.width: 48; sourceSize.height: 48; smooth: true
                                                    source: dmTile.isOn
                                                        ? "qrc:/qml/icons/moon-dark.svg"
                                                        : (dmTile.darkOff ? "qrc:/qml/icons/sun-light.svg" : "qrc:/qml/icons/sun-dark.svg")
                                                }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    Text { text: "Theme"; font.pixelSize: 19; font.weight: Font.Black; color: dmTile.isOn ? "#1A1B2E" : themeHub.phoneInk }
                                                    Text { text: dmTile.isOn ? "Dark Mode" : "Light Mode"; font.pixelSize: 15; font.weight: Font.Bold; color: dmTile.isOn ? "#BF1A1B2E" : themeHub.phoneMutedInk }
                                                }
                                            }
                                            MouseArea {
                                                id: dmTileMa
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: SystemControl.toggleDarkMode()
                                            }
                                        }
                                    }

                                    // Tile 4: Keep Awake
                                    Item {
                                        id: kaTile
                                        width: 268; height: 74
                                        readonly property bool isOn: SystemControl.keepAwake
                                        Rectangle { x: kaTile.isOn ? 5 : 3; y: kaTile.isOn ? 2 : 1; width: 263; height: 70; radius: 35; color: "#1A1B2E" }
                                        Rectangle {
                                            x: kaTileMa.pressed ? 3 : 0
                                            y: kaTileMa.pressed ? 2 : 0
                                            width: 263; height: 70; radius: 35
                                            border.width: kaTile.isOn ? 4.5 : 3; border.color: kaTile.isOn ? "#1A1B2E" : themeHub.phoneBorder
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: kaTile.isOn ? themeHub.accentB : themeHub.phoneCardBg }
                                                GradientStop { position: 1.0; color: kaTile.isOn ? themeHub.accentA : themeHub.phoneCardBg }
                                            }
                                            Rectangle {
                                                visible: kaTile.isOn
                                                anchors.fill: parent; anchors.margins: 4; radius: 31
                                                color: "transparent"; border.width: 4; border.color: "#AAFFFFFF"
                                            }
                                            Row {
                                                anchors.left: parent.left; anchors.leftMargin: 18
                                                anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "☕"; font.pixelSize: 24; color: kaTile.isOn ? "#1A1B2E" : themeHub.phoneInk }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    Text { text: "Keep Awake"; font.pixelSize: 19; font.weight: Font.Black; color: kaTile.isOn ? "#1A1B2E" : themeHub.phoneInk }
                                                    Text { text: kaTile.isOn ? "Active (No Sleep)" : "OFF"; font.pixelSize: 15; font.weight: Font.Bold; color: kaTile.isOn ? "#BF1A1B2E" : themeHub.phoneMutedInk }
                                                }
                                            }
                                            MouseArea {
                                                id: kaTileMa
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: SystemControl.toggleKeepAwake()
                                            }
                                        }
                                    }
                                }

                                // Row 3: Microphone & Speaker Chunky Pill Sliders (2-Column)
                                Row {
                                    width: parent.width; spacing: 14

                                    // Microphone Slider
                                    Item {
                                        id: micSlider
                                        width: 268; height: 104
                                        readonly property bool active: AudioService.micSupported && !AudioService.micMuted
                                        Rectangle { x: micSlider.active ? 4 : 3; y: 2; width: 263; height: 68; radius: 34; color: "#1A1B2E" }
                                        Rectangle {
                                            x: micCapMa.pressed ? 2 : 0; y: micCapMa.pressed ? 2 : 0
                                            width: 263; height: 68; radius: 34
                                            border.width: micSlider.active ? 4.5 : 3; border.color: micSlider.active ? "#1A1B2E" : themeHub.phoneBorder
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: micSlider.active ? themeHub.accentB : themeHub.phoneCardBg }
                                                GradientStop { position: 1.0; color: micSlider.active ? themeHub.accentA : themeHub.phoneCardBg }
                                            }
                                            Rectangle {
                                                visible: micSlider.active
                                                anchors.fill: parent; anchors.margins: 4; radius: 30
                                                color: "transparent"; border.width: 3.5; border.color: "#AAFFFFFF"
                                            }
                                            Row {
                                                anchors.left: parent.left; anchors.leftMargin: 18
                                                anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: AudioService.micMuted ? "🔇" : "🎙"; font.pixelSize: 22; color: micSlider.active ? "#1A1B2E" : themeHub.phoneInk }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    Text { text: "Microphone"; font.pixelSize: 19; font.weight: Font.Black; color: micSlider.active ? "#1A1B2E" : themeHub.phoneInk }
                                                    Text {
                                                        text: !AudioService.micSupported ? "No Mic" : (AudioService.micMuted ? "Muted" : (AudioService.micVolume + "%"))
                                                        font.pixelSize: 15; font.weight: Font.Black; color: micSlider.active ? "#BF1A1B2E" : themeHub.phoneMutedInk
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: micCapMa
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: if (AudioService.micSupported) AudioService.toggleMicMute()
                                            }
                                        }
                                        // Pill track
                                        Item {
                                            x: 4; y: 76; width: 256; height: 24
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.width; height: 18; radius: 9
                                                color: themeHub.phoneCardBg; border.width: 3; border.color: themeHub.phoneBorder
                                                Rectangle {
                                                    x: 3; y: 3; height: 12; radius: 6
                                                    width: Math.max(0, (parent.width - 6) * (AudioService.micVolume / 100.0))
                                                    gradient: Gradient {
                                                        orientation: Gradient.Horizontal
                                                        GradientStop { position: 0.0; color: themeHub.accentB }
                                                        GradientStop { position: 1.0; color: themeHub.accentA }
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                enabled: AudioService.micSupported
                                                function setMic(mx) {
                                                    AudioService.setMicVolume(Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100))
                                                }
                                                onPressed: mouse => setMic(mouse.x)
                                                onPositionChanged: mouse => { if (pressed) setMic(mouse.x) }
                                            }
                                        }
                                    }

                                    // Speaker Slider (left-click mutes; standalone mixer lives in TopBar volumePopupWindow)
                                    Item {
                                        id: spkSlider
                                        width: 268; height: 104
                                        readonly property bool active: !AudioService.masterMuted
                                        readonly property bool darkOff: !active && themeHub.phoneDarkMode
                                        Rectangle { x: spkSlider.active ? 4 : 3; y: 2; width: 263; height: 68; radius: 34; color: "#1A1B2E" }
                                        Rectangle {
                                            x: spkCapMa.pressed ? 2 : 0; y: spkCapMa.pressed ? 2 : 0
                                            width: 263; height: 68; radius: 34
                                            border.width: spkSlider.active ? 4.5 : 3; border.color: spkSlider.active ? "#1A1B2E" : themeHub.phoneBorder
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: spkSlider.active ? themeHub.accentB : themeHub.phoneCardBg }
                                                GradientStop { position: 1.0; color: spkSlider.active ? themeHub.accentA : themeHub.phoneCardBg }
                                            }
                                            Rectangle {
                                                visible: spkSlider.active
                                                anchors.fill: parent; anchors.margins: 4; radius: 30
                                                color: "transparent"; border.width: 3.5; border.color: "#AAFFFFFF"
                                            }
                                            Row {
                                                anchors.left: parent.left; anchors.leftMargin: 18
                                                anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                                Image {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 24; height: 24; sourceSize.width: 48; sourceSize.height: 48; smooth: true
                                                    source: AudioService.masterMuted
                                                        ? (spkSlider.darkOff ? "qrc:/qml/icons/volume-cross-light.svg" : "qrc:/qml/icons/volume-cross-dark.svg")
                                                        : (spkSlider.darkOff ? "qrc:/qml/icons/volume-loud-light.svg" : "qrc:/qml/icons/volume-loud-dark.svg")
                                                }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    Text { text: "Speaker"; font.pixelSize: 19; font.weight: Font.Black; color: spkSlider.active ? "#1A1B2E" : themeHub.phoneInk }
                                                    Text {
                                                        text: AudioService.masterMuted ? "Muted" : (AudioService.masterVolume + "%")
                                                        font.pixelSize: 15; font.weight: Font.Black; color: spkSlider.active ? "#BF1A1B2E" : themeHub.phoneMutedInk
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: spkCapMa
                                                anchors.fill: parent
                                                acceptedButtons: Qt.LeftButton
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: AudioService.toggleMasterMute()
                                            }
                                        }
                                        // Pill track
                                        Item {
                                            x: 4; y: 76; width: 256; height: 24
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.width; height: 18; radius: 9
                                                color: themeHub.phoneCardBg; border.width: 3; border.color: themeHub.phoneBorder
                                                Rectangle {
                                                    x: 3; y: 3; height: 12; radius: 6
                                                    width: Math.max(0, (parent.width - 6) * (AudioService.masterVolume / 100.0))
                                                    gradient: Gradient {
                                                        orientation: Gradient.Horizontal
                                                        GradientStop { position: 0.0; color: themeHub.accentB }
                                                        GradientStop { position: 1.0; color: themeHub.accentA }
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                function setSpk(mx) {
                                                    AudioService.setMasterVolume(Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100))
                                                }
                                                onPressed: mouse => setSpk(mouse.x)
                                                onPositionChanged: mouse => { if (pressed) setSpk(mouse.x) }
                                            }
                                        }
                                    }
                                }

                                // Row 4: Full-Width Dual-Accent Brightness Bar (supports multi-monitor DDC/CI)
                                Item {
                                    id: brControl
                                    width: parent.width; height: 64
                                    readonly property var monList: SystemControl.monitors || []
                                    readonly property int monIdx: Math.min(quickPanelWindow.selectedMonitorIdx, Math.max(0, brControl.monList.length - 1))
                                    readonly property var curMon: (brControl.monList.length > 0 && brControl.monIdx >= 0) ? brControl.monList[brControl.monIdx] : null
                                    readonly property int curBrightness: brControl.curMon ? brControl.curMon.brightness : SystemControl.brightness

                                    Item {
                                        width: parent.width; height: 28
                                        Row {
                                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                                            Text { text: "☀ BRIGHTNESS"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                            Text {
                                                text: brControl.curMon ? ("· " + (brControl.curMon.name || "Monitor")) : ""
                                                font.pixelSize: 15; font.weight: Font.Bold; color: themeHub.phoneMutedInk
                                            }
                                            Repeater {
                                                model: brControl.monList.length > 1 ? brControl.monList.length : 0
                                                delegate: Rectangle {
                                                    required property int index
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 34; height: 26; radius: 9
                                                    color: index === brControl.monIdx ? themeHub.accentA : themeHub.phoneCardBg
                                                    border.width: 2; border.color: themeHub.phoneBorder
                                                    Text { anchors.centerIn: parent; text: "M" + (index + 1); font.pixelSize: 13; font.weight: Font.Black; color: index === brControl.monIdx ? "#1A1B2E" : themeHub.phoneInk }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: quickPanelWindow.selectedMonitorIdx = index }
                                                }
                                            }
                                        }
                                        Text {
                                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                            text: brControl.curBrightness + "%"
                                            font.family: "Consolas"; font.pixelSize: 18; font.weight: Font.Black; color: themeHub.phoneInk
                                        }
                                    }

                                    Item {
                                        y: 32; width: parent.width; height: 28
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width; height: 22; radius: 11
                                            color: themeHub.phoneCardBg; border.width: 3; border.color: themeHub.phoneBorder
                                            Rectangle {
                                                x: 3; y: 3; height: 16; radius: 8
                                                width: Math.max(0, (parent.width - 6) * (brControl.curBrightness / 100.0))
                                                gradient: Gradient {
                                                    orientation: Gradient.Horizontal
                                                    GradientStop { position: 0.0; color: "#FFD166" }
                                                    GradientStop { position: 1.0; color: themeHub.accentA }
                                                }
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            function setBr(mx) {
                                                const pct = Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100)
                                                if (brControl.curMon)
                                                    SystemControl.setMonitorBrightness(brControl.curMon.index, pct)
                                                else
                                                    SystemControl.setBrightness(pct)
                                            }
                                            onPressed: mouse => setBr(mouse.x)
                                            onPositionChanged: mouse => { if (pressed) setBr(mouse.x) }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- Bottom Notifications & Utilities Card ----
                        Rectangle {
                            id: qpBottomCard
                            x: 36; y: 786; width: 582; height: 392
                            radius: 36
                            color: themeHub.phoneCardBg
                            border.width: 3; border.color: themeHub.phoneBorder
                            clip: true

                            Column {
                                anchors.fill: parent; anchors.margins: 18; spacing: 10

                                // Bottom Header: Tabs + Dark Surface Toggle + 2.5D / 2D Toggle
                                Item {
                                    width: parent.width; height: 40
                                    Row {
                                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                                        Repeater {
                                            model: [
                                                { id: "notifications", label: NotificationService.count > 0 ? ("NOTIFS (" + NotificationService.count + ")") : "NOTIFICATIONS" },
                                                { id: "display",       label: "DISPLAY" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool act: quickPanelWindow.bottomTab === modelData.id
                                                width: btLbl.implicitWidth + 24; height: 38; radius: 19
                                                color: act ? themeHub.accentB : themeHub.phonePillBg
                                                border.width: 2.5; border.color: act ? "#1A1B2E" : themeHub.phoneBorder
                                                Text { id: btLbl; anchors.centerIn: parent; text: modelData.label; font.pixelSize: 15; font.weight: Font.Black; color: act ? "#1A1B2E" : themeHub.phoneInk }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: quickPanelWindow.bottomTab = modelData.id }
                                            }
                                        }
                                    }
                                    Row {
                                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                        Rectangle {
                                            width: 40; height: 36; radius: 18
                                            color: themeHub.phoneDarkMode ? "#1A1B2E" : themeHub.phonePillBg
                                            border.width: 2.5; border.color: themeHub.phoneDarkMode ? themeHub.accentA : themeHub.phoneBorder
                                            Text {
                                                id: pmDarkLbl; anchors.centerIn: parent
                                                text: themeHub.phoneDarkMode ? "🌙" : "☀"
                                                font.pixelSize: 15; font.weight: Font.Black
                                                color: themeHub.phoneDarkMode ? themeHub.accentA : themeHub.phoneInk
                                            }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setPhoneDarkMode(!themeHub.phoneDarkMode) }
                                        }
                                        Rectangle {
                                            width: pmSwLbl.implicitWidth + 24; height: 36; radius: 18
                                            color: topBarWindow.phoneMode ? "#1A1B2E" : themeHub.phonePillBg
                                            border.width: 2.5; border.color: themeHub.phoneDarkMode && !topBarWindow.phoneMode ? themeHub.phoneBorder : "#1A1B2E"
                                            Text {
                                                id: pmSwLbl; anchors.centerIn: parent
                                                text: topBarWindow.phoneMode ? "2.5D" : "2D"
                                                font.pixelSize: 15; font.weight: Font.Black
                                                color: topBarWindow.phoneMode ? themeHub.accentB : themeHub.phoneInk
                                            }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setPhoneMode(!themeHub.phoneMode) }
                                        }
                                    }
                                }

                                // TAB A: LIVE OS NOTIFICATIONS + COMPACT MEDIA / TELEMETRY STRIP
                                Column {
                                    visible: quickPanelWindow.bottomTab === "notifications"
                                    width: parent.width; spacing: 8

                                    // Compact Now Playing + Telemetry Strip (48px)
                                    Rectangle {
                                        width: parent.width; height: 48; radius: 15
                                        color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                        Row {
                                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 32; height: 32; radius: 9
                                                color: themeHub.accentA; border.width: 2; border.color: "#1A1B2E"; clip: true
                                                Image {
                                                    anchors.fill: parent
                                                    source: MediaService.hasSession ? MediaService.artUrl : ""
                                                    fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false
                                                    visible: status === Image.Ready
                                                }
                                                Text { visible: !MediaService.hasSession; anchors.centerIn: parent; text: "♪"; font.pixelSize: 17; font.weight: Font.Black; color: "#1A1B2E" }
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: Math.max(100, parent.width - 245)
                                                elide: Text.ElideRight
                                                text: MediaService.hasSession ? (MediaService.title || "Playing") : ("CPU " + WindowTracker.cpuUsage + "% · RAM " + WindowTracker.ramUsage + "%")
                                                font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk
                                            }
                                            Row {
                                                anchors.verticalCenter: parent.verticalCenter; spacing: 5
                                                Rectangle {
                                                    width: 32; height: 32; radius: 16; color: themeHub.accentB; border.width: 2; border.color: "#1A1B2E"
                                                    Text { anchors.centerIn: parent; text: MediaService.isPlaying ? "❚❚" : "▶"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: MediaService.playPause() }
                                                }
                                                Rectangle {
                                                    width: 32; height: 32; radius: 16; color: themeHub.phoneCardBg; border.width: 2; border.color: themeHub.phoneBorder
                                                    Text { anchors.centerIn: parent; text: "⏭"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneInk }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: MediaService.next() }
                                                }
                                            }
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: spotMiniLbl.implicitWidth + 18; height: 32; radius: 16
                                                color: spotMiniMa.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                                                border.width: 2; border.color: themeHub.phoneBorder
                                                Text { id: spotMiniLbl; anchors.centerIn: parent; text: "Spotlight"; font.pixelSize: 13; font.weight: Font.Black; color: spotMiniMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                                MouseArea {
                                                    id: spotMiniMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { topBarWindow.quickPanelOpen = false; themeHub.spotlightOpen = true }
                                                }
                                            }
                                        }
                                    }

                                    // Notifications Header + Clear All
                                    Item {
                                        width: parent.width; height: 30
                                        Text {
                                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                            text: "Notifications (" + NotificationService.count + ")"
                                            font.pixelSize: 17; font.weight: Font.Black; color: themeHub.phoneInk
                                        }
                                        Row {
                                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                            Rectangle {
                                                width: 30; height: 28; radius: 14
                                                color: refNotifMa.containsMouse ? themeHub.hoverTint : themeHub.phonePillBg
                                                border.width: 2; border.color: themeHub.phoneBorder
                                                Text { id: refNotifLbl; anchors.centerIn: parent; text: "↻"; font.pixelSize: 15; font.weight: Font.Black; color: refNotifMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                                MouseArea {
                                                    id: refNotifMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: NotificationService.refresh()
                                                }
                                            }
                                            Rectangle {
                                                visible: NotificationService.count > 0
                                                width: clrNotifLbl.implicitWidth + 20; height: 28; radius: 14
                                                color: clrNotifMa.containsMouse ? "#FCA5A5" : "#FFE4E6"
                                                border.width: 2; border.color: "#1A1B2E"
                                                Text { id: clrNotifLbl; anchors.centerIn: parent; text: "Clear all"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                MouseArea {
                                                    id: clrNotifMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: NotificationService.clearAll()
                                                }
                                            }
                                        }
                                    }

                                    // Notification Feed / Access / Empty State
                                    Item {
                                        width: parent.width; height: 204

                                        // Permission denied / not granted
                                        Rectangle {
                                            visible: !NotificationService.accessGranted
                                            anchors.fill: parent; radius: 18
                                            color: themeHub.phoneDarkMode ? "#261E1B" : "#FFF7ED"; border.width: 2.5; border.color: themeHub.phoneBorder
                                            Column {
                                                anchors.centerIn: parent; width: parent.width - 32; spacing: 8
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: "Notification access required"
                                                    font.pixelSize: 17; font.weight: Font.Black; color: themeHub.phoneInk
                                                }
                                                Text {
                                                    width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                                                    text: "Enable Windows notification access so SekaiDesk can display live toasts here."
                                                    font.pixelSize: 15; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                }
                                                Row {
                                                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                                                    Rectangle {
                                                        width: 132; height: 34; radius: 17; color: themeHub.accentB; border.width: 2; border.color: "#1A1B2E"
                                                        Text { anchors.centerIn: parent; text: "Open Settings"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: SystemControl.openSettings("ms-settings:privacy-notifications") }
                                                    }
                                                    Rectangle {
                                                        width: 86; height: 34; radius: 17; color: themeHub.phoneCardBg; border.width: 2; border.color: themeHub.phoneBorder
                                                        Text { anchors.centerIn: parent; text: "Retry"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: NotificationService.refresh() }
                                                    }
                                                }
                                            }
                                        }

                                        // Empty feed state
                                        Rectangle {
                                            visible: NotificationService.accessGranted && NotificationService.count === 0
                                            anchors.fill: parent; radius: 18
                                            color: themeHub.phoneSubBg; border.width: 2; border.color: themeHub.phoneBorder
                                            Column {
                                                anchors.centerIn: parent; spacing: 6
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: "All caught up"
                                                    font.pixelSize: 18; font.weight: Font.Black; color: themeHub.phoneInk
                                                }
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: "Live Windows notifications will show up here · " + themeHub.bandName
                                                    font.pixelSize: 15; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                }
                                            }
                                        }

                                        // Live Notifications ListView
                                        ListView {
                                            visible: NotificationService.accessGranted && NotificationService.count > 0
                                            anchors.fill: parent
                                            clip: true
                                            spacing: 10
                                            boundsBehavior: Flickable.StopAtBounds
                                            model: NotificationService.notifications
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: ListView.view.width
                                                height: Math.max(78, notifTextCol.implicitHeight + 20)
                                                radius: 18
                                                color: themeHub.phoneSubBg
                                                border.width: 2.5; border.color: themeHub.phoneBorder

                                                Row {
                                                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                                    anchors.topMargin: 10; anchors.bottomMargin: 10
                                                    spacing: 12

                                                    Rectangle {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: 42; height: 42; radius: 12
                                                        color: themeHub.accentB
                                                        border.width: 2; border.color: "#1A1B2E"
                                                        clip: true
                                                        Image {
                                                            id: notifAppImg
                                                            anchors.fill: parent; anchors.margins: 3
                                                            source: modelData.iconUrl || ""
                                                            fillMode: Image.PreserveAspectFit
                                                            asynchronous: true; cache: true; mipmap: true
                                                            visible: source !== "" && status === Image.Ready
                                                        }
                                                        Text {
                                                            visible: !notifAppImg.visible
                                                            anchors.centerIn: parent
                                                            text: (modelData.app || "?").trim().charAt(0).toUpperCase() || "?"
                                                            font.pixelSize: 18; font.weight: Font.Black; color: "#1A1B2E"
                                                        }
                                                    }

                                                    Column {
                                                        id: notifTextCol
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: parent.width - 98
                                                        spacing: 3

                                                        Row {
                                                            width: parent.width; spacing: 6
                                                            Text {
                                                                width: Math.min(implicitWidth, parent.width - timeLbl.implicitWidth - 10)
                                                                elide: Text.ElideRight
                                                                text: modelData.app || "App"
                                                                font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneMutedInk
                                                            }
                                                            Text {
                                                                id: timeLbl
                                                                text: modelData.timeText ? ("· " + modelData.timeText) : ""
                                                                font.pixelSize: 14; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                            }
                                                        }

                                                        Text {
                                                            width: parent.width
                                                            wrapMode: Text.Wrap
                                                            elide: Text.ElideRight
                                                            maximumLineCount: 2
                                                            text: modelData.title || modelData.app || "Notification"
                                                            font.pixelSize: 18; font.weight: Font.Black; color: themeHub.phoneInk
                                                        }

                                                        Text {
                                                            visible: (modelData.body || "") !== ""
                                                            width: parent.width
                                                            wrapMode: Text.Wrap
                                                            maximumLineCount: 2
                                                            elide: Text.ElideRight
                                                            text: modelData.body || ""
                                                            font.pixelSize: 15; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                        }
                                                    }

                                                    Rectangle {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: 32; height: 32; radius: 16
                                                        color: notifDismissMa.containsMouse ? "#FCA5A5" : themeHub.phoneCardBg
                                                        border.width: 2; border.color: themeHub.phoneBorder
                                                        Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 18; font.weight: Font.Black; color: notifDismissMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                                        MouseArea {
                                                            id: notifDismissMa
                                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                const nid = modelData.id
                                                                Qt.callLater(function() { NotificationService.dismiss(nid) })
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // TAB C: SCREEN MIRROR + MULTI-MONITOR DISPLAYS
                                Column {
                                    visible: quickPanelWindow.bottomTab === "display"
                                    width: parent.width; spacing: 12

                                    Text { text: "SCREEN MIRRORING"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneMutedInk }
                                    Row {
                                        width: parent.width; spacing: 8
                                        Repeater {
                                            model: [
                                                { label: "Main", mode: "internal" },
                                                { label: "Duplicate", mode: "clone" },
                                                { label: "Extend", mode: "extend" },
                                                { label: "2nd Only", mode: "external" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: Math.floor((parent.width - 24) / 4); height: 46; radius: 15
                                                color: mirPhoneMa.containsMouse ? themeHub.accentB : themeHub.phonePillBg
                                                border.width: 2.5; border.color: themeHub.phoneBorder
                                                Text { anchors.centerIn: parent; text: modelData.label; font.pixelSize: 15; font.weight: Font.Black; color: mirPhoneMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                                MouseArea {
                                                    id: mirPhoneMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: SystemControl.setDisplayMode(modelData.mode)
                                                }
                                            }
                                        }
                                    }

                                    Text { text: "MONITORS (" + SystemControl.monitors.length + ")"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneMutedInk }
                                    Flickable {
                                        width: parent.width; height: 150; contentWidth: width; contentHeight: monListCol.implicitHeight + 8; clip: true
                                        Column {
                                            id: monListCol; width: parent.width; spacing: 10
                                            Repeater {
                                                model: SystemControl.monitors
                                                delegate: Column {
                                                    required property var modelData
                                                    width: monListCol.width; spacing: 4
                                                    Item {
                                                        width: parent.width; height: 24
                                                        Text { anchors.left: parent.left; text: modelData.name || "Monitor"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        Text { anchors.right: parent.right; text: modelData.brightness + "%"; font.family: "Consolas"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneDarkMode ? "#FBBF24" : "#D97706" }
                                                    }
                                                    Item {
                                                        width: parent.width; height: 22
                                                        Rectangle {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            width: parent.width; height: 16; radius: 8
                                                            color: themeHub.phonePillBg; border.width: 2; border.color: themeHub.phoneBorder
                                                            Rectangle {
                                                                x: 2; y: 2; height: 12; radius: 6
                                                                width: Math.max(0, (parent.width - 4) * (modelData.brightness / 100.0))
                                                                color: "#FBBF24"
                                                            }
                                                        }
                                                        MouseArea {
                                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            function setMb(mx) {
                                                                SystemControl.setMonitorBrightness(modelData.index, Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100))
                                                            }
                                                            onPressed: mouse => setMb(mouse.x)
                                                            onPositionChanged: mouse => { if (pressed) setMb(mouse.x) }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- Inline Wi-Fi / Bluetooth Picker Overlay inside the Phone Screen ----
                        Rectangle {
                            id: qpSubOverlay
                            property string passwordSsid: ""
                            visible: quickPanelWindow.subDialog !== ""
                            onVisibleChanged: if (!visible) passwordSsid = ""
                            x: 34; y: 346; width: 586; height: 834
                            radius: 36
                            color: themeHub.phoneCardBg
                            border.width: 3.5; border.color: themeHub.phoneBorder
                            z: 30

                            Column {
                                anchors.fill: parent; anchors.margins: 22; spacing: 12

                                Item {
                                    width: parent.width; height: 46
                                    Rectangle {
                                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        width: 94; height: 38; radius: 19
                                        color: themeHub.phonePillBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                        Text { anchors.centerIn: parent; text: "← Back"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { qpSubOverlay.passwordSsid = ""; quickPanelWindow.subDialog = "" } }
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: quickPanelWindow.subDialog === "wifi" ? "WI-FI NETWORKS" : "BLUETOOTH DEVICES"
                                        font.pixelSize: 18; font.weight: Font.Black; color: themeHub.phoneInk
                                    }
                                    Rectangle {
                                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        width: qpScanLbl.implicitWidth + 28; height: 38; radius: 19
                                        color: ((quickPanelWindow.subDialog === "wifi" && SystemControl.wifiScanning)
                                                || (quickPanelWindow.subDialog === "bt" && SystemControl.btScanning))
                                               ? "#FEF3C7" : themeHub.accentB
                                        border.width: 2.5; border.color: "#1A1B2E"
                                        Text {
                                            id: qpScanLbl
                                            anchors.centerIn: parent
                                            text: ((quickPanelWindow.subDialog === "wifi" && SystemControl.wifiScanning)
                                                   || (quickPanelWindow.subDialog === "bt" && SystemControl.btScanning))
                                                  ? "Scanning..." : "Scan"
                                            font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E"
                                        }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (quickPanelWindow.subDialog === "wifi") SystemControl.refreshWifi()
                                                else SystemControl.scanBluetooth()
                                            }
                                        }
                                    }
                                }

                                Text {
                                    visible: quickPanelWindow.subDialog === "wifi" && SystemControl.wifiStatusText !== ""
                                    width: parent.width; elide: Text.ElideRight
                                    text: SystemControl.wifiStatusText
                                    font.pixelSize: 14; font.weight: Font.Black; color: themeHub.accentA
                                }

                                // Inline Wi-Fi Password Prompt inside Phone
                                Rectangle {
                                    visible: quickPanelWindow.subDialog === "wifi" && qpSubOverlay.passwordSsid !== ""
                                    width: parent.width; height: 112; radius: 20
                                    color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.accentA
                                    Column {
                                        anchors.fill: parent; anchors.margins: 12; spacing: 8
                                        Text {
                                            width: parent.width; elide: Text.ElideRight
                                            text: "🔒 Password for " + qpSubOverlay.passwordSsid
                                            font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk
                                        }
                                        Row {
                                            width: parent.width; height: 42; spacing: 8
                                            Rectangle {
                                                width: parent.width - 184; height: 42; radius: 12
                                                color: themeHub.phoneCardBg; border.width: 2; border.color: themeHub.phoneBorder; clip: true
                                                TextInput {
                                                    id: qpWifiPwInput
                                                    anchors.fill: parent; anchors.margins: 10
                                                    verticalAlignment: Text.AlignVCenter
                                                    echoMode: TextInput.Password
                                                    font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Bold; color: themeHub.phoneInk
                                                    selectByMouse: true
                                                    onAccepted: {
                                                        const target = qpSubOverlay.passwordSsid
                                                        const pw = text
                                                        qpSubOverlay.passwordSsid = ""
                                                        text = ""
                                                        SystemControl.connectWifiWithPassword(target, pw)
                                                    }
                                                }
                                            }
                                            Rectangle {
                                                width: 96; height: 42; radius: 12; color: themeHub.accentA; border.width: 2; border.color: "#1A1B2E"
                                                Text { anchors.centerIn: parent; text: "Connect"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        const target = qpSubOverlay.passwordSsid
                                                        const pw = qpWifiPwInput.text
                                                        qpSubOverlay.passwordSsid = ""
                                                        qpWifiPwInput.text = ""
                                                        SystemControl.connectWifiWithPassword(target, pw)
                                                    }
                                                }
                                            }
                                            Rectangle {
                                                width: 72; height: 42; radius: 12; color: themeHub.phonePillBg; border.width: 2; border.color: themeHub.phoneBorder
                                                Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { qpSubOverlay.passwordSsid = ""; qpWifiPwInput.text = "" }
                                                }
                                            }
                                        }
                                    }
                                }

                                Flickable {
                                    width: parent.width
                                    height: parent.height - 120 - (quickPanelWindow.subDialog === "wifi" && qpSubOverlay.passwordSsid !== "" ? 124 : 0) - (quickPanelWindow.subDialog === "wifi" && SystemControl.wifiStatusText !== "" ? 28 : 0)
                                    contentWidth: width; contentHeight: subListCol.implicitHeight + 10; clip: true

                                    Column {
                                        id: subListCol; width: parent.width; spacing: 10

                                        // Wi-Fi list
                                        Repeater {
                                            model: quickPanelWindow.subDialog === "wifi" ? SystemControl.wifiNetworks : []
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool isConnecting: SystemControl.wifiConnectingSsid !== "" && (SystemControl.wifiConnectingSsid === modelData.ssid || SystemControl.wifiConnectingSsid === modelData.profile)
                                                readonly property bool isKnown: (modelData.profile && modelData.profile !== "") || !modelData.secured
                                                readonly property bool canForget: !!(modelData.profile && modelData.profile !== "")
                                                width: subListCol.width; height: 56; radius: 20
                                                color: modelData.connected ? themeHub.accentB : (isConnecting ? "#FEF3C7" : themeHub.phoneSubBg)
                                                border.width: 2.5; border.color: (modelData.connected || isConnecting) ? "#1A1B2E" : themeHub.phoneBorder
                                                Text {
                                                    x: 18; anchors.verticalCenter: parent.verticalCenter; width: parent.width - (canForget ? 215 : 155); elide: Text.ElideRight
                                                    text: (modelData.connected ? "✓ " : (modelData.secured && !isKnown ? "🔒 " : "")) + (modelData.ssid || "Hidden Network")
                                                    font.pixelSize: 16; font.weight: Font.Black; color: (modelData.connected || isConnecting) ? "#1A1B2E" : themeHub.phoneInk
                                                }
                                                Text {
                                                    anchors.right: canForget ? qpWifiFgtBtn.left : parent.right
                                                    anchors.rightMargin: canForget ? 10 : 18
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: isConnecting ? "Connecting..." : ((modelData.signal || 0) + "%")
                                                    font.family: "Consolas"; font.pixelSize: 15; font.weight: Font.Black; color: (modelData.connected || isConnecting) ? "#1A1B2E" : themeHub.phoneMutedInk
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; anchors.rightMargin: canForget ? 74 : 0; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (modelData.connected)
                                                            return
                                                        if (isKnown) {
                                                            const prof = modelData.profile || modelData.ssid
                                                            qpSubOverlay.passwordSsid = ""
                                                            Qt.callLater(function() { SystemControl.connectWifi(prof) })
                                                        } else {
                                                            qpSubOverlay.passwordSsid = modelData.ssid
                                                            qpWifiPwInput.text = ""
                                                            qpWifiPwInput.forceActiveFocus()
                                                        }
                                                    }
                                                }
                                                Rectangle {
                                                    id: qpWifiFgtBtn
                                                    visible: canForget
                                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                                    width: 56; height: 28; radius: 14
                                                    color: qpWifiFgtMa.containsMouse ? "#FB7185" : themeHub.phonePillBg
                                                    border.width: 2; border.color: "#1A1B2E"
                                                    Text { anchors.centerIn: parent; text: "Forget"; font.pixelSize: 11; font.weight: Font.Black; color: qpWifiFgtMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                                    MouseArea {
                                                        id: qpWifiFgtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            const prof = modelData.profile
                                                            Qt.callLater(function() { SystemControl.forgetWifi(prof) })
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Bluetooth list
                                        Repeater {
                                            model: quickPanelWindow.subDialog === "bt" ? SystemControl.bluetoothDevices : []
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool canForget: (modelData.paired !== false) && !!(modelData.address && modelData.address !== "" && modelData.address !== "0")
                                                width: subListCol.width; height: 56; radius: 20
                                                color: modelData.connected ? themeHub.accentA : themeHub.phoneSubBg
                                                border.width: 2.5; border.color: modelData.connected ? "#1A1B2E" : themeHub.phoneBorder
                                                Text {
                                                    x: 18; anchors.verticalCenter: parent.verticalCenter; width: parent.width - (canForget ? 210 : 140); elide: Text.ElideRight
                                                    text: modelData.name || "Bluetooth Device"
                                                    font.pixelSize: 16; font.weight: Font.Black; color: modelData.connected ? "#1A1B2E" : themeHub.phoneInk
                                                }
                                                Text {
                                                    anchors.right: canForget ? qpBtFgtBtn.left : parent.right
                                                    anchors.rightMargin: canForget ? 10 : 18
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.connected ? "Connected" : (modelData.paired !== false ? "Paired" : "Nearby")
                                                    font.pixelSize: 14; font.weight: Font.Black; color: modelData.connected ? "#1A1B2E" : themeHub.phoneMutedInk
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; anchors.rightMargin: canForget ? 74 : 0; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (!modelData.connected && modelData.paired === false) {
                                                            topBarWindow.quickPanelOpen = false
                                                            SystemControl.openAddDeviceDialog()
                                                        }
                                                    }
                                                }
                                                Rectangle {
                                                    id: qpBtFgtBtn
                                                    visible: canForget
                                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                                    width: 56; height: 28; radius: 14
                                                    color: qpBtFgtMa.containsMouse ? "#FB7185" : themeHub.phonePillBg
                                                    border.width: 2; border.color: "#1A1B2E"
                                                    Text { anchors.centerIn: parent; text: "Forget"; font.pixelSize: 11; font.weight: Font.Black; color: qpBtFgtMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                                    MouseArea {
                                                        id: qpBtFgtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            const addr = modelData.address
                                                            Qt.callLater(function() { SystemControl.forgetBluetooth(addr) })
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                Row {
                                    width: parent.width; spacing: 10
                                    Rectangle {
                                        visible: quickPanelWindow.subDialog === "bt"
                                        width: 170; height: 48; radius: 24
                                        color: themeHub.accentA; border.width: 2.5; border.color: "#1A1B2E"
                                        Text { anchors.centerIn: parent; text: "+ Add Device"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E" }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: { topBarWindow.quickPanelOpen = false; SystemControl.openAddDeviceDialog() }
                                        }
                                    }
                                    Rectangle {
                                        width: quickPanelWindow.subDialog === "bt" ? (parent.width - 180) : parent.width
                                        height: 48; radius: 24
                                        color: themeHub.phonePillBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                        Text {
                                            anchors.centerIn: parent
                                            text: quickPanelWindow.subDialog === "wifi" ? "Open Windows Wi-Fi Settings" : "Open Bluetooth Settings"
                                            font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk
                                        }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                topBarWindow.quickPanelOpen = false
                                                SystemControl.openSettings(quickPanelWindow.subDialog === "wifi" ? "ms-settings:network-wifi" : "ms-settings:bluetooth")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Live incoming Notification Alert Banner on Phone Peek (click to expand QuickPanel)
                    Item {
                        id: notifAlertBanner
                        visible: quickPanelWindow.notifAlertPeek && quickPanelWindow.alertNotifItem !== null && !quickPanelWindow.panelWanted
                        x: 36; y: 84; width: 582; height: 132
                        z: 45

                        HoverHandler {
                            onHoveredChanged: quickPanelWindow.alertHovered = hovered
                        }

                        Rectangle {
                            x: 5; y: 5; width: parent.width; height: parent.height; radius: 26
                            color: "#1A1B2E"
                        }

                        Rectangle {
                            id: alertBannerCard
                            anchors.fill: parent
                            radius: 26
                            color: themeHub.phoneCardBg
                            border.width: 3.5
                            border.color: themeHub.phoneBorder
                            clip: true

                            Rectangle {
                                x: 14; y: 18; width: 7; height: parent.height - 36; radius: 4
                                color: themeHub.accentA
                            }

                            Column {
                                x: 32; y: 18
                                width: parent.width - 84
                                spacing: 5

                                Row {
                                    spacing: 10
                                    Rectangle {
                                        height: 24; width: Math.min(260, alertAppLbl.implicitWidth + 18); radius: 10
                                        color: themeHub.accentA
                                        border.width: 2; border.color: "#1A1B2E"
                                        Text {
                                            id: alertAppLbl
                                            anchors.centerIn: parent
                                            width: parent.width - 10; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                                            text: (quickPanelWindow.alertNotifItem && quickPanelWindow.alertNotifItem.app ? quickPanelWindow.alertNotifItem.app : "NOTIFICATION").toUpperCase()
                                            font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E"
                                        }
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: quickPanelWindow.alertNotifItem && quickPanelWindow.alertNotifItem.timeText ? quickPanelWindow.alertNotifItem.timeText : "NOW"
                                        font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Bold; color: themeHub.phoneMutedInk
                                    }
                                }

                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: quickPanelWindow.alertNotifItem && quickPanelWindow.alertNotifItem.title ? quickPanelWindow.alertNotifItem.title : "New Notification"
                                    font.family: "Segoe UI"; font.pixelSize: 18; font.weight: Font.Black; color: themeHub.phoneInk
                                }

                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    wrapMode: Text.WordWrap
                                    text: quickPanelWindow.alertNotifItem && quickPanelWindow.alertNotifItem.body ? quickPanelWindow.alertNotifItem.body : ""
                                    font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    quickPanelWindow.dismissNotifPeek()
                                    quickPanelWindow.bottomTab = "notifications"
                                    topBarWindow.quickPanelOpen = true
                                }
                            }

                            Rectangle {
                                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
                                width: 32; height: 32; radius: 16
                                color: alertDismissMa.containsMouse ? "#FB7185" : "#FFE4E6"
                                border.width: 2; border.color: "#1A1B2E"
                                z: 5
                                Text { anchors.centerIn: parent; text: "×"; font.family: "Segoe UI"; font.pixelSize: 18; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    id: alertDismissMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: quickPanelWindow.dismissNotifPeek()
                                }
                            }
                        }
                    }

                    // 5) Phone Top Notch + Camera Lens + Glint
                    Item {
                        x: 202
                        y: quickPanelWindow.screenInset - 12
                        width: 249
                        height: 49 + 12
                        clip: true
                        z: 50

                        Rectangle {
                            y: -27
                            width: parent.width
                            height: parent.height + 27
                            radius: 27
                            color: "#1A1B2E"
                            antialiasing: true
                        }
                        Rectangle {
                            x: 24; y: 15 + 12
                            width: 22; height: 22; radius: 11
                            color: "#0F172A"
                            Rectangle {
                                anchors.centerIn: parent
                                width: 10; height: 10; radius: 5
                                color: "#1E3A5F"
                                Rectangle { x: 2; y: 2; width: 3; height: 3; radius: 2; color: "#93C5FD" }
                            }
                        }
                    }
                }
            }
        }

        // =====================================================================
        // Landscape Settings Stage (90 deg CCW 2.5D Phone Flip + 1440x760 Tablet)
        // =====================================================================
        Item {
            id: landStage
            visible: quickPanelWindow.curSettingsAlpha > 0.001 || themeHub.settingsOpen || quickPanelWindow.settingsAnimating
            enabled: themeHub.settingsOpen && quickPanelWindow.flipProgress >= 0.95 && !quickPanelWindow.flipping
            anchors.fill: parent

            // Soft dim desktop backdrop behind landscape Settings phone
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(10 / 255, 14 / 255, 28 / 255, 0.42 * quickPanelWindow.curSettingsAlpha)
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        topBarWindow.quickPanelClosedAt = Date.now()
                        topBarWindow.quickPanelOpen = false
                        themeHub.settingsOpen = false
                    }
                }
            }

            // Center-origin 2.5D pivot (0px jump from Portrait phoneStage center)
            Item {
                id: landPivot
                x: quickPanelWindow.curCenterX
                y: quickPanelWindow.curCenterY
                width: 0
                height: 0
                opacity: quickPanelWindow.curSettingsAlpha
                transform: Scale {
                    origin.x: 0; origin.y: 0
                    xScale: quickPanelWindow.curLandScale
                    yScale: quickPanelWindow.curLandScale
                }

                // ---- Landscape 2.5D Settings Chassis (SekaiPop SettingsStage parity) ----
                Item {
                    id: flipLandBody
                    visible: quickPanelWindow.curSettingsAlpha > 0.001
                    readonly property real flatK: 1.0 - quickPanelWindow.straightK
                    readonly property real effThickness: quickPanelWindow.landThickness * flatK
                    readonly property real effYaw: quickPanelWindow.curYaw * flatK
                    readonly property real effPitch: quickPanelWindow.curPitch * flatK
                    readonly property var mat: quickPanelWindow.pmBaseForCenter(
                        quickPanelWindow.landW,
                        quickPanelWindow.landH,
                        effThickness,
                        effYaw + quickPanelWindow.sTilt * quickPanelWindow.landTiltYaw * flatK,
                        effPitch + quickPanelWindow.sTilt * quickPanelWindow.landTiltPitch * flatK + quickPanelWindow.wobPitch,
                        90.0 * (1.0 - quickPanelWindow.flipProgress) + quickPanelWindow.wobRoll + quickPanelWindow.sTilt * quickPanelWindow.landTiltRoll * flatK,
                        quickPanelWindow.curPersp
                    )

                    // Grounded 9-slice comic drop shadow
                    BorderImage {
                        source: "qrc:/qml/assets/phone-shadow.png"
                        border { left: 72; top: 72; right: 72; bottom: 72 }
                        x: -26; y: -16
                        width: quickPanelWindow.landW + 64
                        height: quickPanelWindow.landH + 64
                        opacity: 0.85
                        smooth: true
                        transform: Matrix4x4 {
                            matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmZOffset(flipLandBody.mat, -flipLandBody.effThickness - 4))
                        }
                    }

                    // Solid 3D rim slices (extruded wall)
                    Repeater {
                        model: topBarWindow.phoneMode ? 18 : 0
                        delegate: Rectangle {
                            required property int index
                            readonly property real depth: (18 - index) / 18.0
                            visible: flipLandBody.effThickness > 1.0
                            width: quickPanelWindow.landW
                            height: quickPanelWindow.landH
                            radius: quickPanelWindow.landCornerR
                            antialiasing: depth < 0.28
                            color: depth < 0.16 ? "#8E92B8" : (depth < 0.55 ? "#4C5073" : "#24263A")
                            transform: Matrix4x4 {
                                matrix: quickPanelWindow.toQtMat(quickPanelWindow.pmZOffset(flipLandBody.mat, -depth * flipLandBody.effThickness))
                            }
                        }
                    }

                    // Landscape Screen Face (1440x760)
                    Item {
                        id: landScreenFace
                        width: quickPanelWindow.landW
                        height: quickPanelWindow.landH
                        transform: Matrix4x4 {
                            matrix: quickPanelWindow.toQtMat(flipLandBody.mat)
                        }

                        // Eat clicks inside tilted chassis so backdrop doesn't dismiss
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {}
                        }

                        // Outer titanium rim + bezel
                        Rectangle {
                            anchors.fill: parent
                            radius: quickPanelWindow.landCornerR
                            color: "#2E3148"
                            border.width: 4
                            border.color: "#1A1B2E"
                        }
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 10
                            radius: quickPanelWindow.landCornerR - 10
                            color: "#1A1B2E"
                        }

                        // Paper screen interior
                        Rectangle {
                            id: landPaper
                            anchors.fill: parent
                            anchors.margins: 24
                            radius: quickPanelWindow.landCornerR - 24
                            color: themeHub.phoneLandBg
                            border.width: 3
                            border.color: themeHub.phoneBorder
                            clip: true

                            // SekaiPop diagonal stage-light bands
                            SekaiSlant {
                                x: -160; y: -40; width: 520; height: parent.height + 80
                                skew: 0.34
                                color: Qt.rgba(themeHub.accentA.r, themeHub.accentA.g, themeHub.accentA.b, 0.14)
                            }
                            SekaiSlant {
                                x: 160; y: -40; width: 390; height: parent.height + 80
                                skew: 0.34
                                color: Qt.rgba(244 / 255, 114 / 255, 182 / 255, 0.13)
                            }
                            SekaiSlant {
                                x: 310; y: -40; width: 300; height: parent.height + 80
                                skew: 0.34
                                color: Qt.rgba(250 / 255, 204 / 255, 21 / 255, 0.16)
                            }

                            // Top-right comic halftone dots
                            Canvas {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                width: 320; height: 210
                                opacity: 0.16
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.fillStyle = themeHub.accentA
                                    for (let r = 0; r < 10; r++) {
                                        for (let c = 0; c < 14; c++) {
                                            const rad = Math.max(0.8, 5.2 - r * 0.42 - (13 - c) * 0.25)
                                            if (rad <= 0.8) continue
                                            ctx.beginPath()
                                            ctx.arc(width - 14 - c * 22, 14 + r * 20, rad, 0, Math.PI * 2)
                                            ctx.fill()
                                        }
                                    }
                                }
                            }

                            // ---- Settings View Layer (cross-fades with PhoneWallpaperGallery) ----
                            Item {
                                id: landSettingsWrap
                                anchors.fill: parent
                                visible: quickPanelWindow.contentK < 0.995
                                opacity: 1.0 - quickPanelWindow.contentK
                                enabled: quickPanelWindow.contentK < 0.5

                            // ---- Header Bar inside Landscape Phone ----
                            Item {
                                id: landHeader
                                x: 58; y: 20
                                width: parent.width - 82
                                height: 68

                                Row {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 14

                                    // Back button (subpage -> Hub, or Hub -> Phone if opened from QuickPanel)
                                    Item {
                                        visible: themeHub.settingsSection !== "" || quickPanelWindow.settingsOpenedFromQuick
                                        width: backLbl.implicitWidth + 34; height: 50
                                        anchors.verticalCenter: parent.verticalCenter
                                        Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 16; color: "#1A1B2E" }
                                        Rectangle {
                                            x: landBackMa.pressed ? 3 : 0; y: landBackMa.pressed ? 3 : 0
                                            width: parent.width; height: parent.height; radius: 16
                                            color: landBackMa.containsMouse ? themeHub.accentA : themeHub.phoneCardBg
                                            border.width: 3; border.color: landBackMa.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                                            Text {
                                                id: backLbl
                                                anchors.centerIn: parent
                                                text: themeHub.settingsSection !== "" ? "← HUB" : "← PHONE"
                                                font.family: "Segoe UI"; font.pixelSize: 18; font.weight: Font.Black
                                                color: landBackMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                                            }
                                            MouseArea {
                                                id: landBackMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (themeHub.settingsSection !== "")
                                                        themeHub.settingsSection = ""
                                                    else
                                                        themeHub.settingsOpen = false
                                                }
                                            }
                                        }
                                    }

                                    // Section badge + title
                                    Rectangle {
                                        width: 50; height: 50; radius: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: themeHub.accentA
                                        border.width: 3; border.color: "#1A1B2E"
                                        Image {
                                            anchors.centerIn: parent
                                            width: 26; height: 26
                                            source: "qrc:/qml/icons/settings-dark.svg"
                                            smooth: true
                                        }
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 1
                                        Text {
                                            text: {
                                                const s = themeHub.settingsSection
                                                if (s === "quick") return "01 · QUICK"
                                                if (s === "general") return "02 · GENERAL"
                                                if (s === "bar") return "03 · BAR"
                                                if (s === "desktop") return "04 · DESKTOP"
                                                if (s === "system") return "05 · HOTKEYS & SYSTEM"
                                                if (s === "about") return "06 · ABOUT"
                                                return "SEKAIDESK SETTINGS"
                                            }
                                            font.family: "Segoe UI"; font.pixelSize: 28; font.weight: Font.Black; color: themeHub.phoneInk
                                        }
                                        Text {
                                            text: themeHub.settingsSection === ""
                                                  ? "Choose a category card to customize your desktop"
                                                  : "Changes apply live and save automatically"
                                            font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                        }
                                    }
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 10

                                    // Quick Palette Band Swatches
                                    Repeater {
                                        model: themeHub.bands
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: 30; height: 30; radius: 15
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: modelData.A
                                            border.width: (!themeHub.useCustomPalette && themeHub.bandId === modelData.id) ? 4 : 2
                                            border.color: "#1A1B2E"
                                            scale: bandDotMa.containsMouse ? 1.12 : 1.0
                                            MouseArea {
                                                id: bandDotMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: themeHub.setBand(modelData.id)
                                            }
                                        }
                                    }

                                    // Integrated Wallpaper Gallery pill
                                    Item {
                                        width: 124; height: 46
                                        anchors.verticalCenter: parent.verticalCenter
                                        Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 14; color: "#1A1B2E" }
                                        Rectangle {
                                            x: landWallsMa.pressed ? 3 : 0; y: landWallsMa.pressed ? 3 : 0
                                            width: parent.width; height: parent.height; radius: 14
                                            color: landWallsMa.containsMouse ? themeHub.accentA : themeHub.phoneCardBg
                                            border.width: 3; border.color: landWallsMa.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                                            Text {
                                                anchors.centerIn: parent
                                                text: "🖼 WALLS"
                                                font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black
                                                color: landWallsMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                                            }
                                            MouseArea {
                                                id: landWallsMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    themeHub.landscapeContent = "wallpapers"
                                                    WallpaperService.refresh()
                                                }
                                            }
                                        }
                                    }

                                    // Edit Mode shortcut pill
                                    Item {
                                        width: 124; height: 46
                                        anchors.verticalCenter: parent.verticalCenter
                                        Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 14; color: "#1A1B2E" }
                                        Rectangle {
                                            x: landEditMa.pressed ? 3 : 0; y: landEditMa.pressed ? 3 : 0
                                            width: parent.width; height: parent.height; radius: 14
                                            color: themeHub.editMode ? themeHub.accentB : (landEditMa.containsMouse ? "#E0F2FE" : themeHub.phoneCardBg)
                                            border.width: 3; border.color: (themeHub.editMode || landEditMa.containsMouse) ? "#1A1B2E" : themeHub.phoneBorder
                                            Text {
                                                anchors.centerIn: parent
                                                text: themeHub.editMode ? "✎ EDITING" : "✎ EDIT"
                                                font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black
                                                color: (themeHub.editMode || landEditMa.containsMouse) ? "#1A1B2E" : themeHub.phoneInk
                                            }
                                            MouseArea {
                                                id: landEditMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    themeHub.setEditMode(!themeHub.editMode)
                                                    if (themeHub.editMode) {
                                                        themeHub.settingsOpen = false
                                                        topBarWindow.quickPanelOpen = false
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Close button
                                    Item {
                                        width: 50; height: 46
                                        anchors.verticalCenter: parent.verticalCenter
                                        Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 14; color: "#1A1B2E" }
                                        Rectangle {
                                            x: landCloseMa.pressed ? 3 : 0; y: landCloseMa.pressed ? 3 : 0
                                            width: parent.width; height: parent.height; radius: 14
                                            color: landCloseMa.containsMouse ? "#FB7185" : "#FFE4E6"
                                            border.width: 3; border.color: "#1A1B2E"
                                            Text {
                                                anchors.centerIn: parent
                                                text: "✕"
                                                font.family: "Segoe UI"; font.pixelSize: 20; font.weight: Font.Black; color: "#1A1B2E"
                                            }
                                            MouseArea {
                                                id: landCloseMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: themeHub.settingsOpen = false
                                            }
                                        }
                                    }
                                }
                            }

                            // ---- Divider line ----
                            Rectangle {
                                x: 58; y: 94
                                width: parent.width - 82; height: 3
                                color: themeHub.phoneInk
                                opacity: 0.16
                            }

                            // ---- Page Area ----
                            Item {
                                x: 58; y: 110
                                width: parent.width - 82
                                height: parent.height - 130

                                // ==== HUB (SekaiPop Brick-Staggered Slanted Keycap Tiles) ====
                                Item {
                                    id: landHubArea
                                    anchors.fill: parent
                                    readonly property bool isHub: themeHub.settingsSection === ""
                                    property real hubP: isHub ? 1.0 : 0.0
                                    Behavior on hubP { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                                    opacity: hubP
                                    scale: 0.96 + 0.04 * hubP
                                    visible: opacity > 0.01
                                    enabled: isHub

                                    readonly property var hubModel: [
                                        { id: "quick",   num: "01", title: "Quick",            sub: "Notify style, OSD, 2.5D mode & audio",      accent: "#06B6D4", iconSrc: "qrc:/qml/icons/rocket-dark.svg",     stripes: ["#F43F5E", "#F59E0B", "#8B5CF6"] },
                                        { id: "general", num: "02", title: "General",          sub: "Theme bands, wallpaper palette & clock",    accent: "#F43F5E", iconSrc: "qrc:/qml/icons/palette-dark.svg",    stripes: ["#F59E0B", "#8B5CF6", "#10B981"] },
                                        { id: "bar",     num: "03", title: "Bar",              sub: "TopBar style, auto-hide & status modules",  accent: "#F59E0B", iconSrc: "qrc:/qml/icons/checklist-dark.svg",  stripes: ["#8B5CF6", "#10B981", "#EC4899"] },
                                        { id: "desktop", num: "04", title: "Desktop",          sub: "Dock layout, widgets, visualizer & walls",  accent: "#8B5CF6", iconSrc: "qrc:/qml/icons/monitor-dark.svg",    stripes: ["#10B981", "#EC4899", "#06B6D4"] },
                                        { id: "system",  num: "05", title: "Hotkeys & System", sub: "Shortcuts, Game Mode, taskbar & quit",      accent: "#10B981", iconSrc: "qrc:/qml/icons/command-dark.svg",    stripes: ["#EC4899", "#06B6D4", "#F43F5E"] },
                                        { id: "about",   num: "06", title: "About",            sub: "SekaiDesk version, build & credits",        accent: "#EC4899", iconSrc: "qrc:/qml/icons/smartphone-dark.svg", stripes: ["#06B6D4", "#F43F5E", "#F59E0B"] }
                                    ]

                                    Repeater {
                                        model: landHubArea.hubModel
                                        delegate: SekaiHubTile {
                                            required property var modelData
                                            required property int index
                                            readonly property int col: index % 3
                                            readonly property int row: Math.floor(index / 3)
                                            wipeFrom: themeHub.accentB
                                            wipeTo: themeHub.accentA
                                            darkMode: themeHub.phoneDarkMode
                                            x: col * (404 + 24) + row * 34
                                            y: 4 + row * (271 + 26)
                                            tileW: 404
                                            tileH: 271
                                            num: modelData.num
                                            title: modelData.title
                                            subtitle: modelData.sub
                                            iconSource: modelData.iconSrc
                                            accent: modelData.accent
                                            stripeColors: modelData.stripes
                                            onClicked: themeHub.settingsSection = modelData.id
                                        }
                                    }
                                }

                                // ==== SUBPAGE 01: QUICK ====
                                Row {
                                    visible: themeHub.settingsSection === "quick"
                                    anchors.fill: parent
                                    spacing: 24

                                    // Left column: Notifications & Peek
                                    Rectangle {
                                        width: (parent.width - 24) * 0.5; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: quickLeftFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: quickLeftCol.implicitHeight
                                            Column {
                                                id: quickLeftCol
                                                width: quickLeftFlick.width; spacing: 14
                                                Text { text: "NOTIFICATIONS & PEEK"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }
                                                Text { text: "Choose how arriving notifications appear without interfering with the Dock."; wrapMode: Text.WordWrap; width: parent.width; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk }

                                                Column {
                                                    width: parent.width; spacing: 10
                                                    Repeater {
                                                        model: [
                                                            { val: "peek",  title: "Phone Peek (Bottom-Right)",  desc: "Mini phone rises bottom-right; auto-falls back to Popup if tight." },
                                                            { val: "popup", title: "Popup Stack (Top-Right)",   desc: "Clean stacked SekaiPop cards below the TopBar." },
                                                            { val: "off",   title: "Off (Tray Only)",           desc: "Silent collection in QuickPanel notification inbox." }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.notifyStyle === modelData.val
                                                            width: parent.width; height: 76; radius: 16
                                                            color: sel ? (themeHub.phoneDarkMode ? "#132E36" : "#ECFEFF") : themeHub.phoneSubBg
                                                            border.width: sel ? 3.5 : 2
                                                            border.color: sel ? themeHub.accentA : themeHub.phoneBorder
                                                            Column {
                                                                anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 16; anchors.right: parent.right; anchors.rightMargin: 16; spacing: 3
                                                                Text { text: modelData.title; font.family: "Segoe UI"; font.pixelSize: 17; font.weight: Font.Black; color: themeHub.phoneInk }
                                                                Text { text: modelData.desc; width: parent.width; elide: Text.ElideRight; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk }
                                                            }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setNotifyStyle(modelData.val) }
                                                        }
                                                    }
                                                }

                                                // Quiet Fullscreen toggle
                                                Rectangle {
                                                    width: parent.width; height: 58; radius: 16
                                                    color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Text { anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter; text: "Quiet Notifications in Fullscreen"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                                    Rectangle {
                                                        anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                                        width: 78; height: 34; radius: 17
                                                        color: themeHub.notifyQuietFullscreen ? themeHub.accentA : "#CBD5E1"
                                                        border.width: 2.5; border.color: "#1A1B2E"
                                                        Text { anchors.centerIn: parent; text: themeHub.notifyQuietFullscreen ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                                    }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setNotifyQuietFullscreen(!themeHub.notifyQuietFullscreen) }
                                                }

                                                // Test notification button
                                                Rectangle {
                                                    width: parent.width; height: 52; radius: 16
                                                    color: testNotifMa.containsMouse ? themeHub.accentB : themeHub.accentA
                                                    border.width: 3; border.color: "#1A1B2E"
                                                    Text { anchors.centerIn: parent; text: "🔔 SEND TEST NOTIFICATION"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: "#1A1B2E" }
                                                    MouseArea {
                                                        id: testNotifMa
                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: NotificationService.emitTestNotification()
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Right column: OSD, Phone 2.5D & Quick Hardware
                                    Rectangle {
                                        width: (parent.width - 24) * 0.5; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: quickRightFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: quickRightCol.implicitHeight
                                            Column {
                                                id: quickRightCol
                                                width: quickRightFlick.width; spacing: 14
                                                Text { text: "CHASSIS, OSD & QUICK TOGGLES"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }

                                                Repeater {
                                                    model: [
                                                        { label: "Dark Surface (Night Mode)", sub: "Dim QuickPanel phone & Settings cards for low-light use", val: themeHub.phoneDarkMode, act: "phoneDark" },
                                                        { label: "2.5D Tilted Phone Chassis", sub: "Extruded metallic depth walls & 3D flip", val: themeHub.phoneMode, act: "phone" },
                                                        { label: "SekaiPop On-Screen Display (OSD)", sub: "Show pill HUD on Volume / Brightness / Dark Mode", val: themeHub.osdEnabled, act: "osd" },
                                                        { label: "System Dark Mode", sub: "Toggle Windows dark/light app theme", val: SystemControl.darkMode, act: "dark" },
                                                        { label: "Master Audio Mute", sub: "Current volume: " + AudioService.masterVolume + "%", val: AudioService.masterMuted, act: "mute" }
                                                    ]
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width; height: 78; radius: 16
                                                        color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Column {
                                                            anchors.left: parent.left; anchors.leftMargin: 16; anchors.right: swBadge.left; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 3
                                                            Text { text: modelData.label; font.family: "Segoe UI"; font.pixelSize: 17; font.weight: Font.Black; color: themeHub.phoneInk }
                                                            Text { text: modelData.sub; width: parent.width; elide: Text.ElideRight; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk }
                                                        }
                                                        Rectangle {
                                                            id: swBadge
                                                            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                                            width: 78; height: 34; radius: 17
                                                            color: modelData.val ? themeHub.accentA : "#CBD5E1"
                                                            border.width: 2.5; border.color: "#1A1B2E"
                                                            Text { anchors.centerIn: parent; text: modelData.val ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                                        }
                                                        MouseArea {
                                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                if (modelData.act === "phoneDark") themeHub.setPhoneDarkMode(!themeHub.phoneDarkMode)
                                                                else if (modelData.act === "phone") themeHub.setPhoneMode(!themeHub.phoneMode)
                                                                else if (modelData.act === "osd") themeHub.setOsdEnabled(!themeHub.osdEnabled)
                                                                else if (modelData.act === "dark") SystemControl.toggleDarkMode()
                                                                else if (modelData.act === "mute") AudioService.toggleMasterMute()
                                                            }
                                                        }
                                                    }
                                                }

                                                // Mic Mute quick pill
                                                Rectangle {
                                                    visible: AudioService.micSupported
                                                    width: parent.width; height: 56; radius: 16
                                                    color: AudioService.micMuted ? "#FFE4E6" : "#ECFDF5"
                                                    border.width: 2.5; border.color: "#1A1B2E"
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: AudioService.micMuted ? "🎙 MICROPHONE MUTED (CLICK TO UNMUTE)" : "🎙 MICROPHONE ACTIVE (" + AudioService.micVolume + "%)"
                                                        font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E"
                                                    }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: AudioService.toggleMicMute() }
                                                }
                                            }
                                        }
                                    }
                                }

                                // ==== SUBPAGE 02: GENERAL ====
                                Row {
                                    visible: themeHub.settingsSection === "general"
                                    anchors.fill: parent
                                    spacing: 24

                                    // Left: Theme Bands & Wallpaper Match
                                    Rectangle {
                                        width: (parent.width - 24) * 0.5; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: genLeftFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: genLeftCol.implicitHeight
                                            Column {
                                                id: genLeftCol
                                                width: genLeftFlick.width; spacing: 14
                                                Text { text: "UNIT BAND PALETTES"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }
                                                Grid {
                                                    columns: 2; columnSpacing: 12; rowSpacing: 12; width: parent.width
                                                    Repeater {
                                                        model: themeHub.bands
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: !themeHub.useCustomPalette && themeHub.bandId === modelData.id
                                                            width: (parent.width - 12) * 0.5; height: 78; radius: 16
                                                            color: sel ? (themeHub.phoneDarkMode ? "#172E33" : "#F0FDFA") : themeHub.phoneSubBg
                                                            border.width: sel ? 3.5 : 2; border.color: sel ? modelData.A : themeHub.phoneBorder
                                                            Row {
                                                                anchors.fill: parent; anchors.margins: 12; spacing: 12
                                                                Rectangle {
                                                                    width: 46; height: 46; radius: 14; anchors.verticalCenter: parent.verticalCenter
                                                                    gradient: Gradient {
                                                                        GradientStop { position: 0.0; color: modelData.B }
                                                                        GradientStop { position: 1.0; color: modelData.A }
                                                                    }
                                                                    border.width: 2.5; border.color: "#1A1B2E"
                                                                }
                                                                Column {
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    width: parent.width - 58
                                                                    spacing: 2
                                                                    Text { text: modelData.shortName; font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Black; color: modelData.A }
                                                                    Text { width: parent.width; elide: Text.ElideRight; text: modelData.name; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                                                }
                                                            }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setBand(modelData.id) }
                                                        }
                                                    }
                                                }

                                                // Wallpaper Match button
                                                Rectangle {
                                                    width: parent.width; height: 64; radius: 16
                                                    color: themeHub.useCustomPalette ? (themeHub.phoneDarkMode ? "#132E36" : "#ECFEFF") : themeHub.phoneSubBg
                                                    border.width: themeHub.useCustomPalette ? 3.5 : 2.5; border.color: themeHub.useCustomPalette ? themeHub.accentA : themeHub.phoneBorder
                                                    Row {
                                                        anchors.centerIn: parent; spacing: 10
                                                        Text { text: "🎨"; font.pixelSize: 22 }
                                                        Text {
                                                            text: themeHub.useCustomPalette ? "WALLPAPER MATCH ACTIVE (RE-EXTRACT)" : "MATCH PALETTE TO CURRENT WALLPAPER"
                                                            font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk
                                                        }
                                                    }
                                                    MouseArea {
                                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            const pal = WallpaperService.extractCurrentPalette()
                                                            if (pal && pal.accentA)
                                                                themeHub.applyWallpaperPalette(pal)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Right: Clock & Weather Settings
                                    Rectangle {
                                        width: (parent.width - 24) * 0.5; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: genRightFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: genRightCol.implicitHeight
                                            Column {
                                                id: genRightCol
                                                width: genRightFlick.width; spacing: 14
                                                Text { text: "CLOCK & WEATHER"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }

                                                // Weather City input
                                                Row {
                                                    width: parent.width; spacing: 10
                                                    Rectangle {
                                                        width: parent.width - 216; height: 50; radius: 14
                                                        color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        clip: true
                                                        TextInput {
                                                            id: landCityInput
                                                            anchors.fill: parent; anchors.margins: 12
                                                            verticalAlignment: Text.AlignVCenter
                                                            clip: true
                                                            selectByMouse: true
                                                            text: WeatherService.city
                                                            font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Bold; color: themeHub.phoneInk
                                                            onAccepted: WeatherService.setCity(text.trim())
                                                            Keys.onEscapePressed: event => {
                                                                qpKeyCatcher.forceActiveFocus()
                                                                event.accepted = true
                                                            }
                                                            Connections {
                                                                target: WeatherService
                                                                function onWeatherChanged() {
                                                                    if (!landCityInput.activeFocus)
                                                                        landCityInput.text = WeatherService.city
                                                                }
                                                            }
                                                        }
                                                    }
                                                    Rectangle {
                                                        width: 98; height: 50; radius: 14; color: themeHub.accentA; border.width: 2.5; border.color: "#1A1B2E"
                                                        Text { anchors.centerIn: parent; text: "APPLY"; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E" }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: WeatherService.setCity(landCityInput.text.trim()) }
                                                    }
                                                    Rectangle {
                                                        width: 98; height: 50; radius: 14; color: themeHub.phonePillBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Text { anchors.centerIn: parent; text: "↻ SYNC"; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: WeatherService.refresh() }
                                                    }
                                                }

                                                // Weather Unit + Style pills
                                                Row {
                                                    width: parent.width; spacing: 10
                                                    Repeater {
                                                        model: [{ l: "°C", v: "C" }, { l: "°F", v: "F" }]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.weatherUnit === modelData.v
                                                            width: 74; height: 44; radius: 12
                                                            color: sel ? themeHub.accentA : themeHub.phonePillBg
                                                            border.width: 2.5; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWeatherUnit(modelData.v) }
                                                        }
                                                    }
                                                    Item { width: 8; height: 1 }
                                                    Repeater {
                                                        model: [{ l: "CARD", v: "card" }, { l: "COMPACT", v: "compact" }]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.weatherStyle === modelData.v
                                                            width: 120; height: 44; radius: 12
                                                            color: sel ? themeHub.accentB : themeHub.phonePillBg
                                                            border.width: 2.5; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setWeatherStyle(modelData.v) }
                                                        }
                                                    }
                                                }

                                                // Clock style pills (0=KEYS, 1=TOWER, 2=STICKER, 3=STACK)
                                                Row {
                                                    width: parent.width; spacing: 10
                                                    Repeater {
                                                        model: [{ l: "KEYS", v: 0 }, { l: "TOWER", v: 1 }, { l: "STICKER", v: 2 }, { l: "STACK", v: 3 }]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.clockStyle === modelData.v
                                                            width: (parent.width - 30) / 4; height: 46; radius: 12
                                                            color: sel ? themeHub.accentA : themeHub.phonePillBg
                                                            border.width: 2.5; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setClockStyle(modelData.v) }
                                                        }
                                                    }
                                                }

                                                // Clock toggles
                                                Repeater {
                                                    model: [
                                                        { l: "24-Hour Clock Format", val: themeHub.clock24h, k: "24h" },
                                                        { l: "Show Seconds on Clock Widget", val: themeHub.clockSeconds, k: "sec" },
                                                        { l: "Show Date on Clock Widget", val: themeHub.clockShowDate, k: "date" }
                                                    ]
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width; height: 54; radius: 14
                                                        color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Text { anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        Rectangle {
                                                            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                                            width: 74; height: 32; radius: 16
                                                            color: modelData.val ? themeHub.accentA : "#CBD5E1"; border.width: 2; border.color: "#1A1B2E"
                                                            Text { anchors.centerIn: parent; text: modelData.val ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                                        }
                                                        MouseArea {
                                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                if (modelData.k === "24h") themeHub.setClock24h(!themeHub.clock24h)
                                                                else if (modelData.k === "sec") themeHub.setClockSeconds(!themeHub.clockSeconds)
                                                                else if (modelData.k === "date") themeHub.setClockShowDate(!themeHub.clockShowDate)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // ==== SUBPAGE 03: BAR ====
                                Row {
                                    visible: themeHub.settingsSection === "bar"
                                    anchors.fill: parent
                                    spacing: 24

                                    Rectangle {
                                        width: (parent.width - 24) * 0.45; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: barLeftFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: barLeftCol.implicitHeight
                                            Column {
                                                id: barLeftCol
                                                width: barLeftFlick.width; spacing: 14
                                                Text { text: "BAR STYLE & EDGE"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }
                                                Row {
                                                    width: parent.width; spacing: 10
                                                    Repeater {
                                                        model: [
                                                            { id: "transparent", name: "Transparent", desc: "Floating islands" },
                                                            { id: "blur",        name: "Blur",        desc: "Frosted glass" },
                                                            { id: "straight",    name: "Straight",    desc: "Solid edge" }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.barStyle === modelData.id
                                                            width: (parent.width - 20) / 3; height: 84; radius: 16
                                                            color: sel ? "#FEF3C7" : themeHub.phoneSubBg
                                                            border.width: sel ? 3.5 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Column {
                                                                anchors.centerIn: parent; spacing: 4; width: parent.width - 14
                                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.name; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk; elide: Text.ElideRight; width: parent.width; horizontalAlignment: Text.AlignHCenter }
                                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.desc; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.DemiBold; color: sel ? "#475569" : themeHub.phoneMutedInk; elide: Text.ElideRight; width: parent.width; horizontalAlignment: Text.AlignHCenter }
                                                            }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setBarStyle(modelData.id) }
                                                        }
                                                    }
                                                }
                                                // 4-Edge Selector
                                                Column {
                                                    width: parent.width; spacing: 8
                                                    Text { text: "SCREEN EDGE"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneMutedInk }
                                                    Row {
                                                        width: parent.width; spacing: 8
                                                        Repeater {
                                                            model: [
                                                                { id: "top", l: "TOP" },
                                                                { id: "bottom", l: "BOT" },
                                                                { id: "left", l: "LEFT" },
                                                                { id: "right", l: "RIGHT" }
                                                            ]
                                                            delegate: Rectangle {
                                                                required property var modelData
                                                                readonly property bool sel: themeHub.barEdge === modelData.id
                                                                width: (parent.width - 24) / 4; height: 46; radius: 12
                                                                color: sel ? themeHub.accentA : themeHub.phonePillBg
                                                                border.width: sel ? 3 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                                Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setBarEdge(modelData.id) }
                                                            }
                                                        }
                                                    }
                                                }
                                                // Visibility Mode: Auto-Hide vs No-Hide
                                                Row {
                                                    width: parent.width; spacing: 10
                                                    Repeater {
                                                        model: [
                                                            { val: true,  l: "AUTO-HIDE", desc: "Hide on overlap" },
                                                            { val: false, l: "NO-HIDE",   desc: "Always reserve" }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.barAutoHide === modelData.val
                                                            width: (parent.width - 10) * 0.5; height: 68; radius: 16
                                                            color: sel ? themeHub.accentB : themeHub.phoneSubBg
                                                            border.width: sel ? 3 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Column {
                                                                anchors.centerIn: parent; spacing: 3
                                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.desc; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.DemiBold; color: sel ? "#334155" : themeHub.phoneMutedInk }
                                                            }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setBarAutoHide(modelData.val) }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: (parent.width - 24) * 0.55; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: barRightFlick
                                            anchors.fill: parent; anchors.margins: 20
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: barRightCol.implicitHeight
                                            Column {
                                                id: barRightCol
                                                width: barRightFlick.width; spacing: 10
                                                Text { text: "VISIBLE TOPBAR MODULES"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }
                                                Repeater {
                                                    model: [
                                                        { label: "Active App Badge & Window Title", val: themeHub.barShowActiveWindow, k: "win" },
                                                        { label: "SekaiPop Media Pill",             val: themeHub.barShowMedia,        k: "media" },
                                                        { label: "CPU / GPU / RAM Telemetry Pills", val: themeHub.barShowStats,        k: "stats" },
                                                        { label: "System Tray Pill",                val: themeHub.barShowTray,         k: "tray" },
                                                        { label: "Weather Temperature Pill",        val: themeHub.barShowWeather,      k: "weather" },
                                                        { label: "Date & Clock Pill",               val: themeHub.barShowClock,        k: "clock" },
                                                        { label: "Laptop Battery Indicator Pill",   val: themeHub.barShowBattery,      k: "bat" }
                                                    ]
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width; height: 50; radius: 14
                                                        color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Text { anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter; text: modelData.label; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        Rectangle {
                                                            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                                            width: 72; height: 30; radius: 15
                                                            color: modelData.val ? themeHub.accentA : "#CBD5E1"; border.width: 2.5; border.color: "#1A1B2E"
                                                            Text { anchors.centerIn: parent; text: modelData.val ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                        }
                                                        MouseArea {
                                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                if (modelData.k === "win") themeHub.setBarShowActiveWindow(!themeHub.barShowActiveWindow)
                                                                else if (modelData.k === "media") themeHub.setBarShowMedia(!themeHub.barShowMedia)
                                                                else if (modelData.k === "stats") themeHub.setBarShowStats(!themeHub.barShowStats)
                                                                else if (modelData.k === "tray") themeHub.setBarShowTray(!themeHub.barShowTray)
                                                                else if (modelData.k === "weather") themeHub.setBarShowWeather(!themeHub.barShowWeather)
                                                                else if (modelData.k === "clock") themeHub.setBarShowClock(!themeHub.barShowClock)
                                                                else if (modelData.k === "bat") themeHub.setBarShowBattery(!themeHub.barShowBattery)
                                                            }
                                                        }
                                                    }
                                                }
                                                Rectangle {
                                                    width: parent.width; height: 58; radius: 14
                                                    color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Text {
                                                        anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                                        text: "MEDIA PILL VISUALIZER"
                                                        font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk
                                                    }
                                                    Row {
                                                        anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                                        spacing: 8
                                                        Repeater {
                                                            model: [
                                                                { id: "bars", l: "BARS" },
                                                                { id: "wave", l: "WAVE" },
                                                                { id: "off",  l: "OFF" }
                                                            ]
                                                            delegate: Rectangle {
                                                                required property var modelData
                                                                readonly property bool sel: themeHub.barMediaVizStyle === modelData.id
                                                                width: 74; height: 34; radius: 10
                                                                color: sel ? themeHub.accentB : themeHub.phoneCardBg
                                                                border.width: sel ? 2.5 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                                Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                                MouseArea {
                                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                                    onClicked: themeHub.setBarMediaVizStyle(modelData.id)
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // ==== SUBPAGE 04: DESKTOP ====
                                Row {
                                    visible: themeHub.settingsSection === "desktop"
                                    anchors.fill: parent
                                    spacing: 24

                                    // Left: Dock customization
                                    Rectangle {
                                        width: (parent.width - 24) * 0.5; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: dskLeftFlick
                                            anchors.fill: parent; anchors.margins: 20
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: dskLeftCol.implicitHeight
                                            Column {
                                                id: dskLeftCol
                                                width: dskLeftFlick.width; spacing: 10
                                                Text { text: "DOCK STYLE & KEYS"; font.family: "Segoe UI"; font.pixelSize: 20; font.weight: Font.Black; color: themeHub.phoneInk }

                                                // Dock Outer Pill Style
                                                Row {
                                                    width: parent.width; spacing: 8
                                                    Repeater {
                                                        model: [{ id: "float", l: "FLOAT" }, { id: "capsule", l: "CAPSULE" }, { id: "transparent", l: "CLEAR" }]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.dockStyle === modelData.id
                                                            width: (parent.width - 16) / 3; height: 42; radius: 12
                                                            color: sel ? themeHub.accentA : themeHub.phonePillBg
                                                            border.width: 2.5; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setDockStyle(modelData.id) }
                                                        }
                                                    }
                                                }

                                                // Icon Roundness (Auto vs Round Circle vs Square Keycap)
                                                Row {
                                                    width: parent.width; spacing: 8
                                                    Repeater {
                                                        model: [
                                                            { id: "auto",   l: "ICONS: AUTO" },
                                                            { id: "circle", l: "ROUND ICONS" },
                                                            { id: "square", l: "SQUARE KEYCAPS" }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.dockIconShape === modelData.id
                                                            width: (parent.width - 16) / 3; height: 40; radius: 11
                                                            color: sel ? themeHub.accentB : themeHub.phonePillBg
                                                            border.width: sel ? 2.5 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setDockIconShape(modelData.id) }
                                                        }
                                                    }
                                                }

                                                // Dock Tile Size stepped slider (40..64)
                                                Rectangle {
                                                    width: parent.width; height: 52; radius: 14
                                                    color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Row {
                                                        anchors.fill: parent; anchors.margins: 9; spacing: 6
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "SIZE (" + themeHub.dockTileSize + "px)"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk; width: 116 }
                                                        Repeater {
                                                            model: [40, 44, 48, 52, 56, 60, 64]
                                                            delegate: Rectangle {
                                                                required property int modelData
                                                                readonly property bool sel: themeHub.dockTileSize === modelData
                                                                width: 50; height: 34; radius: 9; anchors.verticalCenter: parent.verticalCenter
                                                                color: sel ? themeHub.accentB : themeHub.phoneCardBg
                                                                border.width: 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                                Text { anchors.centerIn: parent; text: String(modelData); font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setDockTileSize(modelData) }
                                                            }
                                                        }
                                                    }
                                                }

                                                // Magnification toggle
                                                Rectangle {
                                                    width: parent.width; height: 46; radius: 13; color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Text { anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter; text: "Dock Hover Magnification"; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk }
                                                    Rectangle {
                                                        anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                                        width: 68; height: 28; radius: 14; color: themeHub.dockMagnify ? themeHub.accentA : "#CBD5E1"; border.width: 2; border.color: "#1A1B2E"
                                                        Text { anchors.centerIn: parent; text: themeHub.dockMagnify ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                    }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setDockMagnify(!themeHub.dockMagnify) }
                                                }

                                                // Dock Edge & Visibility Mode
                                                Row {
                                                    width: parent.width; spacing: 8
                                                    Repeater {
                                                        model: [
                                                            { id: "bottom", l: "BOT" },
                                                            { id: "top",    l: "TOP" },
                                                            { id: "left",   l: "LEFT" },
                                                            { id: "right",  l: "RIGHT" }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.dockEdge === modelData.id
                                                            width: (parent.width - 24) / 4; height: 40; radius: 10
                                                            color: sel ? themeHub.accentA : themeHub.phonePillBg
                                                            border.width: sel ? 2.5 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setDockEdge(modelData.id) }
                                                        }
                                                    }
                                                }

                                                // Auto-hide vs No-hide toggle
                                                Row {
                                                    width: parent.width; spacing: 8
                                                    Repeater {
                                                        model: [
                                                            { val: true,  l: "AUTO-HIDE (Dodge)" },
                                                            { val: false, l: "NO-HIDE (Pinned)" }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: themeHub.dockAutoHide === modelData.val
                                                            width: (parent.width - 8) * 0.5; height: 42; radius: 12
                                                            color: sel ? themeHub.accentB : themeHub.phoneSubBg
                                                            border.width: sel ? 2.5 : 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.setDockAutoHide(modelData.val) }
                                                        }
                                                    }
                                                }

                                                // Dock utility keycap pills (4x2 grid)
                                                Grid {
                                                    columns: 4; columnSpacing: 8; rowSpacing: 8; width: parent.width
                                                    Repeater {
                                                        model: [
                                                            { l: "Finder",    val: themeHub.dockShowFinder,    k: "finder" },
                                                            { l: "Clip",      val: themeHub.dockShowClipboard, k: "clip" },
                                                            { l: "Shelf",     val: themeHub.dockShowDropShelf, k: "drop" },
                                                            { l: "Timer",     val: themeHub.dockShowTimer,     k: "timer" },
                                                            { l: "Files",     val: themeHub.dockShowFiles,     k: "files" },
                                                            { l: "Trash",     val: themeHub.dockShowTrash,     k: "trash" },
                                                            { l: "Media",     val: themeHub.dockShowMedia,     k: "media" }
                                                        ]
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            width: (parent.width - 24) / 4; height: 46; radius: 12
                                                            color: modelData.val ? (themeHub.phoneDarkMode ? "#17302A" : "#ECFDF5") : themeHub.phoneSubBg
                                                            border.width: 2.5; border.color: themeHub.phoneBorder
                                                            Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; text: modelData.l; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneInk }
                                                            Rectangle {
                                                                anchors.right: parent.right; anchors.rightMargin: 7; anchors.verticalCenter: parent.verticalCenter
                                                                width: 44; height: 24; radius: 12; color: modelData.val ? themeHub.accentA : "#CBD5E1"; border.width: 2; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: modelData.val ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                            }
                                                            MouseArea {
                                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                                onClicked: {
                                                                    if (modelData.k === "finder") themeHub.setDockShowFinder(!themeHub.dockShowFinder)
                                                                    else if (modelData.k === "clip") themeHub.setDockShowClipboard(!themeHub.dockShowClipboard)
                                                                    else if (modelData.k === "drop") themeHub.setDockShowDropShelf(!themeHub.dockShowDropShelf)
                                                                    else if (modelData.k === "timer") themeHub.setDockShowTimer(!themeHub.dockShowTimer)
                                                                    else if (modelData.k === "files") themeHub.setDockShowFiles(!themeHub.dockShowFiles)
                                                                    else if (modelData.k === "trash") themeHub.setDockShowTrash(!themeHub.dockShowTrash)
                                                                    else if (modelData.k === "media") themeHub.setDockShowMedia(!themeHub.dockShowMedia)
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Right: Widgets, Visualizer & Wallpaper Selector
                                    Rectangle {
                                        width: (parent.width - 24) * 0.5; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: dskRightFlick
                                            anchors.fill: parent; anchors.margins: 20
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: dskRightCol.implicitHeight
                                            Column {
                                                id: dskRightCol
                                                width: dskRightFlick.width; spacing: 12
                                                Text { text: "WIDGETS, VISUALIZER & WALLPAPER"; font.family: "Segoe UI"; font.pixelSize: 20; font.weight: Font.Black; color: themeHub.phoneInk }

                                                // Desktop widgets grid (all 7 SekaiDesk widgets + "+ Photo" Polaroid adder)
                                                Grid {
                                                    columns: 4; columnSpacing: 8; rowSpacing: 8; width: parent.width
                                                    Repeater {
                                                        model: [
                                                            { k: "clock",    l: "Clock" },
                                                            { k: "weather",  l: "Weather" },
                                                            { k: "calendar", l: "Calendar" },
                                                            { k: "profile",  l: "Profile" },
                                                            { k: "todo",     l: "To-Do" },
                                                            { k: "notes",    l: "Notes" },
                                                            { k: "lyrics",   l: "Lyrics" },
                                                            { k: "__photo",  l: "+ Photo" }
                                                        ]
                                                        delegate: Rectangle {
                                                            id: widChip
                                                            required property var modelData
                                                            readonly property bool isPhoto: modelData.k === "__photo"
                                                            readonly property bool on: !isPhoto && themeHub.widgetVisible(modelData.k)
                                                            width: (parent.width - 24) / 4; height: 46; radius: 13
                                                            color: isPhoto ? "#FFF1F2" : (widChip.on ? themeHub.accentA : themeHub.phonePillBg)
                                                            border.width: 2.5; border.color: (isPhoto || widChip.on) ? "#1A1B2E" : themeHub.phoneBorder
                                                            Text { anchors.centerIn: parent; text: isPhoto ? modelData.l : ((widChip.on ? "✓ " : "") + modelData.l); font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: (isPhoto || widChip.on) ? "#1A1B2E" : themeHub.phoneInk }
                                                            MouseArea {
                                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                                onClicked: {
                                                                    if (widChip.isPhoto) {
                                                                        quickPanelWindow.pickingFile = true
                                                                        const p = SystemControl.pickImageFile("Add Polaroid Photo Frame")
                                                                        quickPanelWindow.pickingFile = false
                                                                        if (p && p.length > 0)
                                                                            themeHub.addImageFrame(p)
                                                                    } else {
                                                                        themeHub.setWidgetVisible(modelData.k, !widChip.on)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                // Visualizer toggle + all 11 styles (GPU shaders + Canvas)
                                                Rectangle {
                                                    width: parent.width; height: visInnerCol.implicitHeight + 24; radius: 16; color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Column {
                                                        id: visInnerCol
                                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                                        spacing: 10
                                                        Item {
                                                            width: parent.width; height: 30
                                                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "AUDIO VISUALIZER"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk }
                                                            Rectangle {
                                                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                                                width: 74; height: 30; radius: 15; color: VisualizerService.enabled ? themeHub.accentA : "#CBD5E1"; border.width: 2; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: VisualizerService.enabled ? "ON" : "OFF"; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: VisualizerService.enabled = !VisualizerService.enabled }
                                                            }
                                                        }
                                                        Grid {
                                                            width: parent.width; columns: 4; columnSpacing: 6; rowSpacing: 6
                                                            Repeater {
                                                                model: ["tide", "ribbons", "aurora", "pulse", "scope", "mirror", "ring", "dots", "sekai", "bars", "wave"]
                                                                delegate: Rectangle {
                                                                    required property string modelData
                                                                    readonly property bool sel: VisualizerService.style === modelData
                                                                    width: (parent.width - 18) / 4; height: 40; radius: 10
                                                                    color: sel ? themeHub.accentB : themeHub.phoneCardBg
                                                                    border.width: 2; border.color: sel ? "#1A1B2E" : themeHub.phoneBorder
                                                                    Text { anchors.centerIn: parent; text: modelData.toUpperCase(); font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: sel ? "#1A1B2E" : themeHub.phoneInk }
                                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: VisualizerService.style = modelData }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                // Integrated Landscape Phone Wallpaper Gallery button
                                                Rectangle {
                                                    width: parent.width; height: 52; radius: 16
                                                    color: openWallMa.containsMouse ? themeHub.accentB : themeHub.accentA
                                                    border.width: 3; border.color: "#1A1B2E"
                                                    Text { anchors.centerIn: parent; text: "🖼 OPEN WALLPAPER GALLERY"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: "#1A1B2E" }
                                                    MouseArea {
                                                        id: openWallMa
                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: themeHub.openWallpapers()
                                                    }
                                                }
                                                Row {
                                                    width: parent.width; spacing: 12
                                                    Rectangle {
                                                        width: (parent.width - 12) * 0.5; height: 50; radius: 14; color: themeHub.phonePillBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Text { anchors.centerIn: parent; text: "🎲 RANDOM WALLPAPER"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: WallpaperService.nextRandomWallpaper() }
                                                    }
                                                    Rectangle {
                                                        width: (parent.width - 12) * 0.5; height: 50; radius: 14; color: themeHub.phonePillBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Text { anchors.centerIn: parent; text: "🖼 PICK PROFILE AVATAR"; font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        MouseArea {
                                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                quickPanelWindow.pickingFile = true
                                                                const p = SystemControl.pickImageFile("Choose Profile Avatar Image")
                                                                quickPanelWindow.pickingFile = false
                                                                if (p && p.length > 0) themeHub.setProfileAvatar(p)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // ==== SUBPAGE 05: HOTKEYS & SYSTEM ====
                                Row {
                                    visible: themeHub.settingsSection === "system"
                                    anchors.fill: parent
                                    spacing: 24

                                    Rectangle {
                                        width: (parent.width - 24) * 0.52; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: sysLeftFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true; boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width; contentHeight: sysLeftCol.implicitHeight
                                            Column {
                                                id: sysLeftCol
                                                width: sysLeftFlick.width; spacing: 10
                                                Text { text: "GLOBAL SHORTCUTS"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }
                                                Repeater {
                                                    model: [
                                                        { keys: "ALT + SPACE",     desc: "Open Spotlight Search & PowerTools" },
                                                        { keys: "CTRL + ALT + V",  desc: "Open Clipboard History & Snippets" },
                                                        { keys: "CTRL + ALT + A",  desc: "Toggle 2.5D QuickPanel Smartphone" },
                                                        { keys: "CTRL + ALT + T",  desc: "Temporarily Show / Hide Windows Taskbar" },
                                                        { keys: "CTRL + ALT + G",  desc: "Toggle Game Mode (Instant Hibernate)" },
                                                        { keys: "TOPBAR BAND",     desc: "Enter Edit Desktop Mode (Scrapbook)" },
                                                        { keys: "ESC",             desc: "Back out of active overlay / modal" }
                                                    ]
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width; height: 54; radius: 14; color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                        Row {
                                                            anchors.fill: parent; anchors.margins: 10; spacing: 12
                                                            Rectangle {
                                                                width: 170; height: 34; radius: 9; anchors.verticalCenter: parent.verticalCenter
                                                                color: themeHub.accentA; border.width: 2; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: modelData.keys; font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                                                            }
                                                            Text {
                                                                width: parent.width - 182; elide: Text.ElideRight
                                                                anchors.verticalCenter: parent.verticalCenter; text: modelData.desc
                                                                font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.DemiBold; color: themeHub.phoneInk
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: (parent.width - 24) * 0.48; height: parent.height
                                        radius: 24; color: themeHub.phoneCardBg; border.width: 3.5; border.color: themeHub.phoneBorder
                                        Flickable {
                                            id: rightActionsFlick
                                            anchors.fill: parent; anchors.margins: 22
                                            clip: true
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: width
                                            contentHeight: rightActionsCol.implicitHeight

                                            Column {
                                                id: rightActionsCol
                                                width: rightActionsFlick.width
                                                spacing: 12
                                                Text { text: "HARDWARE & ACTIONS"; font.family: "Segoe UI"; font.pixelSize: 21; font.weight: Font.Black; color: themeHub.phoneInk }
                                                Rectangle {
                                                    width: parent.width; height: 142; radius: 18; color: themeHub.phoneSubBg; border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Column {
                                                        anchors.fill: parent; anchors.margins: 15; spacing: 6
                                                        Text { width: parent.width; elide: Text.ElideRight; text: "Machine: " + (WindowTracker.machineName || "Windows PC") + "  ·  User: " + (WindowTracker.userName || "User"); font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk }
                                                        Text { width: parent.width; elide: Text.ElideRight; text: "Uptime: " + (WindowTracker.uptimeText || "--"); font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk }
                                                        Text { width: parent.width; elide: Text.ElideRight; text: "CPU: " + WindowTracker.cpuUsage + "% (" + (WindowTracker.cpuTemp >= 0 ? WindowTracker.cpuTemp + "°C" : "--") + ")  ·  RAM: " + WindowTracker.ramUsage + "%"; font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Bold; color: themeHub.phoneInk }
                                                        Text { width: parent.width; elide: Text.ElideRight; text: "Display: " + themeHub.screenW + "×" + themeHub.screenH + "  ·  " + themeHub.currentBand.name; font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Bold; color: themeHub.phoneInk }
                                                    }
                                                }
                                                Rectangle {
                                                    id: gmCard
                                                    width: parent.width
                                                    height: gmCol.implicitHeight + 24
                                                    radius: 16
                                                    color: GameModeService.active ? (themeHub.phoneDarkMode ? "#2E151B" : "#FFF1F2") : themeHub.phoneSubBg
                                                    border.width: 2.5; border.color: themeHub.phoneBorder

                                                    property bool runningPickerOpen: false
                                                    property var runningExes: []

                                                    Column {
                                                        id: gmCol
                                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                                        spacing: 10

                                                        // Header + Live Status Badge + Manual Toggle
                                                        Row {
                                                            width: gmCol.width; height: 38; spacing: 6
                                                            Column {
                                                                width: Math.max(80, gmCol.width - 148)
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                spacing: 1
                                                                Text {
                                                                    width: parent.width; elide: Text.ElideRight
                                                                    text: "GAME MODE & PERFORMANCE"
                                                                    font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk
                                                                }
                                                                Text {
                                                                    width: parent.width; elide: Text.ElideRight
                                                                    text: GameModeService.active
                                                                        ? ("ACTIVE · " + (GameModeService.activeGameExe || "Manual"))
                                                                        : (GameModeService.autoDetect ? "AUTO READY" : "STANDBY")
                                                                    font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold
                                                                    color: GameModeService.active ? "#FB7185" : (GameModeService.autoDetect ? (themeHub.phoneDarkMode ? "#34D399" : "#047857") : themeHub.phoneMutedInk)
                                                                }
                                                            }
                                                            Rectangle {
                                                                width: 142; height: 34; radius: 11
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                color: GameModeService.active
                                                                    ? (gmToggleMa.containsMouse ? "#FECDD3" : "#FFE4E6")
                                                                    : (gmToggleMa.containsMouse ? themeHub.accentA : themeHub.accentB)
                                                                border.width: 2; border.color: "#1A1B2E"
                                                                Text {
                                                                    anchors.centerIn: parent
                                                                    text: GameModeService.active ? "RESUME" : "SLEEP (C+A+G)"
                                                                    font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                                                                }
                                                                MouseArea {
                                                                    id: gmToggleMa
                                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                    onClicked: {
                                                                        if (!GameModeService.active) {
                                                                            themeHub.settingsOpen = false
                                                                            topBarWindow.quickPanelOpen = false
                                                                        }
                                                                        GameModeService.toggleManual()
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        // Auto-Detect Toggle
                                                        Rectangle {
                                                            width: gmCol.width; height: 44; radius: 12
                                                            color: GameModeService.autoDetect ? (themeHub.phoneDarkMode ? "#17302A" : "#ECFDF5") : themeHub.phoneCardBg
                                                            border.width: 2; border.color: themeHub.phoneBorder
                                                            Row {
                                                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                                                Text {
                                                                    width: Math.max(80, gmCol.width - 92)
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    text: "AUTO-DETECT GAMES"
                                                                    font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Bold; color: themeHub.phoneInk
                                                                }
                                                                Rectangle {
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    width: 60; height: 26; radius: 13
                                                                    color: GameModeService.autoDetect ? themeHub.accentB : "#E2E8F0"
                                                                    border.width: 1.5; border.color: "#1A1B2E"
                                                                    Text {
                                                                        anchors.centerIn: parent
                                                                        text: GameModeService.autoDetect ? "ON" : "OFF"
                                                                        font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                                                                    }
                                                                }
                                                            }
                                                            MouseArea {
                                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                                onClicked: GameModeService.autoDetect = !GameModeService.autoDetect
                                                            }
                                                        }

                                                        // Mode Selector (Hibernate vs Zero-Footprint)
                                                        Column {
                                                            width: gmCol.width; spacing: 6
                                                            Row {
                                                                width: gmCol.width; height: 38; spacing: 6
                                                                Repeater {
                                                                    model: [
                                                                        { id: "hibernate", label: "HIBERNATE (INSTANT)" },
                                                                        { id: "zero",      label: "ZERO-FOOTPRINT (~2MB)" }
                                                                    ]
                                                                    delegate: Rectangle {
                                                                        required property var modelData
                                                                        width: (gmCol.width - 6) / 2; height: 38; radius: 10
                                                                        color: GameModeService.mode === modelData.id
                                                                            ? themeHub.accentB
                                                                            : (gmModeMa.containsMouse ? "#CBD5E1" : "#E2E8F0")
                                                                        border.width: 2; border.color: "#1A1B2E"
                                                                        Text {
                                                                            anchors.centerIn: parent
                                                                            text: modelData.label
                                                                            font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                                                                        }
                                                                        MouseArea {
                                                                            id: gmModeMa
                                                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                            onClicked: GameModeService.mode = modelData.id
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                            Text {
                                                                width: gmCol.width; wrapMode: Text.WordWrap
                                                                text: GameModeService.mode === "zero"
                                                                    ? "Exits GUI into pure-Win32 --wait-game (~2MB, 0% CPU/VRAM) until game closes."
                                                                    : "Hides all overlays, pauses workers, sets Win11 EcoQoS & trims RAM/VRAM instantly."
                                                                font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                            }
                                                        }

                                                        // Restore Taskbar in Zero Mode
                                                        Rectangle {
                                                            visible: GameModeService.mode === "zero"
                                                            width: gmCol.width; height: 42; radius: 12
                                                            color: GameModeService.restoreTaskbarInZero ? (themeHub.phoneDarkMode ? "#17253B" : "#EFF6FF") : themeHub.phoneCardBg
                                                            border.width: 2; border.color: themeHub.phoneBorder
                                                            Row {
                                                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                                                Text {
                                                                    width: Math.max(80, gmCol.width - 92)
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    text: "RESTORE TASKBAR IN ZERO MODE"
                                                                    font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.Bold; color: themeHub.phoneInk
                                                                }
                                                                Rectangle {
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    width: 60; height: 26; radius: 13
                                                                    color: GameModeService.restoreTaskbarInZero ? themeHub.accentB : "#E2E8F0"
                                                                    border.width: 1.5; border.color: "#1A1B2E"
                                                                    Text {
                                                                        anchors.centerIn: parent
                                                                        text: GameModeService.restoreTaskbarInZero ? "ON" : "OFF"
                                                                        font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                                                                    }
                                                                }
                                                            }
                                                            MouseArea {
                                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                                onClicked: GameModeService.restoreTaskbarInZero = !GameModeService.restoreTaskbarInZero
                                                            }
                                                        }

                                                        // Game List Header + Actions
                                                        Row {
                                                            width: gmCol.width; height: 30; spacing: 6
                                                            Text {
                                                                width: Math.max(60, gmCol.width - 250)
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "GAME LIST (" + GameModeService.gameList.length + ")"
                                                                font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneInk
                                                            }
                                                            Rectangle {
                                                                width: 96; height: 28; radius: 8
                                                                color: gmCard.runningPickerOpen ? themeHub.accentA : (gmRunBtnMa.containsMouse ? "#DBEAFE" : "#E0F2FE")
                                                                border.width: 1.5; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: "+ RUNNING"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                MouseArea {
                                                                    id: gmRunBtnMa
                                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                    onClicked: {
                                                                        gmCard.runningPickerOpen = !gmCard.runningPickerOpen
                                                                        if (gmCard.runningPickerOpen)
                                                                            gmCard.runningExes = WindowTracker.runningExeNames()
                                                                    }
                                                                }
                                                            }
                                                            Rectangle {
                                                                width: 68; height: 28; radius: 8
                                                                color: gmExeBtnMa.containsMouse ? "#FEF08A" : "#FEF9C3"
                                                                border.width: 1.5; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: "+ .EXE"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                MouseArea {
                                                                    id: gmExeBtnMa
                                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                    onClicked: {
                                                                        quickPanelWindow.pickingFile = true
                                                                        const picked = SystemControl.pickExecutableFile("Select Game Executable")
                                                                        quickPanelWindow.pickingFile = false
                                                                        if (picked !== "")
                                                                            GameModeService.addGameExe(picked)
                                                                        quickPanelWindow.focusActivate()
                                                                    }
                                                                }
                                                            }
                                                            Rectangle {
                                                                width: 68; height: 28; radius: 8
                                                                color: gmResetBtnMa.containsMouse ? "#FCA5A5" : "#FEE2E2"
                                                                border.width: 1.5; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: "RESET"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                MouseArea {
                                                                    id: gmResetBtnMa
                                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                    onClicked: GameModeService.resetDefaultLists()
                                                                }
                                                            }
                                                        }

                                                        // Expandable Running Apps Picker
                                                        Rectangle {
                                                            visible: gmCard.runningPickerOpen
                                                            width: gmCol.width
                                                            height: runningFlow.implicitHeight + 14
                                                            radius: 12; color: "#EFF6FF"; border.width: 1.5; border.color: "#1A1B2E"
                                                            Flow {
                                                                id: runningFlow
                                                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 7 }
                                                                spacing: 6
                                                                Text {
                                                                    visible: gmCard.runningExes.length === 0
                                                                    text: "No other app windows running."
                                                                    font.family: "Segoe UI"; font.pixelSize: 13; color: "#64748B"
                                                                }
                                                                Repeater {
                                                                    model: gmCard.runningExes
                                                                    delegate: Rectangle {
                                                                        required property var modelData
                                                                        readonly property bool alreadyAdded: GameModeService.gameList.indexOf(modelData.exe) >= 0
                                                                        width: runChipTxt.implicitWidth + 16; height: 28; radius: 8
                                                                        color: alreadyAdded ? "#DCFCE7" : (runChipMa.containsMouse ? themeHub.accentB : "#FFFFFF")
                                                                        border.width: 1.5; border.color: "#1A1B2E"
                                                                        Text {
                                                                            id: runChipTxt
                                                                            anchors.centerIn: parent
                                                                            text: (alreadyAdded ? "✓ " : "+ ") + modelData.exe
                                                                            font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: "#1A1B2E"
                                                                        }
                                                                        MouseArea {
                                                                            id: runChipMa
                                                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                            onClicked: GameModeService.addGameExe(modelData.exe)
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        // Game List Chips
                                                        Flow {
                                                            width: gmCol.width; spacing: 6
                                                            Repeater {
                                                                model: GameModeService.gameList
                                                                delegate: Rectangle {
                                                                    required property string modelData
                                                                    width: gChipTxt.implicitWidth + 16; height: 28; radius: 8
                                                                    color: gChipMa.containsMouse ? "#FFE4E6" : "#FFFFFF"
                                                                    border.width: 1.5; border.color: "#1A1B2E"
                                                                    Text {
                                                                        id: gChipTxt
                                                                        anchors.centerIn: parent
                                                                        text: modelData + " ×"
                                                                        font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: "#1A1B2E"
                                                                    }
                                                                    MouseArea {
                                                                        id: gChipMa
                                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: {
                                                                            const exe = modelData
                                                                            Qt.callLater(function() { GameModeService.removeGameExe(exe) })
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        // Exclude List Header + Chips
                                                        Row {
                                                            width: gmCol.width; height: 30; spacing: 6
                                                            Text {
                                                                width: Math.max(60, gmCol.width - 74)
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "EXCLUDE LIST (" + GameModeService.excludeList.length + ")"
                                                                font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneInk
                                                            }
                                                            Rectangle {
                                                                width: 68; height: 28; radius: 8
                                                                color: gmExclBtnMa.containsMouse ? "#E2E8F0" : "#FFFFFF"
                                                                border.width: 1.5; border.color: "#1A1B2E"
                                                                Text { anchors.centerIn: parent; text: "+ .EXE"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                MouseArea {
                                                                    id: gmExclBtnMa
                                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                    onClicked: {
                                                                        quickPanelWindow.pickingFile = true
                                                                        const picked = SystemControl.pickExecutableFile("Select App to Exclude")
                                                                        quickPanelWindow.pickingFile = false
                                                                        if (picked !== "")
                                                                            GameModeService.addExcludeExe(picked)
                                                                        quickPanelWindow.focusActivate()
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        Flow {
                                                            width: gmCol.width; spacing: 6
                                                            Repeater {
                                                                model: GameModeService.excludeList
                                                                delegate: Rectangle {
                                                                    required property string modelData
                                                                    width: exChipTxt.implicitWidth + 16; height: 28; radius: 8
                                                                    color: exChipMa.containsMouse ? "#FFE4E6" : "#E2E8F0"
                                                                    border.width: 1.5; border.color: "#1A1B2E"
                                                                    Text {
                                                                        id: exChipTxt
                                                                        anchors.centerIn: parent
                                                                        text: modelData + " ×"
                                                                        font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: "#334155"
                                                                    }
                                                                    MouseArea {
                                                                        id: exChipMa
                                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: {
                                                                            const exe = modelData
                                                                            Qt.callLater(function() { GameModeService.removeExcludeExe(exe) })
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        // RTSS Guard
                                                        Rectangle {
                                                            width: gmCol.width; height: 42; radius: 11
                                                            color: GameModeService.rtssExcluded
                                                                ? "#DCFCE7"
                                                                : (GameModeService.rtssDetected ? "#FEF3C7" : "#F1F5F9")
                                                            border.width: 1.5; border.color: "#1A1B2E"
                                                            Row {
                                                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 6
                                                                Text {
                                                                    width: Math.max(80, gmCol.width - (GameModeService.rtssDetected && !GameModeService.rtssExcluded ? 202 : 94))
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    elide: Text.ElideRight
                                                                    text: GameModeService.rtssExcluded
                                                                        ? "RTSS GUARD: Protected (SekaiDesk.exe.cfg)"
                                                                        : (GameModeService.rtssDetected ? "RTSS Detected — Hooking Active" : "RTSS Not Detected")
                                                                    font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: "#1A1B2E"
                                                                }
                                                                Rectangle {
                                                                    width: 72; height: 28; radius: 8; anchors.verticalCenter: parent.verticalCenter
                                                                    color: rtssRescanMa.containsMouse ? "#CBD5E1" : "#FFFFFF"
                                                                    border.width: 1.5; border.color: "#1A1B2E"
                                                                    Text { anchors.centerIn: parent; text: "RESCAN"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                    MouseArea {
                                                                        id: rtssRescanMa
                                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: GameModeService.refreshRtssStatus()
                                                                    }
                                                                }
                                                                Rectangle {
                                                                    visible: GameModeService.rtssDetected && !GameModeService.rtssExcluded
                                                                    width: 102; height: 28; radius: 8; anchors.verticalCenter: parent.verticalCenter
                                                                    color: rtssBlockMa.containsMouse ? "#FDE047" : themeHub.accentB
                                                                    border.width: 1.5; border.color: "#1A1B2E"
                                                                    Text { anchors.centerIn: parent; text: "BLOCK RTSS"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                    MouseArea {
                                                                        id: rtssBlockMa
                                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: GameModeService.applyRtssExclusion()
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        Text {
                                                            visible: GameModeService.lastStatus !== ""
                                                            width: gmCol.width; elide: Text.ElideRight
                                                            text: GameModeService.lastStatus
                                                            font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: "#0369A1"
                                                        }
                                                    }
                                                }
                                                Rectangle {
                                                    width: parent.width; height: 118; radius: 16
                                                    color: TaskbarManager.active ? (themeHub.phoneDarkMode ? "#17302A" : "#ECFDF5") : themeHub.phoneSubBg
                                                    border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Column {
                                                        anchors.fill: parent; anchors.margins: 12; spacing: 10
                                                        Row {
                                                            width: parent.width; height: 42; spacing: 8
                                                            Column {
                                                                width: parent.width - 116
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                spacing: 2
                                                                Row {
                                                                    spacing: 6
                                                                    Image { anchors.verticalCenter: parent.verticalCenter; width: 16; height: 16; source: "qrc:/qml/icons/monitor-dark.svg"; smooth: true }
                                                                    Text {
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        text: "HIDE WINDOWS TASKBAR"
                                                                        font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk
                                                                    }
                                                                }
                                                                Text {
                                                                    text: TaskbarManager.statusText
                                                                    font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                                    elide: Text.ElideRight; width: parent.width
                                                                }
                                                            }
                                                            Rectangle {
                                                                width: 108; height: 34; radius: 11
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                color: restoreTbMa.containsMouse ? "#FDE68A" : "#FEF3C7"
                                                                border.width: 2; border.color: "#1A1B2E"
                                                                Row {
                                                                    anchors.centerIn: parent; spacing: 5
                                                                    Image { anchors.verticalCenter: parent.verticalCenter; width: 14; height: 14; source: "qrc:/qml/icons/restart-dark.svg"; smooth: true }
                                                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "RESTORE"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                }
                                                                MouseArea { id: restoreTbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: TaskbarManager.restoreNow() }
                                                            }
                                                        }
                                                        Row {
                                                            width: parent.width; height: 38; spacing: 6
                                                            Repeater {
                                                                model: [
                                                                    { id: "primary", label: "PRIMARY ONLY" },
                                                                    { id: "all",     label: "ALL DISPLAYS" },
                                                                    { id: "off",     label: "OFF (SHOW)" }
                                                                ]
                                                                delegate: Rectangle {
                                                                    required property var modelData
                                                                    width: (parent.width - 12) / 3; height: 38; radius: 10
                                                                    color: themeHub.taskbarHideMode === modelData.id ? themeHub.accentB : (tbSegMa.containsMouse ? "#CBD5E1" : "#E2E8F0")
                                                                    border.width: 2; border.color: "#1A1B2E"
                                                                    Text {
                                                                        anchors.centerIn: parent
                                                                        text: modelData.label
                                                                        font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                                                                    }
                                                                    MouseArea {
                                                                        id: tbSegMa
                                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: themeHub.setTaskbarHideMode(modelData.id)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                Rectangle {
                                                    width: parent.width
                                                    height: ramCardCol.implicitHeight + 24
                                                    radius: 16
                                                    color: RamCleanerService.autoEnabled ? (themeHub.phoneDarkMode ? "#17302A" : "#F0FDF4") : themeHub.phoneSubBg
                                                    border.width: 2.5; border.color: themeHub.phoneBorder

                                                    Column {
                                                        id: ramCardCol
                                                        x: 16; y: 12
                                                        width: parent.width - 32
                                                        spacing: 10

                                                        Row {
                                                            width: parent.width; height: 38
                                                            Column {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: parent.width - 78
                                                                spacing: 1
                                                                Row {
                                                                    spacing: 8
                                                                    Image { anchors.verticalCenter: parent.verticalCenter; width: 17; height: 17; source: "qrc:/qml/icons/rocket-dark.svg"; smooth: true }
                                                                    Text {
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        text: "AUTO CLEAN RAM (STUTTER-FREE)"
                                                                        font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk
                                                                    }
                                                                }
                                                                Text {
                                                                    text: "Priority-0 Standby only · Zero game stutter"
                                                                    font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Bold; color: themeHub.phoneMutedInk
                                                                }
                                                            }
                                                            Rectangle {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: 72; height: 32; radius: 16
                                                                color: RamCleanerService.autoEnabled ? themeHub.accentB : "#E2E8F0"
                                                                border.width: 2; border.color: "#1A1B2E"
                                                                Text {
                                                                    anchors.centerIn: parent
                                                                    text: RamCleanerService.autoEnabled ? "ON" : "OFF"
                                                                    font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E"
                                                                }
                                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: RamCleanerService.setAutoEnabled(!RamCleanerService.autoEnabled) }
                                                            }
                                                        }

                                                        Row {
                                                            width: parent.width; spacing: 6
                                                            Text {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "TRIGGER"
                                                                font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.phoneMutedInk
                                                            }
                                                            Repeater {
                                                                model: [70, 75, 80, 85]
                                                                delegate: Rectangle {
                                                                    required property int modelData
                                                                    width: 44; height: 28; radius: 8
                                                                    color: RamCleanerService.thresholdPercent === modelData ? themeHub.accentA : (ramThMa.containsMouse ? "#CBD5E1" : "#E2E8F0")
                                                                    border.width: 2; border.color: "#1A1B2E"
                                                                    Text { anchors.centerIn: parent; text: modelData + "%"; font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                                                    MouseArea { id: ramThMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: RamCleanerService.setThresholdPercent(modelData) }
                                                                }
                                                            }
                                                            Item { width: 8; height: 1 }
                                                            Text {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "EVERY"
                                                                font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.phoneMutedInk
                                                            }
                                                            Repeater {
                                                                model: [
                                                                    { sec: 120, lbl: "2M" },
                                                                    { sec: 300, lbl: "5M" },
                                                                    { sec: 600, lbl: "10M" }
                                                                ]
                                                                delegate: Rectangle {
                                                                    required property var modelData
                                                                    width: 44; height: 28; radius: 8
                                                                    color: RamCleanerService.intervalSeconds === modelData.sec ? themeHub.accentB : (ramIntMa.containsMouse ? "#CBD5E1" : "#E2E8F0")
                                                                    border.width: 2; border.color: "#1A1B2E"
                                                                    Text { anchors.centerIn: parent; text: modelData.lbl; font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Black; color: "#1A1B2E" }
                                                                    MouseArea { id: ramIntMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: RamCleanerService.setIntervalSeconds(modelData.sec) }
                                                                }
                                                            }
                                                        }

                                                        Row {
                                                            width: parent.width; spacing: 8
                                                            Rectangle {
                                                                width: 196; height: 34; radius: 10
                                                                color: RamCleanerService.cleaning ? "#FEF3C7" : (ramDeepMa.containsMouse ? "#4ADE80" : themeHub.accentB)
                                                                border.width: 2; border.color: "#1A1B2E"
                                                                Text {
                                                                    anchors.centerIn: parent
                                                                    text: RamCleanerService.cleaning ? "CLEANING RAM..." : "DEEP CLEAN RAM NOW"
                                                                    font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                                                                }
                                                                MouseArea {
                                                                    id: ramDeepMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                    enabled: !RamCleanerService.cleaning
                                                                    onClicked: RamCleanerService.cleanNowDeep()
                                                                }
                                                            }
                                                            Text {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: parent.width - 204; elide: Text.ElideRight
                                                                text: RamCleanerService.lastResultText !== ""
                                                                      ? RamCleanerService.lastResultText
                                                                      : "WorkingSets + Modified + Standby"
                                                                font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Bold; color: themeHub.phoneMutedInk
                                                            }
                                                        }
                                                    }
                                                }
                                                Rectangle {
                                                    width: parent.width; height: 54; radius: 16
                                                    color: SystemControl.launchAtStartup ? (themeHub.phoneDarkMode ? "#17302A" : "#ECFDF5") : themeHub.phoneSubBg
                                                    border.width: 2.5; border.color: themeHub.phoneBorder
                                                    Row {
                                                        anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 14; spacing: 10
                                                        Row {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            width: parent.width - 82
                                                            spacing: 8
                                                            Image { anchors.verticalCenter: parent.verticalCenter; width: 17; height: 17; source: "qrc:/qml/icons/rocket-dark.svg"; smooth: true }
                                                            Text {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "START WITH WINDOWS"
                                                                font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: themeHub.phoneInk
                                                            }
                                                        }
                                                        Rectangle {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            width: 72; height: 32; radius: 16
                                                            color: SystemControl.launchAtStartup ? themeHub.accentB : "#E2E8F0"
                                                            border.width: 2; border.color: "#1A1B2E"
                                                            Text {
                                                                anchors.centerIn: parent
                                                                text: SystemControl.launchAtStartup ? "ON" : "OFF"
                                                                font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E"
                                                            }
                                                        }
                                                    }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: SystemControl.toggleLaunchAtStartup() }
                                                }
                                                Rectangle {
                                                    width: parent.width; height: 50; radius: 16; color: "#E0F2FE"; border.width: 2.5; border.color: "#1A1B2E"
                                                    Row {
                                                        anchors.centerIn: parent; spacing: 8
                                                        Image { anchors.verticalCenter: parent.verticalCenter; width: 17; height: 17; source: "qrc:/qml/icons/settings-dark.svg"; smooth: true }
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "OPEN WINDOWS SYSTEM SETTINGS"; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E" }
                                                    }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: SystemControl.openSettings("ms-settings:") }
                                                }
                                                Rectangle {
                                                    width: parent.width; height: 50; radius: 16; color: "#FEF3C7"; border.width: 2.5; border.color: "#1A1B2E"
                                                    Row {
                                                        anchors.centerIn: parent; spacing: 8
                                                        Image { anchors.verticalCenter: parent.verticalCenter; width: 17; height: 17; source: "qrc:/qml/icons/restart-dark.svg"; smooth: true }
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "RESET ALL WIDGET POSITIONS"; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E" }
                                                    }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: themeHub.resetWidgetPositions() }
                                                }
                                                Item {
                                                    width: parent.width; height: 58
                                                    Rectangle {
                                                        x: 3; y: 3
                                                        width: parent.width - 3; height: 54; radius: 16; color: "#1A1B2E"
                                                    }
                                                    Rectangle {
                                                        x: quitSysMa.pressed ? 2 : 0
                                                        y: quitSysMa.pressed ? 2 : 0
                                                        width: parent.width - 3; height: 54; radius: 16
                                                        color: quitSysMa.containsMouse ? "#FDA4AF" : "#FFE4E6"
                                                        border.width: 2.5; border.color: "#1A1B2E"
                                                        Row {
                                                            anchors.centerIn: parent; spacing: 8
                                                            Image { anchors.verticalCenter: parent.verticalCenter; width: 18; height: 18; source: "qrc:/qml/icons/power-dark.svg"; smooth: true }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "QUIT SEKAIDESK"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: "#1A1B2E" }
                                                        }
                                                        MouseArea {
                                                            id: quitSysMa
                                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: SystemControl.quitApp()
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // ==== SUBPAGE 06: ABOUT ====
                                Item {
                                    id: aboutSubpage
                                    visible: themeHub.settingsSection === "about"
                                    anchors.fill: parent
                                    property int comboCount: 0
                                    readonly property int activeWidgetCount:
                                        (themeHub.wClockVisible ? 1 : 0)
                                        + (themeHub.wWeatherVisible ? 1 : 0)
                                        + (themeHub.wTodoVisible ? 1 : 0)
                                        + (themeHub.wNotesVisible ? 1 : 0)
                                        + (themeHub.wLyricsVisible ? 1 : 0)
                                        + (themeHub.wProfileVisible ? 1 : 0)
                                        + (themeHub.wCalendarVisible ? 1 : 0)

                                    Column {
                                        anchors.fill: parent
                                        spacing: 18

                                        // Hero SekaiPlate Banner
                                        Item {
                                            width: parent.width
                                            height: 158

                                            Rectangle {
                                                x: 5; y: 5
                                                width: parent.width - 5
                                                height: parent.height - 5
                                                radius: 24
                                                color: "#1A1B2E"
                                            }

                                            Rectangle {
                                                width: parent.width - 5
                                                height: parent.height - 5
                                                radius: 24
                                                border.width: 3.5
                                                border.color: "#1A1B2E"
                                                clip: true
                                                gradient: Gradient {
                                                    orientation: Gradient.Horizontal
                                                    GradientStop { position: 0.0; color: themeHub.accentA }
                                                    GradientStop { position: 1.0; color: themeHub.accentB }
                                                }

                                                // Subtle slanted stage-light bands
                                                Rectangle {
                                                    x: parent.width * 0.56; y: -40
                                                    width: 72; height: parent.height + 90
                                                    rotation: 18
                                                    color: Qt.rgba(1, 1, 1, 0.18)
                                                }
                                                Rectangle {
                                                    x: parent.width * 0.67; y: -40
                                                    width: 28; height: parent.height + 90
                                                    rotation: 18
                                                    color: Qt.rgba(1, 1, 1, 0.14)
                                                }

                                                Row {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 22
                                                    anchors.rightMargin: 22
                                                    spacing: 20

                                                    // Interactive clickable Wonderhoy sticker emblem (click for combo bounce!)
                                                    Item {
                                                        width: 96; height: 96
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        Rectangle {
                                                            x: 4; y: 4; width: 92; height: 92; radius: 26
                                                            color: "#1A1B2E"
                                                            rotation: (aboutSubpage.comboCount % 2 === 0) ? -4 : 4
                                                            Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                                        }
                                                        Rectangle {
                                                            id: abtEmblemCard
                                                            width: 92; height: 92; radius: 26
                                                            color: "#FFFDF7"
                                                            border.width: 3.5; border.color: "#1A1B2E"
                                                            rotation: (aboutSubpage.comboCount % 2 === 0) ? -4 : 4
                                                            scale: abtEmblemMa.pressed ? 0.88 : (abtEmblemMa.containsMouse ? 1.08 : 1.0)
                                                            Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                                            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }

                                                            Image {
                                                                anchors.fill: parent
                                                                anchors.margins: 4
                                                                source: "qrc:/qml/icons/wonderhoy.png"
                                                                fillMode: Image.PreserveAspectFit
                                                                smooth: true
                                                                mipmap: true
                                                            }
                                                            MouseArea {
                                                                id: abtEmblemMa
                                                                anchors.fill: parent
                                                                hoverEnabled: true
                                                                cursorShape: Qt.PointingHandCursor
                                                                onClicked: aboutSubpage.comboCount += 1
                                                            }
                                                        }
                                                    }

                                                    // Center Title & Feature Chips
                                                    Column {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: parent.width - 96 - 216 - 40
                                                        spacing: 6

                                                        Row {
                                                            spacing: 10
                                                            Text {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "SEKAIDESK SHELL"
                                                                font.family: "Segoe UI"; font.pixelSize: 30; font.weight: Font.Black
                                                                color: "#1A1B2E"
                                                            }
                                                            Rectangle {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: abtVerTxt.implicitWidth + 18; height: 28; radius: 14
                                                                color: "#1A1B2E"
                                                                Text { id: abtVerTxt; anchors.centerIn: parent; text: "v" + UpdateService.currentVersion + " · WIN64"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#FFFFFF" }
                                                            }
                                                            Rectangle {
                                                                visible: aboutSubpage.comboCount > 0
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: abtComboTxt.implicitWidth + 18; height: 28; radius: 14
                                                                color: "#FEF3C7"; border.width: 2; border.color: "#1A1B2E"
                                                                Text { id: abtComboTxt; anchors.centerIn: parent; text: "WONDERHOY ×" + aboutSubpage.comboCount + "!"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                            }
                                                        }

                                                        Text {
                                                            width: parent.width
                                                            elide: Text.ElideRight
                                                            text: "SekaiPop-Comic Desktop Environment for Windows · Qt 6.8.2 Quick & C++20 Win32 Layer"
                                                            font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Bold
                                                            color: Qt.rgba(26/255, 27/255, 46/255, 0.86)
                                                        }

                                                        Row {
                                                            spacing: 8
                                                            topPadding: 2
                                                            Repeater {
                                                                model: ["2.5D Phone Center", "SekaiOsd", "Live Visualizer", "Sticker Lyrics", "Weather Card"]
                                                                delegate: Rectangle {
                                                                    required property string modelData
                                                                    width: abtFeatTxt.implicitWidth + 18; height: 28; radius: 14
                                                                    color: Qt.rgba(1, 1, 1, 0.82); border.width: 2; border.color: "#1A1B2E"
                                                                    Text { id: abtFeatTxt; anchors.centerIn: parent; text: modelData; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Bold; color: "#1A1B2E" }
                                                                }
                                                            }
                                                        }
                                                    }

                                                    // Right Active Band Sticker Card
                                                    Rectangle {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: 216; height: 96; radius: 18
                                                        color: "#FFFDF7"; border.width: 3; border.color: "#1A1B2E"
                                                        Column {
                                                            anchors.centerIn: parent
                                                            width: parent.width - 20
                                                            spacing: 4
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                text: "ACTIVE UNIT THEME"
                                                                font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black
                                                                color: "#64748B"
                                                            }
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                width: parent.width
                                                                horizontalAlignment: Text.AlignHCenter
                                                                elide: Text.ElideRight
                                                                text: themeHub.bandName.toUpperCase()
                                                                font.family: "Segoe UI"; font.pixelSize: 17; font.weight: Font.Black
                                                                color: "#1A1B2E"
                                                            }
                                                            Rectangle {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                width: abtShortTxt.implicitWidth + 18; height: 26; radius: 13
                                                                color: themeHub.accentA; border.width: 2; border.color: "#1A1B2E"
                                                                Text { id: abtShortTxt; anchors.centerIn: parent; text: themeHub.bandShort; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Bottom Twin Cards: Creator Passport + Active Loadout
                                        Row {
                                            width: parent.width
                                            height: parent.height - 176
                                            spacing: 20

                                            // Left Card: Creator Passport & Handwritten Signature
                                            Rectangle {
                                                width: (parent.width - 20) * 0.52
                                                height: parent.height
                                                radius: 24
                                                color: themeHub.phoneCardBg
                                                border.width: 3.5
                                                border.color: themeHub.phoneBorder

                                                Flickable {
                                                    id: abtLeftFlick
                                                    anchors.fill: parent; anchors.margins: 22
                                                    clip: true; boundsBehavior: Flickable.StopAtBounds
                                                    contentWidth: width; contentHeight: abtLeftCol.implicitHeight

                                                    Column {
                                                        id: abtLeftCol
                                                        width: abtLeftFlick.width
                                                        spacing: 12

                                                        Row {
                                                            width: parent.width
                                                            spacing: 10
                                                            Rectangle {
                                                                width: abtPassLbl.implicitWidth + 18; height: 28; radius: 14
                                                                color: themeHub.accentA; border.width: 2; border.color: "#1A1B2E"
                                                                Text { id: abtPassLbl; anchors.centerIn: parent; text: "CREATOR PASSPORT"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                            }
                                                            Text {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: "WINDOWS PORT & CUSTOM STUDIO"
                                                                font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: themeHub.phoneMutedInk
                                                            }
                                                        }

                                                        // Profile / Attribution Row
                                                        Row {
                                                            width: parent.width
                                                            spacing: 14

                                                            Item {
                                                                width: 64; height: 64
                                                                Rectangle {
                                                                    anchors.fill: parent; radius: 32
                                                                    color: themeHub.phonePillBg
                                                                }
                                                                Image {
                                                                    anchors.fill: parent
                                                                    anchors.margins: 3
                                                                    source: "qrc:/qml/icons/author-pfp.png"
                                                                    fillMode: Image.PreserveAspectFit
                                                                    smooth: true
                                                                    mipmap: true
                                                                    antialiasing: true
                                                                }
                                                                Rectangle {
                                                                    anchors.fill: parent; radius: 32
                                                                    color: "transparent"; border.width: 3; border.color: themeHub.phoneBorder
                                                                    antialiasing: true
                                                                }
                                                            }

                                                            Column {
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: parent.width - 78
                                                                spacing: 3
                                                                Row {
                                                                    spacing: 8
                                                                    Text {
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        text: "Yuukitake"
                                                                        font.family: "Segoe UI"; font.pixelSize: 22; font.weight: Font.Black; color: themeHub.phoneInk
                                                                    }
                                                                    Rectangle {
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        width: 78; height: 24; radius: 12
                                                                        color: themeHub.accentB; border.width: 2; border.color: "#1A1B2E"
                                                                        Text { anchors.centerIn: parent; text: "AUTHOR"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                                    }
                                                                }
                                                                Text {
                                                                    width: parent.width
                                                                    elide: Text.ElideRight
                                                                    text: "Windows Desktop Port, C++ Win32 & QML Craft"
                                                                    font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Bold; color: themeHub.phoneInk
                                                                }
                                                                Text {
                                                                    width: parent.width
                                                                    elide: Text.ElideRight
                                                                    text: "Inspired by SekaiPop (Hyprland) · Aesthetic Pop-Comic Shell"
                                                                    font.family: "Segoe UI"; font.pixelSize: 14; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                                                                }
                                                            }
                                                        }

                                                        // Handwritten Signature Box (keep warm white paper so dark ink signature stays crisp)
                                                        Rectangle {
                                                            width: parent.width
                                                            height: Math.max(118, abtLeftFlick.height - 154)
                                                            radius: 18
                                                            color: "#FFFDF7"
                                                            border.width: 2.5
                                                            border.color: themeHub.phoneBorder
                                                            clip: true

                                                            Text {
                                                                anchors.left: parent.left; anchors.leftMargin: 14
                                                                anchors.top: parent.top; anchors.topMargin: 10
                                                                text: "SIGNATURE // AUTHENTICATED"
                                                                font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black
                                                                color: "#94A3B8"
                                                            }

                                                            Image {
                                                                anchors.centerIn: parent
                                                                anchors.verticalCenterOffset: 6
                                                                width: parent.width - 48
                                                                height: parent.height - 38
                                                                source: "qrc:/qml/icons/handsig-yozora.png"
                                                                fillMode: Image.PreserveAspectFit
                                                                smooth: true
                                                                mipmap: true
                                                            }

                                                            Rectangle {
                                                                anchors.right: parent.right; anchors.rightMargin: 14
                                                                anchors.bottom: parent.bottom; anchors.bottomMargin: 10
                                                                width: abtSealTxt.implicitWidth + 18; height: 26; radius: 13
                                                                rotation: -4
                                                                color: themeHub.accentB; border.width: 2; border.color: "#1A1B2E"
                                                                Text { id: abtSealTxt; anchors.centerIn: parent; text: "✦ SEKAI CERTIFIED"; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            // Right Card: Active Loadout & Stack
                                            Rectangle {
                                                width: (parent.width - 20) * 0.48
                                                height: parent.height
                                                radius: 24
                                                color: themeHub.phoneCardBg
                                                border.width: 3.5
                                                border.color: themeHub.phoneBorder

                                                Flickable {
                                                    id: abtRightFlick
                                                    anchors.fill: parent; anchors.margins: 22
                                                    clip: true; boundsBehavior: Flickable.StopAtBounds
                                                    contentWidth: width; contentHeight: abtRightCol.implicitHeight

                                                    Column {
                                                        id: abtRightCol
                                                        width: abtRightFlick.width
                                                        spacing: 14

                                                        Text {
                                                            text: "SYSTEM SPECS"
                                                            font.family: "Segoe UI"; font.pixelSize: 20; font.weight: Font.Black; color: themeHub.phoneInk
                                                        }

                                                        Grid {
                                                            width: parent.width
                                                            columns: 2
                                                            columnSpacing: 12
                                                            rowSpacing: 12
                                                            Repeater {
                                                                model: [
                                                                    { k: "CPU", v: WindowTracker.cpuSpec },
                                                                    { k: "GPU", v: WindowTracker.gpuSpec },
                                                                    { k: "RAM", v: WindowTracker.ramSpec },
                                                                    { k: "OS",  v: WindowTracker.osSpec }
                                                                ]
                                                                delegate: Rectangle {
                                                                    required property var modelData
                                                                    width: (parent.width - 12) * 0.5
                                                                    height: 68
                                                                    radius: 14
                                                                    color: themeHub.phoneSubBg
                                                                    border.width: 2.5
                                                                    border.color: themeHub.phoneBorder
                                                                    Column {
                                                                        anchors.centerIn: parent
                                                                        width: parent.width - 18
                                                                        spacing: 2
                                                                        Text { text: modelData.k; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneMutedInk }
                                                                        Text { width: parent.width; elide: Text.ElideRight; text: modelData.v; font.family: "Consolas"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk }
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        Text {
                                                            text: "ACTIVE SHELL & STACK"
                                                            font.family: "Segoe UI"; font.pixelSize: 20; font.weight: Font.Black; color: themeHub.phoneInk
                                                        }

                                                        Grid {
                                                            width: parent.width
                                                            columns: 2
                                                            columnSpacing: 12
                                                            rowSpacing: 12
                                                            Repeater {
                                                                model: [
                                                                    { k: "TOP BAR",       v: themeHub.barStyle.toUpperCase() + (themeHub.barAutoHide ? " · AUTO" : "") },
                                                                    { k: "BOTTOM DOCK",   v: themeHub.dockStyle.toUpperCase() + (themeHub.dockAutoHide ? " · DODGE" : "") },
                                                                    { k: "NOTIFICATIONS", v: themeHub.notifyStyle.toUpperCase() + (themeHub.osdEnabled ? " · OSD" : "") },
                                                                    { k: "DISPLAY",       v: themeHub.screenW + "×" + themeHub.screenH + " · " + aboutSubpage.activeWidgetCount + "/7 WGT" }
                                                                ]
                                                                delegate: Rectangle {
                                                                    required property var modelData
                                                                    width: (parent.width - 12) * 0.5
                                                                    height: 68
                                                                    radius: 14
                                                                    color: themeHub.phoneSubBg
                                                                    border.width: 2.5
                                                                    border.color: themeHub.phoneBorder
                                                                    Column {
                                                                        anchors.centerIn: parent
                                                                        width: parent.width - 18
                                                                        spacing: 2
                                                                        Text { text: modelData.k; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneMutedInk }
                                                                        Text { width: parent.width; elide: Text.ElideRight; text: modelData.v; font.family: "Consolas"; font.pixelSize: 15; font.weight: Font.Black; color: themeHub.phoneInk }
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        Rectangle {
                                                            width: parent.width
                                                            height: abtUpdCol.implicitHeight + 24
                                                            radius: 16
                                                            color: UpdateService.updateAvailable ? (themeHub.phoneDarkMode ? "#302814" : "#FEF9C3") : themeHub.phoneSubBg
                                                            border.width: 2.5
                                                            border.color: themeHub.phoneBorder

                                                            Column {
                                                                id: abtUpdCol
                                                                x: 14; y: 12
                                                                width: parent.width - 28
                                                                spacing: 8

                                                                Row {
                                                                    width: parent.width
                                                                    spacing: 8

                                                                    Text {
                                                                        text: "AUTO UPDATER"
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneInk
                                                                    }

                                                                    Rectangle {
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        width: abtUpdVerTxt.implicitWidth + 14; height: 22; radius: 11
                                                                        color: themeHub.phoneCardBg; border.width: 2; border.color: themeHub.phoneBorder
                                                                        Text {
                                                                            id: abtUpdVerTxt
                                                                            anchors.centerIn: parent
                                                                            text: "v" + UpdateService.currentVersion + " · " + (UpdateService.isInstallerInstall ? "INSTALLER" : "PORTABLE")
                                                                            font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.phoneInk
                                                                        }
                                                                    }
                                                                }

                                                                Text {
                                                                    width: parent.width
                                                                    wrapMode: Text.WordWrap
                                                                    text: UpdateService.status === "downloading"
                                                                          ? ("Downloading v" + UpdateService.latestVersion + " · " + Math.round(UpdateService.downloadProgress * 100) + "%")
                                                                          : UpdateService.statusText
                                                                    font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.DemiBold
                                                                    color: UpdateService.status === "error" ? "#FB7185" : themeHub.phoneMutedInk
                                                                }

                                                                Rectangle {
                                                                    visible: UpdateService.status === "downloading" || UpdateService.status === "verifying" || UpdateService.status === "installing"
                                                                    width: parent.width; height: 12; radius: 6
                                                                    color: themeHub.phoneCardBg; border.width: 2; border.color: themeHub.phoneBorder
                                                                    clip: true
                                                                    Rectangle {
                                                                        height: parent.height
                                                                        width: parent.width * (UpdateService.status === "downloading" ? UpdateService.downloadProgress : 1.0)
                                                                        color: UpdateService.status === "installing" ? "#4ADE80" : themeHub.accentA
                                                                    }
                                                                }

                                                                Rectangle {
                                                                    width: parent.width; height: 34; radius: 12
                                                                    color: UpdateService.updateAvailable
                                                                           ? (abtUpdMa.containsMouse ? "#4ADE80" : themeHub.accentA)
                                                                           : (abtUpdMa.containsMouse ? themeHub.accentB : themeHub.phoneCardBg)
                                                                    border.width: 2.5; border.color: (UpdateService.updateAvailable || abtUpdMa.containsMouse) ? "#1A1B2E" : themeHub.phoneBorder
                                                                    Text {
                                                                        anchors.centerIn: parent
                                                                        text: {
                                                                            if (UpdateService.status === "checking") return "CHECKING..."
                                                                            if (UpdateService.status === "downloading") return "DOWNLOADING..."
                                                                            if (UpdateService.status === "verifying") return "VERIFYING SHA-256..."
                                                                            if (UpdateService.status === "installing") return "INSTALLING..."
                                                                            if (UpdateService.updateAvailable) return "UPDATE TO v" + UpdateService.latestVersion + " & RESTART"
                                                                            return "CHECK FOR UPDATES"
                                                                        }
                                                                        font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black
                                                                        color: (UpdateService.updateAvailable || abtUpdMa.containsMouse) ? "#1A1B2E" : themeHub.phoneInk
                                                                    }
                                                                    MouseArea {
                                                                        id: abtUpdMa
                                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        enabled: UpdateService.status !== "checking" && UpdateService.status !== "downloading" && UpdateService.status !== "verifying" && UpdateService.status !== "installing"
                                                                        onClicked: {
                                                                            if (UpdateService.updateAvailable)
                                                                                UpdateService.startUpdate()
                                                                            else
                                                                                UpdateService.checkForUpdates(false)
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        Text {
                                                            text: "ENGINE & TECHNOLOGIES"
                                                            font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Black; color: themeHub.phoneMutedInk
                                                        }

                                                        Flow {
                                                            width: parent.width
                                                            spacing: 8
                                                            Repeater {
                                                                model: ["Qt 6.8.2 Quick", "C++20 / Win32", "D3D11 RHI", "DWM Blur", "WASAPI Peak", "SMTC Media", "LRCLIB Sync", "Open-Meteo"]
                                                                delegate: Rectangle {
                                                                    required property string modelData
                                                                    width: abtTechTxt.implicitWidth + 20; height: 30; radius: 15
                                                                    color: themeHub.phoneSubBg; border.width: 2; border.color: themeHub.phoneBorder
                                                                    Text { id: abtTechTxt; anchors.centerIn: parent; text: modelData; font.family: "Consolas"; font.pixelSize: 13; font.weight: Font.Bold; color: themeHub.phoneInk }
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
                            }

                            // ---- Integrated Landscape Wallpaper Gallery Layer ----
                            PhoneWallpaperGallery {
                                id: landWallpaperGallery
                                anchors.fill: parent
                                themeHub: themeHub
                                visible: quickPanelWindow.contentK > 0.005
                                opacity: quickPanelWindow.contentK
                                enabled: quickPanelWindow.contentK >= 0.5
                                onBackToSettings: themeHub.landscapeContent = "settings"
                                onCloseRequested: themeHub.settingsOpen = false
                                onPickingChanged: p => quickPanelWindow.pickingFile = p
                            }
                        }

                        // Left-side Phone Pill Notch + Camera Lens + Glint
                        Item {
                            x: 16
                            y: (parent.height - 196) * 0.5
                            width: 40
                            height: 196
                            z: 50
                            Rectangle {
                                x: -16; y: 0; width: 52; height: 196; radius: 26
                                color: "#1A1B2E"
                            }
                            Rectangle {
                                x: 8; y: 24; width: 20; height: 20; radius: 10
                                color: "#0F172A"
                                Rectangle {
                                    anchors.centerIn: parent; width: 10; height: 10; radius: 5; color: "#1E3A5F"
                                    Rectangle { x: 2; y: 2; width: 3; height: 3; radius: 2; color: "#93C5FD" }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // #2 Dock-Safe Notification Peek (Bottom-Right Mini Phone) & Popup Stack
    // =========================================================================
    PanelWindow {
        id: notifPeekWindow
        readonly property bool quietNow: GameModeService.active || (themeHub.notifyQuietFullscreen && topBarWindow.fullscreenActive)
        // Phone mode is now handled directly by the real 2.5D phone stage in quickPanelWindow!
        readonly property bool usePopupMode: true

        property var peekItem: null
        property real peekProgress: 0.0
        property bool peekHovered: false
        property var popupItems: []
        property bool stackHovered: false

        visible: !quietNow
                 && themeHub.notifyStyle === "popup"
                 && popupItems.length > 0
        clickThrough: false
        color: "transparent"

        width: usePopupMode ? 356 : 348
        height: usePopupMode ? Math.min(380, Math.max(108, popupItems.length * 108 + 16)) : 156
        x: Math.max(0, themeHub.screenW - width - (usePopupMode ? 16 : 20))
        y: usePopupMode ? 38 : Math.max(0, themeHub.screenH - height)

        mask: usePopupMode
              ? [{ x: 0, y: 0, width: width, height: height }]
              : [{ x: 0, y: Math.max(0, Math.round((1.0 - peekProgress) * height)), width: width, height: Math.max(1, Math.round(peekProgress * height)) }]

        function pushNotification(item) {
            if (!item || themeHub.notifyStyle !== "popup" || quietNow)
                return
            if (usePopupMode) {
                const next = popupItems.slice(0)
                next.unshift(item)
                if (next.length > 3)
                    next.length = 3
                popupItems = next
                popupDismissTimer.restart()
            } else {
                peekItem = item
                peekExitAnim.stop()
                peekEnterAnim.restart()
                peekDismissTimer.restart()
            }
        }

        function dismissPeek() {
            peekDismissTimer.stop()
            peekEnterAnim.stop()
            peekExitAnim.restart()
        }

        function dismissPopupAt(idx) {
            const next = popupItems.slice(0)
            if (idx >= 0 && idx < next.length)
                next.splice(idx, 1)
            popupItems = next
            if (next.length === 0)
                popupDismissTimer.stop()
        }

        Connections {
            target: NotificationService
            function onNewNotificationReceived(item) {
                notifPeekWindow.pushNotification(item)
            }
        }

        NumberAnimation {
            id: peekEnterAnim
            target: notifPeekWindow
            property: "peekProgress"
            to: 1.0
            duration: 280
            easing.type: Easing.OutBack
            easing.overshoot: 0.9
        }

        NumberAnimation {
            id: peekExitAnim
            target: notifPeekWindow
            property: "peekProgress"
            to: 0.0
            duration: 190
            easing.type: Easing.InCubic
            onFinished: {
                if (notifPeekWindow.peekProgress <= 0.01)
                    notifPeekWindow.peekItem = null
            }
        }

        Timer {
            id: peekDismissTimer
            interval: 4800
            repeat: false
            running: notifPeekWindow.visible && !notifPeekWindow.usePopupMode && notifPeekWindow.peekItem !== null && !notifPeekWindow.peekHovered
            onTriggered: notifPeekWindow.dismissPeek()
        }

        Timer {
            id: popupDismissTimer
            interval: 4800
            repeat: true
            running: notifPeekWindow.visible && notifPeekWindow.usePopupMode && notifPeekWindow.popupItems.length > 0 && !notifPeekWindow.stackHovered
            onTriggered: {
                if (notifPeekWindow.popupItems.length > 0)
                    notifPeekWindow.dismissPopupAt(notifPeekWindow.popupItems.length - 1)
            }
        }

        // ---- Mode A: Bottom-Right Mini 2.5D Phone Peek ----
        Item {
            visible: !notifPeekWindow.usePopupMode && notifPeekWindow.peekItem !== null
            width: 332
            height: 150
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round((1.0 - notifPeekWindow.peekProgress) * notifPeekWindow.height) + 8

            HoverHandler {
                id: peekHoverHandler
                onHoveredChanged: notifPeekWindow.peekHovered = hovered
            }

            // Outer mini phone bezel rising cleanly from screen bottom edge
            Rectangle {
                anchors.fill: parent
                topLeftRadius: 28
                topRightRadius: 28
                bottomLeftRadius: 0
                bottomRightRadius: 0
                color: "#2E3148"
                border.width: 3
                border.color: "#1A1B2E"
            }
            Rectangle {
                x: 8; y: 8
                width: parent.width - 16
                height: parent.height - 4
                topLeftRadius: 22
                topRightRadius: 22
                color: "#FAFAFF"
                border.width: 2.5
                border.color: "#1A1B2E"
                clip: true

                // Top notch pill
                Rectangle {
                    x: (parent.width - 84) * 0.5
                    y: -6
                    width: 84; height: 18; radius: 9
                    color: "#1A1B2E"
                    Rectangle { x: 14; y: 8; width: 6; height: 6; radius: 3; color: "#38BDF8" }
                }

                // Accent left bar
                Rectangle {
                    x: 12; y: 20; width: 5; height: parent.height - 34; radius: 3
                    color: themeHub.accentA
                }

                // Header row: App badge + Time + Close
                Row {
                    x: 24; y: 18
                    width: parent.width - 36
                    spacing: 8
                    Rectangle {
                        height: 20
                        width: Math.min(168, peekAppTxt.implicitWidth + 14)
                        radius: 8
                        color: themeHub.accentA
                        border.width: 1.5; border.color: "#1A1B2E"
                        Text {
                            id: peekAppTxt
                            anchors.centerIn: parent
                            width: parent.width - 10
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            text: (notifPeekWindow.peekItem && notifPeekWindow.peekItem.app ? notifPeekWindow.peekItem.app : "NOTIFICATION").toUpperCase()
                            font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E"
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: notifPeekWindow.peekItem && notifPeekWindow.peekItem.timeText ? notifPeekWindow.peekItem.timeText : ""
                        font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold; color: "#64748B"
                    }
                }

                // Title & Body
                Text {
                    x: 24; y: 44
                    width: parent.width - 52
                    elide: Text.ElideRight
                    text: notifPeekWindow.peekItem ? (notifPeekWindow.peekItem.title || "") : ""
                    font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                }
                Text {
                    x: 24; y: 66
                    width: parent.width - 38
                    maximumLineCount: 2
                    wrapMode: Text.WordWrap
                    elide: Text.ElideRight
                    text: notifPeekWindow.peekItem ? (notifPeekWindow.peekItem.body || "") : ""
                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.DemiBold; color: "#475569"
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            notifPeekWindow.dismissPeek()
                        } else {
                            notifPeekWindow.dismissPeek()
                            quickPanelWindow.bottomTab = "notifications"
                            topBarWindow.quickPanelOpen = true
                            NotificationService.refresh()
                        }
                    }
                }

                // Close pill
                Rectangle {
                    anchors.right: parent.right; anchors.rightMargin: 10
                    anchors.top: parent.top; anchors.topMargin: 12
                    width: 24; height: 24; radius: 12
                    color: peekCloseMa.containsMouse ? "#FB7185" : "#F1F5F9"
                    border.width: 2; border.color: "#1A1B2E"
                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                    MouseArea {
                        id: peekCloseMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: notifPeekWindow.dismissPeek()
                    }
                }
            }
        }

        // ---- Mode B: Top-Right Popup Card Stack (<= 3 cards) ----
        Column {
            visible: notifPeekWindow.usePopupMode
            anchors.top: parent.top
            anchors.right: parent.right
            spacing: 8
            width: parent.width

            HoverHandler {
                onHoveredChanged: notifPeekWindow.stackHovered = hovered
            }

            Repeater {
                model: notifPeekWindow.popupItems
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: notifPeekWindow.width
                    height: 98

                    Rectangle { x: 4; y: 4; width: parent.width - 6; height: parent.height - 4; radius: 18; color: "#1A1B2E" }
                    Rectangle {
                        width: parent.width - 6; height: parent.height - 4; radius: 18
                        color: "#FAFAFF"; border.width: 3; border.color: "#1A1B2E"
                        clip: true

                        Rectangle { x: 0; y: 0; width: 8; height: parent.height; color: themeHub.accentA }

                        Row {
                            x: 16; y: 10; spacing: 8
                            Rectangle {
                                height: 20; width: Math.min(180, stAppTxt.implicitWidth + 14); radius: 8
                                color: themeHub.accentA; border.width: 1.5; border.color: "#1A1B2E"
                                Text {
                                    id: stAppTxt
                                    anchors.centerIn: parent
                                    width: parent.width - 8; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                                    text: (modelData.app || "NOTIFICATION").toUpperCase()
                                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E"
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.timeText || ""
                                font.family: "Consolas"; font.pixelSize: 10; font.weight: Font.Bold; color: "#64748B"
                            }
                        }

                        Text {
                            x: 16; y: 36; width: parent.width - 48; elide: Text.ElideRight
                            text: modelData.title || ""
                            font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                        }
                        Text {
                            x: 16; y: 56; width: parent.width - 28; maximumLineCount: 2; wrapMode: Text.WordWrap; elide: Text.ElideRight
                            text: modelData.body || ""
                            font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.DemiBold; color: "#475569"
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mouse => {
                                const i = index
                                const isRight = (mouse.button === Qt.RightButton)
                                Qt.callLater(function() {
                                    notifPeekWindow.dismissPopupAt(i)
                                    if (!isRight) {
                                        quickPanelWindow.bottomTab = "notifications"
                                        topBarWindow.quickPanelOpen = true
                                        NotificationService.refresh()
                                    }
                                })
                            }
                        }

                        Rectangle {
                            anchors.right: parent.right; anchors.rightMargin: 10
                            anchors.top: parent.top; anchors.topMargin: 8
                            width: 24; height: 24; radius: 12
                            color: stCloseMa.containsMouse ? "#FB7185" : "#F1F5F9"
                            border.width: 2; border.color: "#1A1B2E"
                            Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                            MouseArea {
                                id: stCloseMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const i = index
                                    Qt.callLater(function() { notifPeekWindow.dismissPopupAt(i) })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // Floating SekaiPop Auto-Updater Toast
    // =========================================================================
    PanelWindow {
        id: updateToastWindow
        visible: !GameModeService.active && UpdateService.toastVisible
        clickThrough: false
        color: "transparent"

        width: 348
        height: 98
        x: Math.max(0, themeHub.screenW - width - 16)
        y: (notifPeekWindow.visible ? (notifPeekWindow.y + notifPeekWindow.height + 8) : 42)
        mask: [{ x: 0, y: 0, width: width, height: height }]

        Item {
            anchors.fill: parent

            Rectangle {
                x: 4; y: 4
                width: parent.width - 4; height: parent.height - 4
                radius: 18
                color: "#1A1B2E"
            }

            Rectangle {
                id: updToastCard
                x: 0; y: 0
                width: parent.width - 4; height: parent.height - 4
                radius: 18
                color: updToastMa.containsMouse && (UpdateService.status === "available" || UpdateService.status === "error") ? "#FEF9C3" : "#FFFFFF"
                border.width: 3
                border.color: "#1A1B2E"
                antialiasing: true

                Rectangle {
                    id: updBadge
                    x: 12; anchors.verticalCenter: parent.verticalCenter
                    width: 40; height: 40; radius: 12
                    color: UpdateService.status === "installing" ? "#4ADE80"
                         : (UpdateService.status === "error" ? "#FDA4AF" : themeHub.accentA)
                    border.width: 2.5; border.color: "#1A1B2E"
                    Image {
                        anchors.centerIn: parent
                        width: 22; height: 22; smooth: true
                        source: "qrc:/qml/icons/rocket-dark.svg"
                    }
                }

                Column {
                    anchors.left: updBadge.right; anchors.leftMargin: 12
                    anchors.right: parent.right; anchors.rightMargin: 38
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: {
                            const st = UpdateService.status
                            if (st === "available") return "UPDATE AVAILABLE · v" + UpdateService.latestVersion
                            if (st === "downloading") return "DOWNLOADING v" + UpdateService.latestVersion + " · " + Math.round(UpdateService.downloadProgress * 100) + "%"
                            if (st === "verifying") return "VERIFYING SHA-256..."
                            if (st === "installing") return "INSTALLING & RESTARTING..."
                            if (st === "error") return "UPDATE FAILED"
                            return "SEKAIDESK UPDATER"
                        }
                        font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E"
                    }

                    Text {
                        visible: UpdateService.status === "available" || UpdateService.status === "error"
                        width: parent.width
                        elide: Text.ElideRight
                        text: UpdateService.status === "error"
                              ? (UpdateService.errorMessage + " · Click to retry")
                              : "Click to download & install automatically"
                        font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.DemiBold
                        color: UpdateService.status === "error" ? "#E11D48" : "#475569"
                    }

                    Rectangle {
                        visible: UpdateService.status === "downloading" || UpdateService.status === "verifying" || UpdateService.status === "installing"
                        width: parent.width; height: 12; radius: 6
                        color: "#F1F5F9"; border.width: 2; border.color: "#1A1B2E"
                        clip: true
                        Rectangle {
                            height: parent.height
                            width: parent.width * (UpdateService.status === "downloading" ? UpdateService.downloadProgress : 1.0)
                            color: UpdateService.status === "installing" ? "#4ADE80" : themeHub.accentA
                        }
                    }

                    Text {
                        visible: (UpdateService.status === "downloading" || UpdateService.status === "verifying") && UpdateService.totalBytes > 0
                        text: (UpdateService.downloadedBytes / 1048576).toFixed(1) + " / " + (UpdateService.totalBytes / 1048576).toFixed(1) + " MB"
                        font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Bold; color: "#475569"
                    }
                }

                MouseArea {
                    id: updToastMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: (UpdateService.status === "available" || UpdateService.status === "error") ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (UpdateService.status === "available" || UpdateService.status === "error")
                            UpdateService.startUpdate()
                    }
                }

                Rectangle {
                    visible: UpdateService.status !== "installing"
                    anchors.right: parent.right; anchors.rightMargin: 10
                    anchors.top: parent.top; anchors.topMargin: 8
                    width: 24; height: 24; radius: 12
                    color: updCloseMa.containsMouse ? "#FB7185" : "#F1F5F9"
                    border.width: 2; border.color: "#1A1B2E"
                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 14; font.weight: Font.Black; color: "#1A1B2E" }
                    MouseArea {
                        id: updCloseMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: UpdateService.dismissToast()
                    }
                }
            }
        }
    }

    // =========================================================================
    // Low-Battery Warning Alert Toast (<=20% warning, <=10% critical)
    // =========================================================================
    PanelWindow {
        id: lowBatteryToastWindow
        property bool alertOpen: false
        property int alertPercent: 20
        property bool alertCritical: false

        visible: alertOpen && (!GameModeService.active || alertCritical)
        clickThrough: false
        color: "transparent"

        width: 348
        height: 96
        x: Math.max(0, themeHub.screenW - width - 16)
        y: updateToastWindow.visible
           ? (updateToastWindow.y + updateToastWindow.height + 8)
           : (notifPeekWindow.visible ? (notifPeekWindow.y + notifPeekWindow.height + 8) : 42)
        mask: [{ x: 0, y: 0, width: width, height: height }]

        Component.onCompleted: Qt.callLater(function() { WindowTracker.checkLowBatteryAlert() })

        Timer {
            id: lowBattAutoHideTimer
            interval: 12000
            onTriggered: if (!lowBatteryToastWindow.alertCritical) lowBatteryToastWindow.alertOpen = false
        }

        Connections {
            target: WindowTracker
            function onLowBatteryAlert(percent, critical) {
                lowBatteryToastWindow.alertPercent = percent
                lowBatteryToastWindow.alertCritical = critical
                lowBatteryToastWindow.alertOpen = true
                if (!critical)
                    lowBattAutoHideTimer.restart()
                else
                    lowBattAutoHideTimer.stop()
            }
            function onStatsChanged() {
                if (!WindowTracker.hasBattery || WindowTracker.batteryCharging || WindowTracker.batteryPercent > 25)
                    lowBatteryToastWindow.alertOpen = false
            }
        }

        Item {
            anchors.fill: parent

            Rectangle {
                x: 4; y: 4
                width: parent.width - 4; height: parent.height - 4
                radius: 18
                color: "#1A1B2E"
            }

            Rectangle {
                id: lowBattCard
                x: 0; y: 0
                width: parent.width - 4; height: parent.height - 4
                radius: 18
                color: themeHub.phoneCardBg
                border.width: 3
                border.color: lowBatteryToastWindow.alertCritical ? "#E11D48" : themeHub.phoneBorder
                antialiasing: true

                Rectangle {
                    id: lowBattBadge
                    x: 12; anchors.verticalCenter: parent.verticalCenter
                    width: 40; height: 40; radius: 12
                    color: lowBatteryToastWindow.alertCritical ? "#FB7185" : "#FACC15"
                    border.width: 2.5; border.color: "#1A1B2E"
                    Text {
                        anchors.centerIn: parent
                        text: lowBatteryToastWindow.alertCritical ? "!" : "⚡"
                        font.family: "Segoe UI"; font.pixelSize: 20; font.weight: Font.Black; color: "#1A1B2E"
                    }
                }

                Column {
                    anchors.left: lowBattBadge.right; anchors.leftMargin: 12
                    anchors.right: parent.right; anchors.rightMargin: 38
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: (lowBatteryToastWindow.alertCritical ? "CRITICAL BATTERY · " : "LOW BATTERY · ") + lowBatteryToastWindow.alertPercent + "%"
                        font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black
                        color: lowBatteryToastWindow.alertCritical ? "#FB7185" : themeHub.phoneInk
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: (WindowTracker.batteryTimeText !== "" ? (WindowTracker.batteryTimeText + " · ") : "") + "Plug in charger"
                        font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.DemiBold
                        color: themeHub.phoneMutedInk
                    }
                }

                MouseArea {
                    id: lowBattToastMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: SystemControl.openSettings("ms-settings:powersleep")
                }

                Rectangle {
                    anchors.right: parent.right; anchors.rightMargin: 10
                    anchors.top: parent.top; anchors.topMargin: 8
                    width: 24; height: 24; radius: 12
                    color: lowBattCloseMa.containsMouse ? "#FB7185" : themeHub.phonePillBg
                    border.width: 2; border.color: themeHub.phoneBorder
                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 14; font.weight: Font.Black; color: themeHub.phoneInk }
                    MouseArea {
                        id: lowBattCloseMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: lowBatteryToastWindow.alertOpen = false
                    }
                }
            }
        }
    }

    // =========================================================================
    // SekaiPop Calendar Popup (click Date/Clock pill on TopBar)
    // =========================================================================
    PanelWindow {
        id: calendarPopupWindow
        visible: topBarWindow.calendarOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0
        property int viewYear: (new Date()).getFullYear()
        property int viewMonth: (new Date()).getMonth() // 0..11

        readonly property var monthNames: [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        readonly property var dayShortNames: ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        readonly property var dayFullNames: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        function isoWeekNumber(d) {
            const tmp = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
            const dayNum = tmp.getUTCDay() || 7
            tmp.setUTCDate(tmp.getUTCDate() + 4 - dayNum)
            const yearStart = new Date(Date.UTC(tmp.getUTCFullYear(), 0, 1))
            return Math.ceil((((tmp - yearStart) / 86400000) + 1) / 7)
        }

        function currentWeekRow(year, month) {
            const now = new Date()
            if (now.getFullYear() !== year || now.getMonth() !== month)
                return -1
            const firstDow = (new Date(year, month, 1).getDay() + 6) % 7
            return Math.floor((firstDow + now.getDate() - 1) / 7)
        }

        function buildCells(year, month) {
            const first = new Date(year, month, 1)
            const dow = (first.getDay() + 6) % 7
            const daysInMonth = new Date(year, month + 1, 0).getDate()
            const prevDays = new Date(year, month, 0).getDate()
            const now = new Date()
            const todayY = now.getFullYear(), todayM = now.getMonth(), todayD = now.getDate()
            const out = []
            for (let i = 0; i < 42; ++i) {
                let d, m = month, y = year, inMonth = true
                if (i < dow) {
                    d = prevDays - dow + i + 1
                    m = month - 1
                    if (m < 0) { m = 11; y -= 1 }
                    inMonth = false
                } else if (i >= dow + daysInMonth) {
                    d = i - dow - daysInMonth + 1
                    m = month + 1
                    if (m > 11) { m = 0; y += 1 }
                    inMonth = false
                } else {
                    d = i - dow + 1
                }
                const isToday = (y === todayY && m === todayM && d === todayD)
                const isWeekend = (i % 7 >= 5)
                out.push({ day: d, inMonth: inMonth, isToday: isToday, isWeekend: isWeekend })
            }
            return out
        }

        width: 288 + cardShadow
        height: calCol.implicitHeight + 24 + cardShadow
        x: topBarWindow.barPopupX(width, Math.round(barFrame.x + 6 + centerContentRow.x + clockPill.x + (clockPill.width - width) * 0.5))
        y: topBarWindow.barPopupY(height, Math.round((themeHub.screenH - height) * 0.5))

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                const now = new Date()
                viewYear = now.getFullYear()
                viewMonth = now.getMonth()
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: calendarPopupWindow.visible
            onTriggered: {
                if ((Date.now() - calendarPopupWindow.openedAt) > 220 && calendarPopupWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.calendarClosedAt = Date.now()
                    topBarWindow.calendarOpen = false
                }
            }
        }

        // Hard offset shadow
        Rectangle {
            x: calendarPopupWindow.cardShadow
            y: calendarPopupWindow.cardShadow
            width: calendarPopupWindow.width - calendarPopupWindow.cardShadow
            height: calendarPopupWindow.height - calendarPopupWindow.cardShadow
            radius: 18
            color: "#0B0F19"
        }

        // Dark Navy SekaiPop Calendar Card
        Rectangle {
            x: 0
            y: 0
            width: calendarPopupWindow.width - calendarPopupWindow.cardShadow
            height: calendarPopupWindow.height - calendarPopupWindow.cardShadow
            radius: 18
            color: "#1B1E2E"
            border.width: 2.5
            border.color: "#E2E8F0"

            Column {
                id: calCol
                x: 12
                y: 12
                width: parent.width - 24
                spacing: 10

                // ===== Top Cyan Gradient Banner =====
                Rectangle {
                    width: parent.width
                    height: 76
                    radius: 14
                    border.width: 2
                    border.color: "#0F172A"
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: themeHub.accentA }
                        GradientStop { position: 1.0; color: themeHub.accentB }
                    }

                    // Tilted Day Badge (Click to return to Today)
                    Rectangle {
                        id: calDayBadge
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 52
                        height: 54
                        radius: 12
                        rotation: -4
                        color: "#333951"
                        border.width: 2
                        border.color: "#0F172A"

                        Column {
                            anchors.centerIn: parent
                            spacing: -2
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: calendarPopupWindow.dayShortNames[(new Date()).getDay()]
                                font.family: "Segoe UI"
                                font.pixelSize: 9
                                font.weight: Font.ExtraBold
                                color: "#CBD5E1"
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: String((new Date()).getDate())
                                font.family: "Segoe UI"
                                font.pixelSize: 22
                                font.weight: Font.Black
                                color: themeHub.accentB
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                const now = new Date()
                                calendarPopupWindow.viewYear = now.getFullYear()
                                calendarPopupWindow.viewMonth = now.getMonth()
                            }
                        }
                    }

                    Column {
                        anchors.left: calDayBadge.right
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        Row {
                            width: parent.width
                            spacing: 6
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: calendarPopupWindow.monthNames[calendarPopupWindow.viewMonth]
                                font.family: "Segoe UI"
                                font.pixelSize: 16
                                font.weight: Font.Black
                                color: "#0F172A"
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: calYearTxt.implicitWidth + 12
                                height: 18
                                radius: 9
                                color: "#272B40"
                                border.width: 1.5
                                border.color: "#0F172A"
                                Text {
                                    id: calYearTxt
                                    anchors.centerIn: parent
                                    text: String(calendarPopupWindow.viewYear)
                                    font.family: "Consolas"
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                    color: "#E2E8F0"
                                }
                            }
                        }

                        Text {
                            readonly property var nowDate: new Date()
                            text: calendarPopupWindow.dayFullNames[nowDate.getDay()] + " · Week " + calendarPopupWindow.isoWeekNumber(nowDate)
                            font.family: "Segoe UI"
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            color: "#0F172A"
                        }

                        Text {
                            readonly property var nowDate: new Date()
                            readonly property int daysLeft: new Date(nowDate.getFullYear(), nowDate.getMonth() + 1, 0).getDate() - nowDate.getDate()
                            text: daysLeft + " days left in " + calendarPopupWindow.monthNames[nowDate.getMonth()]
                            font.family: "Segoe UI"
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                            color: "#1E293B"
                            opacity: 0.85
                        }
                    }
                }

                // ===== Weekday Header Pill =====
                Rectangle {
                    width: parent.width
                    height: 24
                    radius: 8
                    color: "#25293E"

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 2
                        Repeater {
                            model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                            delegate: Item {
                                required property string modelData
                                required property int index
                                readonly property bool isTodayDow: {
                                    const now = new Date()
                                    const dow = (now.getDay() + 6) % 7
                                    return calendarPopupWindow.viewYear === now.getFullYear()
                                        && calendarPopupWindow.viewMonth === now.getMonth()
                                        && dow === index
                                }
                                width: Math.floor((parent.width - 12) / 7)
                                height: 24
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 28
                                    height: 16
                                    radius: 6
                                    visible: isTodayDow
                                    color: themeHub.accentA
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.family: "Segoe UI"
                                    font.pixelSize: 10
                                    font.weight: Font.ExtraBold
                                    color: isTodayDow ? "#0F172A" : (index >= 5 ? "#FB7185" : "#94A3B8")
                                }
                            }
                        }
                    }
                }

                // ===== 6x7 Calendar Grid with Current-Week Row & Weekend Tint =====
                Item {
                    width: parent.width
                    height: 178

                    readonly property int cellW: Math.floor((width - 12 - 12) / 7)
                    readonly property int weekRow: calendarPopupWindow.currentWeekRow(calendarPopupWindow.viewYear, calendarPopupWindow.viewMonth)

                    // Weekend vertical column tint (Sa + Su)
                    Rectangle {
                        x: 6 + (parent.cellW + 2) * 5 - 2
                        y: 0
                        width: parent.cellW * 2 + 6
                        height: parent.height
                        radius: 10
                        color: "#2A2238"
                        opacity: 0.7
                    }

                    // Current week row highlight pill
                    Rectangle {
                        visible: parent.weekRow >= 0
                        x: 2
                        y: parent.weekRow * 29 + 1
                        width: parent.width - 4
                        height: 27
                        radius: 10
                        color: "#223A4A"
                        opacity: 0.85
                    }

                    Grid {
                        x: 6
                        y: 2
                        columns: 7
                        columnSpacing: 2
                        rowSpacing: 3
                        width: parent.width - 12
                        Repeater {
                            model: calendarPopupWindow.buildCells(calendarPopupWindow.viewYear, calendarPopupWindow.viewMonth)
                            delegate: Item {
                                required property var modelData
                                width: Math.floor((parent.width - 12) / 7)
                                height: 26

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 24
                                    height: 24
                                    radius: 8
                                    visible: modelData.isToday
                                    color: themeHub.accentA
                                }

                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.day
                                    font.family: "Segoe UI"
                                    font.pixelSize: 11
                                    font.weight: modelData.isToday ? Font.Black : Font.Bold
                                    color: modelData.isToday
                                        ? "#0F172A"
                                        : (!modelData.inMonth ? "#475569" : (modelData.isWeekend ? "#FB7185" : "#E2E8F0"))
                                }
                            }
                        }
                    }
                }

                // ===== Footer: <  [12 Month Diamonds]  > =====
                Item {
                    width: parent.width
                    height: 26

                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        radius: 8
                        color: calPrevMouse.containsMouse ? "#334155" : "#25293E"
                        border.width: 1.5
                        border.color: "#475569"
                        Text {
                            anchors.centerIn: parent
                            text: "<"
                            font.family: "Consolas"
                            font.pixelSize: 12
                            font.weight: Font.Bold
                            color: "#E2E8F0"
                        }
                        MouseArea {
                            id: calPrevMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (calendarPopupWindow.viewMonth === 0) {
                                    calendarPopupWindow.viewMonth = 11
                                    calendarPopupWindow.viewYear -= 1
                                } else {
                                    calendarPopupWindow.viewMonth -= 1
                                }
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: monthDotsRow.implicitWidth + 16
                        height: 22
                        radius: 11
                        color: "#25293E"
                        border.width: 1
                        border.color: "#334155"

                        Row {
                            id: monthDotsRow
                            anchors.centerIn: parent
                            spacing: 4
                            Repeater {
                                model: 12
                                delegate: Text {
                                    required property int index
                                    text: "◆"
                                    font.family: "Segoe UI Symbol"
                                    font.pixelSize: index === calendarPopupWindow.viewMonth ? 11 : 8
                                    color: index === calendarPopupWindow.viewMonth ? themeHub.accentA : "#475569"
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: calendarPopupWindow.viewMonth = index
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        radius: 8
                        color: calNextMouse.containsMouse ? "#334155" : "#25293E"
                        border.width: 1.5
                        border.color: "#475569"
                        Text {
                            anchors.centerIn: parent
                            text: ">"
                            font.family: "Consolas"
                            font.pixelSize: 12
                            font.weight: Font.Bold
                            color: "#E2E8F0"
                        }
                        MouseArea {
                            id: calNextMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (calendarPopupWindow.viewMonth === 11) {
                                    calendarPopupWindow.viewMonth = 0
                                    calendarPopupWindow.viewYear += 1
                                } else {
                                    calendarPopupWindow.viewMonth += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // SekaiPop Network / Wi-Fi Popup
    // =========================================================================
    PanelWindow {
        id: wifiPopupWindow
        visible: topBarWindow.wifiPopupOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0
        property string passwordSsid: ""

        width: 288 + cardShadow
        height: wifiCol.implicitHeight + 24 + cardShadow
        x: topBarWindow.barPopupX(width, (topBarWindow.anchors.margins.left + topBarWindow.width) - width - 6)
        y: topBarWindow.barPopupY(height, themeHub.screenH - height - 80)

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                passwordSsid = ""
                SystemControl.refresh()
                SystemControl.refreshWifi()
                focusActivate()
            } else {
                passwordSsid = ""
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: wifiPopupWindow.visible
            onTriggered: {
                if ((Date.now() - wifiPopupWindow.openedAt) > 220 && wifiPopupWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.wifiPopupClosedAt = Date.now()
                    topBarWindow.wifiPopupOpen = false
                }
            }
        }

        Rectangle {
            x: wifiPopupWindow.cardShadow
            y: wifiPopupWindow.cardShadow
            width: wifiPopupWindow.width - wifiPopupWindow.cardShadow
            height: wifiPopupWindow.height - wifiPopupWindow.cardShadow
            radius: 16
            color: "#1A1B2E"
        }

        Rectangle {
            x: 0
            y: 0
            width: wifiPopupWindow.width - wifiPopupWindow.cardShadow
            height: wifiPopupWindow.height - wifiPopupWindow.cardShadow
            radius: 16
            color: themeHub.phoneScreenBg
            border.width: 2
            border.color: themeHub.phoneBorder

            Column {
                id: wifiCol
                x: 12
                y: 12
                width: parent.width - 24
                spacing: 8

                Rectangle {
                    width: parent.width
                    height: 44
                    radius: 12
                    color: themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: themeHub.phoneBorder
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        spacing: 2
                        Row {
                            spacing: 6
                            Image {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 14
                                height: 14
                                sourceSize.width: 28
                                sourceSize.height: 28
                                smooth: true
                                source: SystemControl.networkType === "Wi-Fi"
                                    ? (themeHub.phoneDarkMode ? "qrc:/qml/icons/wifi-light.svg" : "qrc:/qml/icons/wifi-dark.svg")
                                    : (themeHub.phoneDarkMode ? "qrc:/qml/icons/network-light.svg" : "qrc:/qml/icons/network-dark.svg")
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: SystemControl.networkType
                                font.family: "Segoe UI"
                                font.pixelSize: 12
                                font.weight: Font.Bold
                                color: themeHub.phoneInk
                            }
                        }
                        Text {
                            text: SystemControl.localIp ? SystemControl.localIp : "No IPv4 address"
                            font.family: "Consolas"
                            font.pixelSize: 10
                            color: themeHub.phoneMutedInk
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 36
                    radius: 12
                    color: themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: themeHub.phoneBorder

                    Text {
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: SystemControl.wifiSupported ? "Wi-Fi" : "Wi-Fi (No adapter)"
                        font.family: "Segoe UI"
                        font.pixelSize: 12
                        font.weight: Font.Bold
                        color: themeHub.phoneInk
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40
                        height: 22
                        radius: 11
                        color: SystemControl.wifiEnabled ? themeHub.accentA : "#CBD5E1"
                        border.width: 1.5
                        border.color: "#1A1B2E"
                        Rectangle {
                            x: SystemControl.wifiEnabled ? 20 : 2
                            y: 2
                            width: 16
                            height: 16
                            radius: 8
                            color: "#FFFFFF"
                            border.width: 1
                            border.color: "#1A1B2E"
                            Behavior on x { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: SystemControl.wifiSupported
                            onClicked: SystemControl.toggleWifi()
                        }
                    }
                }

                Text {
                    visible: SystemControl.wifiStatusText !== ""
                    width: parent.width; elide: Text.ElideRight
                    text: SystemControl.wifiStatusText
                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Bold; color: themeHub.accentA
                }

                // Inline Password Input Card for unsecured/unprofiled Wi-Fi
                Rectangle {
                    visible: SystemControl.wifiEnabled && wifiPopupWindow.passwordSsid !== ""
                    width: parent.width; height: 74; radius: 11
                    color: themeHub.phoneCardBg; border.width: 2; border.color: themeHub.accentA
                    Column {
                        anchors.fill: parent; anchors.margins: 7; spacing: 5
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: "🔒 Password · " + wifiPopupWindow.passwordSsid
                            font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.phoneInk
                        }
                        Row {
                            width: parent.width; height: 26; spacing: 5
                            Rectangle {
                                width: parent.width - 104; height: 26; radius: 7
                                color: themeHub.phoneSubBg; border.width: 1.5; border.color: themeHub.phoneBorder; clip: true
                                TextInput {
                                    id: wifiPwInput
                                    anchors.fill: parent; anchors.margins: 5
                                    verticalAlignment: Text.AlignVCenter
                                    echoMode: TextInput.Password
                                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: themeHub.phoneInk
                                    selectByMouse: true
                                    onAccepted: {
                                        const target = wifiPopupWindow.passwordSsid
                                        const pw = text
                                        wifiPopupWindow.passwordSsid = ""
                                        text = ""
                                        SystemControl.connectWifiWithPassword(target, pw)
                                    }
                                }
                            }
                            Rectangle {
                                width: 54; height: 26; radius: 7; color: themeHub.accentA; border.width: 1.5; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: "Join"; font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const target = wifiPopupWindow.passwordSsid
                                        const pw = wifiPwInput.text
                                        wifiPopupWindow.passwordSsid = ""
                                        wifiPwInput.text = ""
                                        SystemControl.connectWifiWithPassword(target, pw)
                                    }
                                }
                            }
                            Rectangle {
                                width: 40; height: 26; radius: 7; color: themeHub.phonePillBg; border.width: 1.5; border.color: themeHub.phoneBorder
                                Text { anchors.centerIn: parent; text: "×"; font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.phoneInk }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { wifiPopupWindow.passwordSsid = ""; wifiPwInput.text = "" }
                                }
                            }
                        }
                    }
                }

                Flickable {
                    visible: SystemControl.wifiSupported && SystemControl.wifiEnabled
                    width: parent.width
                    height: Math.min(200, Math.max(28, wifiNetCol.implicitHeight))
                    contentWidth: width
                    contentHeight: wifiNetCol.implicitHeight
                    clip: true

                    Column {
                        id: wifiNetCol
                        width: parent.width
                        spacing: 4
                        Text {
                            visible: SystemControl.wifiNetworks.length === 0
                            text: SystemControl.wifiScanning ? "Scanning networks..." : "No networks found"
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            color: themeHub.phoneMutedInk
                        }
                        Repeater {
                            model: SystemControl.wifiNetworks
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool isConnecting: SystemControl.wifiConnectingSsid !== "" && (SystemControl.wifiConnectingSsid === modelData.ssid || SystemControl.wifiConnectingSsid === modelData.profile)
                                readonly property bool isKnown: (modelData.profile && modelData.profile !== "") || !modelData.secured
                                readonly property bool canForget: !!(modelData.profile && modelData.profile !== "")
                                width: wifiNetCol.width
                                height: 28
                                radius: 9
                                color: modelData.connected ? themeHub.accentB : (isConnecting ? "#FEF3C7" : (wnMouse.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg))
                                border.width: 1.5
                                border.color: (modelData.connected || isConnecting || wnMouse.containsMouse) ? "#1A1B2E" : themeHub.phoneBorder

                                Row {
                                    x: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - (canForget ? 104 : 78)
                                    spacing: 6
                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 12
                                        height: 12
                                        sourceSize.width: 24
                                        sourceSize.height: 24
                                        smooth: true
                                        source: (!modelData.connected && !isConnecting && !wnMouse.containsMouse && themeHub.phoneDarkMode)
                                            ? "qrc:/qml/icons/wifi-light.svg"
                                            : "qrc:/qml/icons/wifi-dark.svg"
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 18
                                        elide: Text.ElideRight
                                        text: (modelData.connected ? "✓ " : (modelData.secured && !isKnown ? "🔒 " : "")) + modelData.ssid
                                        font.family: "Segoe UI"
                                        font.pixelSize: 11
                                        font.weight: (modelData.connected || isConnecting) ? Font.Bold : Font.Medium
                                        color: (modelData.connected || isConnecting || wnMouse.containsMouse) ? "#1A1B2E" : themeHub.phoneInk
                                    }
                                }
                                Text {
                                    anchors.right: canForget ? wifiFgtBtn.left : parent.right
                                    anchors.rightMargin: canForget ? 6 : 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: isConnecting ? "Connecting..." : (modelData.signal + "%")
                                    font.family: "Consolas"
                                    font.pixelSize: 10
                                    color: (modelData.connected || isConnecting || wnMouse.containsMouse) ? "#1A1B2E" : themeHub.phoneMutedInk
                                }
                                MouseArea {
                                    id: wnMouse
                                    anchors.fill: parent
                                    anchors.rightMargin: canForget ? 26 : 0
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (modelData.connected)
                                            return
                                        if (isKnown) {
                                            const prof = modelData.profile || modelData.ssid
                                            wifiPopupWindow.passwordSsid = ""
                                            Qt.callLater(function() { SystemControl.connectWifi(prof) })
                                        } else {
                                            wifiPopupWindow.passwordSsid = modelData.ssid
                                            wifiPwInput.text = ""
                                            wifiPwInput.forceActiveFocus()
                                        }
                                    }
                                }
                                Rectangle {
                                    id: wifiFgtBtn
                                    visible: canForget
                                    anchors.right: parent.right
                                    anchors.rightMargin: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18; height: 18; radius: 6
                                    color: wifiFgtMa.containsMouse ? "#FB7185" : themeHub.phonePillBg
                                    border.width: 1; border.color: "#1A1B2E"
                                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 11; font.weight: Font.Black; color: wifiFgtMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                    MouseArea {
                                        id: wifiFgtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const prof = modelData.profile
                                            Qt.callLater(function() { SystemControl.forgetWifi(prof) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 28
                    radius: 10
                    color: netSetMouse.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: netSetMouse.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                    Text {
                        anchors.centerIn: parent
                        text: "Network Settings"
                        font.family: "Segoe UI"
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        color: netSetMouse.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                    }
                    MouseArea {
                        id: netSetMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            topBarWindow.wifiPopupOpen = false
                            SystemControl.openSettings("ms-settings:network")
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // SekaiPop Bluetooth Popup
    // =========================================================================
    PanelWindow {
        id: btPopupWindow
        visible: topBarWindow.btPopupOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0

        width: 276 + cardShadow
        height: btCol.implicitHeight + 24 + cardShadow
        x: topBarWindow.barPopupX(width, (topBarWindow.anchors.margins.left + topBarWindow.width) - width - 6)
        y: topBarWindow.barPopupY(height, themeHub.screenH - height - 80)

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                SystemControl.refreshBluetooth()
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: btPopupWindow.visible
            onTriggered: {
                if ((Date.now() - btPopupWindow.openedAt) > 220 && btPopupWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.btPopupClosedAt = Date.now()
                    topBarWindow.btPopupOpen = false
                }
            }
        }

        Rectangle {
            x: btPopupWindow.cardShadow
            y: btPopupWindow.cardShadow
            width: btPopupWindow.width - btPopupWindow.cardShadow
            height: btPopupWindow.height - btPopupWindow.cardShadow
            radius: 16
            color: "#1A1B2E"
        }

        Rectangle {
            x: 0
            y: 0
            width: btPopupWindow.width - btPopupWindow.cardShadow
            height: btPopupWindow.height - btPopupWindow.cardShadow
            radius: 16
            color: themeHub.phoneScreenBg
            border.width: 2
            border.color: themeHub.phoneBorder

            Column {
                id: btCol
                x: 12
                y: 12
                width: parent.width - 24
                spacing: 8

                Rectangle {
                    width: parent.width
                    height: 36
                    radius: 12
                    color: themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: themeHub.phoneBorder

                    Text {
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: SystemControl.bluetoothSupported ? "Bluetooth" : "Bluetooth (Unavailable)"
                        font.family: "Segoe UI"
                        font.pixelSize: 12
                        font.weight: Font.Bold
                        color: themeHub.phoneInk
                    }

                    Rectangle {
                        visible: SystemControl.bluetoothSupported && SystemControl.bluetoothEnabled
                        anchors.right: btSwitchPill.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: btScanLbl.implicitWidth + 14
                        height: 22
                        radius: 11
                        color: SystemControl.btScanning ? "#FEF3C7" : (btScanMa.containsMouse ? themeHub.accentB : themeHub.phonePillBg)
                        border.width: 1.5
                        border.color: (SystemControl.btScanning || btScanMa.containsMouse) ? "#1A1B2E" : themeHub.phoneBorder
                        Text {
                            id: btScanLbl
                            anchors.centerIn: parent
                            text: SystemControl.btScanning ? "Scanning..." : "Scan"
                            font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black
                            color: (SystemControl.btScanning || btScanMa.containsMouse) ? "#1A1B2E" : themeHub.phoneInk
                        }
                        MouseArea {
                            id: btScanMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            enabled: !SystemControl.btScanning
                            onClicked: SystemControl.scanBluetooth()
                        }
                    }

                    Rectangle {
                        id: btSwitchPill
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40
                        height: 22
                        radius: 11
                        color: SystemControl.bluetoothEnabled ? "#818CF8" : "#CBD5E1"
                        border.width: 1.5
                        border.color: "#1A1B2E"
                        Rectangle {
                            x: SystemControl.bluetoothEnabled ? 20 : 2
                            y: 2
                            width: 16
                            height: 16
                            radius: 8
                            color: "#FFFFFF"
                            border.width: 1
                            border.color: "#1A1B2E"
                            Behavior on x { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: SystemControl.bluetoothSupported
                            onClicked: SystemControl.toggleBluetooth()
                        }
                    }
                }

                Flickable {
                    visible: SystemControl.bluetoothSupported && SystemControl.bluetoothEnabled
                    width: parent.width
                    height: Math.min(200, Math.max(26, btDevCol.implicitHeight))
                    contentWidth: width
                    contentHeight: btDevCol.implicitHeight
                    clip: true

                    Column {
                        id: btDevCol
                        width: parent.width
                        spacing: 4
                        Text {
                            visible: SystemControl.bluetoothDevices.length === 0
                            text: SystemControl.btScanning ? "Scanning nearby Bluetooth devices..." : "No paired devices · Click Scan"
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            color: themeHub.phoneMutedInk
                        }
                        Repeater {
                            model: SystemControl.bluetoothDevices
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool canForget: (modelData.paired !== false) && !!(modelData.address && modelData.address !== "" && modelData.address !== "0")
                                width: btDevCol.width
                                height: 28
                                radius: 9
                                color: modelData.connected ? "#C7D2FE" : themeHub.phoneCardBg
                                border.width: 1.5
                                border.color: modelData.connected ? "#1A1B2E" : themeHub.phoneBorder

                                Row {
                                    x: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - (canForget ? 96 : 74)
                                    spacing: 6
                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 12
                                        height: 12
                                        sourceSize.width: 24
                                        sourceSize.height: 24
                                        smooth: true
                                        source: (!modelData.connected && themeHub.phoneDarkMode)
                                            ? "qrc:/qml/icons/bt-light.svg"
                                            : "qrc:/qml/icons/bt-dark.svg"
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 18
                                        elide: Text.ElideRight
                                        text: modelData.name
                                        font.family: "Segoe UI"
                                        font.pixelSize: 11
                                        font.weight: modelData.connected ? Font.Bold : Font.Medium
                                        color: modelData.connected ? "#1A1B2E" : themeHub.phoneInk
                                    }
                                }
                                Text {
                                    anchors.right: canForget ? btFgtBtn.left : parent.right
                                    anchors.rightMargin: canForget ? 6 : 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.connected ? "Connected" : (modelData.paired !== false ? "Paired" : "Nearby")
                                    font.family: "Segoe UI"
                                    font.pixelSize: 10
                                    color: modelData.connected ? "#3730A3" : themeHub.phoneMutedInk
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.rightMargin: canForget ? 26 : 0
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (!modelData.connected && modelData.paired === false) {
                                            topBarWindow.btPopupOpen = false
                                            SystemControl.openAddDeviceDialog()
                                        }
                                    }
                                }
                                Rectangle {
                                    id: btFgtBtn
                                    visible: canForget
                                    anchors.right: parent.right
                                    anchors.rightMargin: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18; height: 18; radius: 6
                                    color: btFgtMa.containsMouse ? "#FB7185" : themeHub.phonePillBg
                                    border.width: 1; border.color: "#1A1B2E"
                                    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 11; font.weight: Font.Black; color: btFgtMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk }
                                    MouseArea {
                                        id: btFgtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const addr = modelData.address
                                            Qt.callLater(function() { SystemControl.forgetBluetooth(addr) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    height: 28
                    spacing: 6

                    Rectangle {
                        width: 82
                        height: 28
                        radius: 10
                        color: btAddMa.containsMouse ? themeHub.accentB : themeHub.accentA
                        border.width: 1.5
                        border.color: "#1A1B2E"
                        Text {
                            anchors.centerIn: parent
                            text: "+ Add"
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            font.weight: Font.Black
                            color: "#1A1B2E"
                        }
                        MouseArea {
                            id: btAddMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                topBarWindow.btPopupOpen = false
                                SystemControl.openAddDeviceDialog()
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width - 88
                        height: 28
                        radius: 10
                        color: btSetMouse.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                        border.width: 1.5
                        border.color: btSetMouse.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                        Text {
                            anchors.centerIn: parent
                            text: "Bluetooth Settings"
                            font.family: "Segoe UI"
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            color: btSetMouse.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                        }
                        MouseArea {
                            id: btSetMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                topBarWindow.btPopupOpen = false
                                SystemControl.openSettings("ms-settings:bluetooth")
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // Independent TopBar Volume & Per-App Mixer Popup (decoupled from Phone)
    // =========================================================================
    PanelWindow {
        id: volumePopupWindow
        visible: topBarWindow.volumePopupOpen && !topBarWindow.effectiveFullscreen
        clickThrough: false
        color: "transparent"

        readonly property int cardShadow: 4
        property double openedAt: 0

        width: 344 + cardShadow
        height: Math.min(540, volPopupCol.implicitHeight + 24) + cardShadow
        x: topBarWindow.barPopupX(width, (topBarWindow.anchors.margins.left + topBarWindow.width) - width - 6)
        y: topBarWindow.barPopupY(height, themeHub.screenH - height - 60)

        onVisibleChanged: {
            if (visible) {
                openedAt = Date.now()
                AudioService.refreshOutputDevices()
                AudioService.refreshSessions()
                focusActivate()
            }
        }

        Timer {
            interval: 60
            repeat: true
            running: volumePopupWindow.visible
            onTriggered: {
                if ((Date.now() - volumePopupWindow.openedAt) > 220 && volumePopupWindow.isPointerOutsideAndPressed()) {
                    topBarWindow.volumePopupClosedAt = Date.now()
                    topBarWindow.volumePopupOpen = false
                }
            }
        }

        Timer {
            interval: 650
            repeat: true
            running: volumePopupWindow.visible
            onTriggered: AudioService.refreshSessions()
        }

        Rectangle {
            x: volumePopupWindow.cardShadow
            y: volumePopupWindow.cardShadow
            width: volumePopupWindow.width - volumePopupWindow.cardShadow
            height: volumePopupWindow.height - volumePopupWindow.cardShadow
            radius: 16
            color: "#1A1B2E"
        }

        Rectangle {
            x: 0
            y: 0
            width: volumePopupWindow.width - volumePopupWindow.cardShadow
            height: volumePopupWindow.height - volumePopupWindow.cardShadow
            radius: 16
            color: themeHub.phoneScreenBg
            border.width: 2
            border.color: themeHub.phoneBorder

            Column {
                id: volPopupCol
                x: 12
                y: 12
                width: parent.width - 24
                spacing: 8

                // Master Volume Card
                Rectangle {
                    width: parent.width
                    height: 62
                    radius: 12
                    color: themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: themeHub.phoneBorder

                    Column {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 6

                        Item {
                            width: parent.width
                            height: 24
                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                Rectangle {
                                    width: 24; height: 24; radius: 8
                                    color: AudioService.masterMuted ? "#FEE2E2" : themeHub.accentB
                                    border.width: 1.5; border.color: "#1A1B2E"
                                    Image {
                                        anchors.centerIn: parent; width: 14; height: 14; sourceSize.width: 28; sourceSize.height: 28; smooth: true
                                        source: AudioService.masterMuted ? "qrc:/qml/icons/volume-cross-dark.svg" : "qrc:/qml/icons/volume-loud-dark.svg"
                                    }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: AudioService.toggleMasterMute() }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Master Volume"
                                    font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Black; color: themeHub.phoneInk
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: AudioService.masterMuted ? "Muted" : (AudioService.masterVolume + "%")
                                font.family: "Consolas"; font.pixelSize: 12; font.weight: Font.Black
                                color: AudioService.masterMuted ? "#FB7185" : themeHub.phoneInk
                            }
                        }

                        Item {
                            width: parent.width; height: 16
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width; height: 12; radius: 6
                                color: themeHub.phonePillBg; border.width: 1.5; border.color: themeHub.phoneBorder
                                Rectangle {
                                    x: 2; y: 2; height: 8; radius: 4
                                    width: Math.max(0, (parent.width - 4) * (AudioService.masterVolume / 100.0))
                                    color: AudioService.masterMuted ? "#94A3B8" : themeHub.accentA
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                function applyMaster(mx) {
                                    AudioService.setMasterVolume(Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100))
                                }
                                onPressed: mouse => applyMaster(mouse.x)
                                onPositionChanged: mouse => { if (pressed) applyMaster(mouse.x) }
                            }
                        }
                    }
                }

                // Microphone Card (if supported)
                Rectangle {
                    visible: AudioService.micSupported
                    width: parent.width
                    height: 58
                    radius: 12
                    color: themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: themeHub.phoneBorder

                    Column {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 5

                        Item {
                            width: parent.width
                            height: 22
                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                Rectangle {
                                    width: 22; height: 22; radius: 7
                                    color: AudioService.micMuted ? "#FEE2E2" : "#E0F2FE"
                                    border.width: 1.5; border.color: "#1A1B2E"
                                    Text {
                                        anchors.centerIn: parent
                                        text: AudioService.micMuted ? "🔇" : "🎙"
                                        font.pixelSize: 12
                                        color: "#1A1B2E"
                                    }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: AudioService.toggleMicMute() }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Microphone"
                                    font.family: "Segoe UI"; font.pixelSize: 12; font.weight: Font.Bold; color: themeHub.phoneInk
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: AudioService.micMuted ? "Muted" : (AudioService.micVolume + "%")
                                font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Black
                                color: AudioService.micMuted ? "#FB7185" : themeHub.phoneInk
                            }
                        }

                        Item {
                            width: parent.width; height: 14
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width; height: 10; radius: 5
                                color: themeHub.phonePillBg; border.width: 1.5; border.color: themeHub.phoneBorder
                                Rectangle {
                                    x: 2; y: 2; height: 6; radius: 3
                                    width: Math.max(0, (parent.width - 4) * (AudioService.micVolume / 100.0))
                                    color: AudioService.micMuted ? "#94A3B8" : themeHub.accentB
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                function applyMic(mx) {
                                    AudioService.setMicVolume(Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100))
                                }
                                onPressed: mouse => applyMic(mouse.x)
                                onPositionChanged: mouse => { if (pressed) applyMic(mouse.x) }
                            }
                        }
                    }
                }

                // Output Device Picker
                Text {
                    visible: AudioService.outputDevices.length > 0
                    text: "OUTPUT DEVICE"
                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.phoneMutedInk
                }

                Flow {
                    visible: AudioService.outputDevices.length > 0
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: AudioService.outputDevices
                        delegate: Rectangle {
                            required property var modelData
                            width: Math.min(volPopupCol.width, vpDevLbl.implicitWidth + 18)
                            height: 26; radius: 10
                            color: modelData.isDefault ? themeHub.accentB : (vpDevMa.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg)
                            border.width: 1.5; border.color: (modelData.isDefault || vpDevMa.containsMouse) ? "#1A1B2E" : themeHub.phoneBorder
                            Text {
                                id: vpDevLbl
                                anchors.centerIn: parent
                                width: Math.min(implicitWidth, volPopupCol.width - 20)
                                elide: Text.ElideRight
                                text: (modelData.isDefault ? "✓ " : "") + (modelData.name || "Output")
                                font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold
                                color: (modelData.isDefault || vpDevMa.containsMouse) ? "#1A1B2E" : themeHub.phoneInk
                            }
                            MouseArea {
                                id: vpDevMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: Qt.callLater(function() { AudioService.setDefaultOutputDevice(modelData.id) })
                            }
                        }
                    }
                }

                // Per-App Volume Mixer
                Text {
                    text: "APP MIXER (" + AudioService.sessions.length + ")"
                    font.family: "Segoe UI"; font.pixelSize: 10; font.weight: Font.Black; color: themeHub.phoneMutedInk
                }

                Flickable {
                    width: parent.width
                    height: Math.min(196, Math.max(30, vpMixCol.implicitHeight + 4))
                    contentWidth: width
                    contentHeight: vpMixCol.implicitHeight + 4
                    clip: true

                    Column {
                        id: vpMixCol
                        width: parent.width
                        spacing: 6

                        Text {
                            visible: AudioService.sessions.length === 0
                            text: "No active audio apps right now."
                            font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.DemiBold; color: themeHub.phoneMutedInk
                        }

                        Repeater {
                            model: AudioService.sessions
                            delegate: Row {
                                required property var modelData
                                width: vpMixCol.width
                                height: 30
                                spacing: 8

                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18; height: 18
                                    source: modelData.iconUrl || ""
                                    smooth: true; mipmap: true
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 94; elide: Text.ElideRight
                                    text: modelData.name || "App"
                                    font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: themeHub.phoneInk
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 24; height: 22; radius: 7
                                    color: modelData.muted ? "#FDE68A" : themeHub.phoneCardBg
                                    border.width: 1.5; border.color: modelData.muted ? "#1A1B2E" : themeHub.phoneBorder
                                    Image {
                                        anchors.centerIn: parent; width: 12; height: 12; sourceSize.width: 24; sourceSize.height: 24; smooth: true
                                        source: modelData.muted
                                            ? "qrc:/qml/icons/volume-cross-dark.svg"
                                            : (themeHub.phoneDarkMode ? "qrc:/qml/icons/volume-loud-light.svg" : "qrc:/qml/icons/volume-loud-dark.svg")
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const aid = modelData.id
                                            Qt.callLater(function() { AudioService.toggleAppMute(aid) })
                                        }
                                    }
                                }
                                Item {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 196; height: 18
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width; height: 10; radius: 5
                                        color: themeHub.phonePillBg; border.width: 1.5; border.color: themeHub.phoneBorder
                                        Rectangle {
                                            x: 2; y: 2; height: 6; radius: 3
                                            width: Math.max(0, (parent.width - 4) * (modelData.volume / 100.0))
                                            color: modelData.muted ? "#94A3B8" : themeHub.accentA
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        function setSessionVol(mx) {
                                            AudioService.setAppVolume(modelData.id, Math.round(Math.max(0, Math.min(1, mx / Math.max(1, width))) * 100))
                                        }
                                        onPressed: mouse => setSessionVol(mouse.x)
                                        onPositionChanged: mouse => { if (pressed) setSessionVol(mouse.x) }
                                    }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 36; horizontalAlignment: Text.AlignRight
                                    text: modelData.volume + "%"
                                    font.family: "Consolas"; font.pixelSize: 11; font.weight: Font.Black; color: themeHub.phoneInk
                                }
                            }
                        }
                    }
                }

                // Sound Settings Footer
                Rectangle {
                    width: parent.width
                    height: 28
                    radius: 10
                    color: volSetMa.containsMouse ? themeHub.hoverTint : themeHub.phoneCardBg
                    border.width: 1.5
                    border.color: volSetMa.containsMouse ? "#1A1B2E" : themeHub.phoneBorder
                    Text {
                        anchors.centerIn: parent
                        text: "Sound Settings"
                        font.family: "Segoe UI"; font.pixelSize: 11; font.weight: Font.Bold; color: volSetMa.containsMouse ? "#1A1B2E" : themeHub.phoneInk
                    }
                    MouseArea {
                        id: volSetMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            topBarWindow.volumePopupOpen = false
                            SystemControl.openSettings("ms-settings:sound")
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // Round 5 Modules (@qml-mods-5): SekaiOsd, VisualizerOverlay, WallpaperSelector
    // =========================================================================
    VisualizerOverlay {
        themeHub: themeHub
        fullscreenActive: topBarWindow.effectiveFullscreen
    }

    Binding {
        target: VisualizerService
        property: "suppressed"
        value: GameModeService.active
               || topBarWindow.fullscreenActive
               || (WindowTracker.desktopOccluded && !themeHub.editMode)
    }

    SekaiOsd {
        themeHub: themeHub
        fullscreenActive: topBarWindow.effectiveFullscreen
    }

    ScreenRound {
        themeHub: themeHub
        fullscreenActive: topBarWindow.effectiveFullscreen
        scrW: themeHub.screenW
        scrH: themeHub.screenH
    }

    PowerTools {
        themeHub: themeHub
        fullscreenActive: topBarWindow.effectiveFullscreen
        onQuickPanelRequested: topBarWindow.quickPanelOpen = true
        onDismissQuickPanelRequested: quickPanelWindow.dismissImmediatelyForLauncher()
    }

    WallpaperTransitionOverlay {
        themeHub: themeHub
    }

    DesktopImageWidgets {
        themeHub: themeHub
        fullscreenActive: topBarWindow.effectiveFullscreen
    }

    BarExtraPopups {
        id: barExtraPopups
        themeHub: themeHub
        topBarWindow: topBarWindow
        fullscreenActive: topBarWindow.effectiveFullscreen
    }

    DockExtraCards {
        id: dockExtraCards
        themeHub: themeHub
        dockWindow: dockWindow
        fullscreenActive: topBarWindow.effectiveFullscreen
    }

    DesktopWidgets {
        themeHub: themeHub
        fullscreenActive: topBarWindow.effectiveFullscreen
    }
}
