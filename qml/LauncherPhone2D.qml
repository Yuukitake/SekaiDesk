import QtQuick
import QtQuick.Effects
import Quickshell
import SekaiDesk
import "ShelfMath.js" as SM

// Pure 2D Pixel-Aligned Launcher Phone (Alt+Space + in-phone Ctrl+Alt+V Clipboard).
// Matches SekaiPop's flat2d/faceDirect smartphone aesthetic: sharp typography,
// live desktop LCD wallpaper with RGB subpixel mesh, clock + live net speed,
// command rows, 4-column App Grid, and in-phone Clipboard with real image preview.
PanelWindow {
    id: phoneWin

    required property var themeHub
    required property bool fullscreenActive

    signal openQuickPanelRequested()

    // Design space 654 x 1214 scaled cleanly to fit any screen height
    readonly property int designW: 654
    readonly property int designH: 1214
    readonly property int headroom: 28
    readonly property int padX: 40
    readonly property real fitScale: Math.min(0.68, Math.max(0.46, (themeHub.screenH - 110) / (designH + headroom - 40)))
    readonly property int shownHeight: Math.round((designH + headroom - 40) * fitScale)
    readonly property real hiddenLift: designH + 60

    property bool shown: false
    property real lift: hiddenLift
    property double openedAt: 0

    // Live UI state
    property string clockText: "00:00AM"
    property string dateText: "Sun, 18 Oct"
    property string query: ""
    property bool keyNav: false
    property int rowPick: -1
    property int gridIndex: -1
    property int clipIndex: 0
    property string clipCurrentId: ""
    property string pendingConfirm: ""

    // Right-click app context menu inside phone
    property bool ctxOpen: false
    property var ctxApp: null
    property real ctxX: 0
    property real ctxY: 0

    // Modes: "" | "clip" | "calc" | "color"
    readonly property string trimmedQuery: query.trim()
    readonly property string lowerQuery: trimmedQuery.toLowerCase()
    readonly property bool isClipMode: /^(clip|clipboard|cb)(\s+.*)?$/i.test(trimmedQuery)
    readonly property string clipFilter: {
        const m = trimmedQuery.match(/^(?:clip|clipboard|cb)\s*(.*)$/i)
        return m ? (m[1] || "").trim().toLowerCase() : ""
    }
    readonly property string calcResult: evalMath(trimmedQuery)
    readonly property bool isCalcMode: !isClipMode && (/^calc(\s+.*)?$/i.test(trimmedQuery) || calcResult !== "")
    readonly property string colorHexValue: extractHexColor(trimmedQuery)
    readonly property bool isColorMode: !isClipMode && !isCalcMode && colorHexValue !== ""
    readonly property string cardMode: isClipMode ? "clip" : (isCalcMode ? "calc" : (isColorMode ? "color" : ""))
    readonly property bool cardShown: cardMode !== ""

    property real cardK: cardShown ? 1.0 : 0.0
    Behavior on cardK {
        enabled: phoneWin.shown && wanted
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    property bool allowOverFullscreen: false
    readonly property bool wanted: !!themeHub.spotlightOpen && (!fullscreenActive || allowOverFullscreen)

    function applyInitialQuery(initialQ) {
        const txt = String(initialQ || "")
        query = txt
        searchInput.text = txt
        searchInput.cursorPosition = txt.length
        keyNav = false
        rowPick = -1
        gridIndex = (txt.trim() !== "" && !cardShown) ? 0 : -1
        clipIndex = 0
        pendingConfirm = ""
        ctxOpen = false
        focusTimer.restart()
    }

    function closePhone() {
        ctxOpen = false
        pendingConfirm = ""
        themeHub.spotlightClosedAt = Date.now()
        themeHub.clipboardClosedAt = Date.now()
        themeHub.launcherInitialQuery = ""
        themeHub.spotlightOpen = false
    }

    onWantedChanged: {
        if (wanted) {
            GameModeService.setSpotlightOverride(true)
            exitAnim.stop()
            openedAt = Date.now()
            applyInitialQuery(themeHub.launcherInitialQuery || "")
            themeHub.launcherInitialQuery = ""
            shown = true
            if (lift > hiddenLift * 0.9)
                lift = hiddenLift
            enterAnim.restart()
            focusActivate()
            focusTimer.restart()
        } else if (shown) {
            enterAnim.stop()
            ctxOpen = false
            exitAnim.restart()
        } else {
            allowOverFullscreen = false
            GameModeService.setSpotlightOverride(false)
        }
    }

    Timer {
        id: focusTimer
        interval: 35
        onTriggered: {
            if (phoneWin.wanted) {
                phoneWin.focusActivate()
                searchInput.forceActiveFocus()
            }
        }
    }

    onWindowDeactivated: {
        if (themeHub.spotlightOpen && (Date.now() - openedAt) > 200)
            closePhone()
    }

    Timer {
        interval: 60
        repeat: true
        running: phoneWin.visible && phoneWin.wanted
        onTriggered: {
            if ((Date.now() - phoneWin.openedAt) > 250 && phoneWin.isPointerOutsideAndPressed())
                phoneWin.closePhone()
        }
    }

    SequentialAnimation {
        id: enterAnim
        NumberAnimation {
            target: phoneWin
            property: "lift"
            to: -16
            duration: 240
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: phoneWin
            property: "lift"
            to: 0
            duration: 130
            easing.type: Easing.OutQuad
        }
    }

    SequentialAnimation {
        id: exitAnim
        NumberAnimation {
            target: phoneWin
            property: "lift"
            to: -10
            duration: 85
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: phoneWin
            property: "lift"
            to: phoneWin.hiddenLift
            duration: 210
            easing.type: Easing.InCubic
        }
        ScriptAction {
            script: {
                if (!phoneWin.wanted) {
                    phoneWin.shown = false
                    phoneWin.lift = phoneWin.hiddenLift
                    phoneWin.query = ""
                    searchInput.text = ""
                    phoneWin.allowOverFullscreen = false
                    GameModeService.setSpotlightOverride(false)
                }
            }
        }
    }

    visible: shown && (!fullscreenActive || allowOverFullscreen)
    onVisibleChanged: {
        if (!visible && !wanted) {
            allowOverFullscreen = false
            GameModeService.setSpotlightOverride(false)
        }
    }
    clickThrough: false
    color: "transparent"

    width: Math.round((designW + padX * 2) * fitScale)
    height: shownHeight
    x: Math.round((themeHub.screenW - width) * 0.5)
    y: Math.max(24, themeHub.screenH - height)

    // Clock & Date Timer
    Timer {
        interval: 1000
        repeat: true
        running: phoneWin.shown
        triggeredOnStart: true
        onTriggered: {
            const d = new Date()
            let h = d.getHours()
            const ampm = h >= 12 ? "PM" : "AM"
            h = h % 12
            if (h === 0) h = 12
            const hh = String(h).padStart(2, "0")
            const mm = String(d.getMinutes()).padStart(2, "0")
            const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            phoneWin.clockText = hh + ":" + mm + ampm
            phoneWin.dateText = days[d.getDay()] + ", " + d.getDate() + " " + months[d.getMonth()]
        }
    }

    function formatRate(bps) {
        if (!bps || bps < 0)
            return "0 B/s"
        if (bps >= 1048576)
            return (bps / 1048576).toFixed(1) + " MB/s"
        if (bps >= 1024)
            return Math.round(bps / 1024) + " KB/s"
        return Math.round(bps) + " B/s"
    }

    function extractHexColor(raw) {
        const s = (raw || "").trim()
        const m6 = s.match(/^#?([0-9a-fA-F]{6})$/)
        if (m6 && (s.startsWith("#") || /^[0-9a-fA-F]{6}$/.test(s) && /[a-fA-F]/.test(s)))
            return "#" + m6[1].toUpperCase()
        const mColor = s.match(/^color\s+#?([0-9a-fA-F]{6})$/i)
        if (mColor)
            return "#" + mColor[1].toUpperCase()
        if (/^color$/i.test(s))
            return String(themeHub.accentB || "#4ECDC4").toUpperCase()
        return ""
    }

    function evalMath(raw) {
        let s = (raw || "").trim()
        if (s === "")
            return ""
        if (/^calc\s+/i.test(s))
            s = s.replace(/^calc\s+/i, "").trim()
        let expr = s
        if (expr.startsWith("="))
            expr = expr.slice(1).trim()
        else if (!/[+\-*/%()]/.test(expr) && !/\b(sqrt|pow|sin|cos|tan|abs|round|floor|ceil|pi)\b/i.test(expr))
            return ""
        if (expr === "")
            return ""

        const expanded = expr
            .replace(/\bpi\b/gi, "Math.PI")
            .replace(/\bsqrt\b/gi, "Math.sqrt")
            .replace(/\bpow\b/gi, "Math.pow")
            .replace(/\bsin\b/gi, "Math.sin")
            .replace(/\bcos\b/gi, "Math.cos")
            .replace(/\btan\b/gi, "Math.tan")
            .replace(/\babs\b/gi, "Math.abs")
            .replace(/\bround\b/gi, "Math.round")
            .replace(/\bfloor\b/gi, "Math.floor")
            .replace(/\bceil\b/gi, "Math.ceil")
            .replace(/\^/g, "**")

        const cleaned = expanded.replace(/Math\.(PI|sqrt|pow|sin|cos|tan|abs|round|floor|ceil)/g, "")
        if (!/^[0-9.\s+\-*/%(),xXa-fA-F]+$/.test(cleaned))
            return ""
        try {
            const fn = new Function("return (" + expanded + ")")
            const val = fn()
            if (typeof val === "number" && isFinite(val))
                return String(Math.round(val * 1000000) / 1000000)
        } catch (e) {}
        return ""
    }

    // Command catalog (system actions, PowerTools commands, widgets, Settings/Panel triggers)
    readonly property var systemCatalog: [
        { name: "Screenshot region",    sub: "Select an area, saved and copied",          keys: "screenshot snip capture region",     icon: "qrc:/qml/icons/camera-dark.svg",        act: "screenshot", confirm: false },
        { name: "Quick Panel",          sub: "Open or close the control phone panel",      keys: "quick panel control center",         icon: "qrc:/qml/icons/smartphone-dark.svg",    act: "quickpanel", confirm: false },
        { name: "SekaiDesk Settings",   sub: "Open Landscape Phone Settings Hub",          keys: "settings control hub config",        icon: "qrc:/qml/icons/settings-dark.svg",      act: "settings",   confirm: false },
        { name: "Wallpaper Selector",   sub: "Browse wallpapers & sync accent palette",    keys: "wallpaper background gallery",       icon: "qrc:/qml/icons/gallery-dark.svg",       act: "wallpapers", confirm: false },
        { name: "Drop Shelf",           sub: "Open collectible file & note shelf",         keys: "drop shelf tray files",              icon: "qrc:/qml/icons/folder-2-dark.svg",      act: "dropshelf",  confirm: false },
        { name: "Edit Desktop",         sub: "Arrange desktop widgets, bar & dock",        keys: "edit desktop widgets layout",        icon: "qrc:/qml/icons/palette-dark.svg",       act: "editdesktop", confirm: false },
        { name: "Audio Visualizer",     sub: "Toggle desktop audio visualizer",            keys: "visualizer audio spectrum music",    icon: "qrc:/qml/icons/music-note-dark.svg",    act: "visualizer", confirm: false },
        { name: "Empty Recycle Bin",    sub: "Clear all deleted files in Trash",           keys: "empty recycle bin trash",            icon: "qrc:/qml/icons/trash-bin-trash-dark.svg", act: "emptybin", confirm: true },
        { name: "Lock Workstation",     sub: "Lock Windows session (Win+L)",               keys: "lock workstation screen",            icon: "qrc:/qml/icons/lock-dark.svg",          act: "lock",       confirm: false },
        { name: "Sleep Computer",       sub: "Suspend Windows to sleep",                   keys: "sleep suspend",                      icon: "qrc:/qml/icons/moon-sleep-dark.svg",    act: "sleep",      confirm: false },
        { name: "Restart PC",           sub: "Reboot Windows computer",                    keys: "restart reboot reset",               icon: "qrc:/qml/icons/restart-dark.svg",       act: "restart",    confirm: true },
        { name: "Shut Down PC",         sub: "Power off Windows computer",                 keys: "shutdown shut down power off",       icon: "qrc:/qml/icons/power-dark.svg",         act: "shutdown",   confirm: true },
        { name: "Task Manager",         sub: "Inspect processes & CPU/RAM",                keys: "taskmgr task manager processes",     icon: "qrc:/qml/icons/monitor-dark.svg",       target: "taskmgr.exe", confirm: false },
        { name: "Display Settings",     sub: "Resolution, refresh & scaling",              keys: "display monitor resolution",         icon: "qrc:/qml/icons/monitor-dark.svg",       target: "ms-settings:display", confirm: false }
    ]

    function scoreCatalog(sc, qLow) {
        if (!qLow) return 0
        const nm = sc.name.toLowerCase()
        const keys = sc.keys.toLowerCase()
        const tok = keys.split(/\s+/)
        if (nm === qLow || (sc.act && sc.act === qLow)) return 120
        for (let i = 0; i < tok.length; ++i) {
            if (tok[i] === qLow) return 110
        }
        if (nm.startsWith(qLow) || keys.startsWith(qLow)) return 95
        for (let i = 0; i < tok.length; ++i) {
            if (tok[i].startsWith(qLow)) return 85
        }
        if (nm.includes(qLow) || keys.includes(qLow)) return 55
        return 0
    }

    // Ranked command rows shown above the 4-column App Grid when typing
    readonly property var commandRows: {
        const q = trimmedQuery
        const qLow = lowerQuery
        if (cardShown || q === "")
            return []

        const out = []

        // Explorer path autocomplete
        if (/^[a-zA-Z]:[\\/]/.test(q) || q.startsWith("~") || q.startsWith("\\\\") || q.startsWith("%")) {
            const paths = AppLauncher.listPathSuggestions(q)
            for (let i = 0; i < paths.length && out.length < 3; ++i) {
                const p = paths[i]
                const t = p.target || p.path || ""
                const isDir = (p.category === "Folder") || !!p.isDir
                out.push({
                    kind: "path",
                    name: p.name || t,
                    sub: t,
                    icon: isDir ? "qrc:/qml/icons/folder-2-dark.svg" : "qrc:/qml/icons/document-text-dark.svg",
                    target: t,
                    confirm: false
                })
            }
            return out
        }

        // Shell commands (> cmd or >ps cmd)
        if (q.startsWith(">")) {
            const body = q.slice(1).trim()
            if (body.toLowerCase().startsWith("ps ")) {
                const psCmd = body.slice(3).trim()
                out.push({
                    kind: "shell",
                    name: "PowerShell: " + (psCmd || "..."),
                    sub: "Run in Windows PowerShell",
                    icon: "qrc:/qml/icons/command-dark.svg",
                    target: "powershell.exe",
                    args: psCmd !== "" ? "-NoExit -Command \"" + psCmd.replace(/"/g, "\\\"") + "\"" : "",
                    confirm: false
                })
            } else {
                out.push({
                    kind: "shell",
                    name: "Run: " + (body || "..."),
                    sub: "Execute via cmd.exe",
                    icon: "qrc:/qml/icons/command-dark.svg",
                    target: "cmd.exe",
                    args: body !== "" ? "/k " + body : "",
                    confirm: false
                })
            }
            return out
        }

        // URLs & web engines
        if (/^https?:\/\/\S+/i.test(q) || /^[a-zA-Z0-9-]+\.(com|org|net|io|dev|vn|jp|gg|ai|edu)(\/\S*)?$/i.test(q)) {
            const fullUrl = /^https?:\/\//i.test(q) ? q : ("https://" + q)
            out.push({ kind: "url", name: "Open " + fullUrl, sub: "Open in default browser", icon: "qrc:/qml/icons/global-dark.svg", target: fullUrl, confirm: false })
        } else if (/^(g|gg|yt|gh|wiki|tr)\s+(.+)/i.test(q)) {
            const m = q.match(/^(g|gg|yt|gh|wiki|tr)\s+(.+)/i)
            const prefix = m[1].toLowerCase()
            const term = m[2].trim()
            const url = prefix === "yt" ? ("https://www.youtube.com/results?search_query=" + encodeURIComponent(term))
                : prefix === "gh" ? ("https://github.com/search?q=" + encodeURIComponent(term))
                : prefix === "wiki" ? ("https://en.wikipedia.org/wiki/Special:Search?search=" + encodeURIComponent(term))
                : prefix === "tr" ? ("https://translate.google.com/?sl=auto&tl=vi&text=" + encodeURIComponent(term) + "&op=translate")
                : ("https://www.google.com/search?q=" + encodeURIComponent(term))
            out.push({ kind: "url", name: "Web search: \"" + term + "\"", sub: url, icon: "qrc:/qml/icons/global-dark.svg", target: url, confirm: false })
        }

        // Theme bands (`theme ...`)
        if (qLow.startsWith("theme")) {
            const tq = qLow.replace(/^theme\s*/, "").trim()
            for (let b = 0; b < themeHub.bands.length && out.length < 3; ++b) {
                const band = themeHub.bands[b]
                if (tq === "" || band.name.toLowerCase().includes(tq) || band.id.includes(tq)) {
                    out.push({
                        kind: "theme",
                        name: "Theme: " + band.name,
                        sub: "Switch SekaiDesk unit palette",
                        icon: "qrc:/qml/icons/palette-dark.svg",
                        bandId: band.id,
                        confirm: false
                    })
                }
            }
        }

        // Unhide hidden drawer items (`unhide ...`)
        const isUnhideQuery = (qLow === "unhide" || qLow.startsWith("unhide "))
        if (isUnhideQuery) {
            const uq = qLow.replace(/^unhide\s*/, "").trim()
            const hiddenList = AppLauncher.hiddenApps || []
            for (let h = 0; h < hiddenList.length && out.length < 3; ++h) {
                const hi = hiddenList[h]
                const hName = hi.name || hi.target || ""
                const hTarget = hi.target || ""
                if (uq === "" || hName.toLowerCase().indexOf(uq) >= 0 || hTarget.toLowerCase().indexOf(uq) >= 0) {
                    out.push({
                        kind: "unhide",
                        name: "Unhide: " + hName,
                        sub: hTarget,
                        icon: "qrc:/qml/icons/restart-dark.svg",
                        target: hTarget,
                        confirm: false
                    })
                }
            }
            return out
        }

        // Scored system catalog matches
        const scored = []
        for (let s = 0; s < systemCatalog.length; ++s) {
            const sc = systemCatalog[s]
            const score = scoreCatalog(sc, qLow)
            if (score > 0) {
                scored.push({
                    score: score,
                    entry: {
                        kind: sc.act ? "sys" : "win",
                        id: sc.act || sc.name,
                        name: sc.name,
                        sub: sc.sub,
                        icon: sc.icon,
                        act: sc.act || "",
                        target: sc.target || "",
                        confirm: !!sc.confirm
                    }
                })
            }
        }
        scored.sort((a, b) => b.score - a.score)
        for (let k = 0; k < scored.length && out.length < 3; ++k)
            out.push(scored[k].entry)

        // Fallback Web Search when neither command rows nor apps match
        if (out.length === 0 && appEntries.length === 0) {
            out.push({
                kind: "url",
                name: "Search web for \u201c" + q + "\u201d",
                sub: "Open Google Search in browser",
                icon: "qrc:/qml/icons/global-dark.svg",
                target: "https://www.google.com/search?q=" + encodeURIComponent(q),
                confirm: false
            })
        }

        return out.slice(0, 3)
    }

    // Apps for 4-column grid: full A-Z catalog when empty, ranked + substring matches when searching
    readonly property var appEntries: {
        const installed = AppLauncher.installedApps || []
        const q = trimmedQuery
        const qLow = lowerQuery
        if (q === "") {
            const all = []
            for (let i = 0; i < installed.length; ++i) {
                const a = installed[i]
                if (a && a.target && !AppLauncher.isHidden(a.target))
                    all.push(a)
            }
            return all
        }
        const ranked = AppLauncher.searchApps(q) || []
        const seen = {}
        const merged = []
        for (let i = 0; i < ranked.length; ++i) {
            const a = ranked[i]
            const key = String(a.target || a.name || "").toLowerCase()
            if (key && !seen[key]) {
                seen[key] = true
                merged.push(a)
            }
        }
        for (let j = 0; j < installed.length && merged.length < 48; ++j) {
            const b = installed[j]
            if (!b || !b.target || AppLauncher.isHidden(b.target))
                continue
            const key = String(b.target || "").toLowerCase()
            if (!seen[key] && String(b.name || "").toLowerCase().indexOf(qLow) >= 0) {
                seen[key] = true
                merged.push(b)
            }
        }
        return merged
    }

    // Filtered Clipboard Entries preserving original ClipboardService index
    readonly property var filteredClipEntries: {
        const raw = ClipboardService.history || []
        const f = clipFilter
        const out = []
        for (let i = 0; i < raw.length; ++i) {
            const e = raw[i]
            if (!e) continue
            if (f !== "") {
                const prev = String(e.preview || "").toLowerCase()
                const txt = String(e.text || "").toLowerCase()
                if (prev.indexOf(f) < 0 && txt.indexOf(f) < 0)
                    continue
            }
            out.push({
                origIdx: i,
                id: e.id || ("row_" + i),
                isImage: !!e.isImage,
                imageUrl: e.imageUrl || "",
                imagePath: e.imagePath || "",
                text: e.text || "",
                preview: e.preview || "",
                time: e.time || "",
                chars: e.chars || 0,
                pinned: !!e.pinned
            })
        }
        return out
    }

    readonly property var currentClipEntry: (clipIndex >= 0 && clipIndex < filteredClipEntries.length)
        ? filteredClipEntries[clipIndex]
        : null

    readonly property bool hasUnpinnedClip: {
        const raw = ClipboardService.history || []
        for (let i = 0; i < raw.length; ++i) {
            if (!raw[i].pinned)
                return true
        }
        return false
    }

    onFilteredClipEntriesChanged: {
        let idx = -1
        if (clipCurrentId !== "") {
            for (let i = 0; i < filteredClipEntries.length; ++i) {
                if (filteredClipEntries[i].id === clipCurrentId) {
                    idx = i
                    break
                }
            }
        }
        if (idx < 0)
            idx = 0
        clipIndex = Math.max(0, Math.min(idx, Math.max(0, filteredClipEntries.length - 1)))
        clipCurrentId = (clipIndex >= 0 && clipIndex < filteredClipEntries.length)
            ? filteredClipEntries[clipIndex].id : ""
    }

    onClipIndexChanged: {
        clipCurrentId = (clipIndex >= 0 && clipIndex < filteredClipEntries.length)
            ? filteredClipEntries[clipIndex].id : ""
        if (clipList.visible && clipIndex >= 0)
            clipList.positionViewAtIndex(clipIndex, ListView.Contain)
    }

    onQueryChanged: {
        pendingConfirm = ""
        ctxOpen = false
        if (cardShown) {
            rowPick = -1
            gridIndex = -1
            keyNav = false
            return
        }
        const q = trimmedQuery
        if (q === "") {
            rowPick = -1
            gridIndex = -1
            keyNav = false
        } else if (commandRows.length > 0 && appEntries.length === 0) {
            rowPick = 0
            gridIndex = -1
            keyNav = true
        } else if (commandRows.length > 0 && commandRows[0].kind !== "url" && lowerQuery.length >= 2) {
            rowPick = 0
            gridIndex = -1
            keyNav = true
        } else if (appEntries.length > 0) {
            rowPick = -1
            gridIndex = 0
            keyNav = true
        } else {
            rowPick = commandRows.length > 0 ? 0 : -1
            gridIndex = -1
        }
        drawerGrid.positionViewAtBeginning()
    }

    function executeCommandRow(item) {
        if (!item) return
        if (item.confirm && pendingConfirm !== item.id) {
            pendingConfirm = item.id
            return
        }
        pendingConfirm = ""
        if (item.kind === "unhide") {
            AppLauncher.unhideApp(item.target)
            searchInput.text = ""
            return
        }
        if (item.kind === "theme") {
            themeHub.setBand(item.bandId)
            closePhone()
            return
        }
        if (item.kind === "sys") {
            closePhone()
            if (item.act === "screenshot") WindowTracker.takeScreenshot()
            else if (item.act === "quickpanel") openQuickPanelRequested()
            else if (item.act === "settings") themeHub.openSettings("")
            else if (item.act === "wallpapers") themeHub.wallpaperSelectorOpen = true
            else if (item.act === "dropshelf") themeHub.dropShelfOpen = true
            else if (item.act === "editdesktop") themeHub.setEditMode(true)
            else if (item.act === "visualizer") VisualizerService.enabled = !VisualizerService.enabled
            else if (item.act === "emptybin") TrashService.emptyTrash()
            else if (item.act === "lock") WindowTracker.lockWorkstation()
            else if (item.act === "sleep") WindowTracker.sleepComputer()
            else if (item.act === "restart") SystemControl.restartPc()
            else if (item.act === "shutdown") SystemControl.shutdownPc()
            return
        }
        if (item.target)
            AppLauncher.launch(item.target, item.args || "")
        closePhone()
    }

    function launchApp(app, modifiers) {
        if (!app || !app.target) return
        const mods = modifiers || 0
        const isCtrl = (mods & Qt.ControlModifier) !== 0
        const isShift = (mods & Qt.ShiftModifier) !== 0
        if (isCtrl) {
            AppLauncher.revealInExplorer(app.target)
            closePhone()
            return
        }
        AppLauncher.recordUsage(app.target)
        if (isShift)
            AppLauncher.runElevated(app.target, app.args || "")
        else
            AppLauncher.launch(app.target, app.args || "")
        closePhone()
    }

    function activateEnter(modifiers) {
        if (cardMode === "clip") {
            const e = currentClipEntry
            if (e) {
                ClipboardService.copyIndex(e.origIdx)
                closePhone()
            }
            return
        }
        if (cardMode === "calc") {
            if (calcResult !== "") {
                ClipboardService.copyText(calcResult)
                closePhone()
            }
            return
        }
        if (cardMode === "color") {
            if (colorHexValue !== "") {
                ClipboardService.copyText(colorHexValue)
                closePhone()
            }
            return
        }
        if (rowPick >= 0 && rowPick < commandRows.length) {
            executeCommandRow(commandRows[rowPick])
            return
        }
        let idx = gridIndex
        if (idx < 0 && appEntries.length > 0)
            idx = 0
        if (idx >= 0 && idx < appEntries.length)
            launchApp(appEntries[idx], modifiers)
    }

    function navigateKey(key) {
        if (cardMode === "clip") {
            if (filteredClipEntries.length === 0) return
            const step = (key === Qt.Key_Up || key === Qt.Key_Left) ? -1 : 1
            clipIndex = Math.max(0, Math.min(filteredClipEntries.length - 1, clipIndex + step))
            return
        }
        if (cardShown)
            return

        keyNav = true
        const nRows = commandRows.length
        const nApps = appEntries.length

        if (key === Qt.Key_Up) {
            if (rowPick > 0) {
                rowPick--
            } else if (rowPick === 0) {
                // Already at top
            } else if (gridIndex >= 0 && gridIndex < 4 && nRows > 0) {
                gridIndex = -1
                rowPick = nRows - 1
            } else if (gridIndex >= 4) {
                gridIndex = Math.max(0, gridIndex - 4)
                drawerGrid.positionViewAtIndex(gridIndex, GridView.Contain)
            }
            return
        }
        if (key === Qt.Key_Down) {
            if (rowPick >= 0) {
                if (rowPick + 1 < nRows) {
                    rowPick++
                } else if (nApps > 0) {
                    rowPick = -1
                    gridIndex = 0
                    drawerGrid.positionViewAtIndex(0, GridView.Contain)
                }
            } else if (gridIndex < 0) {
                if (nRows > 0) rowPick = 0
                else if (nApps > 0) gridIndex = 0
            } else if (nApps > 0) {
                gridIndex = Math.min(nApps - 1, gridIndex + 4)
                drawerGrid.positionViewAtIndex(gridIndex, GridView.Contain)
            }
            return
        }
        if (key === Qt.Key_Left) {
            if (nApps > 0) {
                rowPick = -1
                gridIndex = (gridIndex < 0) ? 0 : Math.max(0, gridIndex - 1)
                drawerGrid.positionViewAtIndex(gridIndex, GridView.Contain)
            }
            return
        }
        if (key === Qt.Key_Right) {
            if (nApps > 0) {
                rowPick = -1
                gridIndex = (gridIndex < 0) ? 0 : Math.min(nApps - 1, gridIndex + 1)
                drawerGrid.positionViewAtIndex(gridIndex, GridView.Contain)
            }
        }
    }

    // Scaled 2D Phone Design Container (654x1214)
    Item {
        id: phoneScaleBox
        x: Math.round(phoneWin.padX * phoneWin.fitScale)
        y: Math.round((phoneWin.headroom + phoneWin.lift) * phoneWin.fitScale)
        width: phoneWin.designW
        height: phoneWin.designH
        scale: phoneWin.fitScale
        transformOrigin: Item.TopLeft

        readonly property string wallPathRaw: WallpaperService.currentWallpaper || ""
        readonly property string wallUrl: SM.pathToFileUrl(wallPathRaw)
        readonly property bool lcdOn: wallUrl !== "" && lcdWallImg.status === Image.Ready
        property bool darkLeft: false
        property bool darkRight: false
        readonly property color inkLeft: lcdOn ? (darkLeft ? "#FFFFFF" : "#1A1B2E") : "#1A1B2E"
        readonly property color inkRight: lcdOn ? (darkRight ? "#FFFFFF" : "#1A1B2E") : "#1A1B2E"

        // Right-edge 2D Power / Dismiss hardware button
        Rectangle {
            x: 650
            y: 338
            width: 12
            height: 112
            radius: 6
            color: sidePowMa.containsMouse ? themeHub.accentB : "#3A3D5C"
            border.width: 3
            border.color: "#1A1B2E"
            antialiasing: true
            MouseArea {
                id: sidePowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: phoneWin.closePhone()
            }
        }

        // Authentic SekaiPop 9-slice soft airbrushed phone shadow
        BorderImage {
            x: -36
            y: -24
            width: phoneScaleBox.width + 72
            height: phoneScaleBox.height + 64
            source: "qrc:/qml/assets/phone-shadow.png"
            border { left: 140; top: 140; right: 140; bottom: 140 }
            opacity: 0.72
            smooth: true
        }

        // Outer 2D Phone Bezel
        Rectangle {
            id: phoneBezel
            anchors.fill: parent
            radius: 100
            color: "#2B2D42"
            border.width: 4
            border.color: "#1A1B2E"
            antialiasing: true

            // Inner Screen Bounds (18px bezel inset)
            Item {
                id: screenArea
                x: 18
                y: 18
                width: phoneScaleBox.width - 36
                height: phoneScaleBox.height - 36

                // Rounded LCD Mask (matches MultiEffect pattern in Shell.qml)
                Item {
                    id: screenMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: width > 8 && height > 8
                    layer.smooth: true
                    Rectangle {
                        anchors.fill: parent
                        radius: 82
                        color: "#FFFFFF"
                        antialiasing: true
                    }
                }

                // LCD Background Layer (Wallpaper + Backlight Falloff + RGB Mesh + Glass Reflection)
                Item {
                    id: lcdLayer
                    anchors.fill: parent
                    layer.enabled: width > 8 && height > 8
                    layer.smooth: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: screenMask
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "#F8FAFC"
                    }

                    Image {
                        id: lcdWallImg
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        mipmap: true
                        sourceSize: Qt.size(900, 1600)
                        source: phoneWin.shown ? phoneScaleBox.wallUrl : ""
                        visible: status === Image.Ready
                    }

                    // Subtle white wash over LCD wallpaper for readability
                    Rectangle {
                        anchors.fill: parent
                        visible: phoneScaleBox.lcdOn
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.12) }
                            GradientStop { position: 0.3; color: Qt.rgba(1, 1, 1, 0.04) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.05) }
                        }
                    }

                    // 4-edge LCD backlight falloff
                    readonly property color edgeTint: Qt.rgba(0.24, 0.24, 0.39, 0.06)
                    readonly property color edgeClear: Qt.rgba(0.24, 0.24, 0.39, 0.0)
                    Rectangle {
                        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 34
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: lcdLayer.edgeTint } GradientStop { position: 1; color: lcdLayer.edgeClear } }
                    }
                    Rectangle {
                        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 34
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: lcdLayer.edgeClear } GradientStop { position: 1; color: lcdLayer.edgeTint } }
                    }
                    Rectangle {
                        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 34
                        gradient: Gradient { GradientStop { position: 0; color: lcdLayer.edgeTint } GradientStop { position: 1; color: lcdLayer.edgeClear } }
                    }

                    // Authentic SekaiPop 24x24 RGB LCD subpixel mesh (scaled 8/24 -> 8px pitch)
                    Item {
                        readonly property real k: 8.0 / 24.0
                        width: lcdLayer.width / k
                        height: lcdLayer.height / k
                        scale: k
                        transformOrigin: Item.TopLeft
                        opacity: phoneScaleBox.lcdOn ? 0.95 : 0.30

                        Image {
                            anchors.fill: parent
                            source: "qrc:/qml/assets/lcd-mesh.png"
                            fillMode: Image.Tile
                            smooth: true
                            mipmap: true
                        }
                    }

                    // Soft glass glare band
                    Rectangle {
                        width: lcdLayer.width * 2.2
                        height: 190
                        x: lcdLayer.width / 2 - width / 2
                        y: lcdLayer.height * 0.20 - height / 2
                        rotation: -20
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
                            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.16) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
                        }
                    }
                }

                // Hidden Luminance Sampler for Top-Left Clock & Top-Right Net Speed Ink
                Canvas {
                    id: lumSampler
                    width: 62
                    height: 118
                    visible: false
                    renderTarget: Canvas.Image
                    renderStrategy: Canvas.Immediate

                    property string loadedSrc: ""
                    readonly property string wantSrc: (phoneWin.shown && phoneScaleBox.lcdOn) ? phoneScaleBox.wallUrl : ""

                    onWantSrcChanged: {
                        if (loadedSrc !== "" && loadedSrc !== wantSrc)
                            unloadImage(loadedSrc)
                        loadedSrc = wantSrc
                        if (wantSrc !== "") {
                            if (isImageLoaded(wantSrc))
                                requestPaint()
                            else
                                loadImage(wantSrc)
                        } else {
                            phoneScaleBox.darkLeft = false
                            phoneScaleBox.darkRight = false
                        }
                    }
                    onImageLoaded: requestPaint()

                    function regionBrightness(ctx, rx, ry, rw, rh) {
                        const d = ctx.getImageData(rx, ry, rw, rh).data
                        let sum = 0
                        let n = 0
                        for (let i = 0; i < d.length; i += 4) {
                            if (d[i + 3] === 0) continue
                            const r = Math.pow(d[i] / 255, 2.2)
                            const g = Math.pow(d[i + 1] / 255, 2.2)
                            const b = Math.pow(d[i + 2] / 255, 2.2)
                            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
                            n++
                        }
                        return n > 0 ? (sum / n) : 1.0
                    }

                    onPaint: {
                        if (loadedSrc === "" || !isImageLoaded(loadedSrc))
                            return
                        const iw = Math.max(1, lcdWallImg.implicitWidth)
                        const ih = Math.max(1, lcdWallImg.implicitHeight)
                        const asp = iw / ih
                        const cAsp = width / height
                        let dx = 0, dy = 0, dw = width, dh = height
                        if (asp > cAsp) {
                            dw = height * asp
                            dx = (width - dw) * 0.5
                        } else {
                            dh = width / asp
                            dy = (height - dh) * 0.5
                        }
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.drawImage(loadedSrc, dx, dy, dw, dh)
                        phoneScaleBox.darkLeft = regionBrightness(ctx, 5, 2, 12, 5) < 0.30
                        phoneScaleBox.darkRight = regionBrightness(ctx, 42, 2, 15, 5) < 0.30
                    }
                }
            }

            // Center Dynamic Notch + Camera Lens (design coords relative to phoneBezel)
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 14
                width: 170
                height: 36
                radius: 18
                color: "#1A1B2E"
                z: 40

                Rectangle {
                    x: 46
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48
                    height: 6
                    radius: 3
                    color: "#334155"
                }
                Rectangle {
                    x: 112
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    height: 14
                    radius: 7
                    color: "#0F172A"
                    border.width: 2
                    border.color: "#334155"
                    Rectangle {
                        anchors.centerIn: parent
                        width: 5
                        height: 5
                        radius: 2.5
                        color: "#38BDF8"
                        opacity: 0.75
                    }
                }
            }

            // ===== Top Status Strip: Clock/Date (Left) & Live Net Speed (Right) =====
            Column {
                x: 67
                y: 36
                spacing: -5
                z: 30

                Text {
                    text: phoneWin.clockText
                    color: phoneScaleBox.inkLeft
                    style: phoneScaleBox.lcdOn && phoneScaleBox.darkLeft ? Text.Outline : Text.Normal
                    styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.6)
                    font.family: "Segoe UI"
                    font.pixelSize: 24
                    font.weight: Font.Black
                }
                Text {
                    text: phoneWin.dateText
                    color: phoneScaleBox.inkLeft
                    font.family: "Segoe UI"
                    font.pixelSize: 18
                    font.weight: Font.Bold
                }
            }

            Column {
                x: 654 - 67 - 150
                y: 38
                width: 150
                spacing: -1
                z: 30

                Item {
                    width: 150
                    height: 24
                    Image {
                        id: dlIco
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        smooth: true
                        source: (phoneScaleBox.lcdOn && phoneScaleBox.darkRight)
                            ? "qrc:/qml/icons/arrow-down-light.svg"
                            : "qrc:/qml/icons/arrow-down-dark.svg"
                    }
                    Text {
                        anchors.right: dlIco.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: phoneWin.formatRate(WindowTracker.downloadBps)
                        color: phoneScaleBox.inkRight
                        font.family: "Segoe UI"
                        font.pixelSize: 18
                        font.weight: Font.Black
                    }
                }

                Item {
                    width: 150
                    height: 24
                    Image {
                        id: ulIco
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        smooth: true
                        source: (phoneScaleBox.lcdOn && phoneScaleBox.darkRight)
                            ? "qrc:/qml/icons/arrow-up-light.svg"
                            : "qrc:/qml/icons/arrow-up-dark.svg"
                    }
                    Text {
                        anchors.right: ulIco.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: phoneWin.formatRate(WindowTracker.uploadBps)
                        color: phoneScaleBox.inkRight
                        font.family: "Segoe UI"
                        font.pixelSize: 17
                        font.weight: Font.Bold
                    }
                }
            }

            // ===== Search Pill =====
            readonly property real sideX: 52
            readonly property real gridW: 550

            Rectangle {
                x: phoneBezel.sideX + 4
                y: 124 + 4
                width: phoneBezel.gridW
                height: 68
                radius: 34
                color: "#1A1B2E"
                antialiasing: true
                z: 30
            }

            Rectangle {
                id: searchPill
                x: phoneBezel.sideX
                y: 124
                width: phoneBezel.gridW
                height: 68
                radius: 34
                color: "#FFFFFF"
                border.width: 3.5
                border.color: "#1A1B2E"
                antialiasing: true
                z: 31

                Image {
                    x: 24
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    smooth: true
                    source: "qrc:/qml/icons/magnifer-dark.svg"
                }

                Text {
                    x: 68
                    anchors.verticalCenter: parent.verticalCenter
                    visible: searchInput.text.length === 0
                    text: "Search apps, clip, calc, #hex..."
                    color: "#94A3B8"
                    font.family: "Segoe UI"
                    font.pixelSize: 22
                    font.weight: Font.Bold
                }

                TextInput {
                    id: searchInput
                    x: 68
                    width: parent.width - 68 - 62
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#1A1B2E"
                    selectionColor: themeHub.accentA
                    selectedTextColor: "#1A1B2E"
                    font.family: "Segoe UI"
                    font.pixelSize: 23
                    font.weight: Font.Black
                    clip: true
                    focus: true
                    selectByMouse: true

                    onTextChanged: phoneWin.query = text

                    Keys.onPressed: event => {
                        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                        if (ctrl && event.key === Qt.Key_1) {
                            phoneWin.closePhone()
                            phoneWin.openQuickPanelRequested()
                        } else if (ctrl && event.key === Qt.Key_3) {
                            phoneWin.closePhone()
                            themeHub.wallpaperSelectorOpen = true
                        } else if (ctrl && event.key === Qt.Key_4) {
                            phoneWin.closePhone()
                            themeHub.openSettings("")
                        } else if (ctrl && event.key === Qt.Key_P && phoneWin.cardMode === "clip") {
                            if (phoneWin.currentClipEntry)
                                ClipboardService.togglePin(phoneWin.currentClipEntry.origIdx)
                        } else if (event.key === Qt.Key_Escape) {
                            if (phoneWin.ctxOpen) {
                                phoneWin.ctxOpen = false
                            } else if (searchInput.text.length > 0) {
                                searchInput.text = ""
                            } else {
                                phoneWin.closePhone()
                            }
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            phoneWin.activateEnter(event.modifiers)
                        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                            phoneWin.navigateKey(event.key)
                        } else if ((event.key === Qt.Key_Left || event.key === Qt.Key_Right) &&
                                   (searchInput.text.length === 0 || phoneWin.cardShown)) {
                            phoneWin.navigateKey(event.key)
                        } else {
                            return
                        }
                        event.accepted = true
                    }
                }

                Item {
                    visible: searchInput.text.length > 0
                    x: parent.width - 56
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40

                    Rectangle {
                        anchors.fill: parent
                        radius: 20
                        color: clrMa.containsMouse ? themeHub.accentB : "transparent"
                    }
                    Image {
                        anchors.centerIn: parent
                        width: 22
                        height: 22
                        smooth: true
                        source: "qrc:/qml/icons/close-circle-dark.svg"
                    }
                    MouseArea {
                        id: clrMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            searchInput.text = ""
                            searchInput.forceActiveFocus()
                        }
                    }
                }
            }

            // ===== Page Region Below Search Pill =====
            readonly property real pageY: 214
            readonly property real visibleBottom: phoneWin.designH - 58
            readonly property real pageH: visibleBottom - pageY
            readonly property int rowH: 62
            readonly property int rowGap: 8
            readonly property real rowsTarget: (!phoneWin.cardShown && phoneWin.commandRows.length > 0)
                ? (phoneWin.commandRows.length * rowH + (phoneWin.commandRows.length - 1) * rowGap + 12)
                : 0
            property real rowsHeight: rowsTarget
            Behavior on rowsHeight {
                enabled: phoneWin.shown && phoneWin.wanted
                NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
            }

            // ---- Command Rows (System actions, paths, > cmd, web search) ----
            Column {
                id: cmdCol
                x: phoneBezel.sideX
                y: phoneBezel.pageY
                width: phoneBezel.gridW
                spacing: phoneBezel.rowGap
                visible: !phoneWin.cardShown && phoneWin.commandRows.length > 0
                opacity: 1.0 - phoneWin.cardK
                z: 25

                Repeater {
                    model: phoneWin.commandRows
                    delegate: Item {
                        required property var modelData
                        required property int index
                        readonly property bool sel: phoneWin.keyNav && phoneWin.rowPick === index
                        readonly property bool askConfirm: modelData.confirm && phoneWin.pendingConfirm === modelData.id

                        width: cmdCol.width
                        height: phoneBezel.rowH

                        Rectangle {
                            x: 3; y: 3
                            width: parent.width - 3; height: parent.height - 3
                            radius: height / 2
                            color: "#1A1B2E"
                            antialiasing: true
                        }
                        Rectangle {
                            x: 0; y: 0
                            width: parent.width - 3; height: parent.height - 3
                            radius: height / 2
                            color: askConfirm ? "#FDA4AF" : ((sel || rowMa.containsMouse) ? themeHub.accentB : "#FFFFFF")
                            border.width: sel ? 3.5 : 2.5
                            border.color: "#1A1B2E"
                            antialiasing: true

                            Rectangle {
                                x: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: 38; height: 38; radius: 19
                                color: sel ? Qt.rgba(1, 1, 1, 0.6) : "#F1F5F9"
                                Image {
                                    anchors.centerIn: parent
                                    width: 20; height: 20; smooth: true
                                    source: modelData.icon || "qrc:/qml/icons/command-dark.svg"
                                }
                            }

                            Column {
                                x: 60
                                width: parent.width - 78
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: askConfirm ? ("Press Enter again to " + modelData.name) : modelData.name
                                    font.family: "Segoe UI"
                                    font.pixelSize: 17
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.sub || ""
                                    font.family: "Segoe UI"
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                    color: "#475569"
                                }
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: { phoneWin.rowPick = index; phoneWin.gridIndex = -1 }
                                onClicked: {
                                    const rowCopy = modelData
                                    Qt.callLater(() => phoneWin.executeCommandRow(rowCopy))
                                }
                            }
                        }
                    }
                }
            }

            // ---- 4-Column Scrollable App Grid ----
            Item {
                id: drawerPage
                x: phoneBezel.sideX
                y: phoneBezel.pageY + phoneBezel.rowsHeight
                width: phoneBezel.gridW
                height: Math.max(120, phoneBezel.pageH - phoneBezel.rowsHeight)
                opacity: 1.0 - phoneWin.cardK
                scale: 1.0 - 0.025 * phoneWin.cardK
                transformOrigin: Item.Top
                visible: opacity > 0.01
                enabled: phoneWin.cardK < 0.5
                z: 20

                readonly property real cellW: phoneBezel.gridW / 4
                readonly property real cellH: 158

                Component {
                    id: appPickPlate
                    Item {
                        width: drawerPage.cellW
                        height: drawerPage.cellH
                        visible: phoneWin.keyNav && phoneWin.rowPick < 0 && phoneWin.gridIndex >= 0

                        Rectangle {
                            x: 8; y: 6; width: parent.width - 14; height: parent.height - 10; radius: 24
                            color: "#1A1B2E"; antialiasing: true
                        }
                        Rectangle {
                            x: 4; y: 2; width: parent.width - 14; height: parent.height - 10; radius: 24
                            color: themeHub.accentB; border.width: 3.5; border.color: "#1A1B2E"; antialiasing: true
                        }
                    }
                }

                GridView {
                    id: drawerGrid
                    anchors.fill: parent
                    cellWidth: drawerPage.cellW
                    cellHeight: drawerPage.cellH
                    clip: true
                    model: phoneWin.appEntries
                    currentIndex: phoneWin.gridIndex
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: drawerPage.cellH * 3
                    highlight: appPickPlate
                    highlightFollowsCurrentItem: true
                    highlightMoveDuration: 90
                    bottomMargin: 44

                    delegate: Item {
                        id: appTile
                        required property var modelData
                        required property int index

                        readonly property bool picked: phoneWin.keyNav && phoneWin.rowPick < 0 && GridView.isCurrentItem
                        readonly property bool lit: tileMa.containsMouse || picked
                        property real litP: lit ? 1.0 : 0.0
                        Behavior on litP { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        property real pressP: tileMa.pressed ? 1.0 : 0.0
                        Behavior on pressP {
                            NumberAnimation {
                                duration: tileMa.pressed ? 80 : 260
                                easing.type: tileMa.pressed ? Easing.OutQuad : Easing.OutBack
                                easing.overshoot: tileMa.pressed ? 0 : 2.2
                            }
                        }

                        width: drawerPage.cellW
                        height: drawerPage.cellH

                        Image {
                            id: appIco
                            x: Math.round((parent.width - 72) / 2)
                            y: 16
                            width: 72
                            height: 72
                            sourceSize.width: 96
                            sourceSize.height: 96
                            asynchronous: true
                            smooth: true
                            mipmap: true
                            fillMode: Image.PreserveAspectFit
                            source: modelData.target ? ("image://winicon/" + encodeURIComponent(modelData.target)) : ""
                            scale: (1.0 + 0.10 * appTile.litP) * (1.0 - 0.08 * appTile.pressP)
                            transformOrigin: Item.Center
                        }

                        Rectangle {
                            visible: appIco.status === Image.Error || appIco.source === ""
                            x: Math.round((parent.width - 72) / 2)
                            y: 16
                            width: 72; height: 72; radius: 20
                            color: themeHub.accentA; border.width: 3; border.color: "#1A1B2E"
                            scale: appIco.scale
                            Text {
                                anchors.centerIn: parent
                                text: String(modelData.name || "?").slice(0, 1).toUpperCase()
                                font.family: "Segoe UI"; font.pixelSize: 30; font.weight: Font.Black; color: "#1A1B2E"
                            }
                        }

                        Text {
                            x: 6
                            y: 96
                            width: parent.width - 12
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            lineHeight: 0.90
                            elide: Text.ElideRight
                            text: modelData.name || ""
                            color: appTile.picked ? "#1A1B2E" : (phoneScaleBox.lcdOn ? "#FFFFFF" : "#1A1B2E")
                            style: (phoneScaleBox.lcdOn && !appTile.picked) ? Text.Outline : Text.Normal
                            styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.88)
                            font.family: "Segoe UI"
                            font.pixelSize: 16
                            font.weight: Font.Black
                        }

                        MouseArea {
                            id: tileMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: {
                                if (phoneWin.keyNav && phoneWin.gridIndex !== appTile.index)
                                    phoneWin.keyNav = false
                            }
                            onClicked: mouse => {
                                if (mouse.button === Qt.RightButton) {
                                    phoneWin.ctxApp = appTile.modelData
                                    const posInBezel = appTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                    phoneWin.ctxX = Math.max(40, Math.min(phoneBezel.width - 230, posInBezel.x))
                                    phoneWin.ctxY = Math.max(180, Math.min(phoneBezel.height - 200, posInBezel.y))
                                    phoneWin.ctxOpen = true
                                } else {
                                    const appCopy = appTile.modelData
                                    const mods = mouse.modifiers
                                    phoneWin.ctxOpen = false
                                    Qt.callLater(() => phoneWin.launchApp(appCopy, mods))
                                }
                            }
                        }
                    }
                }

                // Grid scrollbar cue
                Rectangle {
                    visible: drawerGrid.contentHeight > drawerGrid.height
                    x: phoneBezel.gridW + 8
                    y: (drawerGrid.height - height) * (drawerGrid.contentY / Math.max(1, drawerGrid.contentHeight - drawerGrid.height))
                    width: 6
                    height: Math.max(30, drawerGrid.height * drawerGrid.height / Math.max(1, drawerGrid.contentHeight))
                    radius: 3
                    color: Qt.rgba(0.10, 0.11, 0.18, 0.35)
                }

                Text {
                    anchors.centerIn: parent
                    visible: phoneWin.trimmedQuery !== "" && phoneWin.appEntries.length === 0 && phoneWin.commandRows.length === 0
                    text: "No apps match"
                    color: phoneScaleBox.lcdOn ? "#FFFFFF" : "#475569"
                    style: phoneScaleBox.lcdOn ? Text.Outline : Text.Normal
                    styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.85)
                    font.family: "Segoe UI"
                    font.pixelSize: 22
                    font.weight: Font.Black
                }
            }

            // ===== Inline Mode Cards Layer (Clipboard with Image Preview, Calc, Color) =====
            Item {
                id: cardLayer
                x: phoneBezel.sideX
                y: phoneBezel.pageY
                width: phoneBezel.gridW
                height: phoneBezel.pageH
                opacity: phoneWin.cardK
                visible: opacity > 0.01
                enabled: phoneWin.cardK > 0.5
                z: 28

                // ---- CARD 1: Clipboard History (Screenshot 2 parity) ----
                Item {
                    id: clipCard
                    anchors.fill: parent
                    visible: phoneWin.cardMode === "clip"

                    readonly property real headH: 42
                    readonly property real rowH: 54
                    readonly property real rowGap: 8
                    readonly property real listY: headH + 10
                    readonly property real sheetWant: 318
                    readonly property real listH: Math.max(180, clipCard.height - listY - sheetWant - 14)

                    // Header: Clipboard icon + title + Clear + count chip
                    Item {
                        width: clipCard.width
                        height: clipCard.headH

                        Image {
                            id: clipHdrIco
                            x: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26; height: 26; smooth: true
                            source: "qrc:/qml/icons/clipboard-add-dark.svg"
                        }

                        Text {
                            anchors.left: clipHdrIco.right
                            anchors.leftMargin: 10
                            anchors.right: clearClipBtn.visible ? clearClipBtn.left : countBadge.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: phoneWin.clipFilter === "" ? "Clipboard" : ("Matching \u201c" + phoneWin.clipFilter + "\u201d")
                            color: phoneScaleBox.lcdOn ? "#FFFFFF" : "#1A1B2E"
                            style: phoneScaleBox.lcdOn ? Text.Outline : Text.Normal
                            styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.85)
                            font.family: "Segoe UI"
                            font.pixelSize: 24
                            font.weight: Font.Black
                        }

                        Rectangle {
                            id: clearClipBtn
                            visible: phoneWin.hasUnpinnedClip
                            anchors.right: countBadge.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 72; height: 32; radius: 16
                            color: clrAllMa.containsMouse ? "#FECDD3" : "#FFFFFF"
                            border.width: 2.5; border.color: "#1A1B2E"; antialiasing: true
                            Text { anchors.centerIn: parent; text: "Clear"; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                            MouseArea {
                                id: clrAllMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: ClipboardService.clearUnpinned()
                            }
                        }

                        Item {
                            id: countBadge
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(54, countTxt.implicitWidth + 30)
                            height: 36

                            Rectangle { x: 3; y: 3; width: parent.width; height: parent.height; radius: height / 2; color: "#1A1B2E"; antialiasing: true }
                            Rectangle {
                                anchors.fill: parent; radius: height / 2; color: themeHub.accentA; border.width: 2.5; border.color: "#1A1B2E"; antialiasing: true
                                Text {
                                    id: countTxt; anchors.centerIn: parent
                                    text: phoneWin.filteredClipEntries.length
                                    font.family: "Segoe UI"; font.pixelSize: 17; font.weight: Font.Black; color: "#1A1B2E"
                                }
                            }
                        }
                    }

                    // Clipboard entries list
                    ListView {
                        id: clipList
                        x: 0
                        y: clipCard.listY
                        width: clipCard.width
                        height: clipCard.listH
                        clip: true
                        spacing: clipCard.rowGap
                        boundsBehavior: Flickable.StopAtBounds
                        model: phoneWin.filteredClipEntries
                        currentIndex: phoneWin.clipIndex
                        visible: phoneWin.filteredClipEntries.length > 0

                        delegate: Item {
                            id: cRow
                            required property var modelData
                            required property int index
                            readonly property bool sel: index === phoneWin.clipIndex

                            width: clipList.width
                            height: clipCard.rowH

                            Rectangle { x: 3; y: 3; width: parent.width - 3; height: parent.height - 3; radius: height / 2; color: "#1A1B2E"; antialiasing: true }
                            Rectangle {
                                x: 0; y: 0; width: parent.width - 3; height: parent.height - 3; radius: height / 2
                                color: cRow.sel ? "#FDA4AF" : (cRowMa.containsMouse ? "#F1F5F9" : "#FFFFFF")
                                border.width: cRow.sel ? 3.5 : 2.5
                                border.color: "#1A1B2E"
                                antialiasing: true

                                Rectangle {
                                    id: cGlyph
                                    x: 12; anchors.verticalCenter: parent.verticalCenter
                                    width: 34; height: 34; radius: 17
                                    color: cRow.sel ? Qt.rgba(1, 1, 1, 0.55) : "#F1F5F9"
                                    Image {
                                        anchors.centerIn: parent; width: 18; height: 18; smooth: true
                                        source: modelData.pinned
                                            ? "qrc:/qml/icons/pin-dark.svg"
                                            : (modelData.isImage
                                                ? "qrc:/qml/icons/gallery-dark.svg"
                                                : "qrc:/qml/icons/document-text-dark.svg")
                                    }
                                }

                                Text {
                                    anchors.left: cGlyph.right
                                    anchors.leftMargin: 12
                                    anchors.right: parent.right
                                    anchors.rightMargin: 20
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    text: modelData.preview || ""
                                    color: "#1A1B2E"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 18
                                    font.weight: cRow.sel ? Font.Black : Font.Bold
                                }
                            }

                            MouseArea {
                                id: cRowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: phoneWin.clipIndex = cRow.index
                                onDoubleClicked: {
                                    const origIdx = cRow.modelData.origIdx
                                    Qt.callLater(() => {
                                        ClipboardService.copyIndex(origIdx)
                                        phoneWin.closePhone()
                                    })
                                }
                            }
                        }
                    }

                    // Empty clipboard message
                    Text {
                        x: 20; y: clipCard.listY + 40
                        width: clipCard.width - 40
                        visible: phoneWin.filteredClipEntries.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: phoneWin.clipFilter !== ""
                            ? "Nothing in your clipboard history matches that."
                            : "Nothing copied yet.\nCopy text or a screenshot and it shows up here."
                        color: phoneScaleBox.lcdOn ? "#FFFFFF" : "#475569"
                        style: phoneScaleBox.lcdOn ? Text.Outline : Text.Normal
                        styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.85)
                        font.family: "Segoe UI"
                        font.pixelSize: 19
                        font.weight: Font.Black
                    }

                    // List scrollbar cue
                    Rectangle {
                        visible: clipList.visible && clipList.contentHeight > clipList.height
                        x: clipCard.width + 8
                        y: clipList.y + (clipList.height - height) * (clipList.contentY / Math.max(1, clipList.contentHeight - clipList.height))
                        width: 6
                        height: Math.max(28, clipList.height * clipList.height / Math.max(1, clipList.contentHeight))
                        radius: 3
                        color: Qt.rgba(0.10, 0.11, 0.18, 0.35)
                    }

                    // Bottom Preview Sheet (shows real copied screenshot or full selectable text)
                    Item {
                        id: clipSheetWrap
                        y: clipCard.height - clipCard.sheetWant
                        width: clipCard.width
                        height: clipCard.sheetWant

                        Rectangle { x: 4; y: 4; width: parent.width - 4; height: parent.height - 4; radius: 28; color: "#1A1B2E"; antialiasing: true }
                        Rectangle {
                            id: clipSheet
                            x: 0; y: 0; width: parent.width - 4; height: parent.height - 4; radius: 28
                            color: "#FFFFFF"; border.width: 3; border.color: "#1A1B2E"; antialiasing: true

                            // Preview Well
                            Rectangle {
                                id: previewWell
                                x: 14; y: 14
                                width: clipSheet.width - 28
                                height: clipSheet.height - 28 - 54
                                radius: 18
                                color: "#F1F5F9"
                                border.width: 2
                                border.color: "#CBD5E1"
                                clip: true

                                Flickable {
                                    id: clipTextFlick
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    visible: phoneWin.currentClipEntry !== null && !phoneWin.currentClipEntry.isImage
                                    contentWidth: width
                                    contentHeight: clipTextBody.implicitHeight
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds

                                    TextEdit {
                                        id: clipTextBody
                                        width: clipTextFlick.width
                                        readOnly: true
                                        selectByMouse: true
                                        wrapMode: TextEdit.Wrap
                                        text: (phoneWin.currentClipEntry && !phoneWin.currentClipEntry.isImage) ? phoneWin.currentClipEntry.text : ""
                                        color: "#1A1B2E"
                                        selectionColor: themeHub.accentA
                                        selectedTextColor: "#1A1B2E"
                                        font.family: "Consolas"
                                        font.pixelSize: 16
                                    }
                                }

                                Image {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    visible: phoneWin.currentClipEntry !== null && phoneWin.currentClipEntry.isImage
                                    source: (phoneWin.currentClipEntry && phoneWin.currentClipEntry.isImage) ? phoneWin.currentClipEntry.imageUrl : ""
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    cache: false
                                    smooth: true
                                    sourceSize: Qt.size(900, 900)
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: phoneWin.currentClipEntry === null
                                    text: "Pick something above"
                                    font.family: "Segoe UI"; font.pixelSize: 18; font.weight: Font.Bold; color: "#64748B"
                                }
                            }

                            // Footer Bar: info text + Pin + Delete + Copy pill
                            Item {
                                x: 14
                                y: clipSheet.height - 54
                                width: clipSheet.width - 28
                                height: 42

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: actionBtns.left
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    text: {
                                        const e = phoneWin.currentClipEntry
                                        if (!e) return ""
                                        return e.isImage ? e.preview : (e.chars + " chars \u00B7 " + e.time)
                                    }
                                    color: "#475569"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 15
                                    font.weight: Font.Bold
                                }

                                Row {
                                    id: actionBtns
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 8
                                    visible: phoneWin.currentClipEntry !== null

                                    // Pin toggle circle
                                    Rectangle {
                                        width: 38; height: 38; radius: 19
                                        color: (phoneWin.currentClipEntry && phoneWin.currentClipEntry.pinned)
                                            ? themeHub.accentB
                                            : (pinMa.containsMouse ? "#E2E8F0" : "#F8FAFC")
                                        border.width: 2.5; border.color: "#1A1B2E"; antialiasing: true
                                        Image { anchors.centerIn: parent; width: 17; height: 17; smooth: true; source: "qrc:/qml/icons/pin-dark.svg" }
                                        MouseArea {
                                            id: pinMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (phoneWin.currentClipEntry)
                                                    ClipboardService.togglePin(phoneWin.currentClipEntry.origIdx)
                                            }
                                        }
                                    }

                                    // Trash circle
                                    Rectangle {
                                        width: 38; height: 38; radius: 19
                                        color: delMa.containsMouse ? "#FDA4AF" : "#FFE4E6"
                                        border.width: 2.5; border.color: "#1A1B2E"; antialiasing: true
                                        Image { anchors.centerIn: parent; width: 17; height: 17; smooth: true; source: "qrc:/qml/icons/trash-bin-trash-dark.svg" }
                                        MouseArea {
                                            id: delMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (phoneWin.currentClipEntry)
                                                    ClipboardService.removeIndex(phoneWin.currentClipEntry.origIdx)
                                            }
                                        }
                                    }

                                    // Copy pill
                                    Item {
                                        width: 96; height: 38
                                        Rectangle { x: 2; y: 2; width: parent.width; height: parent.height; radius: 19; color: "#1A1B2E"; antialiasing: true }
                                        Rectangle {
                                            x: copyMa.pressed ? 1 : 0; y: copyMa.pressed ? 1 : 0
                                            width: parent.width; height: parent.height; radius: 19
                                            color: copyMa.containsMouse ? themeHub.accentB : "#FDA4AF"
                                            border.width: 2.5; border.color: "#1A1B2E"; antialiasing: true
                                            Text { anchors.centerIn: parent; text: "Copy"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: "#1A1B2E" }
                                            MouseArea {
                                                id: copyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (phoneWin.currentClipEntry) {
                                                        ClipboardService.copyIndex(phoneWin.currentClipEntry.origIdx)
                                                        phoneWin.closePhone()
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

                // ---- CARD 2: Calculator ----
                Item {
                    anchors.fill: parent
                    visible: phoneWin.cardMode === "calc"

                    Rectangle { x: 4; y: 4; width: parent.width - 4; height: 210; radius: 28; color: "#1A1B2E" }
                    Rectangle {
                        width: parent.width - 4; height: 210; radius: 28
                        color: "#FFFFFF"; border.width: 3; border.color: "#1A1B2E"
                        Column {
                            anchors.fill: parent; anchors.margins: 24; spacing: 14
                            Row {
                                spacing: 10
                                Image { anchors.verticalCenter: parent.verticalCenter; width: 24; height: 24; source: "qrc:/qml/icons/calculator-dark.svg" }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Calculator"; font.family: "Segoe UI"; font.pixelSize: 22; font.weight: Font.Black; color: "#1A1B2E" }
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: phoneWin.calcResult !== "" ? ("= " + phoneWin.calcResult) : "Type an expression (e.g. 24 * 15)"
                                font.family: "Consolas"; font.pixelSize: phoneWin.calcResult !== "" ? 42 : 20
                                font.weight: Font.Black; color: phoneWin.calcResult !== "" ? "#1A1B2E" : "#64748B"
                            }
                            Rectangle {
                                visible: phoneWin.calcResult !== ""
                                width: 164; height: 42; radius: 21
                                color: calcCpMa.containsMouse ? themeHub.accentB : themeHub.accentA
                                border.width: 2.5; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: "Enter \u00B7 Copy"; font.family: "Segoe UI"; font.pixelSize: 16; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    id: calcCpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { ClipboardService.copyText(phoneWin.calcResult); phoneWin.closePhone() }
                                }
                            }
                        }
                    }
                }

                // ---- CARD 3: Color Swatch (#RRGGBB) ----
                Item {
                    anchors.fill: parent
                    visible: phoneWin.cardMode === "color"

                    Rectangle { x: 4; y: 4; width: parent.width - 4; height: 240; radius: 28; color: "#1A1B2E" }
                    Rectangle {
                        width: parent.width - 4; height: 240; radius: 28
                        color: "#FFFFFF"; border.width: 3; border.color: "#1A1B2E"
                        Row {
                            anchors.fill: parent; anchors.margins: 22; spacing: 20
                            Rectangle {
                                width: 120; height: 120; radius: 24; anchors.verticalCenter: parent.verticalCenter
                                color: phoneWin.colorHexValue !== "" ? phoneWin.colorHexValue : "#4ECDC4"
                                border.width: 3.5; border.color: "#1A1B2E"
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                Text { text: phoneWin.colorHexValue; font.family: "Consolas"; font.pixelSize: 30; font.weight: Font.Black; color: "#1A1B2E" }
                                Text {
                                    readonly property color colVal: phoneWin.colorHexValue !== "" ? phoneWin.colorHexValue : "#4ECDC4"
                                    text: "rgb(" + Math.round(colVal.r * 255) + ", " + Math.round(colVal.g * 255) + ", " + Math.round(colVal.b * 255) + ")"
                                    font.family: "Consolas"; font.pixelSize: 16; font.weight: Font.Bold; color: "#475569"
                                }
                                Rectangle {
                                    width: 144; height: 40; radius: 20
                                    color: hexCpMa.containsMouse ? themeHub.accentB : themeHub.accentA
                                    border.width: 2.5; border.color: "#1A1B2E"
                                    Text { anchors.centerIn: parent; text: "Copy HEX"; font.family: "Segoe UI"; font.pixelSize: 15; font.weight: Font.Black; color: "#1A1B2E" }
                                    MouseArea {
                                        id: hexCpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { ClipboardService.copyText(phoneWin.colorHexValue); phoneWin.closePhone() }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- Right-Click App Context Overlay inside Phone ----
            Rectangle {
                anchors.fill: parent
                radius: 100
                color: "transparent"
                visible: phoneWin.ctxOpen
                z: 45
                MouseArea {
                    anchors.fill: parent
                    onClicked: phoneWin.ctxOpen = false
                }
            }

            Item {
                visible: phoneWin.ctxOpen && phoneWin.ctxApp !== null
                x: phoneWin.ctxX
                y: phoneWin.ctxY
                width: 214
                height: 142
                z: 50

                Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 18; color: "#1A1B2E" }
                Rectangle {
                    anchors.fill: parent; radius: 18; color: "#FFFFFF"; border.width: 3; border.color: "#1A1B2E"
                    Column {
                        anchors.fill: parent; anchors.margins: 10; spacing: 6
                        Repeater {
                            model: [
                                { id: "admin",  label: "Run as Administrator" },
                                { id: "folder", label: "Open App Folder" },
                                { id: "hide",   label: "Hide from Drawer" }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: parent.width; height: 36; radius: 10
                                color: cMenuMa.containsMouse ? themeHub.accentB : "#F8FAFC"
                                border.width: 2; border.color: "#1A1B2E"
                                Text { anchors.centerIn: parent; text: modelData.label; font.family: "Segoe UI"; font.pixelSize: 13; font.weight: Font.Black; color: "#1A1B2E" }
                                MouseArea {
                                    id: cMenuMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const a = phoneWin.ctxApp
                                        const actionId = modelData.id
                                        phoneWin.ctxOpen = false
                                        if (!a || !a.target) return
                                        Qt.callLater(() => {
                                            if (actionId === "admin") {
                                                AppLauncher.runElevated(a.target, a.args || "")
                                                phoneWin.closePhone()
                                            } else if (actionId === "folder") {
                                                AppLauncher.revealInExplorer(a.target)
                                                phoneWin.closePhone()
                                            } else if (actionId === "hide") {
                                                AppLauncher.hideApp(a.target, a.name || "")
                                            }
                                        })
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
