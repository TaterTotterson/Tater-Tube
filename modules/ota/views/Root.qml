import QtQuick
import Components

FocusScope {
    id: otaRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.ota"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "OVER THE AIR"
    property string moduleIcon: _moduleInfo.icon || ""

    property var channels: []
    property int currentIndex: -1
    property string pendingChannelId: ""
    property string statusText: "LOADING CHANNELS..."
    property string serverName: ""
    property string hdhomerunHost: ""
    property string hdhomerunInputText: ""
    property bool hdhomerunSetupVisible: false
    property bool leaving: false
    property bool hasStartedPlayback: false
    property bool tuningStaticVisible: true
    property bool noSignalVisible: false
    property bool stoppingForTune: false
    property bool streamRequestActive: false
    property int lineupRequestSerial: 0
    property int tuneDelayMs: 1200
    property int previousIndex: -1

    focus: true

    onHdhomerunSetupVisibleChanged: {
        if (hdhomerunSetupVisible)
            hdhomerunFocusTimer.restart()
    }

    function channelLabel(channel) {
        if (!channel) return "NO CHANNEL"
        var number = channel.number || ""
        var name = channel.name || ""
        if (number !== "" && name !== "") return "CH " + number + "  " + name
        if (number !== "") return "CH " + number
        if (name !== "") return name
        return "CHANNEL"
    }

    function settingValue(key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "") return fallback
        return value
    }

    function loadOtaSettings() {
        hdhomerunHost = settingValue("hdhomerun_host", "")
    }

    function normalizeHdhomerunBase(raw) {
        var host = (raw || "").trim()
        if (host === "") return ""

        var lineupIndex = host.toLowerCase().indexOf("/lineup.json")
        if (lineupIndex >= 0)
            host = host.slice(0, lineupIndex)

        if (!/^https?:\/\//i.test(host))
            host = "http://" + host

        while (host.length > 0 && host.charAt(host.length - 1) === "/")
            host = host.slice(0, -1)
        return host
    }

    function hdhomerunLineupUrl() {
        var base = normalizeHdhomerunBase(hdhomerunHost)
        return base === "" ? "" : base + "/lineup.json"
    }

    function selectedChannel() {
        if (currentIndex < 0 || currentIndex >= channels.length) return null
        return channels[currentIndex]
    }

    function showStaticForChannel(channel) {
        if (!channel || !channel.id) return

        tuningStaticVisible = true
        noSignalVisible = false
        hasStartedPlayback = false
        streamRequestActive = false
        statusText = channelLabel(channel)
        pendingChannelId = channel.id

        if (mpvController.running) {
            stoppingForTune = true
            mpvController.stop()
        }
    }

    function requestSelectedStream() {
        var channel = selectedChannel()
        if (!channel || !channel.id) return

        tuneTimer.stop()
        pendingChannelId = channel.id
        streamRequestActive = true
        statusText = "TUNING " + channelLabel(channel)

        var streamUrl = channel.url || channel.id
        if (!streamUrl) {
            statusText = "HDHOMERUN CHANNEL HAS NO STREAM URL"
            streamRequestActive = false
            tuningStaticVisible = false
            noSignalVisible = true
            return
        }
        appCore.save_setting(moduleId, "last_hdhomerun_channel_id", channel.id)
        playStream(channel.id, streamUrl, "")
    }

    function playStream(channelId, url, httpHeaderFields) {
        if (channelId !== pendingChannelId) return

        var channel = channels[currentIndex]
        var label = channelLabel(channel)
        statusText = label
        hasStartedPlayback = true
        tuningStaticVisible = false
        noSignalVisible = false
        streamRequestActive = false
        mpvController.loadAndPlay(url, 0.0, 0, -1, [], false, -1, 0.0,
                                  httpHeaderFields || "", false, "ota", false, label)
    }

    function tuneIndex(index, immediate) {
        if (channels.length === 0) return
        if (index < 0) index = channels.length - 1
        if (index >= channels.length) index = 0

        if (currentIndex >= 0 && currentIndex !== index)
            previousIndex = currentIndex
        currentIndex = index
        var channel = channels[currentIndex]
        if (!channel || !channel.id) return

        showStaticForChannel(channel)
        if (immediate) {
            requestSelectedStream()
        } else {
            tuneTimer.restart()
        }
    }

    function tuneRelative(delta, immediate) {
        if (channels.length === 0) return
        tuneIndex(currentIndex + delta, !!immediate)
    }

    function tuneNow() {
        if (channels.length === 0) return
        if (tuningStaticVisible || tuneTimer.running || streamRequestActive)
            requestSelectedStream()
    }

    function tuneLastChannel() {
        if (channels.length === 0) return
        if (previousIndex < 0 || previousIndex >= channels.length) return
        tuneIndex(previousIndex, false)
    }

    function showHdhomerunSetup(message) {
        tuneTimer.stop()
        channels = []
        currentIndex = -1
        pendingChannelId = ""
        streamRequestActive = false
        hasStartedPlayback = false
        tuningStaticVisible = true
        noSignalVisible = false
        hdhomerunSetupVisible = true
        hdhomerunInputText = hdhomerunHost !== "" ? hdhomerunHost : "hdhomerun.local"
        hdhomerunHostField.text = hdhomerunInputText
        statusText = message || "ENTER HDHOMERUN ADDRESS"
        if (mpvController.running)
            mpvController.stop()
    }

    function saveHdhomerunSetup() {
        var value = (hdhomerunHostField.text || "").trim()
        if (value === "") {
            statusText = "ENTER HDHOMERUN ADDRESS"
            hdhomerunHostField.forceActiveFocus()
            return
        }

        hdhomerunHost = value
        hdhomerunSetupVisible = false
        appCore.save_setting(moduleId, "hdhomerun_host", value)
    }

    function loadHdhomerunChannels() {
        var lineupUrl = hdhomerunLineupUrl()
        if (lineupUrl === "") {
            showHdhomerunSetup("ENTER HDHOMERUN ADDRESS")
            return
        }

        channels = []
        currentIndex = -1
        pendingChannelId = ""
        streamRequestActive = false
        hasStartedPlayback = false
        tuningStaticVisible = true
        noSignalVisible = false
        hdhomerunSetupVisible = false
        statusText = "LOADING HDHOMERUN CHANNELS..."

        var requestSerial = ++lineupRequestSerial
        var request = new XMLHttpRequest()
        request.onreadystatechange = function() {
            if (request.readyState !== 4) return
            if (requestSerial !== lineupRequestSerial || otaRoot.leaving)
                return

            if (request.status < 200 || request.status >= 300) {
                showHdhomerunSetup("HDHOMERUN LINEUP FAILED")
                return
            }

            var lineup
            try {
                lineup = JSON.parse(request.responseText)
            } catch (e) {
                showHdhomerunSetup("HDHOMERUN LINEUP IS INVALID")
                return
            }
            if (!Array.isArray(lineup)) {
                showHdhomerunSetup("HDHOMERUN LINEUP IS INVALID")
                return
            }

            var parsedChannels = []
            for (var i = 0; i < lineup.length; i++) {
                var item = lineup[i] || {}
                var tags = (item.Tags || "").toString().toLowerCase()
                var streamUrl = item.URL || ""
                if (streamUrl === "" || tags.indexOf("drm") >= 0)
                    continue

                parsedChannels.push({
                    id: streamUrl,
                    url: streamUrl,
                    number: item.GuideNumber || "",
                    name: item.GuideName || ""
                })
            }

            channels = parsedChannels
            if (channels.length === 0) {
                statusText = "NO HDHOMERUN CHANNELS"
                return
            }

            var restoreId = appCore.get_setting(moduleId, "last_hdhomerun_channel_id") || ""
            var restoreIndex = 0
            for (var j = 0; j < channels.length; j++) {
                if (channels[j].id === restoreId) {
                    restoreIndex = j
                    break
                }
            }
            tuneIndex(restoreIndex, false)
        }
        request.open("GET", lineupUrl)
        request.send()
    }

    function loadHdhomerunSource() {
        loadOtaSettings()
        hdhomerunSetupVisible = false
        lineupRequestSerial++
        serverName = "HDHOMERUN"
        loadHdhomerunChannels()
    }

    function exitOta() {
        leaving = true
        lineupRequestSerial++
        tuneTimer.stop()
        mpvController.stop()
        goBack()
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Up) {
            if (hdhomerunSetupVisible) {
                event.accepted = true
                return
            }
            tuneRelative(1, false)
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            if (hdhomerunSetupVisible) {
                event.accepted = true
                return
            }
            tuneRelative(-1, false)
            event.accepted = true
        } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            exitOta()
            event.accepted = true
        } else if (event.key === Qt.Key_Space) {
            mpvController.sendKey("SPACE")
            event.accepted = true
        } else if (event.key === Qt.Key_Left) {
            tuneLastChannel()
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            mpvController.sendKey("RIGHT")
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (hdhomerunSetupVisible)
                saveHdhomerunSetup()
            else
                tuneNow()
            event.accepted = true
        }
    }

    Timer {
        id: tuneTimer
        interval: otaRoot.tuneDelayMs
        repeat: false
        onTriggered: otaRoot.requestSelectedStream()
    }

    Timer {
        id: hdhomerunFocusTimer
        interval: 1
        repeat: false
        onTriggered: {
            hdhomerunHostField.forceActiveFocus()
            hdhomerunHostField.selectAll()
        }
    }

    Connections {
        target: appCore
        function onModuleSettingChanged(mid, key, value) {
            if (mid !== moduleId) return
            if (key !== "hdhomerun_host") return
            loadHdhomerunSource()
        }
    }

    Connections {
        target: mpvController
        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (stoppingForTune) {
                stoppingForTune = false
                return
            }
            if (!leaving && hasStartedPlayback)
                goBack()
        }
        function onPlaybackFailed() {
            if (stoppingForTune) {
                stoppingForTune = false
                return
            }
            statusText = "OTA PLAYBACK FAILED"
            streamRequestActive = false
            tuningStaticVisible = false
            noSignalVisible = true
        }
        function onScriptMessageReceived(message, arg) {
            if (message === "240mp-ota-tune-now") {
                tuneNow()
                return
            }

            if (message === "240mp-ota-last-channel") {
                tuneLastChannel()
                return
            }

            if (message !== "240mp-ota-channel-step")
                return

            var delta = parseInt(arg)
            if (isNaN(delta) || delta === 0)
                return

            tuneRelative(delta, false)
        }
    }

    Component.onCompleted: {
        loadHdhomerunSource()
    }

    Component.onDestruction: {
        if (!leaving)
            mpvController.stop()
    }

    StaticBackground {
        anchors.fill: parent
        visible: otaRoot.tuningStaticVisible
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: otaRoot.tuningStaticVisible ? "transparent" : "black"
    }

    NoSignalScreen {
        anchors.fill: parent
        visible: otaRoot.noSignalVisible
        inputLabel: "AIR"
        message: "NO SIGNAL"
        detail: "WEAK SIGNAL"
        z: 4
    }

    AppBar {
        iconSource: otaRoot.moduleIcon
        title: otaRoot.moduleName
        subtitle: otaRoot.serverName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
        visible: !otaRoot.noSignalVisible && (otaRoot.tuningStaticVisible || !hasStartedPlayback)
    }

    Column {
        visible: otaRoot.hdhomerunSetupVisible
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.sw * 0.115625
        anchors.rightMargin: root.sw * 0.115625
        spacing: root.sh * 0.025

        Text {
            text: otaRoot.statusText
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.0333333
        }

        Rectangle {
            width: parent.width
            height: root.sh * 0.075
            color: root.accentColor

            TextInput {
                id: hdhomerunHostField
                anchors.fill: parent
                anchors.leftMargin: root.sw * 0.009375
                anchors.rightMargin: root.sw * 0.009375
                verticalAlignment: TextInput.AlignVCenter
                color: root.surfaceColor
                selectedTextColor: root.surfaceColor
                selectionColor: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.05
                clip: true

                Keys.onReturnPressed: otaRoot.saveHdhomerunSetup()
                Keys.onEnterPressed: otaRoot.saveHdhomerunSetup()
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                        otaRoot.exitOta()
                        event.accepted = true
                    }
                }
            }
        }

    }

    Text {
        text: statusText
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.8
        wrapMode: Text.WordWrap
        font.pixelSize: root.sh * 0.05
        visible: !otaRoot.noSignalVisible && !otaRoot.hdhomerunSetupVisible && (otaRoot.tuningStaticVisible || !hasStartedPlayback)
    }

}
