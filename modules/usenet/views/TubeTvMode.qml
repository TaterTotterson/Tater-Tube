import QtQuick
import Components

FocusScope {
    id: tvRoot

    property var navParams: ({})

    signal goBack()

    property string tubeModuleId: "com.240mp.usenet"
    property var sourceCategories: navParams.categories || []
    property var channels: []
    property var commercialPool: []
    property var tvLoadQueue: []
    property var tvCurrentLoad: ({})
    property var tvChannelMap: ({})
    property var tvChannelOrder: []
    property int currentIndex: -1
    property int previousIndex: -1
    property int currentScheduleIndex: -1
    property double startedAtMs: 0
    property bool loading: true
    property bool loadingServerLineup: false
    property bool leaving: false
    property bool tuningStaticVisible: true
    property bool noSignalVisible: false
    property bool stoppingForTune: false
    property bool stoppingForScheduleAdvance: false
    property bool streamStarted: false
    property bool transitionBlankVisible: false
    property bool showChannelLabelAfterTransition: false
    // Debounce channel surfing without making every cold tune wait a full second.
    property int tuneDelayMs: 700
    property string statusText: "LOADING TV MODE"
    property string streamInfoText: ""
    property bool currentStreamUsesServer: false
    property double currentPlaybackOffsetSeconds: 0
    property bool currentPlaybackUsesServerSeek: false
    property bool guideChannelVisible: false
    property var guideDisplayChannels: []
    property var guideLineupMetadata: ({})
    property double guideNowMs: Date.now()
    property double guideServerClockOffsetMs: 0
    property string guideMascotSource: Qt.resolvedUrl("../../../assets/images/mascots/usenet.png")
    property bool teletextVisible: false
    property string teletextPage: "100"
    property string teletextTitle: "TATERTEXT INDEX"
    property double teletextNowMs: Date.now()
    property var teletextActiveStreams: []
    property var teletextServerStatus: ({})
    property string teletextFont: "DejaVu Sans Mono"

    focus: true

    function padChannelNumber(value) {
        var text = String(value)
        return text.length < 2 ? "0" + text : text
    }

    function shuffleList(items) {
        var shuffled = (items || []).slice()
        for (var i = shuffled.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1))
            var tmp = shuffled[i]
            shuffled[i] = shuffled[j]
            shuffled[j] = tmp
        }
        return shuffled
    }

    function settingEnabled(moduleId, key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "")
            return fallback
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function commercialsEnabled() {
        return settingEnabled(tubeModuleId, "tube_tv_mode_commercials", true)
    }

    function guideServiceEnabled() {
        return settingEnabled(tubeModuleId, "tube_tv_guide_channel", true)
    }

    function teletextServiceEnabled() {
        return settingEnabled(tubeModuleId, "tube_tv_teletext", true)
    }

    function midrollCommercialsEnabled() {
        return settingEnabled(tubeModuleId, "tube_midroll_commercials", false)
    }

    function rawDurationSeconds(item) {
        var raw = item ? item.durationSeconds : 0
        if ((raw === undefined || raw === null || raw === "") && item)
            raw = item.duration
        var value = typeof raw === "number" ? raw : parseFloat(raw)
        if (isNaN(value) || value <= 0)
            return 0
        if (value > 10000)
            value = value / 1000.0
        return value
    }

    function durationSeconds(item, fallback) {
        var value = rawDurationSeconds(item)
        if (value <= 0)
            value = fallback
        return Math.max(5, value)
    }

    function hasKnownDuration(item) {
        return rawDurationSeconds(item) > 0
    }

    function channelLabel(channel) {
        if (!channel) return "CH --"
        var title = String(channel.title || "").trim()
        return "CH " + (channel.number || "--") + (title !== "" ? " " + title : "")
    }

    function isGuideChannel(channel) {
        return channel && channel.guideChannel === true
    }

    function guideChannel() {
        return {
            number: "01",
            title: "TATER GUIDE",
            guideChannel: true,
            schedule: [],
            totalDuration: 3600
        }
    }

    function dateMs(value) {
        var parsed = Date.parse(String(value || ""))
        return isNaN(parsed) ? 0 : parsed
    }

    function formatShortDuration(seconds) {
        var total = Math.max(0, Math.round(Number(seconds || 0)))
        var minutes = Math.floor(total / 60)
        if (minutes <= 0)
            return total + "S"
        if (minutes < 60)
            return minutes + "M"
        var hours = Math.floor(minutes / 60)
        var remaining = minutes % 60
        return hours + "H" + (remaining > 0 ? " " + remaining + "M" : "")
    }

    function scheduleTitle(row) {
        if (!row)
            return "STAND BY"
        var title = String(row.title || "").trim()
        if (title !== "")
            return title.toUpperCase()
        var path = String(row.path || "").split(/[\\/]/)
        return path.length > 0 ? String(path[path.length - 1]).toUpperCase() : "UNTITLED"
    }

    function scheduleKindLabel(row) {
        var kind = String((row && (row.kind || row.mediaType || row.type)) || "MEDIA").toUpperCase()
        if (kind === "COMMERCIAL")
            return "SPOT"
        if (kind === "EPISODE")
            return "TV"
        if (kind === "MOVIE")
            return "MOVIE"
        return kind
    }

    function guideNextRows(channel, currentIndex, count) {
        if (!channel || !channel.schedule || channel.schedule.length === 0)
            return []
        var rows = []
        var start = currentIndex >= 0 ? currentIndex + 1 : 0
        var limit = Math.min(count, channel.schedule.length)
        for (var i = 0; i < limit; i++)
            rows.push(channel.schedule[(start + i) % channel.schedule.length])
        return rows
    }

    function guideRowPitch() {
        return Math.max(1, root.sh * 0.14) + Math.max(1, root.sh * 0.006)
    }

    function guideCycleHeight() {
        var count = guideDisplayChannels ? guideDisplayChannels.length : 0
        return count * guideRowPitch()
    }

    function guideScrollSpeed() {
        return guideRowPitch() / 14.0
    }

    function guideScrollBaseMs() {
        var serverStartMs = dateMs(guideLineupMetadata.startedAt)
        if (serverStartMs > 0)
            return serverStartMs
        return startedAtMs > 0 ? startedAtMs : Date.now()
    }

    function timelineNowMs() {
        return Date.now() + guideServerClockOffsetMs
    }

    function guideTimelineNowMs() {
        return guideNowMs + guideServerClockOffsetMs
    }

    function teletextTimelineNowMs() {
        return teletextNowMs + guideServerClockOffsetMs
    }

    function guideScrollY() {
        var cycleHeight = guideCycleHeight()
        if (cycleHeight <= 0)
            return 0
        var elapsed = Math.max(0, (guideTimelineNowMs() - guideScrollBaseMs()) / 1000.0)
        var offset = (elapsed * guideScrollSpeed()) % cycleHeight
        return -offset
    }

    function guideRepeatedChannels(viewportHeight) {
        var base = guideDisplayChannels || []
        if (base.length === 0)
            return []
        var cycleHeight = Math.max(1, guideCycleHeight())
        var repeats = Math.max(3, Math.ceil((Math.max(0, viewportHeight) + cycleHeight) / cycleHeight) + 1)
        var rows = []
        for (var repeat = 0; repeat < repeats; repeat++) {
            for (var i = 0; i < base.length; i++)
                rows.push(base[i])
        }
        return rows
    }

    function teletextChannels() {
        if (!teletextServiceEnabled())
            return []
        return [
            { number: "100", title: "TATERTEXT INDEX", teletextPage: "100" },
            { number: "101", title: "TATER STATUS", teletextPage: "101" },
            { number: "200", title: "TUBE TV GUIDE", teletextPage: "200" },
            { number: "300", title: "SYSTEM STATS", teletextPage: "300" },
            { number: "400", title: "NOW PLAYING", teletextPage: "400" },
            { number: "500", title: "SERVER STATUS", teletextPage: "500" },
            { number: "600", title: "CONTROLS HELP", teletextPage: "600" },
            { number: "888", title: "SUBTITLES", teletextPage: "888" }
        ]
    }

    function isTeletextChannel(channel) {
        return channel && String(channel.teletextPage || "") !== ""
    }

    function teletextChannelCount() {
        return teletextChannels().length
    }

    function teletextRealChannels() {
        return guideDisplayChannels || []
    }

    function serviceChannels(realChannels) {
        var out = []
        if (guideServiceEnabled())
            out.push(guideChannel())
        return out.concat(realChannels || []).concat(teletextChannels())
    }

    function startupChannelIndex(realChannelCount) {
        return guideServiceEnabled() && realChannelCount > 0 ? 1 : 0
    }

    function teletextTwo(value) {
        return value < 10 ? "0" + value : String(value)
    }

    function teletextClock() {
        var d = new Date(teletextNowMs)
        return teletextTwo(d.getHours()) + ":" + teletextTwo(d.getMinutes()) + ":" + teletextTwo(d.getSeconds())
    }

    function teletextDate() {
        var d = new Date(teletextNowMs)
        return teletextTwo(d.getMonth() + 1) + "/" + teletextTwo(d.getDate()) + "/" + String(d.getFullYear()).slice(-2)
    }

    function teletextClean(value, fallback) {
        var text = String(value === undefined || value === null ? "" : value).trim()
        return text === "" ? fallback : text.toUpperCase()
    }

    function teletextShort(value, limit) {
        var text = teletextClean(value, "")
        if (text.length <= limit)
            return text
        return text.slice(0, Math.max(0, limit - 1)) + "."
    }

    function teletextLine(text, color, bg) {
        return {
            text: teletextClean(text, "").slice(0, 42),
            color: color || "#ffffff",
            bg: bg || "transparent"
        }
    }

    function teletextBlank() {
        return teletextLine("", "#ffffff")
    }

    function teletextHeader(page, title, bg) {
        return [
            teletextLine("P" + page + "  TATERTEXT  " + teletextDate() + " " + teletextClock(), "#ffffff", "#000000"),
            teletextLine("##########################################", "#ffff00", bg || "#0018a8"),
            teletextLine("## " + teletextShort(title, 36), "#ffff00", bg || "#0018a8"),
            teletextLine("##########################################", "#ffff00", bg || "#0018a8")
        ]
    }

    function teletextArtTater(color) {
        return [
            teletextLine("        .----.       .----.", color || "#ffff00"),
            teletextLine("       / T  T |     / TUBE|", color || "#ffff00"),
            teletextLine("      |  .--. |    | .--. |", "#ffffff"),
            teletextLine("      | ( OO )|    | ON  ||", "#ffffff"),
            teletextLine("       '.___.'      '.___.'", color || "#ffff00")
        ]
    }

    function teletextArtDish(color) {
        return [
            teletextLine("          ____", color || "#00ffff"),
            teletextLine("     ____/    )   TATER SIGNAL", color || "#00ffff"),
            teletextLine("   _/  __   _/    ))  ))  ))", "#ffffff"),
            teletextLine("  /___/  )_/      GOOD LOCK", "#ffff00")
        ]
    }

    function teletextBox(rows, title, color) {
        rows.push(teletextLine("+" + "----------------------------------------" + "+", color || "#ff3030"))
        rows.push(teletextLine("| " + teletextShort(title, 38), color || "#ff3030"))
        rows.push(teletextLine("+" + "----------------------------------------" + "+", color || "#ff3030"))
    }

    function teletextSetting(key, fallback) {
        var value = appCore.get_setting(tubeModuleId, key)
        if (value === undefined || value === null || value === "")
            return fallback
        return value
    }

    function teletextBool(value) {
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function teletextSetupStatus() {
        var status = usenetBackend.get_setup_status()
        return status || ({})
    }

    function teletextRefreshData() {
        teletextNowMs = Date.now()
        teletextServerStatus = teletextSetupStatus()
        if (teletextVisible && (teletextPage === "300" || teletextPage === "400" || teletextPage === "500"))
            usenetBackend.load_active_streams()
    }

    function teletextAddFooter(rows) {
        rows.push(teletextBlank())
        rows.push(teletextLine(" FASTEXT  RED   GREEN  YELLOW  BLUE ", "#000000", "#00ffff"))
        rows.push(teletextLine("  TUNE UP/DOWN FOR NEXT SERVICE PAGE", "#ffff00", "#000000"))
        return rows
    }

    function teletextIndexRows() {
        var rows = teletextHeader("100", "TATER TUBE MAIN INDEX", "#0018a8")
        rows = rows.concat(teletextArtTater("#ffff00"))
        rows.push(teletextLine("100 MAIN INDEX       101 TATER STATUS", "#00ff00", "#000000"))
        rows.push(teletextLine("200 TUBE TV GUIDE    300 SYSTEM MAP", "#ffffff", "#000000"))
        rows.push(teletextLine("400 NOW PLAYING      500 SERVER ROOM", "#ffffff", "#000000"))
        rows.push(teletextLine("600 REMOTE HELP      888 SUBTITLES", "#ffffff", "#000000"))
        rows.push(teletextLine("==========================================", "#ff3030"))
        rows.push(teletextLine("   WELCOME TO THE TATER TEXT SERVICE", "#ffff00", "#0018a8"))
        rows.push(teletextLine("   NO CURSOR - WAIT FOR YOUR PAGE", "#00ffff"))
        rows.push(teletextLine("   OLD SIGNALS  NEW TUBES  HOT SPUDS", "#00ff00"))
        return teletextAddFooter(rows)
    }

    function teletextStatusRows() {
        var status = teletextServerStatus || ({})
        var channelCount = teletextRealChannels().length
        var mode = teletextClean(teletextSetting("tube_transcode_mode", "AUTO"), "AUTO")
        var quality = profileLabel(teletextSetting("tube_transcode_quality", "AUTO"))
        var rows = teletextHeader("101", "TATER TUBE STATUS", "#d60000")
        teletextBox(rows, "SET TOP BOX REPORT", "#ffff00")
        rows.push(teletextLine("APP VERSION .... " + appCore.appVersion, "#00ff00"))
        rows.push(teletextLine("SERVER PAIRED ... " + (status.configured ? "YES" : "NO"), status.configured ? "#00ff00" : "#ff3030"))
        rows.push(teletextLine("TUBE CHANNELS ... " + channelCount + "    TEXT " + teletextChannelCount(), "#ffffff"))
        rows.push(teletextLine("SCREEN .......... " + Math.round(root.sw) + "X" + Math.round(root.sh), "#ffffff"))
        rows.push(teletextLine("TRANSCODE ....... " + mode + " / " + (quality === "" ? "AUTO" : quality), "#00ffff"))
        rows.push(teletextLine("COMMERCIALS ..... " + (commercialsEnabled() ? "ON" : "OFF"), commercialsEnabled() ? "#00ff00" : "#ffff00"))
        rows.push(teletextLine("AUTO CHANNELS ... " + (autoChannelsEnabled() ? "ON" : "OFF"), autoChannelsEnabled() ? "#00ff00" : "#ffff00"))
        rows = rows.concat(teletextArtDish("#00ffff"))
        return teletextAddFooter(rows)
    }

    function teletextGuideRows() {
        var rows = teletextHeader("200", "TATER GUIDE", "#0018a8")
        var list = teletextRealChannels()
        if (list.length === 0) {
            rows.push(teletextLine("NO TUBE TV CHANNELS AVAILABLE", "#ff3030"))
            rows.push(teletextLine("CHECK SERVER SCHEDULE AND MEDIA DURATIONS", "#ffff00"))
        } else {
            rows.push(teletextLine(" CH   NOW SHOWING                 NEXT", "#000000", "#00ffff"))
            for (var i = 0; i < Math.min(7, list.length); i++) {
                var channel = list[i]
                var resolved = findScheduleItem(channel, teletextTimelineNowMs())
                var current = resolved ? resolved.item : null
                var next = guideNextRows(channel, resolved ? resolved.index : -1, 1)
                var label = String(channel.number || "--") + "  " + teletextShort(scheduleTitle(current), 24)
                rows.push(teletextLine(label, i % 2 === 0 ? "#ffffff" : "#ffff00", i % 2 === 0 ? "#000000" : "#00005f"))
                if (next.length > 0)
                    rows.push(teletextLine("     >> " + teletextShort(scheduleTitle(next[0]), 31), "#00ff00"))
            }
        }
        return teletextAddFooter(rows)
    }

    function teletextSystemRows() {
        var rows = teletextHeader("300", "TATER WEATHER MAP", "#0018a8")
        rows.push(teletextLine("      SYSTEM CONDITIONS FOR THE TUBE", "#00ff00"))
        rows.push(teletextLine("        .-''''-.      SNOW  40%", "#ffff00"))
        rows.push(teletextLine("      .'  CRT   '.    BUZZ  LOW", "#ffff00"))
        rows.push(teletextLine("     /  STATIC   |    SYNC  GOOD", "#ffffff"))
        rows.push(teletextLine("     '._      _.'     HEAT  OK", "#ffffff"))
        rows.push(teletextLine("--------'----'----------------------", "#ff3030"))
        rows.push(teletextLine("RESOLUTION ..... " + Math.round(root.sw) + "X" + Math.round(root.sh), "#ffffff"))
        rows.push(teletextLine("SERVER ......... " + (teletextServerStatus.configured ? "LOCKED" : "NOT PAIRED"), teletextServerStatus.configured ? "#00ff00" : "#ff3030"))
        rows.push(teletextLine("STREAMS ........ " + teletextActiveStreams.length + " ACTIVE", "#ffffff"))
        rows.push(teletextLine("OUTLOOK ........ TRACKING IMPROVING", "#00ffff"))
        return teletextAddFooter(rows)
    }

    function teletextNowPlayingRows() {
        var rows = teletextHeader("400", "NOW PLAYING", "#0018a8")
        rows.push(teletextLine("   ___   ___   ___     ACTIVE STREAMS", "#ffff00"))
        rows.push(teletextLine("  |REC| |PLAY| |TV |    LIVE FROM SERVER", "#ffff00"))
        rows.push(teletextLine("   ---   ---   ---", "#ff3030"))
        var streams = asList(teletextActiveStreams)
        if (streams.length === 0) {
            rows.push(teletextLine("NO ACTIVE SERVER STREAMS", "#ffff00"))
            rows.push(teletextLine("STAND BY FOR TRANSMISSION", "#00ffff"))
        } else {
            for (var i = 0; i < Math.min(4, streams.length); i++) {
                var row = streams[i] || ({})
                rows.push(teletextLine("> " + teletextShort(row.title || row.name || row.path || "UNTITLED", 35), "#ffffff", "#00005f"))
                rows.push(teletextLine("  BOX " + teletextShort(row.player_name || row.player || "TATER", 18) + "  " + teletextShort(streamInfoFromActiveStream(row), 16), "#00ff00"))
            }
        }
        return teletextAddFooter(rows)
    }

    function teletextServerRows() {
        var status = teletextServerStatus || ({})
        var serverUrl = teletextShort(status.serverUrl || "NOT SET", 31)
        var rows = teletextHeader("500", "SERVER ROOM", "#d60000")
        rows.push(teletextLine("  [====]  [====]  [====]  TATER RACK", "#00ffff"))
        rows.push(teletextLine("  |    |  |    |  |    |  HUMMING", "#ffffff"))
        rows.push(teletextLine("  [====]  [====]  [====]  " + (status.configured ? "ONLINE" : "PAIR ME"), status.configured ? "#00ff00" : "#ff3030"))
        teletextBox(rows, "LINK STATUS", "#ffff00")
        rows.push(teletextLine("PAIRING ....... " + (status.configured ? "READY" : "REQUIRED"), status.configured ? "#00ff00" : "#ff3030"))
        rows.push(teletextLine("URL ........... " + serverUrl, "#ffffff"))
        rows.push(teletextLine("ACTIVE ........ " + teletextActiveStreams.length + " STREAMS", "#ffffff"))
        rows.push(teletextLine("MODE .......... " + teletextClean(teletextSetting("tube_transcode_mode", "AUTO"), "AUTO"), "#00ffff"))
        rows.push(teletextLine("QUALITY ....... " + teletextClean(teletextSetting("tube_transcode_quality", "AUTO"), "AUTO"), "#00ffff"))
        rows.push(teletextLine("GUIDE START ... " + teletextShort(guideLineupMetadata.startedAt || "UNKNOWN", 24), "#ffff00"))
        return teletextAddFooter(rows)
    }

    function teletextHelpRows() {
        var rows = teletextHeader("600", "REMOTE HELP", "#0018a8")
        rows.push(teletextLine("      .----------------------.", "#ffff00"))
        rows.push(teletextLine("      |  UP  | OK |  BACK    |", "#ffffff"))
        rows.push(teletextLine("      | DOWN |HOME|  MENU    |", "#ffffff"))
        rows.push(teletextLine("      '----------------------'", "#ffff00"))
        rows.push(teletextLine("UP .......... NEXT CHANNEL", "#00ff00"))
        rows.push(teletextLine("DOWN ........ PREVIOUS CHANNEL", "#00ff00"))
        rows.push(teletextLine("BACK ........ EXIT TUBE TV", "#ffffff"))
        rows.push(teletextLine("OK .......... TUNE CURRENT CHANNEL", "#ffffff"))
        rows.push(teletextLine("LEFT/RIGHT .. DISABLED IN TV MODE", "#ffff00"))
        rows.push(teletextLine("TEXT PAGES ARE PASSIVE BROADCASTS", "#00ffff"))
        return teletextAddFooter(rows)
    }

    function teletextSubtitleRows() {
        var rows = teletextHeader("888", "SUBTITLE SERVICE", "#0018a8")
        rows.push(teletextLine("   .--------------------------------.", "#ffff00"))
        rows.push(teletextLine("   | [STATIC CRACKLES]              |", "#ffffff"))
        rows.push(teletextLine("   | [A TAPE WHIRS IN THE DISTANCE] |", "#ffffff"))
        rows.push(teletextLine("   | [REMOTE BUTTON CLICKS]         |", "#ffffff"))
        rows.push(teletextLine("   '--------------------------------'", "#ffff00"))
        rows.push(teletextLine("888 WAS OFTEN A SUBTITLE PAGE", "#00ffff"))
        rows.push(teletextLine("TATER TEXT HONORS THE OLD SIGNAL", "#00ff00"))
        rows.push(teletextLine("NO ACTUAL SUBTITLES ARE BROADCAST", "#ffff00"))
        return teletextAddFooter(rows)
    }

    function teletextRows() {
        if (teletextPage === "101")
            return teletextStatusRows()
        if (teletextPage === "200")
            return teletextGuideRows()
        if (teletextPage === "300")
            return teletextSystemRows()
        if (teletextPage === "400")
            return teletextNowPlayingRows()
        if (teletextPage === "500")
            return teletextServerRows()
        if (teletextPage === "600")
            return teletextHelpRows()
        if (teletextPage === "888")
            return teletextSubtitleRows()
        return teletextIndexRows()
    }

    function mediaKind(row) {
        return String((row && (row.mediaType || row.type)) || "").toLowerCase()
    }

    function rowType(row) {
        return String((row && row.type) || "").toLowerCase()
    }

    function asList(value) {
        if (!value)
            return []
        if (Array.isArray(value))
            return value
        if (typeof value.length === "number") {
            var list = []
            for (var i = 0; i < value.length; i++)
                list.push(value[i])
            return list
        }
        if (typeof value === "object") {
            var keys = Object.keys(value).filter(function(key) {
                return /^\d+$/.test(key)
            }).sort(function(left, right) {
                return parseInt(left) - parseInt(right)
            })
            if (keys.length > 0) {
                var mapped = []
                for (var k = 0; k < keys.length; k++)
                    mapped.push(value[keys[k]])
                return mapped
            }
        }
        return []
    }

    function intOrDefault(value, fallback) {
        if (value === undefined || value === null || value === "")
            return fallback
        var parsed = parseInt(value)
        return isNaN(parsed) ? fallback : parsed
    }

    function localCategoryRows() {
        var categories = asList(sourceCategories)
        for (var i = 0; i < categories.length; i++) {
            var row = categories[i] || ({})
            if (rowType(row) === "localroot")
                return asList(row.children).filter(function(child) { return rowType(child) === "local" })
        }
        return []
    }

    function savedCustomChannels() {
        var saved = appCore.get_setting(tubeModuleId, "tube_custom_tv_channels")
        return asList(saved)
    }

    function autoChannelsEnabled() {
        var value = appCore.get_setting(tubeModuleId, "tube_auto_channels")
        if (value === undefined || value === null || value === "")
            return true
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function cleanUpper(value) {
        return String(value || "").trim().toUpperCase()
    }

    function queryValue(url, key) {
        var escaped = String(key || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
        var match = String(url || "").match(new RegExp("[?&]" + escaped + "=([^&]*)"))
        if (!match)
            return ""
        return decodeURIComponent(String(match[1]).replace(/\+/g, " "))
    }

    function profileLabel(value) {
        var profile = cleanUpper(value).replace(/_/g, " ")
        if (profile === "CRT 480P")
            return "CRT 480P"
        if (profile === "HDMI 1080P")
            return "HDMI 1080P"
        if (profile === "HDMI 4K")
            return "HDMI 4K"
        return profile
    }

    function formatRate(bytesPerSecond) {
        var value = Number(bytesPerSecond || 0)
        if (!isFinite(value) || value <= 0)
            return ""
        if (value >= 1024 * 1024)
            return (value / (1024 * 1024)).toFixed(1) + " MB/S"
        if (value >= 1024)
            return Math.round(value / 1024) + " KB/S"
        return Math.round(value) + " B/S"
    }

    function plannedStreamInfo(playbackUrl, item) {
        if (item && item.kind === "commercial")
            return "SERVER SPOT | DIRECT PLAY"
        if (queryValue(playbackUrl, "transcode") === "0")
            return "SERVER STREAM | DIRECT PLAY"

        var profile = profileLabel(queryValue(playbackUrl, "profile"))
        var parts = ["SERVER TRANSCODE", "HW AUTO"]
        if (profile !== "")
            parts.push(profile)
        return parts.join(" | ")
    }

    function streamInfoFromActiveStream(row) {
        if (!row)
            return ""

        var status = cleanUpper(row["status"])
        var speed = formatRate(row["bytes_per_second"])
        var profile = profileLabel(row["transcode_name"] || row["transcode_profile"])
        var codec = cleanUpper(row["video_codec"])
        var accel = cleanUpper(row["hardware_acceleration"])
        var parts = []

        if (row["transcoded"] === true) {
            if (row["hardware_active"] === true && accel !== "")
                parts.push("HW " + accel)
            else
                parts.push("SOFTWARE")
            if (codec !== "")
                parts.push(codec)
            if (profile !== "")
                parts.push(profile)
        } else {
            parts.push(status === "STARTING" || status === "BUFFERING"
                       ? "SERVER STREAM" : "DIRECT PLAY")
        }

        if (speed !== "")
            parts.push(speed)
        if (status !== "" && status !== "TRANSCODING")
            parts.push(status)
        return parts.join(" | ")
    }

    function updateStreamOverlayInfo(info) {
        var text = cleanUpper(info)
        if (text === "")
            return
        streamInfoText = text
        if (mpvController.running)
            mpvController.sendScriptMessage("240mp-ota-stream-info", streamInfoText)
    }

    function refreshActiveStreamInfo() {
        if (!currentStreamUsesServer || !streamStarted || tuningStaticVisible
                || noSignalVisible || leaving || !mpvController.running)
            return
        usenetBackend.load_active_streams()
    }

    function sourceSearchText(item) {
        if (!item)
            return ""
        var parts = [
            item.title || "",
            item.name || "",
            item.detail || "",
            item.description || "",
            item.category || "",
            item.path || "",
            item.date || "",
            item.year || "",
            item.mediaType || "",
            item.type || ""
        ]
        var genres = item.genres || item.genre || []
        if (Array.isArray(genres))
            parts.push(genres.join(" "))
        else
            parts.push(genres)
        return parts.join(" ").toLowerCase()
    }

    function itemYear(item) {
        var candidates = [
            item ? item.year : "",
            item ? item.date : "",
            item ? item.title : "",
            item ? item.path : ""
        ]
        for (var i = 0; i < candidates.length; i++) {
            var match = String(candidates[i] || "").match(/(19[0-9]{2}|20[0-9]{2})/)
            if (match)
                return parseInt(match[1])
        }
        return 0
    }

    function textHasAnyTerm(text, terms) {
        var haystack = String(text || "").toLowerCase()
        for (var i = 0; i < terms.length; i++) {
            if (haystack.indexOf(String(terms[i]).toLowerCase()) >= 0)
                return true
        }
        return false
    }

    function programHasAnyTerm(program, terms) {
        return textHasAnyTerm(sourceSearchText(program), terms)
    }

    function groupHasAnyTerm(group, terms) {
        if (textHasAnyTerm(group ? group.title : "", terms))
            return true
        var episodes = group ? (group.episodes || []) : []
        for (var i = 0; i < episodes.length; i++) {
            if (programHasAnyTerm(episodes[i], terms))
                return true
        }
        return false
    }

    function groupYear(group) {
        var episodes = group ? (group.episodes || []) : []
        for (var i = 0; i < episodes.length; i++) {
            var year = itemYear(episodes[i])
            if (year > 0)
                return year
        }
        var match = String(group ? group.title : "").match(/(19[0-9]{2}|20[0-9]{2})/)
        return match ? parseInt(match[1]) : 0
    }

    function filteredPrograms(programs, predicate) {
        var rows = []
        for (var i = 0; i < (programs || []).length; i++) {
            var program = programs[i] || ({})
            if (predicate(program))
                rows.push(program)
        }
        return rows
    }

    function filteredGroups(groups, predicate) {
        var rows = []
        for (var i = 0; i < (groups || []).length; i++) {
            var group = groups[i] || ({})
            if (predicate(group))
                rows.push(group)
        }
        return rows
    }

    function decadeLabel(decade) {
        return decade >= 2000 ? (String(decade) + "S") : (String(decade).slice(2) + "S")
    }

    function themedTitle(sourceTitle, channelTitle) {
        var source = cleanUpper(sourceTitle)
        var title = cleanUpper(channelTitle)
        var generic = ["", "LOCAL", "MOVIES", "MOVIE", "TV", "TELEVISION", "SHOWS", "SERIES", "VIDEO"]
        for (var i = 0; i < generic.length; i++) {
            if (source === generic[i])
                return title
        }
        if (title.indexOf(source) === 0)
            return title
        return source + " " + title
    }

    function channelSignature(programs, groups) {
        var keys = []
        for (var i = 0; i < (programs || []).length; i++) {
            var program = programs[i] || ({})
            keys.push("p:" + (mediaItemKey(program) || i))
        }
        for (var g = 0; g < (groups || []).length; g++) {
            var group = groups[g] || ({})
            keys.push("g:" + (group.title || g))
        }
        keys.sort()
        return keys.join("|")
    }

    function appendThemedSource(rows, signatures, title, sourceType, programs, groups, minCount, commercialCategory) {
        var programRows = programs || []
        var groupRows = groups || []
        var count = sourceType === "tv" ? groupRows.length : programRows.length
        if (count < minCount)
            return
        var signature = sourceType + ":" + channelSignature(programRows, groupRows)
        if (signature === sourceType + ":" || signatures[signature])
            return
        signatures[signature] = true
        rows.push({
            title: title,
            sourceType: "auto_theme",
            commercialCategory: commercialCategory || "",
            programs: programRows,
            groups: groupRows
        })
    }

    function themedSourcesFor(source) {
        var rows = []
        var signatures = ({})
        var programs = source.programs || []
        var groups = source.groups || []
        var baseTitle = source.title || "LOCAL"
        var commercialCategory = source.commercialCategory || ""
        var movieRules = [
            { title: "ACTION MOVIES", terms: ["action", "adventure", "thriller"], min: 2 },
            { title: "COMEDY MOVIES", terms: ["comedy"], min: 2 },
            { title: "HORROR MOVIES", terms: ["horror"], min: 2 },
            { title: "SCI-FI MOVIES", terms: ["science fiction", "sci-fi", "sci fi", "scifi"], min: 2 },
            { title: "FANTASY MOVIES", terms: ["fantasy"], min: 2 },
            { title: "FAMILY MOVIES", terms: ["family", "children", "kids", "disney", "pixar"], min: 2 },
            { title: "CARTOON MOVIES", terms: ["animation", "animated", "anime", "cartoon"], min: 2 },
            { title: "DOCUMENTARY MOVIES", terms: ["documentary", "docu"], min: 2 },
            { title: "DRAMA MOVIES", terms: ["drama"], min: 2 },
            { title: "CRIME MOVIES", terms: ["crime", "mystery"], min: 2 }
        ]
        for (var i = 0; i < movieRules.length; i++) {
            var rule = movieRules[i]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, rule.title), "movie",
                               filteredPrograms(programs, function(program) { return programHasAnyTerm(program, rule.terms) }),
                               [], rule.min, commercialCategory)
        }

        appendThemedSource(rows, signatures, themedTitle(baseTitle, "CLASSIC MOVIES"), "movie",
                           filteredPrograms(programs, function(program) {
                               var year = itemYear(program)
                               return year > 0 && year <= 1979
                           }), [], 2, commercialCategory)

        var decades = [1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
        for (var d = 0; d < decades.length; d++) {
            var decade = decades[d]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, decadeLabel(decade) + " MOVIES"), "movie",
                               filteredPrograms(programs, function(program) {
                                   var year = itemYear(program)
                                   return year >= decade && year < decade + 10
                               }), [], 2, commercialCategory)
        }

        var tvRules = [
            { title: "CARTOON CHANNEL", terms: ["animation", "animated", "anime", "cartoon", "children", "kids"], min: 1 },
            { title: "COMEDY CHANNEL", terms: ["comedy"], min: 1 },
            { title: "DRAMA CHANNEL", terms: ["drama"], min: 1 },
            { title: "SCI-FI CHANNEL", terms: ["science fiction", "sci-fi", "sci fi", "scifi"], min: 1 },
            { title: "ACTION CHANNEL", terms: ["action", "adventure"], min: 1 },
            { title: "CRIME CHANNEL", terms: ["crime", "mystery"], min: 1 },
            { title: "REALITY CHANNEL", terms: ["reality"], min: 1 },
            { title: "DOCUMENTARY CHANNEL", terms: ["documentary", "docu"], min: 1 }
        ]
        for (var r = 0; r < tvRules.length; r++) {
            var tvRule = tvRules[r]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, tvRule.title), "tv",
                               [], filteredGroups(groups, function(group) { return groupHasAnyTerm(group, tvRule.terms) }),
                               tvRule.min, commercialCategory)
        }

        appendThemedSource(rows, signatures, themedTitle(baseTitle, "CLASSIC TV"), "tv", [],
                           filteredGroups(groups, function(group) {
                               var year = groupYear(group)
                               return year > 0 && year <= 1979
                           }), 1, commercialCategory)

        for (var td = 0; td < decades.length; td++) {
            var tvDecade = decades[td]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, decadeLabel(tvDecade) + " TV"), "tv", [],
                               filteredGroups(groups, function(group) {
                                   var year = groupYear(group)
                                   return year >= tvDecade && year < tvDecade + 10
                               }), 1, commercialCategory)
        }
        return rows
    }

    function mediaItemKey(item) {
        if (!item)
            return ""
        return String(item.streamUrl || item.url || item.ratingKey || item.key ||
                      item.partKey || item.path || item.title || "").trim()
    }

    function lastProgramKey(schedule) {
        for (var i = (schedule || []).length - 1; i >= 0; i--) {
            var item = schedule[i] || ({})
            if (item.kind !== "commercial") {
                var key = mediaItemKey(item)
                if (key !== "")
                    return key
            }
        }
        return ""
    }

    function stateCanAvoidRepeat(state, previousKey) {
        if (!state || previousKey === "")
            return true
        var episodes = state.episodes || []
        if (episodes.length === 0)
            return false
        if (mediaItemKey(episodes[state.nextIndex % episodes.length]) !== previousKey)
            return true
        return episodes.length > 1
    }

    function chooseStateIndex(states, previousState, stickiness, previousKey) {
        if (!states || states.length === 0)
            return -1
        var stateIndex = Math.floor(Math.random() * states.length)
        if (previousState >= 0 && Math.random() < stickiness)
            stateIndex = previousState
        if (stateCanAvoidRepeat(states[stateIndex], previousKey))
            return stateIndex
        for (var i = 0; i < states.length; i++) {
            if (stateCanAvoidRepeat(states[i], previousKey))
                return i
        }
        return stateIndex
    }

    function nextEpisodeForState(state, previousKey) {
        if (!state)
            return null
        var episodes = state.episodes || []
        if (episodes.length === 0)
            return null
        for (var i = 0; i < episodes.length; i++) {
            var episode = episodes[state.nextIndex % episodes.length]
            state.nextIndex++
            if (mediaItemKey(episode) !== previousKey || episodes.length === 1)
                return episode
        }
        return episodes[(state.nextIndex - 1 + episodes.length) % episodes.length]
    }

    function takeNextMovie(movies, movieIndex, previousKey) {
        if (!movies || movieIndex >= movies.length)
            return null
        if (previousKey !== "" && mediaItemKey(movies[movieIndex]) === previousKey) {
            for (var i = movieIndex + 1; i < movies.length; i++) {
                if (mediaItemKey(movies[i]) !== previousKey) {
                    var tmp = movies[movieIndex]
                    movies[movieIndex] = movies[i]
                    movies[i] = tmp
                    break
                }
            }
        }
        return movies[movieIndex]
    }

    function commercialStatePool(state) {
        return state && state.pool ? state.pool : []
    }

    function randomCommercialFromState(state) {
        var pool = commercialStatePool(state)
        if (pool.length === 0)
            return null
        var deck = state.deck || []
        if (deck.length === 0)
            deck = shuffleList(pool)
        var previousKey = state.lastKey || ""
        for (var attempt = 0; attempt < Math.max(2, pool.length + 1); attempt++) {
            if (deck.length === 0)
                deck = shuffleList(pool)
            var commercial = deck.shift()
            var key = mediaItemKey(commercial)
            if (pool.length > 1 && key !== "" && key === previousKey) {
                deck.push(commercial)
                continue
            }
            state.deck = deck
            state.lastKey = key
            return commercial
        }
        var fallback = deck.length > 0 ? deck.shift() : pool[0]
        state.deck = deck
        state.lastKey = mediaItemKey(fallback)
        return fallback
    }

    function commercialStateForChannel(channelSource, states) {
        var category = String((channelSource && channelSource.commercialCategory) || "").trim()
        var key = category === "" ? "__global__" : ("category:" + category)
        if (!states[key]) {
            states[key] = {
                pool: category === ""
                      ? commercialPool
                      : usenetBackend.get_commercial_videos_for_category(category),
                deck: []
            }
        }
        return states[key]
    }

    function appendScheduleItem(schedule, source, kind, startAt, segmentDuration, mediaOffset, forceAdvance) {
        if (!source)
            return startAt
        if (kind === "commercial") {
            if (!source.url)
                return startAt
        } else if (!source.streamUrl) {
            return startAt
        }

        var fallback = kind === "commercial" ? 30 : (kind === "movie" ? 5400 : 600)
        var knownDuration = hasKnownDuration(source)
        var fullDuration = durationSeconds(source, fallback)
        var duration = segmentDuration === undefined || segmentDuration === null
                       ? fullDuration
                       : Math.max(5, segmentDuration)
        var item = Object.assign({}, source)
        item.kind = kind
        item.duration = duration
        item.durationKnown = knownDuration
        item.fullDuration = fullDuration
        item.mediaOffset = Math.max(0, mediaOffset || 0)
        item.forceAdvance = forceAdvance === true
        item.start = startAt
        item.end = startAt + duration
        schedule.push(item)
        return item.end
    }

    function appendCommercialBreak(schedule, startAt, commercialState) {
        var pool = commercialStatePool(commercialState)
        if (!commercialsEnabled() || pool.length === 0)
            return startAt

        var total = startAt
        var targetCount = 2 + Math.floor(Math.random() * 3)
        var added = 0
        var attempts = 0
        var maxAttempts = Math.max(targetCount * 3, pool.length * 2)
        while (added < targetCount && attempts < maxAttempts) {
            attempts++
            var commercial = randomCommercialFromState(commercialState)
            if (commercial) {
                var before = total
                total = appendScheduleItem(schedule, commercial, "commercial", total)
                if (total > before)
                    added++
            }
        }
        return total
    }

    function midrollOffsetsFor(kind, duration, commercialState) {
        if (!midrollCommercialsEnabled() || !commercialsEnabled() ||
                commercialStatePool(commercialState).length === 0)
            return []
        if (kind !== "movie" && kind !== "episode")
            return []
        if (duration < 1200)
            return []

        var count = kind === "movie"
            ? (duration >= 7200 ? 3 : (duration >= 3600 ? 2 : 1))
            : (duration >= 2700 ? 2 : 1)
        var guard = Math.min(900, Math.max(420, duration * 0.15))
        var jitter = Math.min(360, Math.max(90, duration * 0.06))
        var minGap = Math.min(900, Math.max(420, duration / (count + 2)))
        var offsets = []
        for (var i = 1; i <= count; i++) {
            var center = duration * (i / (count + 1))
            var offset = center + ((Math.random() * 2.0 - 1.0) * jitter)
            offset = Math.max(guard, Math.min(duration - guard, offset))
            if (offsets.length > 0 && offset - offsets[offsets.length - 1] < minGap)
                offset = offsets[offsets.length - 1] + minGap
            if (offset > guard && offset < duration - guard)
                offsets.push(offset)
        }
        return offsets
    }

    function appendProgramWithMidroll(schedule, source, kind, startAt, commercialState) {
        var fallback = kind === "movie" ? 5400 : 600
        var fullDuration = durationSeconds(source, fallback)
        var offsets = midrollOffsetsFor(kind, fullDuration, commercialState)
        if (offsets.length === 0)
            return appendScheduleItem(schedule, source, kind, startAt)

        var total = startAt
        var cursor = 0
        for (var i = 0; i < offsets.length; i++) {
            var offset = Math.max(cursor + 5, Math.min(fullDuration - 5, offsets[i]))
            total = appendScheduleItem(schedule, source, kind, total,
                                       offset - cursor, cursor, true)
            total = appendCommercialBreak(schedule, total, commercialState)
            cursor = offset
        }
        if (fullDuration - cursor >= 5)
            total = appendScheduleItem(schedule, source, kind, total,
                                       fullDuration - cursor, cursor, false)
        return total
    }

    function buildMovieSchedule(programs, commercialState) {
        var schedule = []
        var total = 0
        var movies = shuffleList(programs || [])
        for (var i = 0; i < movies.length; i++) {
            total = appendProgramWithMidroll(schedule, movies[i], "movie", total, commercialState)
            total = appendCommercialBreak(schedule, total, commercialState)
        }
        return { schedule: schedule, totalDuration: total }
    }

    function buildTvSchedule(groups, commercialState) {
        var schedule = []
        var total = 0
        var states = []
        var totalEpisodes = 0

        for (var i = 0; i < (groups || []).length; i++) {
            var group = groups[i] || ({})
            var episodes = group.episodes || []
            if (episodes.length === 0)
                continue
            states.push({
                group: group,
                episodes: episodes,
                nextIndex: Math.floor(Math.random() * episodes.length)
            })
            totalEpisodes += episodes.length
        }

        if (states.length === 0 || totalEpisodes <= 0)
            return { schedule: [], totalDuration: 0 }

        var previousState = -1
        for (var slot = 0; slot < totalEpisodes; slot++) {
            var stateIndex = chooseStateIndex(states, previousState, 0.28,
                                             lastProgramKey(schedule))

            var state = states[stateIndex]
            var episode = nextEpisodeForState(state, lastProgramKey(schedule))
            if (!episode)
                continue
            total = appendProgramWithMidroll(schedule, episode, "episode", total, commercialState)
            total = appendCommercialBreak(schedule, total, commercialState)
            previousState = stateIndex
        }

        return { schedule: schedule, totalDuration: total }
    }

    function buildMixedSchedule(programs, groups, commercialState) {
        var schedule = []
        var total = 0
        var movies = shuffleList(programs || [])
        var states = []
        var totalSlots = movies.length

        for (var i = 0; i < (groups || []).length; i++) {
            var group = groups[i] || ({})
            var episodes = group.episodes || []
            if (episodes.length > 0) {
                states.push({
                    group: group,
                    episodes: episodes,
                    nextIndex: Math.floor(Math.random() * episodes.length)
                })
                totalSlots += episodes.length
            }
        }

        var movieIndex = 0
        var previousState = -1
        for (var slot = 0; slot < totalSlots; slot++) {
            var useSeries = states.length > 0 && (movieIndex >= movies.length || Math.random() < 0.55)
            if (useSeries) {
                var stateIndex = chooseStateIndex(states, previousState, 0.34,
                                                 lastProgramKey(schedule))
                var state = states[stateIndex]
                var episode = nextEpisodeForState(state, lastProgramKey(schedule))
                if (!episode)
                    continue
                total = appendProgramWithMidroll(schedule, episode, "episode", total, commercialState)
                total = appendCommercialBreak(schedule, total, commercialState)
                previousState = stateIndex
            } else if (movieIndex < movies.length) {
                var movie = takeNextMovie(movies, movieIndex, lastProgramKey(schedule))
                total = appendProgramWithMidroll(schedule, movie, "movie", total, commercialState)
                total = appendCommercialBreak(schedule, total, commercialState)
                movieIndex++
                previousState = -1
            }
        }
        return { schedule: schedule, totalDuration: total }
    }

    function ensureChannel(load) {
        var key = load.channelKey || load.categoryId || load.title || "local"
        if (!tvChannelMap[key]) {
            tvChannelMap[key] = {
                key: key,
                title: load.channelTitle || load.title || "LOCAL",
                sourceType: load.sourceType || "auto",
                commercialCategory: load.commercialCategory || "",
                programs: [],
                groups: [],
                seenKeys: ({})
            }
            tvChannelOrder.push(key)
        }
        return tvChannelMap[key]
    }

    function addFileToChannel(load, row) {
        if (!row || !row.streamUrl)
            return
        var channel = ensureChannel(load)
        var item = Object.assign({}, row)
        item.title = row.title || "LOCAL"
        var itemKey = mediaItemKey(item)
        if (itemKey !== "") {
            if (channel.seenKeys && channel.seenKeys[itemKey])
                return
            channel.seenKeys[itemKey] = true
        }
        var kind = mediaKind(row)
        if (kind === "episode") {
            var showTitle = load.showTitle || channel.title || "TV"
            var group = null
            for (var i = 0; i < channel.groups.length; i++) {
                if (channel.groups[i].title === showTitle) {
                    group = channel.groups[i]
                    break
                }
            }
            if (!group) {
                group = { title: showTitle, episodes: [] }
                channel.groups.push(group)
            }
            group.episodes.push(item)
        } else {
            channel.programs.push(item)
        }
    }

    function enqueueLoad(load) {
        if (!load || !load.categoryId)
            return
        tvLoadQueue.push(load)
    }

    function enqueueFolder(load, row) {
        var kind = mediaKind(row)
        var next = Object.assign({}, load, {
            title: row.title || load.title,
            path: row.path || "",
            sourceIndex: intOrDefault(row.sourceIndex, intOrDefault(load.sourceIndex, -1))
        })
        if (kind === "show")
            next.showTitle = row.title || load.showTitle || load.title
        enqueueLoad(next)
    }

    function processLoadedRows(rows) {
        var load = tvCurrentLoad || ({})
        var loadedRows = asList(rows)
        for (var i = 0; i < loadedRows.length; i++) {
            var row = loadedRows[i] || ({})
            if (rowType(row) === "localfile")
                addFileToChannel(load, row)
            else if (rowType(row) === "localfolder")
                enqueueFolder(load, row)
        }
    }

    function loadNextLocalBatch() {
        if (tvLoadQueue.length === 0) {
            buildReadyChannels()
            return
        }
        tvCurrentLoad = tvLoadQueue.shift()
        statusText = "SCANNING " + (tvCurrentLoad.title || tvCurrentLoad.channelTitle || "LOCAL")
        usenetBackend.load_local_items(tvCurrentLoad.categoryId || "",
                                       tvCurrentLoad.path || "",
                                       intOrDefault(tvCurrentLoad.sourceIndex, -1),
                                       tvCurrentLoad.title || tvCurrentLoad.channelTitle || "LOCAL")
    }

    function queueCustomChannels() {
        var custom = savedCustomChannels()
        for (var i = 0; i < custom.length; i++) {
            var channel = custom[i] || ({})
            var channelKey = "custom:" + (channel.id || channel.title || i)
            var items = asList(channel.items)
            ensureChannel({
                channelKey: channelKey,
                channelTitle: channel.title || "CUSTOM",
                sourceType: "custom",
                commercialCategory: channel.commercialCategory || ""
            })
            for (var j = 0; j < items.length; j++) {
                var item = items[j] || ({})
                var load = {
                    channelKey: channelKey,
                    channelTitle: channel.title || "CUSTOM",
                    sourceType: "custom",
                    commercialCategory: channel.commercialCategory || "",
                    categoryId: item.categoryId || item.id || "",
                    path: item.path || "",
                    sourceIndex: intOrDefault(item.sourceIndex, -1),
                    title: item.title || channel.title || "CUSTOM",
                    showTitle: mediaKind(item) === "show" ? item.title : ""
                }
                if (rowType(item) === "localfile" && item.streamUrl)
                    addFileToChannel(load, item)
                else
                    enqueueLoad(load)
            }
        }
    }

    function startLocalLoad() {
        loading = true
        noSignalVisible = false
        tuningStaticVisible = true
        statusText = "SCANNING LOCAL"
        tvLoadQueue = []
        tvCurrentLoad = ({})
        tvChannelMap = ({})
        tvChannelOrder = []
        channels = []

        queueCustomChannels()

        if (autoChannelsEnabled()) {
            var localRows = localCategoryRows()
            for (var i = 0; i < localRows.length; i++) {
                var row = localRows[i] || ({})
                enqueueLoad({
                    channelKey: "auto:" + (row.id || row.categoryId || row.title || i),
                    channelTitle: row.title || "LOCAL",
                    sourceType: "auto",
                    categoryId: row.id || row.categoryId || "",
                    path: "",
                    sourceIndex: -1,
                    title: row.title || "LOCAL"
                })
            }
        }

        if (tvLoadQueue.length === 0 && tvChannelOrder.length === 0) {
            loading = false
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "NO CHANNELS AVAILABLE"
            return
        }
        loadNextLocalBatch()
    }

    function buildReadyChannels() {
        var ready = []
        var commercialStates = ({})
        var orderedSources = []
        for (var i = 0; i < tvChannelOrder.length; i++) {
            var source = tvChannelMap[tvChannelOrder[i]]
            if (source) {
                orderedSources.push(source)
                if (source.sourceType !== "custom") {
                    var themed = themedSourcesFor(source)
                    for (var t = 0; t < themed.length; t++)
                        orderedSources.push(themed[t])
                }
            }
        }

        for (var s = 0; s < orderedSources.length; s++) {
            var channelSource = orderedSources[s] || ({})
            var commercialState = commercialStateForChannel(channelSource, commercialStates)
            var groups = channelSource.groups || []
            var programs = channelSource.programs || []
            var scheduleData = groups.length > 0 && programs.length === 0
                ? buildTvSchedule(groups, commercialState)
                : (groups.length > 0
                   ? buildMixedSchedule(programs, groups, commercialState)
                   : buildMovieSchedule(programs, commercialState))
            if (!scheduleData.schedule || scheduleData.schedule.length === 0 ||
                    scheduleData.totalDuration <= 0) {
                continue
            }
            ready.push({
                number: padChannelNumber(ready.length + 2),
                title: channelSource.title || "LOCAL",
                schedule: scheduleData.schedule,
                totalDuration: scheduleData.totalDuration
            })
        }

        channels = ready
        loading = false
        currentScheduleIndex = -1
        previousIndex = -1
        startedAtMs = Date.now()

        if (channels.length === 0) {
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "NO CHANNELS AVAILABLE"
            return
        }

        tuneIndex(0, false)
    }

    function startCommercialLoad() {
        commercialPool = commercialsEnabled()
            ? usenetBackend.get_commercial_videos_for_setting("tube_commercial_categories")
            : []
        startLocalLoad()
    }

    function startServerLineupLoad() {
        loading = true
        loadingServerLineup = true
        noSignalVisible = false
        tuningStaticVisible = true
        transitionBlankVisible = false
        stoppingForTune = false
        stoppingForScheduleAdvance = false
        streamStarted = false
        showChannelLabelAfterTransition = false
        currentIndex = -1
        previousIndex = -1
        currentScheduleIndex = -1
        channels = []
        statusText = "LOADING SERVER TV"
        usenetBackend.load_tube_tv_lineup()
    }

    function applyServerLineup(rows, metadata) {
        var realChannels = asList(rows).filter(function(channel) {
            return String((channel && channel.number) || "") !== "01"
        })
        guideDisplayChannels = realChannels
        guideLineupMetadata = metadata || ({})
        var serverNowMs = dateMs(guideLineupMetadata.serverNow)
        if (serverNowMs <= 0)
            serverNowMs = dateMs(guideLineupMetadata.updatedAt)
        if (serverNowMs <= 0)
            serverNowMs = dateMs(guideLineupMetadata.generatedAt)
        guideServerClockOffsetMs = serverNowMs > 0 ? (serverNowMs - Date.now()) : 0
        channels = serviceChannels(realChannels)
        loading = false
        loadingServerLineup = false
        currentScheduleIndex = -1
        previousIndex = -1
        var serverStartMs = dateMs(guideLineupMetadata.startedAt)
        startedAtMs = serverStartMs > 0 ? serverStartMs : Date.now()

        if (channels.length === 0) {
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "NO CHANNELS AVAILABLE"
            return
        }

        tuneIndex(startupChannelIndex(realChannels.length), false)
    }

    function selectedChannel() {
        if (currentIndex < 0 || currentIndex >= channels.length)
            return null
        return channels[currentIndex]
    }

    function findScheduleItem(channel) {
        if (!channel || !channel.schedule || channel.schedule.length === 0 ||
                channel.totalDuration <= 0) {
            return null
        }

        var nowMs = arguments.length > 1 && arguments[1] > 0 ? arguments[1] : timelineNowMs()
        var elapsed = Math.max(0, (nowMs - startedAtMs) / 1000.0)
        var position = elapsed % channel.totalDuration
        for (var i = 0; i < channel.schedule.length; i++) {
            var item = channel.schedule[i]
            if (position >= item.start && position < item.end) {
                var segmentOffset = Math.max(0, position - item.start)
                var mediaOffset = Math.max(0, item.mediaOffset || 0)
                return {
                    item: item,
                    index: i,
                    offset: mediaOffset + segmentOffset,
                    segmentRemaining: Math.max(0, item.duration - segmentOffset)
                }
            }
        }

        return { item: channel.schedule[0], index: 0, offset: channel.schedule[0].mediaOffset || 0,
                 segmentRemaining: channel.schedule[0].duration || 0 }
    }

    function applyObservedScheduleDuration(channel, index, observedFullDuration) {
        if (!channel || !channel.schedule || index < 0 || index >= channel.schedule.length)
            return
        if (!observedFullDuration || observedFullDuration <= 1.0)
            return

        var item = channel.schedule[index]
        if (!item)
            return

        var oldDuration = Math.max(0, Number(item.duration || 0))
        var mediaOffset = Math.max(0, Number(item.mediaOffset || 0))
        var newDuration = item.kind === "commercial"
            ? observedFullDuration
            : Math.max(5, observedFullDuration - mediaOffset)

        if (item.forceAdvance === true && oldDuration > 0 && newDuration > oldDuration)
            return

        if (oldDuration <= 0 || Math.abs(newDuration - oldDuration) < 1.0)
            return

        var delta = newDuration - oldDuration
        item.duration = newDuration
        item.fullDuration = observedFullDuration
        item.durationKnown = true
        item.end = item.start + newDuration

        for (var i = index + 1; i < channel.schedule.length; i++) {
            var row = channel.schedule[i]
            row.start = Math.max(0, Number(row.start || 0) + delta)
            row.end = Math.max(row.start, Number(row.end || 0) + delta)
        }
        channel.totalDuration = Math.max(1, Number(channel.totalDuration || 0) + delta)
    }

    function learnCurrentPlaybackDuration(finalPositionMs, finalDurationMs) {
        var channel = selectedChannel()
        if (!channel || currentScheduleIndex < 0)
            return

        var finalPositionSeconds = Math.max(0, Number(finalPositionMs || 0) / 1000.0)
        var finalDurationSeconds = Math.max(0, Number(finalDurationMs || 0) / 1000.0)
        var observedFullDuration = finalDurationSeconds
        if (currentPlaybackUsesServerSeek) {
            observedFullDuration = currentPlaybackOffsetSeconds + Math.max(finalPositionSeconds,
                                                                           finalDurationSeconds)
        }
        applyObservedScheduleDuration(channel, currentScheduleIndex, observedFullDuration)
    }

    function usesServerSeek(item) {
        if (!item)
            return false
        return item.serverSeek === true || String(item.seekMode || "").toLowerCase() === "server"
    }

    function urlWithStartOffset(url, offset) {
        if (!url || offset <= 0.5)
            return url
        var hashIndex = url.indexOf("#")
        var base = hashIndex >= 0 ? url.slice(0, hashIndex) : url
        var hash = hashIndex >= 0 ? url.slice(hashIndex) : ""
        var separator = base.indexOf("?") >= 0 ? "&" : "?"
        return base + separator + "start=" + encodeURIComponent(offset.toFixed(3)) + hash
    }

    function showStaticForChannel(channel) {
        scheduleAdvanceTimer.stop()
        transitionBlankVisible = true
        guideChannelVisible = false
        teletextVisible = false
        tuningStaticVisible = false
        noSignalVisible = false
        streamStarted = false
        showChannelLabelAfterTransition = true
        stoppingForScheduleAdvance = false
        statusText = channelLabel(channel)

        if (mpvController.running)
            mpvController.sendScriptMessage("240mp-ota-transition-black")
    }

    function requestScheduleItem(channel, item, index, offset, segmentRemaining) {
        if (!channel || !item ||
                (item.kind === "commercial"
                 ? !item.url
                 : !item.streamUrl)) {
            transitionBlankVisible = false
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "LOCAL TV CHANNEL EMPTY"
            return
        }

        currentScheduleIndex = index
        var label = channelLabel(channel)
        statusText = label
        var url = item.kind === "commercial"
            ? item.url
            : item.streamUrl
        var startOffset = offset || 0.0
        if (item.kind === "commercial" && item.local === true)
            startOffset = 0.0
        var useServerSeek = item.kind !== "commercial" && usenetBackend.uses_server_seek()
        var timelineOffset = startOffset
        if (useServerSeek) {
            url = urlWithStartOffset(url, startOffset)
            startOffset = 0.0
        }
        launchPlayback(url, startOffset, label, segmentRemaining || 0.0, item,
                       timelineOffset, useServerSeek)
    }

    function requestSelectedStream() {
        tuneTimer.stop()
        if (loading || channels.length === 0)
            return

        var channel = selectedChannel()
        if (isGuideChannel(channel)) {
            showGuideChannel()
            return
        }
        if (isTeletextChannel(channel)) {
            showTeletextChannel(channel)
            return
        }
        var resolved = findScheduleItem(channel)
        if (!resolved) {
            requestScheduleItem(channel, null, -1, 0.0, 0.0)
            return
        }
        requestScheduleItem(channel, resolved.item, resolved.index,
                            resolved.offset || 0.0,
                            resolved.segmentRemaining || 0.0)
    }

    function showGuideChannel() {
        scheduleAdvanceTimer.stop()
        transitionBlankVisible = false
        showChannelLabelAfterTransition = false
        tuningStaticVisible = false
        noSignalVisible = false
        streamStarted = false
        currentStreamUsesServer = false
        currentScheduleIndex = -1
        statusText = "CH 01 TATER GUIDE"
        if (mpvController.running) {
            stoppingForTune = true
            mpvController.stop()
        }
        guideChannelVisible = true
        teletextVisible = false
        guideNowMs = Date.now()
    }

    function showTeletextChannel(channel) {
        scheduleAdvanceTimer.stop()
        transitionBlankVisible = false
        showChannelLabelAfterTransition = false
        tuningStaticVisible = false
        noSignalVisible = false
        streamStarted = false
        currentStreamUsesServer = false
        currentScheduleIndex = -1
        guideChannelVisible = false
        teletextPage = String(channel.teletextPage || "100")
        teletextTitle = String(channel.title || "TATERTEXT")
        statusText = channelLabel(channel)
        if (mpvController.running) {
            stoppingForTune = true
            mpvController.stop()
        }
        teletextVisible = true
        teletextRefreshData()
    }

    function launchPlayback(url, offset, label, segmentRemaining, item, timelineOffset, useServerSeek) {
        if (!url) {
            transitionBlankVisible = false
            noSignalVisible = true
            tuningStaticVisible = false
            statusText = "LOCAL TV PLAYBACK FAILED"
            return
        }

        streamStarted = true
        stoppingForTune = false
        stoppingForScheduleAdvance = false
        noSignalVisible = false
        var playbackUrl = usenetBackend.playback_url(url, Math.round(root.sw), Math.round(root.sh))
        currentStreamUsesServer = true
        currentPlaybackOffsetSeconds = Math.max(0, Number(timelineOffset || offset || 0))
        currentPlaybackUsesServerSeek = useServerSeek === true
        updateStreamOverlayInfo(plannedStreamInfo(playbackUrl, item))
        var oscMode = transitionBlankVisible ? "ota-quiet" : "ota"
        mpvController.loadAndPlay(playbackUrl, offset || 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, oscMode, false, label || statusText)

        scheduleAdvanceTimer.stop()
        if (item && item.forceAdvance === true && (segmentRemaining || 0) > 1.0) {
            scheduleAdvanceTimer.interval = Math.max(1000, Math.round(segmentRemaining * 1000))
            scheduleAdvanceTimer.restart()
        }
    }

    function playNextScheduleItem() {
        scheduleAdvanceTimer.stop()
        if (channels.length === 0)
            return

        var channel = selectedChannel()
        if (!channel || !channel.schedule || channel.schedule.length === 0) {
            requestSelectedStream()
            return
        }

        var nextIndex = currentScheduleIndex + 1
        if (nextIndex < 0 || nextIndex >= channel.schedule.length)
            nextIndex = 0

        var nextItem = channel.schedule[nextIndex]
        transitionBlankVisible = true
        showChannelLabelAfterTransition = false
        tuningStaticVisible = false
        noSignalVisible = false
        streamStarted = false
        requestScheduleItem(channel, nextItem, nextIndex,
                            nextItem.mediaOffset || 0.0,
                            nextItem.duration || 0.0)
    }

    function tuneIndex(index, immediate) {
        if (loading || channels.length === 0)
            return
        if (index < 0)
            index = channels.length - 1
        if (index >= channels.length)
            index = 0
        if (currentIndex >= 0 && currentIndex !== index)
            previousIndex = currentIndex

        currentIndex = index
        currentScheduleIndex = -1
        showStaticForChannel(channels[currentIndex])
        if (immediate)
            requestSelectedStream()
        else
            tuneTimer.restart()
    }

    function tuneRelative(delta, immediate) {
        tuneIndex(currentIndex + delta, immediate)
    }

    function tuneNow() {
        if (loading || transitionBlankVisible || !tuningStaticVisible)
            return
        tuneTimer.stop()
        requestSelectedStream()
    }

    function tuneLastChannel() {
        if (previousIndex < 0 || previousIndex >= channels.length)
            return
        tuneIndex(previousIndex, false)
    }

    function exitTvMode() {
        leaving = true
        tuneTimer.stop()
        scheduleAdvanceTimer.stop()
        if (mpvController.running)
            mpvController.stop()
        goBack()
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            exitTvMode()
            event.accepted = true
        } else if (loading) {
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            tuneRelative(1, false)
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            tuneRelative(-1, false)
            event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            tuneNow()
            event.accepted = true
        } else if (event.key === Qt.Key_Menu) {
            mpvController.sendKey("MENU")
            event.accepted = true
        }
    }

    Timer {
        id: tuneTimer
        interval: tvRoot.tuneDelayMs
        repeat: false
        onTriggered: tvRoot.requestSelectedStream()
    }

    Timer {
        id: scheduleAdvanceTimer
        repeat: false
        onTriggered: {
            if (tvRoot.leaving)
                return
            tvRoot.playNextScheduleItem()
        }
    }

    Timer {
        id: streamInfoPollTimer
        interval: 3000
        repeat: true
        running: tvRoot.currentStreamUsesServer && tvRoot.streamStarted
                 && !tvRoot.tuningStaticVisible && !tvRoot.noSignalVisible
                 && !tvRoot.leaving
        onTriggered: tvRoot.refreshActiveStreamInfo()
    }

    Timer {
        id: guideClockTimer
        interval: 100
        repeat: true
        running: tvRoot.guideChannelVisible && !tvRoot.leaving
        onTriggered: tvRoot.guideNowMs = Date.now()
    }

    Timer {
        id: teletextRefreshTimer
        interval: 1000
        repeat: true
        running: tvRoot.teletextVisible && !tvRoot.leaving
        onTriggered: {
            tvRoot.teletextNowMs = Date.now()
            if (Math.floor(tvRoot.teletextNowMs / 1000) % 5 === 0)
                tvRoot.teletextRefreshData()
        }
    }

    Connections {
        target: usenetBackend

        function onItemsLoaded(categoryTitle, rows) {
            if (!tvRoot.loading)
                return
            tvRoot.processLoadedRows(rows || [])
            tvRoot.loadNextLocalBatch()
        }

        function onErrorOccurred(message) {
            if (!tvRoot.loading)
                return
            if (tvRoot.loadingServerLineup) {
                tvRoot.loading = false
                tvRoot.loadingServerLineup = false
                tvRoot.transitionBlankVisible = false
                tvRoot.tuningStaticVisible = false
                tvRoot.noSignalVisible = true
                tvRoot.statusText = String(message || "TV LINEUP FAILED").toUpperCase()
                return
            }
            if (tvRoot.tvLoadQueue.length > 0) {
                tvRoot.loadNextLocalBatch()
                return
            }
            tvRoot.buildReadyChannels()
        }

        function onTubeTvLineupLoaded(rows, metadata) {
            if (!tvRoot.loadingServerLineup)
                return
            tvRoot.applyServerLineup(rows || [], metadata || ({}))
        }

        function onActiveStreamsLoaded(streams) {
            var rows = tvRoot.asList(streams)
            if (tvRoot.teletextVisible)
                tvRoot.teletextActiveStreams = rows
            if (!tvRoot.currentStreamUsesServer)
                return
            if (rows.length === 0)
                return
            tvRoot.updateStreamOverlayInfo(tvRoot.streamInfoFromActiveStream(rows[0]))
        }
    }

    Connections {
        target: mpvController

        function onPositionChanged(ms) {
            if (ms > 0 && tvRoot.streamStarted)
                tvRoot.tuningStaticVisible = false
        }

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (tvRoot.leaving)
                return
            scheduleAdvanceTimer.stop()
            tvRoot.learnCurrentPlaybackDuration(finalPositionMs, finalDurationMs)
            tvRoot.playNextScheduleItem()
        }

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (tvRoot.stoppingForScheduleAdvance) {
                tvRoot.stoppingForScheduleAdvance = false
                tvRoot.playNextScheduleItem()
                return
            }
            if (tvRoot.stoppingForTune) {
                tvRoot.stoppingForTune = false
                return
            }
            if (!tvRoot.leaving && tvRoot.streamStarted)
                tvRoot.exitTvMode()
        }

        function onPlaybackFailed() {
            if (tvRoot.stoppingForTune) {
                tvRoot.stoppingForTune = false
                return
            }
            scheduleAdvanceTimer.stop()
            tvRoot.streamStarted = false
            tvRoot.transitionBlankVisible = false
            tvRoot.tuningStaticVisible = false
            tvRoot.noSignalVisible = true
            tvRoot.statusText = "LOCAL TV PLAYBACK FAILED"
            if (mpvController.running) {
                tvRoot.stoppingForTune = true
                mpvController.stop()
            }
        }

        function onScriptMessageReceived(message, arg) {
            if (message === "240mp-ota-file-loaded") {
                tvRoot.transitionBlankVisible = false
                tvRoot.tuningStaticVisible = false
                tvRoot.streamStarted = true
                tvRoot.updateStreamOverlayInfo(tvRoot.streamInfoText)
                if (tvRoot.showChannelLabelAfterTransition) {
                    tvRoot.showChannelLabelAfterTransition = false
                    mpvController.sendScriptMessage("240mp-osd-menu-show")
                    mpvController.sendScriptMessage("240mp-ota-tuned-channel", tvRoot.statusText)
                }
                tvRoot.refreshActiveStreamInfo()
                return
            }

            if (message === "240mp-ota-tune-now") {
                tvRoot.tuneNow()
                return
            }

            if (message === "240mp-ota-last-channel") {
                tvRoot.tuneLastChannel()
                return
            }

            if (message !== "240mp-ota-channel-step")
                return

            var delta = parseInt(arg)
            if (isNaN(delta) || delta === 0)
                return
            tvRoot.tuneRelative(delta, false)
        }
    }

    Component.onCompleted: startServerLineupLoad()

    Component.onDestruction: {
        if (!leaving && mpvController.running)
            mpvController.stop()
    }

    StaticBackground {
        anchors.fill: parent
        visible: tvRoot.tuningStaticVisible
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: tvRoot.tuningStaticVisible ? "transparent" : "black"
    }

    Rectangle {
        id: guideScreen
        anchors.fill: parent
        visible: tvRoot.guideChannelVisible && !tvRoot.loading
        color: "#050403"
        z: 4

        Rectangle {
            id: guideHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.19
            color: "#14100c"
            border.color: root.primaryColor
            border.width: Math.max(1, root.sh * 0.003)

            Image {
                id: guideMascot
                source: tvRoot.guideMascotSource
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.035
                anchors.verticalCenter: parent.verticalCenter
                width: root.sw * 0.13
                height: parent.height * 0.88
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
            }

            Text {
                anchors.left: guideMascot.right
                anchors.leftMargin: root.sw * 0.025
                anchors.verticalCenter: parent.verticalCenter
                text: "TATER GUIDE"
                color: root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.078
                horizontalAlignment: Text.AlignLeft
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.045
                anchors.verticalCenter: parent.verticalCenter
                text: "CH 01"
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.055
            }
        }

        Rectangle {
            id: guideColumnHeader
            anchors.top: guideHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.072
            color: "#0b0806"
            border.color: "#55ff7a00"
            border.width: Math.max(1, root.sh * 0.002)

            Text {
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.055
                anchors.verticalCenter: parent.verticalCenter
                text: "CHANNEL"
                color: root.secondaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.032
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.28
                anchors.verticalCenter: parent.verticalCenter
                text: "NOW SHOWING"
                color: root.secondaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.032
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.065
                anchors.verticalCenter: parent.verticalCenter
                text: "UP NEXT"
                color: root.secondaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.032
            }
        }

        Item {
            id: guideViewport
            anchors.top: guideColumnHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true

            Column {
                id: guideRowsColumn
                width: guideViewport.width
                y: {
                    var cycleHeight = tvRoot.guideCycleHeight()
                    var guideY = 0
                    if (cycleHeight > 0) {
                        var elapsed = Math.max(0, (tvRoot.guideTimelineNowMs() - tvRoot.guideScrollBaseMs()) / 1000.0)
                        guideY = -((elapsed * tvRoot.guideScrollSpeed()) % cycleHeight)
                    }
                    guideY
                }
                spacing: Math.max(1, root.sh * 0.006)

                Repeater {
                    model: tvRoot.guideRepeatedChannels(guideViewport.height)

                    Rectangle {
                        width: guideViewport.width
                        height: root.sh * 0.14
                        color: index % 2 === 0 ? "#15110d" : "#0d0a07"
                        border.color: "#33ff7a00"
                        border.width: Math.max(1, root.sh * 0.0018)

                        property var channel: modelData || ({})
                        property var resolved: tvRoot.findScheduleItem(channel, tvRoot.guideTimelineNowMs())
                        property var currentItem: resolved ? resolved.item : ({})
                        property var nextRows: tvRoot.guideNextRows(channel, resolved ? resolved.index : -1, 2)

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: root.sw * 0.045
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.sw * 0.18
                            text: "CH " + (channel.number || "--") + "\n" + String(channel.title || "").toUpperCase()
                            color: root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.034
                            lineHeight: 0.9
                            elide: Text.ElideRight
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: root.sw * 0.28
                            anchors.right: parent.right
                            anchors.rightMargin: root.sw * 0.36
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: root.sh * 0.008

                            Text {
                                width: parent.width
                                text: tvRoot.scheduleTitle(currentItem)
                                color: "#f4efe7"
                                font.family: root.globalFont
                                font.pixelSize: root.sh * 0.04
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: tvRoot.scheduleKindLabel(currentItem) + " / " + tvRoot.formatShortDuration(currentItem.duration || 0)
                                color: "#9f9488"
                                font.family: root.globalFont
                                font.pixelSize: root.sh * 0.026
                                elide: Text.ElideRight
                            }
                        }

                        Column {
                            anchors.right: parent.right
                            anchors.rightMargin: root.sw * 0.045
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.sw * 0.29
                            spacing: root.sh * 0.007

                            Repeater {
                                model: nextRows

                                Text {
                                    width: parent.width
                                    text: tvRoot.scheduleTitle(modelData)
                                    color: index === 0 ? root.secondaryColor : "#8f8377"
                                    font.family: root.globalFont
                                    font.pixelSize: index === 0 ? root.sh * 0.032 : root.sh * 0.026
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: guideViewport.width
                    height: root.sh * 0.22
                    color: "transparent"
                    visible: tvRoot.guideDisplayChannels.length === 0

                    Text {
                        anchors.centerIn: parent
                        text: "NO CHANNEL DATA AVAILABLE"
                        color: root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.045
                    }
                }
            }

        }

        Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.color: "#22ffffff"
            border.width: Math.max(1, root.sh * 0.002)
        }
    }

    Rectangle {
        id: teletextScreen
        anchors.fill: parent
        visible: tvRoot.teletextVisible && !tvRoot.loading
        color: "#000000"
        z: 4

        Rectangle {
            id: teletextTopBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.105
            color: "#0018a8"

            Text {
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.035
                anchors.verticalCenter: parent.verticalCenter
                text: "P" + tvRoot.teletextPage
                color: "#ffff00"
                font.family: tvRoot.teletextFont
                font.bold: true
                font.pixelSize: root.sh * 0.055
            }

            Text {
                anchors.centerIn: parent
                text: "TATERTEXT"
                color: "#ffffff"
                font.family: tvRoot.teletextFont
                font.bold: true
                font.pixelSize: root.sh * 0.062
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.035
                anchors.verticalCenter: parent.verticalCenter
                text: tvRoot.teletextClock()
                color: "#00ffff"
                font.family: tvRoot.teletextFont
                font.bold: true
                font.pixelSize: root.sh * 0.047
            }
        }

        Rectangle {
            id: teletextSubBar
            anchors.top: teletextTopBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.06
            color: "#000000"
            border.color: "#ffffff"
            border.width: Math.max(1, root.sh * 0.002)

            Text {
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.04
                anchors.verticalCenter: parent.verticalCenter
                text: "CH " + (tvRoot.selectedChannel() ? tvRoot.selectedChannel().number : "---") + "  " + tvRoot.teletextTitle
                color: "#00ff00"
                font.family: tvRoot.teletextFont
                font.bold: true
                font.pixelSize: root.sh * 0.034
                elide: Text.ElideRight
                width: parent.width * 0.7
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.04
                anchors.verticalCenter: parent.verticalCenter
                text: tvRoot.teletextDate()
                color: "#ffff00"
                font.family: tvRoot.teletextFont
                font.bold: true
                font.pixelSize: root.sh * 0.034
            }
        }

        Item {
            id: teletextBody
            anchors.top: teletextSubBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: teletextFastBar.top
            anchors.margins: root.sw * 0.026
            clip: true

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Math.max(1, root.sh * 0.003)

                Repeater {
                    model: tvRoot.teletextRows()

                    Rectangle {
                        width: parent.width
                        height: root.sh * 0.029
                        color: modelData.bg || "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: root.sw * 0.025
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - root.sw * 0.05
                            text: modelData.text || ""
                            color: modelData.color || "#ffffff"
                            font.family: tvRoot.teletextFont
                            font.bold: true
                            font.pixelSize: root.sh * 0.023
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignLeft
                        }
                    }
                }
            }
        }

        Row {
            id: teletextFastBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: root.sh * 0.075

            Repeater {
                model: [
                    { label: "NEWS", color: "#d60000" },
                    { label: "STATUS", color: "#00a800" },
                    { label: "GUIDE", color: "#d6d600" },
                    { label: "SERVER", color: "#0039d8" }
                ]

                Rectangle {
                    width: teletextFastBar.width / 4
                    height: teletextFastBar.height
                    color: modelData.color

                    Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: modelData.label === "GUIDE" ? "#000000" : "#ffffff"
                        font.family: tvRoot.teletextFont
                        font.bold: true
                        font.pixelSize: root.sh * 0.032
                    }
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.color: "#444444"
            border.width: Math.max(1, root.sh * 0.002)
        }
    }

    NoSignalScreen {
        anchors.fill: parent
        visible: tvRoot.noSignalVisible
        inputLabel: "VIDEO"
        message: "NO SIGNAL"
        detail: tvRoot.statusText
        z: 4
    }

    Text {
        visible: tvRoot.loading
        text: tvRoot.statusText
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.78
        wrapMode: Text.WordWrap
        font.pixelSize: root.sh * 0.045
        z: 6
    }

    Rectangle {
        visible: tvRoot.tuningStaticVisible && !tvRoot.loading && !tvRoot.transitionBlankVisible
        z: 5
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.sh * 0.09
        anchors.rightMargin: root.sw * 0.07
        width: Math.min(root.sw * 0.66,
                        Math.max(channelText.implicitWidth + root.sw * 0.04,
                                 root.sw * 0.18))
        height: root.sh * 0.085
        color: "#60000000"
        border.color: root.primaryColor
        border.width: Math.max(1, root.sh * 0.004)

        Text {
            id: channelText
            anchors.centerIn: parent
            width: parent.width - root.sw * 0.025
            text: tvRoot.statusText
            color: root.primaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.055
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
