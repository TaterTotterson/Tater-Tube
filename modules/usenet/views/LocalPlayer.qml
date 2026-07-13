pragma ComponentBehavior: Bound

import QtQuick
import Components

FocusScope {
    id: playerRoot

    property var navParams: ({})

    signal goBack()

    property string moduleId: "com.240mp.usenet"
    property var item: navParams.item || {}
    property string title: navParams.title || item.title || "THE TUBE"
    property string statusText: ""
    property bool playbackStarted: false
    property bool playbackCompleted: false
    property bool noSignalVisible: false
    property int playbackBaseOffsetMs: 0
    property string streamInfoText: ""

    focus: true

    function numericValue(value, fallback) {
        var number = Number(value)
        return isFinite(number) ? number : (fallback || 0)
    }

    function itemViewOffsetMs(row) {
        if (!row)
            return 0
        var offset = numericValue(row.viewOffset, 0)
        if (offset <= 0)
            offset = numericValue(row.viewOffsetSeconds, 0) * 1000
        return Math.max(0, Math.round(offset))
    }

    function itemDurationMs(row) {
        if (!row)
            return 0
        var duration = numericValue(row.duration, 0)
        if (duration > 0)
            return Math.round(duration * 1000)
        duration = numericValue(row.durationSeconds, 0)
        return duration > 0 ? Math.round(duration * 1000) : 0
    }

    function urlWithStartOffset(url, offset) {
        if (!url || !offset || offset <= 0)
            return url
        var hashIndex = url.indexOf("#")
        var base = hashIndex >= 0 ? url.slice(0, hashIndex) : url
        var hash = hashIndex >= 0 ? url.slice(hashIndex) : ""
        var separator = base.indexOf("?") >= 0 ? "&" : "?"
        return base + separator + "start=" + encodeURIComponent(offset.toFixed(3)) + hash
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

    function plannedStreamInfo(playbackUrl) {
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

    function hasPlaybackStateItem() {
        return item
                && ((item.playStateId || "") !== "" || (item.path || "") !== "")
                && (item.type || "") === "localFile"
    }

    function currentPlaybackPositionMs() {
        var position = numericValue(mpvController.position, 0)
        if (playbackBaseOffsetMs > 0 && position < playbackBaseOffsetMs)
            position += playbackBaseOffsetMs
        return Math.max(0, Math.round(position))
    }

    function currentPlaybackDurationMs() {
        var duration = numericValue(mpvController.duration, 0)
        var itemDuration = itemDurationMs(item)
        if (duration <= 0 || (itemDuration > 0 && duration < currentPlaybackPositionMs()))
            duration = itemDuration
        return Math.max(0, Math.round(duration))
    }

    function saveCurrentPlayState(completed) {
        if (!hasPlaybackStateItem() || playbackCompleted)
            return
        var positionMs = currentPlaybackPositionMs()
        var durationMs = currentPlaybackDurationMs()
        playbackCompleted = completed === true
        usenetBackend.save_play_state({
            playStateId: item.playStateId || "",
            seriesId: item.seriesStateId || "",
            title: item.title || "LOCAL",
            seriesTitle: item.seriesTitle || "",
            mediaType: item.mediaType || "",
            categoryId: item.categoryId || "",
            sourceIndex: item.sourceIndex || 0,
            path: item.path || "",
            positionMs: completed ? durationMs : positionMs,
            durationMs: durationMs,
            completed: completed === true
        })
    }

    function startPlayback() {
        var rawUrl = item.streamUrl || ""
        if (rawUrl === "") {
            noSignalVisible = true
            return
        }

        playbackStarted = true
        playbackCompleted = false
        playbackBaseOffsetMs = 0
        statusText = "PLAYING " + title

        var startOffsetMs = itemViewOffsetMs(item)
        var startOffset = startOffsetMs / 1000.0
        if (startOffset > 0 && usenetBackend.uses_server_seek()) {
            rawUrl = urlWithStartOffset(rawUrl, startOffset)
            playbackBaseOffsetMs = startOffsetMs
            startOffset = 0.0
        }

        var playbackUrl = usenetBackend.playback_url(rawUrl, Math.round(root.sw), Math.round(root.sh))
        updateStreamOverlayInfo(plannedStreamInfo(playbackUrl))
        mpvController.loadAndPlay(playbackUrl, startOffset, 0, -1, [], false, -1, 0.0,
                                  "", false, "tube", false, title)
    }

    function stopAndReturn() {
        if (playbackStarted) {
            saveCurrentPlayState(false)
            playbackStarted = false
            mpvController.stop()
        }
        goBack()
    }

    Keys.onPressed: function(event) {
        if (noSignalVisible) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back ||
                event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            stopAndReturn()
            event.accepted = true
        } else if (event.key === Qt.Key_Menu) {
            mpvController.sendKey("MENU")
            event.accepted = true
        } else if (event.key === Qt.Key_Space) {
            mpvController.sendKey("SPACE")
            event.accepted = true
        } else if (event.key === Qt.Key_Left) {
            mpvController.sendKey("LEFT")
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            mpvController.sendKey("RIGHT")
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            mpvController.sendKey("UP")
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            mpvController.sendKey("DOWN")
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            mpvController.sendKey("ENTER")
            event.accepted = true
        }
    }

    Component.onCompleted: startPlayback()

    Component.onDestruction: {
        if (playbackStarted) {
            saveCurrentPlayState(false)
            mpvController.stop()
        }
    }

    Timer {
        interval: 3000
        repeat: true
        running: playbackStarted && mpvController.running
        onTriggered: usenetBackend.load_active_streams()
    }

    Timer {
        interval: 15000
        repeat: true
        running: playbackStarted && hasPlaybackStateItem()
        onTriggered: saveCurrentPlayState(false)
    }

    Connections {
        target: usenetBackend

        function onActiveStreamsLoaded(streams) {
            if (!playerRoot.playbackStarted)
                return
            var rows = streams || []
            if (rows.length === 0)
                return
            playerRoot.updateStreamOverlayInfo(playerRoot.streamInfoFromActiveStream(rows[0]))
        }
    }

    Connections {
        target: mpvController

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (!playbackStarted)
                return
            saveCurrentPlayState(false)
            playbackStarted = false
            goBack()
        }

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (!playbackStarted)
                return
            saveCurrentPlayState(true)
            playbackStarted = false
            goBack()
        }

        function onPlaybackFailed() {
            if (!playbackStarted)
                return
            saveCurrentPlayState(false)
            playbackStarted = false
            noSignalVisible = true
        }

        function onScriptMessageReceived(message, arg) {
            if (!playbackStarted)
                return
            if (message === "240mp-ota-file-loaded") {
                updateStreamOverlayInfo(streamInfoText)
                usenetBackend.load_active_streams()
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    Text {
        visible: playbackStarted && !mpvController.running && !noSignalVisible
        text: "LOADING..."
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05
    }

    NoSignalScreen {
        anchors.fill: parent
        visible: noSignalVisible
        inputLabel: "VIDEO 1"
        message: "NO SIGNAL"
        detail: "THE TUBE PLAYBACK FAILED"
        z: 4
    }
}
