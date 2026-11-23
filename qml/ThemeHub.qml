import QtQuick
import Quickshell
import SekaiDesk

Item {
    id: hub
    visible: false

    // Reference primary screen dimensions passed from Shell.qml
    property int screenW: 1920
    property int screenH: 1080

    // Unified virtual desktop bounds spanning all connected monitors
    readonly property rect virtualRect: Quickshell.virtualGeometry
    readonly property int virtMinX: virtualRect.width > 0 ? Math.round(virtualRect.x) : 0
    readonly property int virtMinY: virtualRect.height > 0 ? Math.round(virtualRect.y) : 0
    readonly property int virtMaxX: virtualRect.width > 0 ? Math.round(virtualRect.x + virtualRect.width) : screenW
    readonly property int virtMaxY: virtualRect.height > 0 ? Math.round(virtualRect.y + virtualRect.height) : screenH

    readonly property var bands: [
        {
            id: "vs",
            name: "Virtual Singer",
            shortName: "VS",
            border: "#555473",
            A: "#04feee",
            B: "#00ffcb",
            deep: "#232235",
            hoverTint: "#d9fff6"
        },
        {
            id: "leoneed",
            name: "Leo/need",
            shortName: "L/n",
            border: "#2d3775",
            A: "#8ea3ff",
            B: "#9fd8ff",
            deep: "#181e3f",
            hoverTint: "#f1f9ff"
        },
        {
            id: "mmj",
            name: "MORE MORE JUMP!",
            shortName: "MMJ",
            border: "#39662d",
            A: "#a4ee55",
            B: "#7fe9a8",
            deep: "#223c1b",
            hoverTint: "#ecfcf2"
        },
        {
            id: "vbs",
            name: "Vivid BAD SQUAD",
            shortName: "VBS",
            border: "#561938",
            A: "#ff5c9a",
            B: "#ff96c0",
            deep: "#43142c",
            hoverTint: "#ffeff6"
        },
        {
            id: "wxs",
            name: "Wonderlands×Showtime",
            shortName: "WxS",
            border: "#6a3c11",
            A: "#ffa51f",
            B: "#ffd54a",
            deep: "#4b2a0c",
            hoverTint: "#fff9e4"
        },
        {
            id: "nightcord",
            name: "Nightcord at 25:00",
            shortName: "25ji",
            border: "#43285f",
            A: "#c08cf2",
            B: "#e2b5ff",
            deep: "#2b1a3d",
            hoverTint: "#fbf4ff"
        },
        {
            id: "mono",
            name: "Monochrome",
            shortName: "MONO",
            border: "#444444",
            A: "#f4f4f4",
            B: "#bdbdbd",
            deep: "#1a1a1a",
            hoverTint: "#e9e9e9"
        }
    ]

    property string bandId: ConfigStore.stringValue("theme.band", "vs")
    property bool useCustomPalette: ConfigStore.boolValue("theme.useCustomPalette", false)
    property string customAccentA: ConfigStore.stringValue("theme.customAccentA", "#04feee")
    property string customAccentB: ConfigStore.stringValue("theme.customAccentB", "#00ffcb")
    property string customBorder: ConfigStore.stringValue("theme.customBorder", "#555473")
    property string customDeep: ConfigStore.stringValue("theme.customDeep", "#232235")

    readonly property var currentBand: {
        for (let i = 0; i < bands.length; ++i) {
            if (bands[i].id === bandId)
                return bands[i]
        }
        return bands[0]
    }

    readonly property color accentA: useCustomPalette ? customAccentA : currentBand.A
    readonly property color accentB: useCustomPalette ? customAccentB : currentBand.B
    readonly property color bandBorder: useCustomPalette ? customBorder : currentBand.border
    readonly property color bandDeep: useCustomPalette ? customDeep : currentBand.deep
    readonly property color hoverTint: useCustomPalette ? "#E8F4FF" : currentBand.hoverTint
    function _clamp01(v) {
        return Math.max(0.0, Math.min(1.0, Number(v) || 0.0))
    }

    function _barTint(c, mul, add, alpha, minR, minG, minB) {
        if (!c)
            return Qt.rgba(minR, minG, minB, alpha)
        const r = Number(c.r)
        const g = Number(c.g)
        const b = Number(c.b)
        if (!isFinite(r) || !isFinite(g) || !isFinite(b))
            return Qt.rgba(minR, minG, minB, alpha)
        return Qt.rgba(
            Math.max(minR, _clamp01(r * mul + add)),
            Math.max(minG, _clamp01(g * mul + add)),
            Math.max(minB, _clamp01(b * mul + add)),
            alpha
        )
    }

    readonly property color darkInk: "#1A1B2E"
    readonly property color barBodyColor: _barTint(bandDeep, 0.72, 0.0, 0.94, 0.06, 0.07, 0.11)
    readonly property color barRimColor: _barTint(bandBorder, 1.28, 0.07, 0.96, 0.16, 0.18, 0.28)
    readonly property color barShadeColor: Qt.rgba(0.04, 0.05, 0.10, 0.88)
    readonly property color barChipColor: _barTint(bandBorder, 0.95, 0.08, 0.64, 0.14, 0.16, 0.25)
    readonly property color barChipHover: _barTint(bandBorder, 1.20, 0.14, 0.82, 0.20, 0.22, 0.34)
    readonly property color barInkColor: "#EAEFF8"
    readonly property color barMutedInk: "#A6B4CC"
    readonly property string bandName: useCustomPalette ? "Wallpaper Match" : currentBand.name
    readonly property string bandShort: useCustomPalette ? "WALL" : currentBand.shortName

    function setBand(id) {
        useCustomPalette = false
        ConfigStore.set("theme.useCustomPalette", false)
        bandId = id
        ConfigStore.set("theme.band", id)
    }

    function applyWallpaperPalette(map) {
        if (!map)
            return
        if (map.accentA) customAccentA = String(map.accentA)
        if (map.accentB) customAccentB = String(map.accentB)
        if (map.border) customBorder = String(map.border)
        if (map.deep) customDeep = String(map.deep)
        useCustomPalette = true
        ConfigStore.set("theme.customAccentA", customAccentA)
        ConfigStore.set("theme.customAccentB", customAccentB)
        ConfigStore.set("theme.customBorder", customBorder)
        ConfigStore.set("theme.customDeep", customDeep)
        ConfigStore.set("theme.useCustomPalette", true)
    }

    Connections {
        target: WallpaperService
        function onCurrentWallpaperChanged() {
            if (hub.useCustomPalette && WallpaperService.currentWallpaper !== "") {
                const pal = WallpaperService.extractPalette(WallpaperService.currentWallpaper)
                if (pal && pal.accentA)
                    hub.applyWallpaperPalette(pal)
            }
        }
    }

    // Shell / UI toggles
    property bool screenRoundEnabled: ConfigStore.boolValue("ui.screenRound", true)
    property bool dockAutoHide: ConfigStore.boolValue("dock.autoHide", true)
    property bool phoneMode: ConfigStore.boolValue("quickPanel.phoneMode", true)
    property bool phoneDarkMode: ConfigStore.boolValue("quickPanel.darkMode", false)
    readonly property color phoneScreenBg: phoneDarkMode ? "#121524" : "#F3F6FD"
    readonly property color phoneLandBg:   phoneDarkMode
        ? Qt.tint("#131627", Qt.rgba(accentB.r, accentB.g, accentB.b, 0.08))
        : Qt.tint("#FAFAFF", Qt.rgba(accentB.r, accentB.g, accentB.b, 0.14))
    readonly property color phoneCardBg:   phoneDarkMode ? "#1C2136" : "#FFFFFF"
    readonly property color phoneSubBg:    phoneDarkMode ? "#252B45" : "#F8FAFC"
    readonly property color phonePillBg:   phoneDarkMode ? "#252B45" : "#F1F5F9"
    readonly property color phoneInk:      phoneDarkMode ? "#F1F5F9" : "#1A1B2E"
    readonly property color phoneMutedInk: phoneDarkMode ? "#94A3B8" : "#64748B"
    readonly property color phoneBorder:   phoneDarkMode ? "#384166" : "#1A1B2E"
    property string taskbarHideMode: ConfigStore.stringValue("taskbar.hideMode", "primary")
    property bool taskbarWin11Strict: ConfigStore.boolValue("taskbar.win11StrictHide", true)

    Connections {
        target: TaskbarManager
        function onHideModeChanged() {
            hub.taskbarHideMode = TaskbarManager.hideMode
        }
        function onWin11StrictHideChanged() {
            hub.taskbarWin11Strict = TaskbarManager.win11StrictHide
        }
    }

    // Notifications & OSD
    property string notifyStyle: ConfigStore.stringValue("notifications.style", "peek")
    property bool notifyQuietFullscreen: ConfigStore.boolValue("notifications.quietFullscreen", true)
    property bool osdEnabled: ConfigStore.boolValue("ui.osdEnabled", true)

    function setNotifyStyle(v) {
        const s = (v === "popup" || v === "off") ? v : "peek"
        notifyStyle = s
        ConfigStore.set("notifications.style", s)
    }
    function setNotifyQuietFullscreen(v) {
        notifyQuietFullscreen = !!v
        ConfigStore.set("notifications.quietFullscreen", notifyQuietFullscreen)
    }
    function setOsdEnabled(v) {
        osdEnabled = !!v
        ConfigStore.set("ui.osdEnabled", osdEnabled)
        SystemControl.setSuppressStockOsd(osdEnabled)
    }

    // Bar customization
    property string barEdge: ConfigStore.stringValue("bar.edge", "top")
    readonly property bool barVertical: barEdge === "left" || barEdge === "right"
    property string barStyle: {
        const s = ConfigStore.stringValue("bar.style", "blur")
        return (s === "transparent" || s === "blur" || s === "straight") ? s : "blur"
    }
    property bool barAutoHide: ConfigStore.boolValue("bar.autoHide", false)
    property bool barShowActiveWindow: ConfigStore.boolValue("bar.showActiveWindow", true)
    property bool barShowMedia: ConfigStore.boolValue("bar.showMedia", true)
    property bool barShowWeather: ConfigStore.boolValue("bar.showWeather", true)
    property bool barShowStats: ConfigStore.boolValue("bar.showStats", true)
    property bool barShowClock: ConfigStore.boolValue("bar.showClock", true)
    property bool barShowTray: ConfigStore.boolValue("bar.showTray", true)
    property string barMediaVizStyle: {
        const s = ConfigStore.stringValue("bar.mediaVizStyle", "bars")
        return (s === "wave" || s === "off") ? s : "bars"
    }
    property bool barShowBattery: ConfigStore.boolValue("bar.showBattery", true)
    readonly property int barStripThickness: barVertical
        ? 44
        : (barStyle === "transparent" ? 36 : 30)

    // PresetMotion-style 3-beat choreography (slide out -> swap style/edge -> bounce in)
    property bool motionBarOut: false
    property bool motionDockOut: false
    readonly property int motionOutMs: 190
    readonly property int motionInMs: 380
    property string _targetBarEdge: barEdge
    property string _targetBarStyle: barStyle
    property string _targetDockEdge: dockEdge
    property string _targetDockStyle: dockStyle

    Timer {
        id: barMotionSwapTimer
        interval: 210
        onTriggered: {
            hub.barEdge = hub._targetBarEdge
            hub.barStyle = hub._targetBarStyle
            barMotionReleaseTimer.restart()
        }
    }
    Timer {
        id: barMotionReleaseTimer
        interval: 30
        onTriggered: hub.motionBarOut = false
    }
    Timer {
        id: dockMotionSwapTimer
        interval: 210
        onTriggered: {
            hub.dockEdge = hub._targetDockEdge
            hub.dockStyle = hub._targetDockStyle
            dockMotionReleaseTimer.restart()
        }
    }
    Timer {
        id: dockMotionReleaseTimer
        interval: 30
        onTriggered: hub.motionDockOut = false
    }

    function scheduleBarTransition() {
        barMotionReleaseTimer.stop()
        hub.motionBarOut = true
        barMotionSwapTimer.restart()
    }
    function scheduleDockTransition() {
        dockMotionReleaseTimer.stop()
        hub.motionDockOut = true
        dockMotionSwapTimer.restart()
    }

    function setBarEdge(v) {
        const s = (v === "bottom" || v === "left" || v === "right") ? v : "top"
        if (s === _targetBarEdge && s === barEdge)
            return
        _targetBarEdge = s
        ConfigStore.set("bar.edge", s)
        scheduleBarTransition()
    }
    function setBarStyle(v) {
        const s = (v === "transparent" || v === "straight" || v === "blur") ? v : "blur"
        if (s === _targetBarStyle && s === barStyle)
            return
        _targetBarStyle = s
        ConfigStore.set("bar.style", s)
        scheduleBarTransition()
    }
    function setBarAutoHide(v) { barAutoHide = !!v; ConfigStore.set("bar.autoHide", barAutoHide) }
    function setBarShowActiveWindow(v) { barShowActiveWindow = !!v; ConfigStore.set("bar.showActiveWindow", barShowActiveWindow) }
    function setBarShowMedia(v) { barShowMedia = !!v; ConfigStore.set("bar.showMedia", barShowMedia) }
    function setBarShowWeather(v) { barShowWeather = !!v; ConfigStore.set("bar.showWeather", barShowWeather) }
    function setBarShowStats(v) { barShowStats = !!v; ConfigStore.set("bar.showStats", barShowStats) }
    function setBarShowClock(v) { barShowClock = !!v; ConfigStore.set("bar.showClock", barShowClock) }
    function setBarShowTray(v) { barShowTray = !!v; ConfigStore.set("bar.showTray", barShowTray) }
    function setBarMediaVizStyle(v) {
        const s = (v === "wave" || v === "off") ? v : "bars"
        barMediaVizStyle = s
        ConfigStore.set("bar.mediaVizStyle", s)
    }
    function setBarShowBattery(v) { barShowBattery = !!v; ConfigStore.set("bar.showBattery", barShowBattery) }

    // Dock customization
    property string dockEdge: ConfigStore.stringValue("dock.edge", "bottom")
    readonly property bool dockVertical: dockEdge === "left" || dockEdge === "right"
    property string dockStyle: ConfigStore.stringValue("dock.style", "transparent")
    property string dockIconShape: ConfigStore.stringValue("dock.iconShape", "square")
    property int dockTileSize: Math.max(40, Math.min(64, ConfigStore.intValue("dock.tileSize", 48)))
    property bool dockMagnify: ConfigStore.boolValue("dock.magnify", true)
    property bool dockShowFinder: ConfigStore.boolValue("dock.showFinder", false)
    property bool dockShowClipboard: ConfigStore.boolValue("dock.showClipboard", false)
    property bool dockShowDropShelf: ConfigStore.boolValue("dock.showDropShelf", false)
    property bool dockShowTrash: ConfigStore.boolValue("dock.showTrash", false)
    property bool dockShowTimer: ConfigStore.boolValue("dock.showTimer", false)
    property bool dockShowFiles: ConfigStore.boolValue("dock.showFiles", true)
    property bool dockShowMedia: ConfigStore.boolValue("dock.showMedia", false)

    function setDockEdge(v) {
        const s = (v === "top" || v === "left" || v === "right") ? v : "bottom"
        if (s === _targetDockEdge && s === dockEdge)
            return
        _targetDockEdge = s
        ConfigStore.set("dock.edge", s)
        scheduleDockTransition()
    }

    Component.onCompleted: {
        if (!ConfigStore.boolValue("dock.toolsMigratedV6", false)) {
            setDockShowFinder(false)
            setDockShowClipboard(false)
            setDockShowDropShelf(false)
            setDockShowTrash(false)
            ConfigStore.set("dock.toolsMigratedV6", true)
        }
        if (!ConfigStore.boolValue("dock.autoHideMigratedV8", false)) {
            setDockAutoHide(true)
            ConfigStore.set("dock.autoHideMigratedV8", true)
        }
        SystemControl.setSuppressStockOsd(osdEnabled)
        taskbarHideMode = TaskbarManager.hideMode
        taskbarWin11Strict = TaskbarManager.win11StrictHide
        _loadImageFrames()
    }

    function setDockStyle(v) {
        const s = (v === "float" || v === "capsule" || v === "transparent") ? v : "capsule"
        if (s === _targetDockStyle && s === dockStyle)
            return
        _targetDockStyle = s
        ConfigStore.set("dock.style", s)
        scheduleDockTransition()
    }
    function setDockIconShape(v) {
        const s = (v === "circle" || v === "square") ? v : "auto"
        dockIconShape = s
        ConfigStore.set("dock.iconShape", s)
    }
    function setDockTileSize(v) {
        const n = Number(v)
        const sz = isNaN(n) ? 48 : Math.max(40, Math.min(64, Math.round(n)))
        dockTileSize = sz
        ConfigStore.set("dock.tileSize", sz)
    }
    function setDockMagnify(v) { dockMagnify = !!v; ConfigStore.set("dock.magnify", dockMagnify) }
    function setDockShowFinder(v) { dockShowFinder = !!v; ConfigStore.set("dock.showFinder", dockShowFinder) }
    function setDockShowClipboard(v) { dockShowClipboard = !!v; ConfigStore.set("dock.showClipboard", dockShowClipboard) }
    function setDockShowDropShelf(v) { dockShowDropShelf = !!v; ConfigStore.set("dock.showDropShelf", dockShowDropShelf) }
    function setDockShowTrash(v) { dockShowTrash = !!v; ConfigStore.set("dock.showTrash", dockShowTrash) }
    function setDockShowTimer(v) { dockShowTimer = !!v; ConfigStore.set("dock.showTimer", dockShowTimer) }
    function setDockShowFiles(v) { dockShowFiles = !!v; ConfigStore.set("dock.showFiles", dockShowFiles) }
    function setDockShowMedia(v) { dockShowMedia = !!v; ConfigStore.set("dock.showMedia", dockShowMedia) }

    // Edit Desktop mode state
    property bool editMode: false
    property bool widgetsLocked: ConfigStore.boolValue("widgets.locked", false)
    property string editTab: "widgets"

    function setScreenRound(v) {
        screenRoundEnabled = !!v
        ConfigStore.set("ui.screenRound", screenRoundEnabled)
    }

    function setDockAutoHide(v) {
        dockAutoHide = !!v
        ConfigStore.set("dock.autoHide", dockAutoHide)
    }

    function setTaskbarHideMode(v) {
        TaskbarManager.setHideMode(String(v || "primary"))
        taskbarHideMode = TaskbarManager.hideMode
    }

    function setTaskbarWin11Strict(v) {
        TaskbarManager.setWin11StrictHide(!!v)
        taskbarWin11Strict = TaskbarManager.win11StrictHide
    }

    function setPhoneMode(v) {
        phoneMode = !!v
        ConfigStore.set("quickPanel.phoneMode", phoneMode)
    }

    function setPhoneDarkMode(v) {
        phoneDarkMode = !!v
        ConfigStore.set("quickPanel.darkMode", phoneDarkMode)
    }

    function setWidgetsLocked(v) {
        widgetsLocked = !!v
        ConfigStore.set("widgets.locked", widgetsLocked)
    }

    function setEditMode(v) {
        editMode = !!v
        if (editMode)
            closeAllTools()
    }

    // Modal & tool windows
    property bool settingsOpen: false
    property double settingsClosedAt: 0
    property string settingsSection: ""
    property string landscapeContent: "settings" // "settings" | "wallpapers"
    property bool wallpaperSelectorOpen: false
    property double wallpaperSelectorClosedAt: 0
    property bool spotlightOpen: false
    property double spotlightClosedAt: 0
    property string launcherInitialQuery: ""
    property bool clipboardOpen: false
    property double clipboardClosedAt: 0
    property bool dropShelfOpen: false
    property double dropShelfClosedAt: 0

    onWallpaperSelectorOpenChanged: {
        if (wallpaperSelectorOpen)
            openWallpapers()
    }

    function openSettings(section) {
        spotlightOpen = false
        clipboardOpen = false
        dropShelfOpen = false
        wallpaperSelectorOpen = false
        landscapeContent = "settings"
        settingsSection = section || ""
        settingsOpen = true
    }

    function openWallpapers() {
        spotlightOpen = false
        clipboardOpen = false
        dropShelfOpen = false
        wallpaperSelectorOpen = false
        landscapeContent = "wallpapers"
        settingsOpen = true
    }

    function closeAllTools() {
        settingsOpen = false
        wallpaperSelectorOpen = false
        spotlightOpen = false
        clipboardOpen = false
        dropShelfOpen = false
    }

    function captureLookMap() {
        return {
            bandId: bandId,
            useCustomPalette: useCustomPalette,
            customAccentA: String(customAccentA),
            customAccentB: String(customAccentB),
            customBorder: String(customBorder),
            customDeep: String(customDeep),
            accentA: String(accentA),
            accentB: String(accentB),
            screenRoundEnabled: screenRoundEnabled,
            dockEdge: dockEdge,
            dockAutoHide: dockAutoHide,
            dockStyle: dockStyle,
            dockIconShape: dockIconShape,
            dockTileSize: dockTileSize,
            dockMagnify: dockMagnify,
            dockShowFinder: dockShowFinder,
            dockShowClipboard: dockShowClipboard,
            dockShowDropShelf: dockShowDropShelf,
            dockShowTrash: dockShowTrash,
            dockShowTimer: dockShowTimer,
            dockShowFiles: dockShowFiles,
            dockShowMedia: dockShowMedia,
            barEdge: barEdge,
            barStyle: barStyle,
            barAutoHide: barAutoHide,
            barShowActiveWindow: barShowActiveWindow,
            barShowMedia: barShowMedia,
            barMediaVizStyle: barMediaVizStyle,
            barShowWeather: barShowWeather,
            barShowStats: barShowStats,
            barShowBattery: barShowBattery,
            barShowClock: barShowClock,
            barShowTray: barShowTray,
            phoneMode: phoneMode,
            phoneDarkMode: phoneDarkMode,
            osdEnabled: osdEnabled,
            notifyStyle: notifyStyle,
            notifyQuietFullscreen: notifyQuietFullscreen,
            clockStyle: clockStyle,
            clockUse24h: clockUse24h,
            clockSeconds: clockSeconds,
            clockShowDate: clockShowDate,
            weatherMinimal: weatherMinimal,
            weatherView: weatherView,
            weatherUnit: weatherUnit,
            widgets: {
                clock: wClockVisible,
                weather: wWeatherVisible,
                todo: wTodoVisible,
                notes: wNotesVisible,
                lyrics: wLyricsVisible,
                profile: wProfileVisible,
                calendar: wCalendarVisible
            },
            widgetSizes: {
                clockScale: wClockScale,
                weatherScale: wWeatherScale,
                profileScale: wProfileScale,
                calendarScale: wCalendarScale,
                lyricsScale: wLyricsScale,
                todoW: wTodoW,
                todoH: wTodoH,
                notesW: wNotesW,
                notesH: wNotesH
            },
            visualizer: {
                enabled: VisualizerService.enabled,
                style: VisualizerService.style,
                sizeIndex: VisualizerService.sizeIndex,
                colorMode: VisualizerService.colorMode
            },
            wallpaper: WallpaperService.currentWallpaper || "",
            taskbarHideMode: taskbarHideMode,
            taskbarWin11Strict: taskbarWin11Strict
        }
    }

    function applyLookMap(data) {
        if (!data)
            return
        if (data.useCustomPalette) {
            applyWallpaperPalette({
                accentA: data.customAccentA || data.accentA || customAccentA,
                accentB: data.customAccentB || data.accentB || customAccentB,
                border: data.customBorder || customBorder,
                deep: data.customDeep || customDeep
            })
        } else if (data.bandId) {
            setBand(String(data.bandId))
        }
        if (data.screenRoundEnabled !== undefined) setScreenRound(data.screenRoundEnabled)
        if (data.dockEdge !== undefined) setDockEdge(data.dockEdge)
        if (data.dockAutoHide !== undefined) setDockAutoHide(data.dockAutoHide)
        if (data.dockStyle !== undefined) setDockStyle(data.dockStyle)
        if (data.dockIconShape !== undefined) setDockIconShape(data.dockIconShape)
        if (data.dockTileSize !== undefined) setDockTileSize(data.dockTileSize)
        if (data.dockMagnify !== undefined) setDockMagnify(data.dockMagnify)
        if (data.dockShowFinder !== undefined) setDockShowFinder(data.dockShowFinder)
        if (data.dockShowClipboard !== undefined) setDockShowClipboard(data.dockShowClipboard)
        if (data.dockShowDropShelf !== undefined) setDockShowDropShelf(data.dockShowDropShelf)
        if (data.dockShowTrash !== undefined) setDockShowTrash(data.dockShowTrash)
        if (data.dockShowTimer !== undefined) setDockShowTimer(data.dockShowTimer)
        if (data.dockShowFiles !== undefined) setDockShowFiles(data.dockShowFiles)
        if (data.dockShowMedia !== undefined) setDockShowMedia(data.dockShowMedia)
        if (data.barEdge !== undefined) setBarEdge(data.barEdge)
        if (data.barStyle !== undefined) setBarStyle(data.barStyle)
        if (data.barAutoHide !== undefined) setBarAutoHide(data.barAutoHide)
        if (data.barShowActiveWindow !== undefined) setBarShowActiveWindow(data.barShowActiveWindow)
        if (data.barShowMedia !== undefined) setBarShowMedia(data.barShowMedia)
        if (data.barMediaVizStyle !== undefined) setBarMediaVizStyle(data.barMediaVizStyle)
        if (data.barShowWeather !== undefined) setBarShowWeather(data.barShowWeather)
        if (data.barShowStats !== undefined) setBarShowStats(data.barShowStats)
        if (data.barShowBattery !== undefined) setBarShowBattery(data.barShowBattery)
        if (data.barShowClock !== undefined) setBarShowClock(data.barShowClock)
        if (data.barShowTray !== undefined) setBarShowTray(data.barShowTray)
        if (data.phoneMode !== undefined) setPhoneMode(data.phoneMode)
        if (data.phoneDarkMode !== undefined) setPhoneDarkMode(data.phoneDarkMode)
        if (data.osdEnabled !== undefined) setOsdEnabled(data.osdEnabled)
        if (data.notifyStyle !== undefined) setNotifyStyle(data.notifyStyle)
        if (data.notifyQuietFullscreen !== undefined) setNotifyQuietFullscreen(data.notifyQuietFullscreen)
        if (data.clockStyle !== undefined) setClockStyle(data.clockStyle)
        if (data.clockUse24h !== undefined) setClockUse24h(data.clockUse24h)
        if (data.clockSeconds !== undefined) setClockSeconds(data.clockSeconds)
        if (data.clockShowDate !== undefined) setClockShowDate(data.clockShowDate)
        if (data.weatherMinimal !== undefined) setWeatherMinimal(data.weatherMinimal)
        if (data.weatherView !== undefined) setWeatherView(data.weatherView)
        if (data.weatherUnit !== undefined) setWeatherUnit(data.weatherUnit)
        if (data.widgets) {
            const keys = ["clock", "weather", "todo", "notes", "lyrics", "profile", "calendar"]
            for (let i = 0; i < keys.length; ++i) {
                const k = keys[i]
                if (data.widgets[k] !== undefined)
                    setWidgetVisible(k, !!data.widgets[k])
            }
        }
        if (data.widgetSizes) {
            if (data.widgetSizes.clockScale !== undefined) saveWidgetScale("clock", data.widgetSizes.clockScale)
            if (data.widgetSizes.weatherScale !== undefined) saveWidgetScale("weather", data.widgetSizes.weatherScale)
            if (data.widgetSizes.profileScale !== undefined) saveWidgetScale("profile", data.widgetSizes.profileScale)
            if (data.widgetSizes.calendarScale !== undefined) saveWidgetScale("calendar", data.widgetSizes.calendarScale)
            if (data.widgetSizes.lyricsScale !== undefined) saveWidgetScale("lyrics", data.widgetSizes.lyricsScale)
            if (data.widgetSizes.todoW !== undefined && data.widgetSizes.todoH !== undefined)
                saveWidgetSize("todo", data.widgetSizes.todoW, data.widgetSizes.todoH)
            if (data.widgetSizes.notesW !== undefined && data.widgetSizes.notesH !== undefined)
                saveWidgetSize("notes", data.widgetSizes.notesW, data.widgetSizes.notesH)
        }
        if (data.visualizer) {
            if (data.visualizer.style !== undefined) VisualizerService.style = String(data.visualizer.style)
            if (data.visualizer.sizeIndex !== undefined) VisualizerService.sizeIndex = Number(data.visualizer.sizeIndex)
            if (data.visualizer.colorMode !== undefined) VisualizerService.colorMode = Number(data.visualizer.colorMode)
            if (data.visualizer.enabled !== undefined) VisualizerService.enabled = !!data.visualizer.enabled
        }
        if (data.wallpaper && String(data.wallpaper) !== "")
            WallpaperService.applyWallpaper(String(data.wallpaper))
        if (data.taskbarHideMode !== undefined) setTaskbarHideMode(data.taskbarHideMode)
        if (data.taskbarWin11Strict !== undefined) setTaskbarWin11Strict(data.taskbarWin11Strict)
    }

    // Desktop widgets visibility (persisted)
    property bool wClockVisible: ConfigStore.boolValue("widgets.clock.visible", true)
    property bool wWeatherVisible: ConfigStore.boolValue("widgets.weather.visible", false)
    property bool wTodoVisible: ConfigStore.boolValue("widgets.todo.visible", false)
    property bool wNotesVisible: ConfigStore.boolValue("widgets.notes.visible", false)
    property bool wLyricsVisible: ConfigStore.boolValue("widgets.lyrics.visible", false)
    property bool wProfileVisible: ConfigStore.boolValue("widgets.profile.visible", false)
    property bool wCalendarVisible: ConfigStore.boolValue("widgets.calendar.visible", false)

    // Clock widget style (0=KEYS, 1=TOWER, 2=STICKER, 3=STACK) and format
    readonly property var clockDesignNames: ["KEYS", "TOWER", "STICKER", "STACK"]
    property int clockStyle: {
        const raw = ConfigStore.get("widgets.clock.style", 3)
        if (typeof raw === "number")
            return Math.max(0, Math.min(3, Math.round(raw)))
        const s = String(raw || "").toLowerCase()
        if (s === "keys" || s === "0") return 0
        if (s === "tower" || s === "1") return 1
        if (s === "sticker" || s === "2") return 2
        return 3
    }
    property bool clockUse24h: ConfigStore.boolValue("widgets.clock.use24h", false)
    readonly property bool clock24h: clockUse24h
    property bool clockSeconds: ConfigStore.boolValue("widgets.clock.showSeconds", true)
    property bool clockShowDate: ConfigStore.boolValue("widgets.clock.showDate", true)

    function setClockStyle(st) {
        let idx = 3
        if (typeof st === "number") {
            idx = Math.max(0, Math.min(3, Math.round(st)))
        } else {
            const s = String(st || "").toLowerCase()
            if (s === "keys" || s === "0") idx = 0
            else if (s === "tower" || s === "1") idx = 1
            else if (s === "sticker" || s === "2") idx = 2
            else idx = 3
        }
        clockStyle = idx
        ConfigStore.set("widgets.clock.style", idx)
    }

    function cycleClockStyle() {
        setClockStyle((clockStyle + 1) % 4)
    }

    function setClockUse24h(v) {
        clockUse24h = !!v
        ConfigStore.set("widgets.clock.use24h", clockUse24h)
    }

    function setClock24h(v) {
        setClockUse24h(v)
    }

    function setClockSeconds(v) {
        clockSeconds = !!v
        ConfigStore.set("widgets.clock.showSeconds", clockSeconds)
    }

    function setClockShowDate(v) {
        clockShowDate = !!v
        ConfigStore.set("widgets.clock.showDate", clockShowDate)
    }

    // Weather widget preferences
    property bool weatherMinimal: ConfigStore.boolValue("widgets.weather.minimal", false)
    readonly property string weatherStyle: weatherMinimal ? "compact" : "card"
    property string weatherView: {
        const v = ConfigStore.stringValue("widgets.weather.view", "hourly")
        return v === "days" ? "days" : "hourly"
    }
    property string weatherUnit: {
        const u = ConfigStore.stringValue("widgets.weather.unit", "C").toUpperCase()
        return u === "F" ? "F" : "C"
    }

    function setWeatherMinimal(v) {
        weatherMinimal = !!v
        ConfigStore.set("widgets.weather.minimal", weatherMinimal)
    }

    function setWeatherStyle(v) {
        setWeatherMinimal(String(v || "").toLowerCase() === "compact")
    }

    function setWeatherView(v) {
        weatherView = (v === "days") ? "days" : "hourly"
        ConfigStore.set("widgets.weather.view", weatherView)
    }

    function setWeatherUnit(v) {
        const u = String(v || "C").toUpperCase() === "F" ? "F" : "C"
        weatherUnit = u
        ConfigStore.set("widgets.weather.unit", u)
    }

    function formatTemp(celsius) {
        const c = Number(celsius)
        if (isNaN(c))
            return 0
        return weatherUnit === "F" ? Math.round(c * 9.0 / 5.0 + 32.0) : Math.round(c)
    }

    function configReal(key, fallback) {
        const v = Number(ConfigStore.get(key, fallback))
        return (isNaN(v) || v <= 0) ? fallback : v
    }

    // Todo widget compact toggle
    property bool todoSmall: ConfigStore.boolValue("widgets.todo.small", false)
    function setTodoSmall(v) {
        todoSmall = !!v
        ConfigStore.set("widgets.todo.small", todoSmall)
        const h = todoSmall ? 268 : 340
        wTodoH = h
        ConfigStore.set("widgets.todo.height", h)
    }

    // Per-widget resize state (uniform scale 0.65..1.65 + free W/H for Todo & Notes)
    property real wClockScale: Math.max(0.65, Math.min(1.65, configReal("widgets.clock.scale", 1.0)))
    property real wWeatherScale: Math.max(0.65, Math.min(1.65, configReal("widgets.weather.scale", 1.0)))
    property real wProfileScale: Math.max(0.65, Math.min(1.65, configReal("widgets.profile.scale", 1.0)))
    property real wCalendarScale: Math.max(0.65, Math.min(1.65, configReal("widgets.calendar.scale", 1.0)))
    property real wLyricsScale: Math.max(0.65, Math.min(1.65, configReal("widgets.lyrics.scale", 1.0)))
    property real wTodoScale: Math.max(0.65, Math.min(1.65, configReal("widgets.todo.scale", 1.0)))
    property real wNotesScale: Math.max(0.65, Math.min(1.65, configReal("widgets.notes.scale", 1.0)))

    property int wTodoW: Math.max(240, Math.min(580, ConfigStore.intValue("widgets.todo.width", 320)))
    property int wTodoH: Math.max(190, Math.min(680, ConfigStore.intValue("widgets.todo.height", todoSmall ? 268 : 340)))
    property int wNotesW: Math.max(210, Math.min(680, ConfigStore.intValue("widgets.notes.width", 288)))
    property int wNotesH: Math.max(170, Math.min(620, ConfigStore.intValue("widgets.notes.height", 248)))

    function widgetScale(key) {
        if (key === "clock") return wClockScale
        if (key === "weather") return wWeatherScale
        if (key === "profile") return wProfileScale
        if (key === "calendar") return wCalendarScale
        if (key === "lyrics") return wLyricsScale
        if (key === "todo") return wTodoScale
        if (key === "notes") return wNotesScale
        return 1.0
    }

    function saveWidgetScale(key, sc) {
        const s = Math.max(0.65, Math.min(1.65, Math.round(Number(sc) * 100) / 100))
        ConfigStore.set("widgets." + key + ".scale", s)
        if (key === "clock") wClockScale = s
        else if (key === "weather") wWeatherScale = s
        else if (key === "profile") wProfileScale = s
        else if (key === "calendar") wCalendarScale = s
        else if (key === "lyrics") wLyricsScale = s
        else if (key === "todo") wTodoScale = s
        else if (key === "notes") wNotesScale = s
    }

    function saveWidgetSize(key, w, h) {
        if (key === "todo") {
            const cw = Math.max(240, Math.min(580, Math.round(w)))
            const ch = Math.max(190, Math.min(680, Math.round(h)))
            wTodoW = cw
            wTodoH = ch
            ConfigStore.set("widgets.todo.width", cw)
            ConfigStore.set("widgets.todo.height", ch)
        } else if (key === "notes") {
            const cw = Math.max(210, Math.min(680, Math.round(w)))
            const ch = Math.max(170, Math.min(620, Math.round(h)))
            wNotesW = cw
            wNotesH = ch
            ConfigStore.set("widgets.notes.width", cw)
            ConfigStore.set("widgets.notes.height", ch)
        }
    }

    function resetWidgetSize(key) {
        saveWidgetScale(key, 1.0)
        if (key === "todo") {
            todoSmall = false
            ConfigStore.set("widgets.todo.small", false)
            saveWidgetSize("todo", 320, 340)
        } else if (key === "notes") {
            saveWidgetSize("notes", 288, 248)
        }
    }

    function widgetMinYAt(cx, rawY) {
        const onPrimaryScreen = (cx >= 0 && cx < screenW && rawY >= 0 && rawY < screenH)
        return (onPrimaryScreen && barEdge === "top" && !barAutoHide) ? 52 : (virtMinY + 8)
    }

    function clampWidgetX(nx, marginRight) {
        const mr = (marginRight !== undefined) ? marginRight : 100
        const minX = virtMinX + 8
        const maxX = Math.max(minX, virtMaxX - mr)
        return Math.max(minX, Math.min(maxX, Math.round(nx)))
    }

    function clampWidgetY(cx, ny, marginBottom) {
        const mb = (marginBottom !== undefined) ? marginBottom : 80
        const ry = Math.round(ny)
        const minY = widgetMinYAt(cx, ry)
        const maxY = Math.max(minY, virtMaxY - mb)
        return Math.max(minY, Math.min(maxY, ry))
    }

    function initWidgetX(key, fallbackX) {
        return clampWidgetX(ConfigStore.intValue("widgets." + key + ".x", fallbackX), 140)
    }

    function initWidgetY(key, fallbackY, resolvedX) {
        return clampWidgetY(resolvedX, ConfigStore.intValue("widgets." + key + ".y", fallbackY), 80)
    }

    // Desktop widgets coordinates (multi-monitor virtual desktop bounds; TopBar margin only on primary)
    property int wClockX: initWidgetX("clock", Math.max(320, screenW - 350))
    property int wClockY: initWidgetY("clock", 64, wClockX)
    property int wWeatherX: initWidgetX("weather", 28)
    property int wWeatherY: initWidgetY("weather", 346, wWeatherX)
    property int wProfileX: initWidgetX("profile", 28)
    property int wProfileY: initWidgetY("profile", 56, wProfileX)
    property int wTodoX: initWidgetX("todo", Math.max(320, screenW - 350))
    property int wTodoY: initWidgetY("todo", 356, wTodoX)
    property int wNotesX: initWidgetX("notes", Math.max(320, screenW - 350))
    property int wNotesY: initWidgetY("notes", 644, wNotesX)
    property int wLyricsX: initWidgetX("lyrics", Math.max(240, Math.round((screenW - 600) * 0.5)))
    property int wLyricsY: initWidgetY("lyrics", Math.max(400, screenH - 250), wLyricsX)
    property int wCalendarX: initWidgetX("calendar", 364)
    property int wCalendarY: initWidgetY("calendar", 56, wCalendarX)

    function widgetVisible(key) {
        if (key === "clock") return wClockVisible
        if (key === "weather") return wWeatherVisible
        if (key === "todo") return wTodoVisible
        if (key === "notes") return wNotesVisible
        if (key === "lyrics") return wLyricsVisible
        if (key === "profile") return wProfileVisible
        if (key === "calendar") return wCalendarVisible
        return false
    }

    function setWidgetVisible(key, vis) {
        const v = !!vis
        ConfigStore.set("widgets." + key + ".visible", v)
        if (key === "clock") wClockVisible = v
        else if (key === "weather") wWeatherVisible = v
        else if (key === "todo") wTodoVisible = v
        else if (key === "notes") wNotesVisible = v
        else if (key === "lyrics") wLyricsVisible = v
        else if (key === "profile") wProfileVisible = v
        else if (key === "calendar") wCalendarVisible = v
    }

    function saveWidgetPos(key, nx, ny) {
        const cx = clampWidgetX(nx, 100)
        const cy = clampWidgetY(cx, ny, 80)
        ConfigStore.set("widgets." + key + ".x", cx)
        ConfigStore.set("widgets." + key + ".y", cy)
        if (key === "clock") { wClockX = cx; wClockY = cy }
        else if (key === "weather") { wWeatherX = cx; wWeatherY = cy }
        else if (key === "todo") { wTodoX = cx; wTodoY = cy }
        else if (key === "notes") { wNotesX = cx; wNotesY = cy }
        else if (key === "lyrics") { wLyricsX = cx; wLyricsY = cy }
        else if (key === "profile") { wProfileX = cx; wProfileY = cy }
        else if (key === "calendar") { wCalendarX = cx; wCalendarY = cy }
    }

    function resetWidgetPositions() {
        saveWidgetPos("profile", 28, 56)
        saveWidgetPos("weather", 28, 346)
        saveWidgetPos("calendar", 364, 56)
        saveWidgetPos("clock", Math.max(320, screenW - 350), 64)
        saveWidgetPos("todo", Math.max(320, screenW - 350), 356)
        saveWidgetPos("notes", Math.max(320, screenW - 350), 644)
        saveWidgetPos("lyrics", Math.max(240, Math.round((screenW - 600) * 0.5)), Math.max(400, screenH - 250))
    }

    Component.onDestruction: ConfigStore.flush()

    // Todo data
    property var todoItems: {
        const raw = ConfigStore.get("widgets.todo.items", null)
        if (Array.isArray(raw))
            return raw
        return [
            { text: "Check SekaiDesk Band Themes", done: false },
            { text: "Try Alt+Space Spotlight", done: false }
        ]
    }

    function saveTodoItems(arr) {
        todoItems = arr
        ConfigStore.set("widgets.todo.items", arr)
    }

    function addTodo(text) {
        const clean = (text || "").trim()
        if (clean === "")
            return
        const next = todoItems.slice()
        next.unshift({ text: clean, done: false })
        saveTodoItems(next)
    }

    function toggleTodo(idx) {
        if (idx < 0 || idx >= todoItems.length)
            return
        const next = todoItems.slice()
        next[idx] = { text: next[idx].text, done: !next[idx].done }
        saveTodoItems(next)
    }

    function renameTodo(idx, newText) {
        const clean = (newText || "").trim()
        if (idx < 0 || idx >= todoItems.length || clean === "")
            return
        const next = todoItems.slice()
        next[idx] = { text: clean, done: !!next[idx].done }
        saveTodoItems(next)
    }

    function removeTodo(idx) {
        Qt.callLater(function() {
            if (idx < 0 || idx >= todoItems.length)
                return
            const next = todoItems.slice()
            next.splice(idx, 1)
            saveTodoItems(next)
        })
    }

    function clearDoneTodos() {
        const next = todoItems.filter(it => !it.done)
        saveTodoItems(next)
    }

    // Notes persisted text & SekaiPop paper tint
    property string noteText: ConfigStore.stringValue("widgets.notes.text", "Quick note...\n• Alt+Space: Spotlight\n• Ctrl+Alt+V: Clipboard")
    property string noteTint: ConfigStore.stringValue("widgets.notes.tint", "butter")
    function saveNoteText(t) {
        noteText = t
        ConfigStore.set("widgets.notes.text", t)
    }
    function setNoteTint(t) {
        noteTint = t || "butter"
        ConfigStore.set("widgets.notes.tint", noteTint)
    }

    // Profile persisted text & customizable images
    property string profileName: ConfigStore.stringValue("widgets.profile.name", "Yozora")
    property string profileStatus: ConfigStore.stringValue("widgets.profile.status", "Wonderhoy Desktop Shell")
    property string profileAvatarUrl: ConfigStore.stringValue("widgets.profile.avatar", "")
    property string profileBannerUrl: ConfigStore.stringValue("widgets.profile.banner", "")
    property string quickPanelBannerUrl: ConfigStore.stringValue("quickPanel.banner", "")
    property string quickPanelAvatarUrl: ConfigStore.stringValue("quickPanel.avatar", "")

    function saveProfile(name, status) {
        profileName = name.trim() !== "" ? name.trim() : "Yozora"
        profileStatus = status.trim() !== "" ? status.trim() : "SekaiDesk"
        ConfigStore.set("widgets.profile.name", profileName)
        ConfigStore.set("widgets.profile.status", profileStatus)
    }

    function setProfileAvatar(url) {
        profileAvatarUrl = String(url || "")
        ConfigStore.set("widgets.profile.avatar", profileAvatarUrl)
    }

    function setProfileBanner(url) {
        profileBannerUrl = String(url || "")
        ConfigStore.set("widgets.profile.banner", profileBannerUrl)
    }

    function setQuickPanelBanner(url) {
        quickPanelBannerUrl = String(url || "")
        ConfigStore.set("quickPanel.banner", quickPanelBannerUrl)
    }

    function setQuickPanelAvatar(url) {
        quickPanelAvatarUrl = String(url || "")
        ConfigStore.set("quickPanel.avatar", quickPanelAvatarUrl)
    }

    // Calendar Events & Deadlines persisted in ConfigStore
    property var calendarEvents: {
        const raw = ConfigStore.get("widgets.calendar.events", null)
        if (Array.isArray(raw))
            return raw
        const rawJson = ConfigStore.stringValue("widgets.calendar.eventsJson", "")
        if (rawJson !== "") {
            try {
                const parsed = JSON.parse(rawJson)
                if (Array.isArray(parsed))
                    return parsed
            } catch (e) {}
        }
        return []
    }

    function saveCalendarEvents(arr) {
        const clean = Array.isArray(arr) ? arr : []
        calendarEvents = clean
        ConfigStore.set("widgets.calendar.events", clean)
        ConfigStore.set("widgets.calendar.eventsJson", JSON.stringify(clean))
    }

    function nextCalendarEventId(list) {
        const used = {}
        for (let i = 0; i < list.length; ++i)
            used[list[i].id] = true
        let n = list.length + 1
        while (used["e" + n])
            n++
        return "e" + n
    }

    function upsertCalendarEvent(ev) {
        if (!ev || !ev.title || !ev.date)
            return
        const next = calendarEvents.slice()
        const entry = {
            id: ev.id && ev.id !== "" ? ev.id : nextCalendarEventId(next),
            title: String(ev.title).trim().slice(0, 80),
            date: String(ev.date),
            time: String(ev.time || ""),
            note: String(ev.note || "").trim().slice(0, 240),
            color: Math.max(0, Math.min(4, parseInt(ev.color, 10) || 0)),
            kind: ev.kind === "deadline" ? "deadline" : "event",
            done: ev.kind === "deadline" && ev.done === true
        }
        let replaced = false
        for (let i = 0; i < next.length; ++i) {
            if (next[i].id === entry.id) {
                next[i] = entry
                replaced = true
                break
            }
        }
        if (!replaced)
            next.push(entry)
        saveCalendarEvents(next)
    }

    function toggleCalendarDone(id) {
        const next = calendarEvents.slice()
        for (let i = 0; i < next.length; ++i) {
            if (next[i].id === id) {
                const cur = next[i]
                next[i] = {
                    id: cur.id, title: cur.title, date: cur.date, time: cur.time,
                    note: cur.note, color: cur.color, kind: cur.kind, done: !cur.done
                }
                saveCalendarEvents(next)
                return
            }
        }
    }

    function deleteCalendarEvent(id) {
        saveCalendarEvents(calendarEvents.filter(e => e.id !== id))
    }

    // Desktop Image Frames (#6 Polaroid / Washi-Tape ImageWidget)
    property var imageFrames: []

    function _loadImageFrames() {
        const rawJson = ConfigStore.stringValue("widgets.imageFrames", "")
        if (rawJson !== "") {
            try {
                const parsed = JSON.parse(rawJson)
                if (Array.isArray(parsed)) {
                    imageFrames = parsed
                    return
                }
            } catch (e) {}
        }
        imageFrames = []
    }

    function _saveImageFrames(list) {
        const clean = Array.isArray(list) ? list : []
        imageFrames = clean
        ConfigStore.set("widgets.imageFrames", JSON.stringify(clean))
    }

    function addImageFrame(path) {
        const clean = String(path || "").trim()
        const n = imageFrames.length
        const baseX = Math.max(virtMinX + 24, Math.round((screenW - 260) * 0.5) + ((n % 4) - 1) * 36)
        const baseY = Math.max(64, Math.round((screenH - 300) * 0.45) + ((n % 3) - 1) * 28)
        const tilts = [-2.5, 2.0, -1.5, 3.0]
        const entry = {
            id: "img_" + Date.now() + "_" + Math.floor(Math.random() * 10000),
            path: clean,
            x: clampWidgetX(baseX, 140),
            y: clampWidgetY(baseX, baseY, 120),
            w: 260,
            h: 300,
            fitMode: "crop",
            showTape: true,
            showFrame: true,
            pinned: false,
            tilt: tilts[n % tilts.length]
        }
        const next = imageFrames.slice()
        next.push(entry)
        _saveImageFrames(next)
        return entry.id
    }

    function updateImageFrame(id, patch) {
        if (!id || !patch)
            return
        const next = imageFrames.slice()
        let changed = false
        for (let i = 0; i < next.length; ++i) {
            if (next[i].id === id) {
                const merged = Object.assign({}, next[i], patch)
                merged.w = Math.max(140, Math.min(720, Math.round(Number(merged.w) || 260)))
                merged.h = Math.max(140, Math.min(720, Math.round(Number(merged.h) || 300)))
                if (patch.x !== undefined || patch.y !== undefined) {
                    merged.x = clampWidgetX(merged.x, 80)
                    merged.y = clampWidgetY(merged.x, merged.y, 80)
                }
                next[i] = merged
                changed = true
                break
            }
        }
        if (changed)
            _saveImageFrames(next)
    }

    function removeImageFrame(id) {
        _saveImageFrames(imageFrames.filter(it => it.id !== id))
    }
}
