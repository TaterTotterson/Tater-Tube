import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Components

Window {
    id: root
    flags: Qt.FramelessWindowHint | Qt.Window
    x:      Qt.platform.os === "osx" ? macScreenX      : Screen.virtualX
    y:      Qt.platform.os === "osx" ? macScreenY      : Screen.virtualY
    width:  Qt.platform.os === "osx" ? macScreenWidth  : Screen.width
    height: Qt.platform.os === "osx" ? macScreenHeight : Screen.height
    visible: true
    color: root.surfaceColor

    // --- Color Schemes ---
    readonly property var themes: ({
        "Video 1": {
            "primary": "#FFFFFF",
            "secondary": "#C2BFE4",
            "tertiary": "#8480C9",
            "surface": "#0A0094",
            "accent": "#AECFFF"
        },
        "Late Night": {
            "primary": "#FFFFFF",
            "secondary": "#A1A1A1",
            "tertiary": "#444444",
            "surface": "#000000",
            "accent": "#FFD900"
        },
        "Synthwave": {
            "primary": "#FFFFFF",
            "secondary": "#D48BFF",
            "tertiary": "#7836B5",
            "surface": "#12012B",
            "accent": "#00E5FF"
        },
        "Terminal": {
            "primary": "#4AF626",
            "secondary": "#32A81B",
            "tertiary": "#1A590E",
            "surface": "#000000",
            "accent": "#4AF626"
        },
        "T-120": {
            "primary": "#000000",
            "secondary": "#818181",
            "tertiary": "#df9c27",
            "surface": "#FAF5E8",
            "accent": "#EE442F"
        },
        "Amber": {
            "primary": "#FFB000",
            "secondary": "#B37B00",
            "tertiary": "#B37B00",
            "surface": "#000000",
            "accent": "#FFEE11"
        },
        "Kinescope": {
            "primary": "#FFFFFF",
            "secondary": "#9E9E9E",
            "tertiary": "#424242",
            "surface": "#121212",
            "accent": "#FFFFFF"
        },
        "Off Air": {
            "primary": "#FFFFFF",
            "secondary": "#E8E8E8",
            "tertiary": "#8A8A8A",
            "surface": "#050505",
            "accent": "#FF6A00",
            "static": true
        }
    })
    property var allThemes: themes  // may gain a "Custom" entry on startup
    property string currentTheme: "Off Air"
    readonly property var offAirHighlightColors: ({
        "Orange": "#FF6A00",
        "Cyan": "#00E5FF",
        "Green": "#39FF14",
        "Magenta": "#FF2BD6",
        "Red": "#FF3030",
        "Blue": "#3EA0FF",
        "Amber": "#FFB000",
        "White": "#FFFFFF"
    })
    property string offAirHighlightColor: "Orange"
    property int vcrClockBaseMinutes: 0
    property double vcrClockSetAtMs: 0
    property int vcrClockTick: 0
    property bool vcrClockColonVisible: true
    property string vcrClockText: formatVcrClock()
    property string sleepTimerMode: "Off"
    property double sleepTimerEndMs: 0
    property int sleepTimerRemainingSeconds: -1
    property bool sleepTimerWarningVisible: sleepTimerRemainingSeconds > 0 && sleepTimerRemainingSeconds <= 60
    property string primaryColor:   (allThemes[currentTheme] || allThemes["Off Air"]).primary
    property string secondaryColor: (allThemes[currentTheme] || allThemes["Off Air"]).secondary
    property string tertiaryColor:  (allThemes[currentTheme] || allThemes["Off Air"]).tertiary
    property string surfaceColor:   (allThemes[currentTheme] || allThemes["Off Air"]).surface
    property string accentColor:    currentTheme === "Off Air"
        ? (offAirHighlightColors[offAirHighlightColor] || offAirHighlightColors["Orange"])
        : (allThemes[currentTheme] || allThemes["Off Air"]).accent
    property bool staticBackgroundEnabled: !!((allThemes[currentTheme] || allThemes["Off Air"]).static)

    readonly property real sw: width
    readonly property real sh: height

    Connections {
        target: appCore
        function onAppSettingChanged(key, value) {
            if (key === "color_scheme") root.currentTheme = value
            if (key === "off_air_highlight_color") root.offAirHighlightColor = value
            if (key === "vcr_clock_minutes" || key === "vcr_clock_set_at_ms")
                root.loadVcrClock(appCore.get_settings())
            if (key === "sleep_timer_mode" || key === "sleep_timer_end_ms")
                root.loadSleepTimer(appCore.get_settings())
        }
    }

    function clampInt(value, minValue, maxValue, fallback) {
        var parsed = parseInt(value)
        if (isNaN(parsed)) return fallback
        return Math.max(minValue, Math.min(maxValue, parsed))
    }

    function loadVcrClock(cfg) {
        var app = (cfg && cfg.app) ? cfg.app : {}
        var minutes = Number(app.vcr_clock_minutes)
        var setAt = Number(app.vcr_clock_set_at_ms)
        if (isNaN(minutes)) minutes = 0
        if (isNaN(setAt) || setAt <= 0) setAt = Date.now()
        vcrClockBaseMinutes = ((Math.floor(minutes) % 1440) + 1440) % 1440
        vcrClockSetAtMs = setAt
        vcrClockTick++
    }

    function vcrClockMinutesNow() {
        var elapsedMinutes = Math.max(0, Math.floor((Date.now() - vcrClockSetAtMs) / 60000))
        return (vcrClockBaseMinutes + elapsedMinutes) % 1440
    }

    function vcrClockParts() {
        var minutes = vcrClockMinutesNow()
        var hour24 = Math.floor(minutes / 60)
        var minute = minutes % 60
        var period = hour24 >= 12 ? "PM" : "AM"
        var hour12 = hour24 % 12
        if (hour12 === 0) hour12 = 12
        return { hour: hour12, minute: minute, period: period }
    }

    function formatVcrClock() {
        vcrClockTick
        var parts = vcrClockParts()
        var minute = parts.minute < 10 ? "0" + parts.minute : "" + parts.minute
        var colon = vcrClockColonVisible ? ":" : " "
        return parts.hour + colon + minute + " " + parts.period
    }

    function setVcrClock(hour12, minute, period) {
        var hour = clampInt(hour12, 1, 12, 12)
        var min = clampInt(minute, 0, 59, 0)
        var p = (period === "PM") ? "PM" : "AM"
        var hour24 = hour % 12
        if (p === "PM") hour24 += 12
        var minutes = hour24 * 60 + min
        var setAt = Date.now()
        vcrClockBaseMinutes = minutes
        vcrClockSetAtMs = setAt
        vcrClockTick++
        appCore.save_setting("", "vcr_clock_minutes", minutes)
        appCore.save_setting("", "vcr_clock_set_at_ms", setAt)
    }

    function sleepTimerMinutes(mode) {
        if (mode === "30 Min") return 30
        if (mode === "60 Min") return 60
        if (mode === "90 Min") return 90
        return 0
    }

    function loadSleepTimer(cfg) {
        var app = (cfg && cfg.app) ? cfg.app : {}
        sleepTimerMode = app.sleep_timer_mode || "Off"
        sleepTimerEndMs = Number(app.sleep_timer_end_ms || 0)
        if (sleepTimerMinutes(sleepTimerMode) <= 0)
            sleepTimerRemainingSeconds = -1
        checkSleepTimer()
    }

    function setSleepTimerMode(mode) {
        var minutes = sleepTimerMinutes(mode)
        sleepTimerMode = minutes > 0 ? mode : "Off"
        sleepTimerEndMs = minutes > 0 ? Date.now() + minutes * 60000 : 0
        appCore.save_setting("", "sleep_timer_mode", sleepTimerMode)
        appCore.save_setting("", "sleep_timer_end_ms", sleepTimerEndMs)
        checkSleepTimer()
    }

    function checkSleepTimer() {
        var minutes = sleepTimerMinutes(sleepTimerMode)
        if (minutes <= 0 || sleepTimerEndMs <= 0) {
            sleepTimerRemainingSeconds = -1
            return
        }

        var remaining = Math.ceil((sleepTimerEndMs - Date.now()) / 1000)
        sleepTimerRemainingSeconds = remaining
        if (remaining <= 0)
            Qt.quit()
    }

    Component.onCompleted: {
        var cfg = appCore.get_settings()

        var custom = appCore.getCustomColorScheme()
        if (Object.keys(custom).length === 5) {
            var t = Object.assign({}, themes)
            t["Custom"] = custom
            root.allThemes = t
        }

        var savedTheme = (cfg.app && cfg.app.color_scheme) || "Off Air"
        if (savedTheme === "Custom" && !root.allThemes["Custom"]) {
            appCore.save_setting("", "color_scheme", "Off Air")
            savedTheme = "Off Air"
        }
        root.currentTheme = savedTheme

        var savedOffAirHighlight = (cfg.app && cfg.app.off_air_highlight_color) || "Orange"
        if (!root.offAirHighlightColors[savedOffAirHighlight]) {
            appCore.save_setting("", "off_air_highlight_color", "Orange")
            savedOffAirHighlight = "Orange"
        }
        root.offAirHighlightColor = savedOffAirHighlight
        loadVcrClock(cfg)
        loadSleepTimer(cfg)

        // Break declarative bindings on macOS so the C++ NSWindow override
        // in forceWindowFullScreen() isn't immediately re-fought by QML.
        if (Qt.platform.os === "osx") {
            root.x = macScreenX
            root.y = macScreenY
            root.width = macScreenWidth
            root.height = macScreenHeight
        }
    }
    
    FontLoader {
        id: font; source: "assets/fonts/VCR_OSD_MONO_1.001.ttf"
    }
    property string globalFont: font.name;

    Timer {
        interval: 500
        repeat: true
        running: true
        onTriggered: {
            root.vcrClockColonVisible = !root.vcrClockColonVisible
            root.vcrClockTick++
            root.checkSleepTimer()
        }
    }

    // --- INPUT / APP INFO MIRRORS ---
    // Views must bind these via `root.*`, never the appCore/inputManager
    // context properties directly: when the module Loader swaps views, the
    // dying view's context properties resolve to null and any binding on them
    // throws a TypeError during teardown. id-resolved `root.*` stays valid
    // (root lives as long as the app), so these mirrors are teardown-safe.
    // The null guards absorb the same nulling here at app shutdown, when the
    // engine invalidates the root context itself.
    readonly property var hints: inputManager ? inputManager.hints : ({})
    readonly property string appVersion: appCore ? appCore.appVersion : ""

    // --- APP-LEVEL NAV STACK ---
    property var appNavStack: []
    property var appCurrentParams: ({})

    // --- MODULE LOADER ---
    StaticBackground {
        anchors.fill: parent
        visible: root.staticBackgroundEnabled
        running: visible
    }

    Loader {
        id: moduleLoader;
        anchors.fill: parent;
        focus: true;
        source: "views/ModuleList.qml";

        Keys.onPressed: (event) => {
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Q) {
                Qt.quit()
            }
        }

        onLoaded: item.forceActiveFocus()

        Connections {
            target: moduleLoader.item
            ignoreUnknownSignals: true

            function onNavigateTo(path, params, listState) {
                root.appNavStack.push({ source: moduleLoader.source, params: root.appCurrentParams, listState: listState || {} })
                root.appCurrentParams = params || {}
                moduleLoader.setSource(path, { "navParams": params || {} })
            }

            function onGoBack() {
                if (root.appNavStack.length === 0) return
                var prev = root.appNavStack.pop()
                root.appCurrentParams = prev.params
                moduleLoader.setSource(prev.source, { "navParams": prev.params, "navListState": prev.listState || {} })
            }

        }
    }

    Rectangle {
        visible: root.sleepTimerWarningVisible
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.sh * 0.10
        anchors.rightMargin: root.sw * 0.10
        width: root.sw * 0.25
        height: root.sh * 0.12
        color: "black"
        border.color: root.primaryColor
        border.width: 2

        Column {
            anchors.centerIn: parent
            spacing: root.sh * 0.01

            Text {
                text: "SLEEP"
                color: root.primaryColor
                font.family: root.globalFont
                horizontalAlignment: Text.AlignHCenter
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }

            Text {
                text: Math.max(0, root.sleepTimerRemainingSeconds)
                color: root.accentColor
                font.family: root.globalFont
                horizontalAlignment: Text.AlignHCenter
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.05
            }
        }
    }
}
