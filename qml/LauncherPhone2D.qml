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

    // Right-click app context menu & drawer manager overlays inside phone
    property bool ctxOpen: false
    property var ctxApp: null
    property string ctxFolderId: ""
    property real ctxX: 0
    property real ctxY: 0
    property bool pickingFile: false
    property bool hiddenSheetOpen: false
    property string openFolderId: ""

    // Phone drag-to-group / drag-out state
    property var draggingApp: null
    property var draggingTargets: []
    property int dragSourceIndex: -1
    property int dragHoverIndex: -1
    property real dragGhostX: 0
    property real dragGhostY: 0
    property string dragFromFolderId: ""
    property bool dragOutsideFolder: false

    function clearDragState() {
        draggingApp = null
        draggingTargets = []
        dragSourceIndex = -1
        dragHoverIndex = -1
        dragFromFolderId = ""
        dragOutsideFolder = false
        drawerGrid.interactive = true
    }

    function isDragMemberTarget(target) {
        const k = String(target || "").trim().toLowerCase()
        if (!k || !draggingTargets)
            return false
        for (let i = 0; i < draggingTargets.length; ++i) {
            if (String(draggingTargets[i] || "").trim().toLowerCase() === k)
                return true
        }
        return false
    }

    // Multi-select mode for fast grouping & fast hiding
    property bool selectMode: false
    property var selectedMap: ({})
    readonly property int selectedCount: Object.keys(selectedMap || {}).length

    function isSelectedTarget(target) {
        const k = String(target || "").trim().toLowerCase()
        return k !== "" && !!(selectedMap && selectedMap[k])
    }

    function toggleSelectApp(app) {
        if (!app || !app.target)
            return
        const k = String(app.target).trim().toLowerCase()
        if (!k)
            return
        const next = Object.assign({}, selectedMap || {})
        if (next[k])
            delete next[k]
        else
            next[k] = { target: String(app.target), name: String(app.name || "") }
        selectedMap = next
    }

    function clearSelection() {
        selectMode = false
        selectedMap = ({})
    }

    // Keep GridView scroll Y fixed when hiding, unhiding, or grouping items
    function preserveScrollAndRun(fn) {
        const savedY = drawerGrid.contentY
        drawerWheelAnim.stop()
        if (fn)
            fn()
        Qt.callLater(() => {
            const maxY = Math.max(0, drawerGrid.contentHeight + drawerGrid.bottomMargin - drawerGrid.height)
            const clampedY = Math.max(0, Math.min(maxY, savedY))
            drawerGrid.contentY = clampedY
            drawerGrid.wheelTargetY = clampedY
        })
    }

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
        ctxFolderId = ""
        hiddenSheetOpen = false
        openFolderId = ""
        clearSelection()
        clearDragState()
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
        if (!pickingFile && themeHub.spotlightOpen && (Date.now() - openedAt) > 200)
            closePhone()
    }

    Timer {
        interval: 60
        repeat: true
        running: phoneWin.visible && phoneWin.wanted
        onTriggered: {
            if (!phoneWin.pickingFile && !phoneWin.draggingApp && (Date.now() - phoneWin.openedAt) > 250 && phoneWin.isPointerOutsideAndPressed())
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
        const _hiddenLen = (AppLauncher.hiddenApps || []).length
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
            if (!b || !b.target)
                continue
            const key = String(b.target || "").toLowerCase()
            if (!seen[key] && String(b.name || "").toLowerCase().indexOf(qLow) >= 0) {
                seen[key] = true
                merged.push(b)
            }
        }
        return merged
    }

    // Drawer grid model: Folders + ungrouped apps when browsing, flat search results when typing
    readonly property var drawerItems: {
        const apps = appEntries || []
        if (trimmedQuery !== "") {
            const out = []
            for (let i = 0; i < apps.length; ++i) {
                const a = apps[i]
                out.push({
                    kind: "app",
                    id: "",
                    name: a.name || "",
                    target: a.target || "",
                    args: a.args || "",
                    category: a.category || "App",
                    apps: []
                })
            }
            return out
        }

        const byTarget = {}
        const byName = {}
        for (let i = 0; i < apps.length; ++i) {
            const k = String(apps[i].target || "").trim().toLowerCase()
            const nk = String(apps[i].name || "").trim().toLowerCase()
            if (k)
                byTarget[k] = apps[i]
            if (nk && !byName[nk])
                byName[nk] = apps[i]
        }

        const folders = AppLauncher.drawerFolders || []
        const inFolder = {}
        const inFolderNames = {}
        const result = []

        for (let f = 0; f < folders.length; ++f) {
            const fld = folders[f]
            if (!fld || !fld.id)
                continue
            const rawList = fld.apps || []
            const resolved = []
            for (let j = 0; j < rawList.length; ++j) {
                const t = String(rawList[j] || "").trim()
                const k = t.toLowerCase()
                if (!k || AppLauncher.isHidden(t) || inFolder[k])
                    continue
                const parts = t.replace(/\//g, "\\").split("\\")
                const leaf = (parts[parts.length - 1] || t).replace(/\.(lnk|exe|url)$/i, "")
                const matchObj = byTarget[k] || byName[leaf.toLowerCase()]
                const resolvedItem = matchObj || { name: leaf, target: t, args: "", category: "Custom" }
                const rk = String(resolvedItem.target || "").trim().toLowerCase()
                const rnk = String(resolvedItem.name || "").trim().toLowerCase()
                if ((rk && inFolder[rk]) || (rnk && inFolderNames[rnk]))
                    continue
                inFolder[k] = true
                if (rk)
                    inFolder[rk] = true
                if (rnk)
                    inFolderNames[rnk] = true
                resolved.push(resolvedItem)
            }
            if (resolved.length > 0) {
                result.push({
                    kind: "folder",
                    id: String(fld.id),
                    name: String(fld.name || "Folder"),
                    target: "",
                    args: "",
                    category: "Folder",
                    apps: resolved
                })
            }
        }

        for (let i = 0; i < apps.length; ++i) {
            const a = apps[i]
            const k = String(a.target || "").trim().toLowerCase()
            const nk = String(a.name || "").trim().toLowerCase()
            if ((k && inFolder[k]) || (nk && inFolderNames[nk]))
                continue
            result.push({
                kind: "app",
                id: "",
                name: a.name || "",
                target: a.target || "",
                args: a.args || "",
                category: a.category || "App",
                apps: []
            })
        }
        return result
    }

    readonly property var openFolderObj: {
        if (openFolderId === "")
            return null
        const items = drawerItems || []
        for (let i = 0; i < items.length; ++i) {
            if (items[i].kind === "folder" && items[i].id === openFolderId)
                return items[i]
        }
        return null
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
        if (q !== "" && selectMode)
            clearSelection()
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
        drawerWheelAnim.stop()
        drawerGrid.wheelTargetY = 0
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
        if (idx < 0 && drawerItems.length > 0)
            idx = 0
        if (idx >= 0 && idx < drawerItems.length) {
            const item = drawerItems[idx]
            if (item.kind === "folder") {
                openFolderId = item.id
            } else {
                launchApp(item, modifiers)
            }
        }
    }

    function navigateKey(key) {
        if (cardMode === "clip") {
            if (filteredClipEntries.length === 0) return
            const step = (key === Qt.Key_Up || key === Qt.Key_Left) ? -1 : 1
            clipIndex = Math.max(0, Math.min(filteredClipEntries.length - 1, clipIndex + step))
            return
        }
        if (cardShown || openFolderId !== "" || hiddenSheetOpen)
            return

        keyNav = true
        const nRows = commandRows.length
        const nApps = drawerItems.length

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
                            } else if (phoneWin.hiddenSheetOpen) {
                                phoneWin.hiddenSheetOpen = false
                            } else if (phoneWin.openFolderId !== "") {
                                phoneWin.openFolderId = ""
                            } else if (phoneWin.selectMode) {
                                phoneWin.clearSelection()
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
            readonly property bool actionBarShown: !phoneWin.cardShown && phoneWin.trimmedQuery === ""
            readonly property real actionBarH: actionBarShown ? 42 : 0
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

            // ---- Drawer Action Bar (+ Add App / Hidden Apps) ----
            Item {
                id: drawerActionBar
                x: phoneBezel.sideX
                y: phoneBezel.pageY
                width: phoneBezel.gridW
                height: 36
                visible: phoneBezel.actionBarShown
                opacity: 1.0 - phoneWin.cardK
                z: 24

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    text: phoneWin.draggingApp
                        ? ("Drop " + ((phoneWin.draggingTargets || []).length > 1 ? (phoneWin.draggingTargets.length + " apps ") : "") + "onto app/folder")
                        : (phoneWin.selectMode
                            ? (phoneWin.selectedCount > 0 ? "Drag stack or tap folder" : "Tap apps to select")
                            : "Hold drag · Ctrl+Click")
                    color: phoneScaleBox.lcdOn ? "#FFFFFF" : "#475569"
                    style: phoneScaleBox.lcdOn ? Text.Outline : Text.Normal
                    styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.85)
                    font.family: "Segoe UI"
                    font.pixelSize: 13
                    font.weight: Font.Bold
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Rectangle {
                        id: selectModeBtn
                        width: selectBtnRow.implicitWidth + 20
                        height: 32
                        radius: 16
                        color: phoneWin.selectMode
                            ? themeHub.accentB
                            : (selectModeMa.containsMouse ? themeHub.accentA : "#FFFFFF")
                        border.width: 2.5
                        border.color: "#1A1B2E"
                        antialiasing: true

                        Row {
                            id: selectBtnRow
                            anchors.centerIn: parent
                            spacing: 4
                            Text {
                                text: phoneWin.selectMode ? ("Select (" + phoneWin.selectedCount + ")") : "Select"
                                font.family: "Segoe UI"
                                font.pixelSize: 13
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }
                        }

                        MouseArea {
                            id: selectModeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                phoneWin.ctxOpen = false
                                if (phoneWin.selectMode)
                                    phoneWin.clearSelection()
                                else
                                    phoneWin.selectMode = true
                            }
                        }
                    }

                    Rectangle {
                        id: hiddenAppsBtn
                        readonly property int hiddenCount: (AppLauncher.hiddenApps || []).length
                        width: hiddenBtnRow.implicitWidth + 22
                        height: 32
                        radius: 16
                        color: hiddenAppsMa.containsMouse ? themeHub.accentB : "#FFFFFF"
                        border.width: 2.5
                        border.color: "#1A1B2E"
                        antialiasing: true
                        opacity: hiddenCount > 0 ? 1.0 : 0.72

                        Row {
                            id: hiddenBtnRow
                            anchors.centerIn: parent
                            spacing: 5
                            Text {
                                text: hiddenAppsBtn.hiddenCount > 0 ? ("Hidden (" + hiddenAppsBtn.hiddenCount + ")") : "Hidden"
                                font.family: "Segoe UI"
                                font.pixelSize: 13
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }
                        }

                        MouseArea {
                            id: hiddenAppsMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                phoneWin.ctxOpen = false
                                phoneWin.openFolderId = ""
                                phoneWin.hiddenSheetOpen = true
                            }
                        }
                    }

                    Rectangle {
                        id: addAppBtn
                        width: addBtnRow.implicitWidth + 22
                        height: 32
                        radius: 16
                        color: addAppMa.containsMouse ? themeHub.accentB : themeHub.accentA
                        border.width: 2.5
                        border.color: "#1A1B2E"
                        antialiasing: true

                        Row {
                            id: addBtnRow
                            anchors.centerIn: parent
                            spacing: 4
                            Text {
                                text: "+ Add"
                                font.family: "Segoe UI"
                                font.pixelSize: 13
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }
                        }

                        MouseArea {
                            id: addAppMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                phoneWin.ctxOpen = false
                                phoneWin.pickingFile = true
                                Qt.callLater(() => {
                                    const picked = SystemControl.pickExecutableFile("Add App to Drawer")
                                    phoneWin.pickingFile = false
                                    phoneWin.focusActivate()
                                    searchInput.forceActiveFocus()
                                    if (picked && picked.length > 0)
                                        AppLauncher.addCustomApp(picked)
                                })
                            }
                        }
                    }
                }
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

            // ---- 4-Column Scrollable App & Folder Grid ----
            Item {
                id: drawerPage
                x: phoneBezel.sideX
                y: phoneBezel.pageY + phoneBezel.actionBarH + phoneBezel.rowsHeight
                width: phoneBezel.gridW
                height: Math.max(120, phoneBezel.pageH - phoneBezel.actionBarH - phoneBezel.rowsHeight)
                opacity: 1.0 - phoneWin.cardK
                scale: 1.0 - 0.025 * phoneWin.cardK
                transformOrigin: Item.Top
                visible: opacity > 0.01
                enabled: phoneWin.cardK < 0.5 && phoneWin.openFolderId === "" && !phoneWin.hiddenSheetOpen
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
                    model: phoneWin.drawerItems
                    currentIndex: phoneWin.gridIndex
                    boundsBehavior: Flickable.DragOverBounds
                    flickDeceleration: 1700
                    maximumFlickVelocity: 4200
                    pixelAligned: true
                    cacheBuffer: drawerPage.cellH * 6
                    highlight: appPickPlate
                    highlightFollowsCurrentItem: true
                    highlightMoveDuration: 90
                    bottomMargin: phoneWin.selectMode ? 104 : 44

                    property real wheelTargetY: 0
                    NumberAnimation {
                        id: drawerWheelAnim
                        target: drawerGrid
                        property: "contentY"
                        duration: 170
                        easing.type: Easing.OutCubic
                    }

                    onDraggingChanged: {
                        if (dragging) {
                            drawerWheelAnim.stop()
                            wheelTargetY = contentY
                        }
                    }

                    displaced: Transition {
                        NumberAnimation {
                            properties: "x,y"
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }

                    WheelHandler {
                        id: drawerWheelHandler
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: event => {
                            const delta = event.pixelDelta.y !== 0
                                ? event.pixelDelta.y
                                : (event.angleDelta.y / 120.0) * 124
                            const maxY = Math.max(0, drawerGrid.contentHeight + drawerGrid.bottomMargin - drawerGrid.height)
                            const base = drawerWheelAnim.running ? drawerGrid.wheelTargetY : drawerGrid.contentY
                            const nextY = Math.max(0, Math.min(maxY, base - delta))
                            drawerGrid.wheelTargetY = nextY
                            drawerWheelAnim.stop()
                            drawerWheelAnim.to = nextY
                            drawerWheelAnim.start()
                            event.accepted = true
                        }
                    }

                    Timer {
                        id: dragEdgeScrollTimer
                        interval: 16
                        repeat: true
                        running: phoneWin.draggingApp !== null && phoneWin.dragFromFolderId === ""
                        onTriggered: {
                            const maxY = Math.max(0, drawerGrid.contentHeight + drawerGrid.bottomMargin - drawerGrid.height)
                            if (maxY <= 0)
                                return
                            const ly = phoneWin.dragGhostY - drawerPage.y
                            let nextY = drawerGrid.contentY
                            if (ly < 68) {
                                nextY = Math.max(0, nextY - Math.max(4, Math.round((68 - ly) * 0.24)))
                            } else if (ly > drawerPage.height - 68) {
                                nextY = Math.min(maxY, nextY + Math.max(4, Math.round((ly - (drawerPage.height - 68)) * 0.24)))
                            }
                            if (nextY !== drawerGrid.contentY) {
                                drawerGrid.contentY = nextY
                                drawerGrid.wheelTargetY = nextY
                                const gx = phoneWin.dragGhostX - drawerPage.x
                                const gy = phoneWin.dragGhostY - drawerPage.y
                                const hit = drawerGrid.indexAt(gx, gy + drawerGrid.contentY)
                                phoneWin.dragHoverIndex = (hit >= 0 && hit !== phoneWin.dragSourceIndex) ? hit : -1
                            }
                        }
                    }

                    delegate: Item {
                        id: appTile
                        required property var modelData
                        required property int index

                        readonly property bool isFolder: modelData.kind === "folder"
                        readonly property bool isSelected: !isFolder && phoneWin.isSelectedTarget(modelData.target)
                        readonly property bool picked: phoneWin.keyNav && phoneWin.rowPick < 0 && GridView.isCurrentItem
                        readonly property bool isDragSelf: !isFolder && phoneWin.draggingApp !== null
                            && ((phoneWin.dragSourceIndex === index && phoneWin.dragFromFolderId === "")
                                || phoneWin.isDragMemberTarget(modelData.target))
                        readonly property bool isDropTarget: phoneWin.draggingApp !== null && phoneWin.dragHoverIndex === index && !isDragSelf
                        readonly property bool lit: tileMa.containsMouse || picked || isDropTarget || isSelected
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
                        opacity: isDragSelf ? 0.28 : 1.0

                        // Drop target / Selected accent halo
                        Rectangle {
                            visible: appTile.isDropTarget || appTile.isSelected
                            x: Math.round((parent.width - 86) / 2)
                            y: 9
                            width: 86
                            height: 86
                            radius: 26
                            color: appTile.isSelected ? Qt.rgba(0.31, 0.80, 0.77, 0.28) : Qt.rgba(1, 1, 1, 0.24)
                            border.width: 3.5
                            border.color: appTile.isSelected ? themeHub.accentA : themeHub.accentB
                            antialiasing: true
                        }

                        // Folder 2x2 Mini-Grid Tile
                        Rectangle {
                            id: folderBox
                            visible: appTile.isFolder
                            x: Math.round((parent.width - 72) / 2)
                            y: 16
                            width: 72
                            height: 72
                            radius: 20
                            color: appTile.isDropTarget
                                ? themeHub.accentB
                                : (phoneScaleBox.lcdOn ? Qt.rgba(1, 1, 1, 0.86) : "#F1F5FF")
                            border.width: 3
                            border.color: "#1A1B2E"
                            antialiasing: true
                            scale: (1.0 + 0.10 * appTile.litP) * (1.0 - 0.08 * appTile.pressP)
                            transformOrigin: Item.Center

                            Grid {
                                anchors.centerIn: parent
                                columns: 2
                                spacing: 4
                                Repeater {
                                    model: (appTile.modelData.apps || []).slice(0, 4)
                                    delegate: Image {
                                        required property var modelData
                                        width: 26
                                        height: 26
                                        sourceSize.width: 48
                                        sourceSize.height: 48
                                        asynchronous: true
                                        smooth: true
                                        mipmap: true
                                        fillMode: Image.PreserveAspectFit
                                        source: modelData.target ? ("image://winicon/" + encodeURIComponent(modelData.target)) : ""
                                    }
                                }
                            }
                        }

                        // Standard App Icon
                        Image {
                            id: appIco
                            visible: !appTile.isFolder
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
                            source: (!appTile.isFolder && modelData.target) ? ("image://winicon/" + encodeURIComponent(modelData.target)) : ""
                            scale: (1.0 + 0.10 * appTile.litP) * (1.0 - 0.08 * appTile.pressP)
                            transformOrigin: Item.Center
                        }

                        Rectangle {
                            visible: !appTile.isFolder && (appIco.status === Image.Error || appIco.source === "")
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

                        // Multi-select checkmark badge (top-right of icon)
                        Rectangle {
                            visible: phoneWin.selectMode && !appTile.isFolder
                            x: Math.round((parent.width + 72) / 2) - 18
                            y: 8
                            width: 24
                            height: 24
                            radius: 12
                            color: appTile.isSelected ? themeHub.accentA : "#FFFFFF"
                            border.width: 2.5
                            border.color: "#1A1B2E"
                            z: 5
                            antialiasing: true
                            Text {
                                visible: appTile.isSelected
                                anchors.centerIn: parent
                                text: "\u2713"
                                font.family: "Segoe UI"
                                font.pixelSize: 13
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }
                        }

                        MouseArea {
                            id: tileMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            pressAndHoldInterval: 210
                            cursorShape: phoneWin.draggingApp ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                            onPressAndHold: mouse => {
                                if (mouse.button !== Qt.LeftButton || appTile.isFolder || phoneWin.trimmedQuery !== "")
                                    return
                                phoneWin.ctxOpen = false
                                drawerGrid.interactive = false
                                drawerWheelAnim.stop()
                                let dragList = []
                                if (phoneWin.selectMode) {
                                    if (!phoneWin.isSelectedTarget(appTile.modelData.target))
                                        phoneWin.toggleSelectApp(appTile.modelData)
                                    const map = phoneWin.selectedMap || {}
                                    for (const k in map) {
                                        if (map[k] && map[k].target)
                                            dragList.push(map[k].target)
                                    }
                                }
                                if (dragList.length === 0 && appTile.modelData.target)
                                    dragList = [String(appTile.modelData.target)]
                                phoneWin.draggingTargets = dragList
                                phoneWin.draggingApp = appTile.modelData
                                phoneWin.dragFromFolderId = ""
                                phoneWin.dragSourceIndex = appTile.index
                                phoneWin.dragHoverIndex = -1
                                const p = appTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                phoneWin.dragGhostX = p.x
                                phoneWin.dragGhostY = p.y
                            }
                            onPositionChanged: mouse => {
                                if (phoneWin.draggingApp && phoneWin.dragSourceIndex === appTile.index && phoneWin.dragFromFolderId === "") {
                                    const p = appTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                    phoneWin.dragGhostX = p.x
                                    phoneWin.dragGhostY = p.y
                                    const gPt = appTile.mapToItem(drawerGrid, mouse.x, mouse.y)
                                    const hit = drawerGrid.indexAt(gPt.x, gPt.y + drawerGrid.contentY)
                                    phoneWin.dragHoverIndex = (hit >= 0 && hit !== appTile.index) ? hit : -1
                                    return
                                }
                                if (phoneWin.keyNav && phoneWin.gridIndex !== appTile.index)
                                    phoneWin.keyNav = false
                            }
                            onReleased: mouse => {
                                if (mouse.button === Qt.LeftButton && phoneWin.draggingApp && phoneWin.dragSourceIndex === appTile.index && phoneWin.dragFromFolderId === "") {
                                    const targets = (phoneWin.draggingTargets && phoneWin.draggingTargets.length > 0)
                                        ? phoneWin.draggingTargets.slice()
                                        : [String(phoneWin.draggingApp.target || "")]
                                    const hoverIdx = phoneWin.dragHoverIndex
                                    const srcIdx = phoneWin.dragSourceIndex
                                    const wasSelect = phoneWin.selectMode
                                    phoneWin.clearDragState()
                                    if (hoverIdx >= 0 && hoverIdx < phoneWin.drawerItems.length && targets.length > 0) {
                                        const dst = phoneWin.drawerItems[hoverIdx]
                                        if (dst && dst.kind === "folder" && dst.id) {
                                            const fid = String(dst.id)
                                            if (wasSelect)
                                                phoneWin.clearSelection()
                                            Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.addAppsToFolder(fid, targets)))
                                        } else if (dst && dst.kind === "app" && dst.target && hoverIdx !== srcIdx) {
                                            const dstTarget = String(dst.target)
                                            const dstNorm = dstTarget.trim().toLowerCase()
                                            let dstInStack = false
                                            for (let i = 0; i < targets.length; ++i) {
                                                if (String(targets[i] || "").trim().toLowerCase() === dstNorm) {
                                                    dstInStack = true
                                                    break
                                                }
                                            }
                                            if (!dstInStack) {
                                                if (wasSelect)
                                                    phoneWin.clearSelection()
                                                if (targets.length > 1) {
                                                    const combined = [dstTarget].concat(targets)
                                                    Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.createFolderMulti("Folder", combined)))
                                                } else {
                                                    const t0 = targets[0]
                                                    Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.createFolder("Folder", dstTarget, t0)))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            onCanceled: {
                                if (phoneWin.dragSourceIndex === appTile.index && phoneWin.dragFromFolderId === "")
                                    phoneWin.clearDragState()
                            }
                            onClicked: mouse => {
                                if (phoneWin.draggingApp)
                                    return
                                if (mouse.button === Qt.RightButton) {
                                    phoneWin.ctxApp = appTile.modelData
                                    phoneWin.ctxFolderId = ""
                                    const posInBezel = appTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                    phoneWin.ctxX = Math.max(40, Math.min(phoneBezel.width - 230, posInBezel.x))
                                    phoneWin.ctxY = Math.max(180, Math.min(phoneBezel.height - 240, posInBezel.y))
                                    phoneWin.ctxOpen = true
                                } else if (appTile.isFolder) {
                                    phoneWin.ctxOpen = false
                                    if (phoneWin.selectMode && phoneWin.selectedCount > 0) {
                                        const map = phoneWin.selectedMap || {}
                                        const targets = []
                                        for (const k in map) {
                                            if (map[k] && map[k].target)
                                                targets.push(map[k].target)
                                        }
                                        const fid = String(appTile.modelData.id || "")
                                        phoneWin.clearSelection()
                                        if (fid !== "" && targets.length > 0)
                                            Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.addAppsToFolder(fid, targets)))
                                    } else {
                                        phoneWin.openFolderId = appTile.modelData.id
                                    }
                                } else if (phoneWin.selectMode || (mouse.modifiers & Qt.ControlModifier) !== 0) {
                                    phoneWin.ctxOpen = false
                                    if (!phoneWin.selectMode)
                                        phoneWin.selectMode = true
                                    phoneWin.toggleSelectApp(appTile.modelData)
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
                    visible: phoneWin.trimmedQuery !== "" && phoneWin.drawerItems.length === 0 && phoneWin.commandRows.length === 0
                    text: "No apps match"
                    color: phoneScaleBox.lcdOn ? "#FFFFFF" : "#475569"
                    style: phoneScaleBox.lcdOn ? Text.Outline : Text.Normal
                    styleColor: Qt.rgba(0.10, 0.10, 0.22, 0.85)
                    font.family: "Segoe UI"
                    font.pixelSize: 22
                    font.weight: Font.Black
                }

                // Floating Multi-Select Action Bar
                Item {
                    id: multiSelectBar
                    visible: phoneWin.selectMode && phoneWin.trimmedQuery === ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 10
                    width: parent.width - 16
                    height: 54
                    z: 35

                    Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 27; color: "#1A1B2E" }
                    Rectangle {
                        anchors.fill: parent
                        radius: 27
                        color: "#FFFFFF"
                        border.width: 3
                        border.color: "#1A1B2E"
                        antialiasing: true

                        Text {
                            x: 18
                            anchors.verticalCenter: parent.verticalCenter
                            text: phoneWin.selectedCount + " selected"
                            font.family: "Segoe UI"
                            font.pixelSize: 15
                            font.weight: Font.Black
                            color: "#1A1B2E"
                        }

                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            Rectangle {
                                id: msGroupBtn
                                enabled: phoneWin.selectedCount >= 2
                                opacity: enabled ? 1.0 : 0.45
                                width: 92
                                height: 36
                                radius: 18
                                color: msGroupMa.containsMouse && enabled ? themeHub.accentB : themeHub.accentA
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "Group"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 14
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: msGroupMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: msGroupBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: {
                                        if (!msGroupBtn.enabled)
                                            return
                                        const map = phoneWin.selectedMap || {}
                                        const targets = []
                                        for (const k in map) {
                                            if (map[k] && map[k].target)
                                                targets.push(map[k].target)
                                        }
                                        phoneWin.clearSelection()
                                        if (targets.length >= 2) {
                                            Qt.callLater(() => phoneWin.preserveScrollAndRun(() => {
                                                const fid = AppLauncher.createFolderMulti("Folder", targets)
                                                if (fid && fid.length > 0) {
                                                    phoneWin.openFolderId = fid
                                                    ctxRenameFocusTimer.restart()
                                                }
                                            }))
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                id: msHideBtn
                                enabled: phoneWin.selectedCount >= 1
                                opacity: enabled ? 1.0 : 0.45
                                width: 74
                                height: 36
                                radius: 18
                                color: msHideMa.containsMouse && enabled ? "#FDA4AF" : "#F1F5F9"
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "Hide"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 14
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: msHideMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: msHideBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: {
                                        if (!msHideBtn.enabled)
                                            return
                                        const map = phoneWin.selectedMap || {}
                                        const items = []
                                        for (const k in map) {
                                            if (map[k] && map[k].target)
                                                items.push({ target: map[k].target, name: map[k].name || "" })
                                        }
                                        phoneWin.clearSelection()
                                        if (items.length > 0) {
                                            Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.hideApps(items)))
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                id: msDoneBtn
                                width: 72
                                height: 36
                                radius: 18
                                color: msDoneMa.containsMouse ? themeHub.accentB : "#FFFFFF"
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "Done"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 14
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: msDoneMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: phoneWin.clearSelection()
                                }
                            }
                        }
                    }
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

            // ---- Open Folder Modal Overlay ----
            Rectangle {
                id: openFolderBackdrop
                anchors.fill: parent
                radius: 100
                color: Qt.rgba(0.06, 0.07, 0.14, 0.56)
                visible: phoneWin.openFolderObj !== null
                z: 48
                onVisibleChanged: {
                    if (visible && phoneWin.openFolderObj)
                        folderTitleInput.text = phoneWin.openFolderObj.name
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (folderTitleInput.activeFocus)
                            folderTitleInput.focus = false
                        phoneWin.openFolderId = ""
                    }
                }

                // Drag-out hint pill above folder card
                Rectangle {
                    visible: phoneWin.draggingApp !== null && phoneWin.dragFromFolderId !== ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: folderCard.y - 54
                    width: dragOutHintTxt.implicitWidth + 32
                    height: 36
                    radius: 18
                    color: phoneWin.dragOutsideFolder ? "#FDA4AF" : "#FFFFFF"
                    border.width: 2.5
                    border.color: "#1A1B2E"
                    z: 2
                    Text {
                        id: dragOutHintTxt
                        anchors.centerIn: parent
                        text: phoneWin.dragOutsideFolder ? "Release to move out of folder" : "Drag outside card to ungroup app"
                        font.family: "Segoe UI"
                        font.pixelSize: 14
                        font.weight: Font.Black
                        color: "#1A1B2E"
                    }
                }

                Item {
                    id: folderCard
                    x: Math.round((parent.width - width) / 2)
                    y: 256
                    width: 530
                    height: 560
                    z: 1

                    MouseArea {
                        anchors.fill: parent
                    }

                    Rectangle { x: 5; y: 5; width: parent.width; height: parent.height; radius: 30; color: "#1A1B2E" }
                    Rectangle {
                        anchors.fill: parent
                        radius: 30
                        color: "#FFFFFF"
                        border.width: 3.5
                        border.color: phoneWin.dragOutsideFolder ? "#F43F5E" : "#1A1B2E"
                        antialiasing: true

                        // Folder Header: editable title + Ungroup + Close
                        Item {
                            x: 20
                            y: 16
                            width: parent.width - 40
                            height: 48

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: ungroupBtn.left
                                anchors.rightMargin: 10
                                height: 44
                                radius: 14
                                color: "#F8FAFC"
                                border.width: 2.5
                                border.color: folderTitleInput.activeFocus ? themeHub.accentB : "#CBD5E1"

                                TextInput {
                                    id: folderTitleInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 14
                                    anchors.rightMargin: 14
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: "#1A1B2E"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 22
                                    font.weight: Font.Black
                                    selectByMouse: true
                                    text: phoneWin.openFolderObj ? phoneWin.openFolderObj.name : ""

                                    function commitTitle() {
                                        const fid = phoneWin.openFolderId
                                        const nextName = text.trim()
                                        if (fid !== "" && nextName !== "")
                                            AppLauncher.renameFolder(fid, nextName)
                                        focus = false
                                        searchInput.forceActiveFocus()
                                    }

                                    onEditingFinished: commitTitle()
                                    Keys.onReturnPressed: commitTitle()
                                    Keys.onEnterPressed: commitTitle()
                                }
                            }

                            Rectangle {
                                id: ungroupBtn
                                anchors.right: closeFolderBtn.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: 96
                                height: 38
                                radius: 19
                                color: ungroupMa.containsMouse ? "#FDA4AF" : "#F1F5F9"
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "Ungroup"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 13
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: ungroupMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const fid = phoneWin.openFolderId
                                        phoneWin.openFolderId = ""
                                        if (fid !== "")
                                            Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.deleteFolder(fid)))
                                    }
                                }
                            }

                            Rectangle {
                                id: closeFolderBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 38
                                height: 38
                                radius: 19
                                color: closeFolderMa.containsMouse ? themeHub.accentB : "#FFFFFF"
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "\u2715"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 16
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: closeFolderMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        phoneWin.openFolderId = ""
                                        searchInput.forceActiveFocus()
                                    }
                                }
                            }
                        }

                        // 3-column App Grid inside Folder
                        GridView {
                            id: folderAppsGrid
                            x: 20
                            y: 76
                            width: parent.width - 40
                            height: parent.height - 96
                            cellWidth: width / 3
                            cellHeight: 146
                            clip: true
                            boundsBehavior: Flickable.DragOverBounds
                            model: phoneWin.openFolderObj ? phoneWin.openFolderObj.apps : []

                            delegate: Item {
                                id: folderAppTile
                                required property var modelData
                                required property int index
                                width: folderAppsGrid.cellWidth
                                height: folderAppsGrid.cellHeight
                                readonly property bool isDragSelf: phoneWin.draggingApp !== null && phoneWin.dragFromFolderId === phoneWin.openFolderId && phoneWin.dragSourceIndex === index
                                opacity: isDragSelf ? 0.25 : 1.0

                                Rectangle {
                                    visible: folderAppMa.containsMouse && !phoneWin.draggingApp
                                    x: 10; y: 4; width: parent.width - 20; height: parent.height - 8
                                    radius: 20; color: "#F1F5FF"; border.width: 2; border.color: "#CBD5E1"
                                }

                                Image {
                                    id: folderAppIco
                                    x: Math.round((parent.width - 68) / 2)
                                    y: 12
                                    width: 68
                                    height: 68
                                    sourceSize.width: 96
                                    sourceSize.height: 96
                                    asynchronous: true
                                    smooth: true
                                    mipmap: true
                                    fillMode: Image.PreserveAspectFit
                                    source: modelData.target ? ("image://winicon/" + encodeURIComponent(modelData.target)) : ""
                                }

                                Rectangle {
                                    visible: folderAppIco.status === Image.Error || folderAppIco.source === ""
                                    x: Math.round((parent.width - 68) / 2)
                                    y: 12
                                    width: 68; height: 68; radius: 18
                                    color: themeHub.accentA; border.width: 2.5; border.color: "#1A1B2E"
                                    Text {
                                        anchors.centerIn: parent
                                        text: String(modelData.name || "?").slice(0, 1).toUpperCase()
                                        font.family: "Segoe UI"; font.pixelSize: 28; font.weight: Font.Black; color: "#1A1B2E"
                                    }
                                }

                                Text {
                                    x: 6
                                    y: 88
                                    width: parent.width - 12
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    lineHeight: 0.90
                                    elide: Text.ElideRight
                                    text: modelData.name || ""
                                    color: "#1A1B2E"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 15
                                    font.weight: Font.Black
                                }

                                MouseArea {
                                    id: folderAppMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    pressAndHoldInterval: 200
                                    cursorShape: phoneWin.draggingApp ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                    onPressAndHold: mouse => {
                                        if (mouse.button !== Qt.LeftButton)
                                            return
                                        phoneWin.ctxOpen = false
                                        phoneWin.draggingApp = folderAppTile.modelData
                                        phoneWin.dragFromFolderId = phoneWin.openFolderId
                                        phoneWin.dragSourceIndex = folderAppTile.index
                                        phoneWin.dragOutsideFolder = false
                                        const p = folderAppTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                        phoneWin.dragGhostX = p.x
                                        phoneWin.dragGhostY = p.y
                                    }
                                    onPositionChanged: mouse => {
                                        if (phoneWin.draggingApp && phoneWin.dragFromFolderId === phoneWin.openFolderId && phoneWin.dragSourceIndex === folderAppTile.index) {
                                            const p = folderAppTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                            phoneWin.dragGhostX = p.x
                                            phoneWin.dragGhostY = p.y
                                            const cPt = folderAppTile.mapToItem(folderCard, mouse.x, mouse.y)
                                            phoneWin.dragOutsideFolder = (cPt.x < -12 || cPt.x > folderCard.width + 12 || cPt.y < -12 || cPt.y > folderCard.height + 12)
                                        }
                                    }
                                    onReleased: mouse => {
                                        if (mouse.button === Qt.LeftButton && phoneWin.draggingApp && phoneWin.dragFromFolderId === phoneWin.openFolderId && phoneWin.dragSourceIndex === folderAppTile.index) {
                                            const fid = phoneWin.dragFromFolderId
                                            const srcTarget = String(phoneWin.draggingApp.target || "")
                                            const outside = phoneWin.dragOutsideFolder
                                            phoneWin.clearDragState()
                                            if (outside && fid !== "" && srcTarget !== "")
                                                Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.removeAppFromFolder(fid, srcTarget)))
                                        }
                                    }
                                    onCanceled: {
                                        if (phoneWin.dragFromFolderId === phoneWin.openFolderId && phoneWin.dragSourceIndex === folderAppTile.index)
                                            phoneWin.clearDragState()
                                    }
                                    onClicked: mouse => {
                                        if (phoneWin.draggingApp)
                                            return
                                        if (mouse.button === Qt.RightButton) {
                                            phoneWin.ctxApp = folderAppTile.modelData
                                            phoneWin.ctxFolderId = phoneWin.openFolderId
                                            const posInBezel = folderAppTile.mapToItem(phoneBezel, mouse.x, mouse.y)
                                            phoneWin.ctxX = Math.max(40, Math.min(phoneBezel.width - 230, posInBezel.x))
                                            phoneWin.ctxY = Math.max(180, Math.min(phoneBezel.height - 260, posInBezel.y))
                                            phoneWin.ctxOpen = true
                                        } else {
                                            const appCopy = folderAppTile.modelData
                                            const mods = mouse.modifiers
                                            phoneWin.ctxOpen = false
                                            Qt.callLater(() => phoneWin.launchApp(appCopy, mods))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- Hidden Apps Manager Overlay ----
            Rectangle {
                id: hiddenSheetBackdrop
                anchors.fill: parent
                radius: 100
                color: Qt.rgba(0.06, 0.07, 0.14, 0.56)
                visible: phoneWin.hiddenSheetOpen
                z: 49

                MouseArea {
                    anchors.fill: parent
                    onClicked: phoneWin.hiddenSheetOpen = false
                }

                Item {
                    id: hiddenSheetCard
                    x: Math.round((parent.width - width) / 2)
                    y: 230
                    width: 530
                    height: 620

                    MouseArea { anchors.fill: parent }

                    Rectangle { x: 5; y: 5; width: parent.width; height: parent.height; radius: 30; color: "#1A1B2E" }
                    Rectangle {
                        anchors.fill: parent
                        radius: 30
                        color: "#FFFFFF"
                        border.width: 3.5
                        border.color: "#1A1B2E"
                        antialiasing: true

                        Item {
                            x: 22
                            y: 18
                            width: parent.width - 44
                            height: 44

                            Text {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Hidden Apps (" + (AppLauncher.hiddenApps || []).length + ")"
                                font.family: "Segoe UI"
                                font.pixelSize: 22
                                font.weight: Font.Black
                                color: "#1A1B2E"
                            }

                            Rectangle {
                                id: restoreAllBtn
                                visible: (AppLauncher.hiddenApps || []).length > 0
                                anchors.right: closeHiddenBtn.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: 108
                                height: 36
                                radius: 18
                                color: restoreAllMa.containsMouse ? themeHub.accentB : themeHub.accentA
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "Restore All"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 13
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: restoreAllMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.clearHiddenApps()))
                                }
                            }

                            Rectangle {
                                id: closeHiddenBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 38
                                height: 38
                                radius: 19
                                color: closeHiddenMa.containsMouse ? themeHub.accentB : "#FFFFFF"
                                border.width: 2.5
                                border.color: "#1A1B2E"
                                Text {
                                    anchors.centerIn: parent
                                    text: "\u2715"
                                    font.family: "Segoe UI"
                                    font.pixelSize: 16
                                    font.weight: Font.Black
                                    color: "#1A1B2E"
                                }
                                MouseArea {
                                    id: closeHiddenMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: phoneWin.hiddenSheetOpen = false
                                }
                            }
                        }

                        ListView {
                            id: hiddenAppsList
                            x: 20
                            y: 74
                            width: parent.width - 40
                            height: parent.height - 94
                            clip: true
                            spacing: 8
                            model: AppLauncher.hiddenApps || []

                            delegate: Rectangle {
                                required property var modelData
                                width: hiddenAppsList.width
                                height: 56
                                radius: 16
                                color: "#F8FAFC"
                                border.width: 2
                                border.color: "#CBD5E1"

                                Image {
                                    x: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 34
                                    height: 34
                                    sourceSize.width: 64
                                    sourceSize.height: 64
                                    asynchronous: true
                                    smooth: true
                                    source: modelData.target ? ("image://winicon/" + encodeURIComponent(modelData.target)) : ""
                                }

                                Column {
                                    x: 54
                                    width: parent.width - 154
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: modelData.name || modelData.target || ""
                                        font.family: "Segoe UI"
                                        font.pixelSize: 15
                                        font.weight: Font.Black
                                        color: "#1A1B2E"
                                    }
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideMiddle
                                        text: modelData.target || ""
                                        font.family: "Segoe UI"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: "#64748B"
                                    }
                                }

                                Rectangle {
                                    id: unhideRowBtn
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 82
                                    height: 34
                                    radius: 17
                                    color: unhideRowMa.containsMouse ? themeHub.accentB : "#FFFFFF"
                                    border.width: 2
                                    border.color: "#1A1B2E"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "Restore"
                                        font.family: "Segoe UI"
                                        font.pixelSize: 13
                                        font.weight: Font.Black
                                        color: "#1A1B2E"
                                    }
                                    MouseArea {
                                        id: unhideRowMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const t = String(modelData.target || "")
                                            if (t !== "")
                                                Qt.callLater(() => phoneWin.preserveScrollAndRun(() => AppLauncher.unhideApp(t)))
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: hiddenAppsList
                            visible: (AppLauncher.hiddenApps || []).length === 0
                            text: "No hidden apps.\nRight-click any app to hide it."
                            horizontalAlignment: Text.AlignHCenter
                            font.family: "Segoe UI"
                            font.pixelSize: 16
                            font.weight: Font.Bold
                            color: "#64748B"
                        }
                    }
                }
            }

            // ---- Right-Click App / Folder Context Overlay inside Phone ----
            Rectangle {
                anchors.fill: parent
                radius: 100
                color: "transparent"
                visible: phoneWin.ctxOpen
                z: 51
                MouseArea {
                    anchors.fill: parent
                    onClicked: phoneWin.ctxOpen = false
                }
            }

            Item {
                id: ctxMenuBox
                visible: phoneWin.ctxOpen && phoneWin.ctxApp !== null
                readonly property var menuItems: {
                    if (!phoneWin.ctxApp)
                        return []
                    if (phoneWin.ctxApp.kind === "folder") {
                        return [
                            { id: "rename_folder", label: "Rename Folder" },
                            { id: "delete_folder", label: "Ungroup Folder" }
                        ]
                    }
                    const items = []
                    if (phoneWin.ctxFolderId !== "")
                        items.push({ id: "remove_folder", label: "Remove from Folder" })
                    items.push({ id: "pin_dock", label: "Pin to Dock" })
                    items.push({ id: "admin",    label: "Run as Administrator" })
                    items.push({ id: "folder",   label: "Open App Folder" })
                    items.push({ id: "hide",     label: "Hide from Drawer" })
                    return items
                }
                x: phoneWin.ctxX
                y: phoneWin.ctxY
                width: 214
                height: 20 + menuItems.length * 42 - (menuItems.length > 0 ? 6 : 0)
                z: 55

                Rectangle { x: 4; y: 4; width: parent.width; height: parent.height; radius: 18; color: "#1A1B2E" }
                Rectangle {
                    anchors.fill: parent; radius: 18; color: "#FFFFFF"; border.width: 3; border.color: "#1A1B2E"
                    Column {
                        anchors.fill: parent; anchors.margins: 10; spacing: 6
                        Repeater {
                            model: ctxMenuBox.menuItems
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
                                        const fid = phoneWin.ctxFolderId
                                        const actionId = modelData.id
                                        phoneWin.ctxOpen = false
                                        if (!a) return
                                        Qt.callLater(() => {
                                            if (actionId === "rename_folder") {
                                                phoneWin.openFolderId = String(a.id || "")
                                                ctxRenameFocusTimer.restart()
                                            } else if (actionId === "delete_folder") {
                                                phoneWin.preserveScrollAndRun(() => AppLauncher.deleteFolder(String(a.id || "")))
                                            } else if (actionId === "remove_folder") {
                                                phoneWin.preserveScrollAndRun(() => AppLauncher.removeAppFromFolder(fid, String(a.target || "")))
                                            } else if (actionId === "pin_dock") {
                                                if (a.target)
                                                    AppLauncher.addPinnedApp(a.name || "App", a.target, a.args || "")
                                            } else if (actionId === "admin" && a.target) {
                                                AppLauncher.runElevated(a.target, a.args || "")
                                                phoneWin.closePhone()
                                            } else if (actionId === "folder" && a.target) {
                                                AppLauncher.revealInExplorer(a.target)
                                                phoneWin.closePhone()
                                            } else if (actionId === "hide" && a.target) {
                                                phoneWin.preserveScrollAndRun(() => AppLauncher.hideApp(a.target, a.name || ""))
                                            }
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Timer {
                id: ctxRenameFocusTimer
                interval: 40
                onTriggered: {
                    folderTitleInput.forceActiveFocus()
                    folderTitleInput.selectAll()
                }
            }

            // ---- Floating Drag Ghost ----
            Item {
                id: dragGhostBox
                readonly property int stackCount: (phoneWin.draggingTargets && phoneWin.draggingTargets.length > 0)
                    ? phoneWin.draggingTargets.length : 1
                visible: phoneWin.draggingApp !== null
                x: phoneWin.dragGhostX - width * 0.5
                y: phoneWin.dragGhostY - 44
                width: 96
                height: 96
                scale: 1.12
                z: 65

                // Stacked pile shadow card when dragging multiple apps
                Rectangle {
                    visible: dragGhostBox.stackCount > 1
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 7
                    anchors.verticalCenterOffset: 6
                    rotation: 7
                    width: 80
                    height: 80
                    radius: 22
                    color: Qt.rgba(0.92, 0.95, 1.0, 0.90)
                    border.width: 2.5
                    border.color: "#1A1B2E"
                    antialiasing: true
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: 82
                    height: 82
                    radius: 22
                    color: phoneWin.dragOutsideFolder ? Qt.rgba(0.99, 0.90, 0.92, 0.94) : Qt.rgba(1, 1, 1, 0.92)
                    border.width: 3
                    border.color: phoneWin.dragOutsideFolder ? "#F43F5E" : themeHub.accentB
                    antialiasing: true
                }

                Image {
                    anchors.centerIn: parent
                    width: 68
                    height: 68
                    sourceSize.width: 96
                    sourceSize.height: 96
                    smooth: true
                    mipmap: true
                    fillMode: Image.PreserveAspectFit
                    source: (phoneWin.draggingApp && phoneWin.draggingApp.target)
                        ? ("image://winicon/" + encodeURIComponent(phoneWin.draggingApp.target))
                        : ""
                }

                // Stack count pill badge
                Rectangle {
                    visible: dragGhostBox.stackCount > 1
                    x: parent.width - width - 2
                    y: 2
                    width: Math.max(26, stackCountTxt.implicitWidth + 12)
                    height: 26
                    radius: 13
                    color: themeHub.accentA
                    border.width: 2.5
                    border.color: "#1A1B2E"
                    antialiasing: true
                    Text {
                        id: stackCountTxt
                        anchors.centerIn: parent
                        text: String(dragGhostBox.stackCount)
                        font.family: "Segoe UI"
                        font.pixelSize: 13
                        font.weight: Font.Black
                        color: "#1A1B2E"
                    }
                }
            }
        }
    }
}
