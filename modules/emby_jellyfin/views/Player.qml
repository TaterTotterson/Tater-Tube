import QtQuick
import Components
import "../../shared/TaterBumpers.js" as TaterBumpers

FocusScope {
    id: playerRoot

    property var navParams: ({})

    signal navigateTo(string path, var params)
    signal goBack()
    // Emitted when autoplay advances in place, so Root can repoint the BACK
    // target to the now-playing episode's detail instead of the original one.
    signal updateBackItem(var item)

    property string streamUrl:    navParams.streamUrl    || ""
    property string httpHeaderFields:    navParams.httpHeaderFields    || ""
    property string ratingKey:    navParams.ratingKey    || ""
    property string partKey:      navParams.partKey      || ""
    property string partId:       navParams.partId       || ""
    property string sessionId:    navParams.sessionId    || ""
    property int    viewOffset:   navParams.viewOffset   || 0
    property string itemTitle:    navParams.title        || ""
    property string mediaType:    navParams.mediaType    || ""
    property string overlayTitle: navParams.grandparentTitle || navParams.title || ""
    property var    audioStreams:     navParams.audioStreams     || []
    property var    subtitleStreams:  navParams.subtitleStreams  || []
    property int    audioIdx:    0
    property int    subtitleIdx: 0
    property bool   isTranscoding:    navParams.isTranscoding    || false
    property var    imageSubtitleIds: navParams.imageSubtitleIds || []
    property string selectedAudioId:    navParams.selectedAudioId    || ""
    property string selectedSubtitleId: navParams.selectedSubtitleId || "0"

    property bool stoppedReported:    false
    property bool playbackStarted:    false
    property bool overlayVisible:     false
    property bool noSignalVisible:    false
    property int  choiceIndex:        0
    property string resumeSetting:    "ask"
    property bool pendingRetryTranscode: false

    // Autoplay-next-episode. When enabled, a natural end-of-file advances to the
    // next episode in the same season, carrying over the audio/subtitle language.
    property bool   autoplayNext:       false
    property bool   pendingNextEpisode: false
    property string carryAudioLang:     ""        // language code of the chosen audio track
    property string carrySubLang:       "__off__" // language code, or "__off__" when subtitles are off
    property bool   playingTaterBumper: false
    property bool   movieBumperPlayed: false
    property string bumperContinuation: ""
    property int    pendingProgramOffsetMs: 0
    property var    pendingEpisodeDetail: ({})

    property int lastKnownPositionMs: 0
    property int lastKnownDurationMs: 0

    focus: true

    Keys.onPressed: function(event) {
        if (noSignalVisible) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back ||
                event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                goBack()
                event.accepted = true
            }
        } else if (overlayVisible) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                choiceIndex = 0
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                choiceIndex = 1
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                overlayVisible = false
                if (choiceIndex === 0) {
                    beginPlayback(viewOffset)
                } else {
                    startFromBeginning()
                }
                event.accepted = true
            }
        } else {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                mpvController.sendKey("ESC")
                event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
                mpvController.sendKey("BS")
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                mpvController.sendKey("MENU")
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                mpvController.sendKey("UP")
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                mpvController.sendKey("DOWN")
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                mpvController.sendKey("LEFT")
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                mpvController.sendKey("RIGHT")
                event.accepted = true
            } else if (event.key === Qt.Key_Space) {
                mpvController.sendKey("SPACE")
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                mpvController.sendKey("ENTER")
                event.accepted = true
            }
        }
    }

    function newSessionId() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var id = ""
        for (var i = 0; i < 12; i++) id += chars[Math.floor(Math.random() * chars.length)]
        return id
    }

    // Report the final "stopped" timeline for the current episode exactly once.
    // The fallback position/duration are used only when no live value is known.
    function reportStopped(finalPositionMs, finalDurationMs) {
        if (stoppedReported) return
        stoppedReported = true
        var pos = lastKnownPositionMs || finalPositionMs
        var dur = lastKnownDurationMs || finalDurationMs
        embyBackend.update_timeline(ratingKey, partKey, "stopped", pos, dur)
    }

    function stopPlayback() {
        reportStopped(mpvController.position, mpvController.duration)
        mpvController.stop()
    }

    function initStreamIndices() {
        var selAudio = navParams.selectedAudioId    || ""
        var selSub   = navParams.selectedSubtitleId || "0"
        for (var i = 0; i < audioStreams.length; i++) {
            if (audioStreams[i].id === selAudio) { audioIdx = i; break }
        }
        for (var j = 0; j < subtitleStreams.length; j++) {
            if (subtitleStreams[j].id === selSub) { subtitleIdx = j; break }
        }
        captureCarryLanguages()
    }

    // Record the language of the current audio/subtitle selection so the next
    // episode (which has different per-file stream IDs) can be matched by language.
    function captureCarryLanguages() {
        var a = audioStreams[audioIdx]
        carryAudioLang = (a && a.language) ? a.language : ""
        // subtitleIdx 0 is the synthetic "OFF" entry — preserve "off" deliberately.
        var s = subtitleStreams[subtitleIdx]
        carrySubLang = (subtitleIdx === 0 || !s) ? "__off__" : (s.language || "")
    }

    // Select audioIdx/subtitleIdx on the current stream lists to match the carried
    // languages. Falls back to the first audio track / subtitles-off when no match.
    function applyCarryLanguages() {
        audioIdx = 0
        for (var i = 0; i < audioStreams.length; i++) {
            if (carryAudioLang && audioStreams[i].language === carryAudioLang) { audioIdx = i; break }
        }
        subtitleIdx = 0
        if (carrySubLang !== "__off__" && carrySubLang !== "") {
            for (var j = 1; j < subtitleStreams.length; j++) {
                if (subtitleStreams[j].language === carrySubLang) { subtitleIdx = j; break }
            }
        }
    }

    function buildSubArgs() {
        var allSubUrls = []
        for (var i = 1; i < subtitleStreams.length; i++) {
            if (subtitleStreams[i] && subtitleStreams[i].subUrl)
                allSubUrls.push(subtitleStreams[i].subUrl)
        }
        var selectedSub = subtitleIdx > 0 ? subtitleStreams[subtitleIdx] : null
        var selectedSubUrl = selectedSub ? (selectedSub.subUrl || "") : ""
        if (selectedSubUrl && allSubUrls.length > 1) {
            allSubUrls = allSubUrls.filter(function(u) { return u !== selectedSubUrl })
            allSubUrls.unshift(selectedSubUrl)
        }
        var subTrack
        if (subtitleIdx === 0)
            subTrack = -1
        else if (selectedSubUrl)
            subTrack = 0
        else
            subTrack = subtitleIdx
        return { urls: allSubUrls, track: subTrack }
    }

    // Starting mpv runs synchronously and, on the Pi, immediately switches VT
    // (suspending Qt's render thread) before the LOADING frame can paint. Defer
    // the launch one tick so the loading indicator is rendered first — mirroring
    // the async transcode path, which already yields to the event loop. Without
    // this, RESUME/direct-play show no loading screen on the Pi.
    Timer {
        id: startTimer
        interval: 50
        repeat: false
        property int pendingOffset: 0
        onTriggered: doStartPlayback(pendingOffset)
    }

    function beginPlayback(offsetMs) {
        if (String(mediaType || "").toLowerCase() === "movie" && !movieBumperPlayed &&
                TaterBumpers.enabledByDefault(
                    appCore.get_setting("", "tater_bumpers_vod_movies"))) {
            movieBumperPlayed = true
            pendingProgramOffsetMs = offsetMs
            playTaterBumper("movie")
            return
        }
        queueProgramPlayback(offsetMs)
    }

    function queueProgramPlayback(offsetMs) {
        startTimer.pendingOffset = offsetMs
        startTimer.restart()
    }

    function playTaterBumper(continuation) {
        var bumper = TaterBumpers.next(
                    appCore, continuation === "movie" ? "vod-movie" : "vod-series")
        if (!bumper || !bumper.url) {
            bumperContinuation = continuation
            finishTaterBumper()
            return
        }
        bumperContinuation = continuation
        playingTaterBumper = true
        playbackStarted = false
        noSignalVisible = false
        mpvController.setViewingContext({ suppress_viewing_event: true })
        mpvController.loadAndPlay(bumper.url, 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "", false, "TATER TUBE")
    }

    function finishTaterBumper() {
        var continuation = bumperContinuation
        bumperContinuation = ""
        playingTaterBumper = false
        playbackStarted = false
        if (continuation === "movie") {
            var offsetMs = pendingProgramOffsetMs
            pendingProgramOffsetMs = 0
            queueProgramPlayback(offsetMs)
            return
        }
        if (continuation === "episode") {
            var detail = pendingEpisodeDetail || ({})
            pendingEpisodeDetail = ({})
            if (detail.ratingKey)
                advanceToEpisode(detail)
            else
                goBack()
        }
    }

    function doStartPlayback(offsetMs) {
        noSignalVisible = false
        if (isTranscoding) {
            // Transcode covers the full timeline (requested at offset 0), so seek mpv
            // to the resume point. This keeps everything before offsetMs seekable, so
            // the user can rewind past the resume point.
            mpvController.loadAndPlay(streamUrl, offsetMs / 1000.0, 0, -1, [], false, -1, 0.0,
                                      httpHeaderFields, false, "", false, overlayTitle)
        } else {
            var sub = buildSubArgs()
            mpvController.loadAndPlay(streamUrl, offsetMs / 1000.0,
                                       audioIdx + 1, sub.track, sub.urls, false, -1, 0.0,
                                       httpHeaderFields, false, "", false, overlayTitle)
        }
    }

    function startFromBeginning() {
        // Transcode already starts at 0, so both paths simply play from the start.
        // Use beginPlayback so the loading indicator shows while mpv spins up.
        beginPlayback(0)
    }

    function formatTime(ms) {
        var s = Math.floor(ms / 1000)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0)
            return h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    function toggleEnabledByDefault(raw) {
        return !(raw === false || raw === "OFF" || raw === "off" || raw === 0 || raw === "0")
    }

    Connections {
        target: embyBackend
        function onErrorOccurred(msg) {
            console.log("[Player] Backend error: " + msg)
            if (pendingRetryTranscode || pendingNextEpisode) {
                pendingRetryTranscode = false
                pendingNextEpisode = false
                goBack()
            }
        }
        function onStreamUrlReady(url, httpHeaderFields) {
            if (pendingNextEpisode) {
                // Stream URL for the auto-advanced next episode just arrived.
                pendingNextEpisode = false
                playerRoot.streamUrl = url
                playerRoot.httpHeaderFields = httpHeaderFields
                doStartPlayback(0)
                return
            }
            if (pendingRetryTranscode) {
                pendingRetryTranscode = false
                isTranscoding = true
                // Fallback transcode was requested at offset 0 (full timeline), so seek
                // mpv to the resume point — keeps everything before it seekable.
                var sub = buildSubArgs()
                mpvController.loadAndPlay(url, viewOffset / 1000.0, audioIdx + 1, sub.track, sub.urls, false, -1, 0.0,
                                          httpHeaderFields, false, "", false, overlayTitle)
                return
            }
        }

        function onNextEpisodeReady(detail) {
            if (!pendingNextEpisode) return
            // Empty detail → no next episode in the season (or a lookup failure).
            // Fall back to the standard behavior: return to the detail view.
            if (!detail || !detail.ratingKey) {
                pendingNextEpisode = false
                goBack()
                return
            }
            pendingNextEpisode = false
            var seriesKey = detail.grandparentTitle || overlayTitle || detail.parentRatingKey || ratingKey
            if (TaterBumpers.enabledByDefault(
                        appCore.get_setting("", "tater_bumpers_vod_series")) &&
                    TaterBumpers.shouldPlayBetweenEpisodes("vod", seriesKey)) {
                pendingEpisodeDetail = detail
                playTaterBumper("episode")
                return
            }
            playerRoot.advanceToEpisode(detail)
        }
    }

    // Swap the player's context to the next episode in place (no navigation) and
    // begin playing it from the beginning, carrying over the track languages.
    function advanceToEpisode(detail) {
        ratingKey   = detail.ratingKey
        partKey     = detail.partKey      || ""
        partId      = detail.partId       || ""
        itemTitle   = detail.title        || ""
        mediaType   = detail.type         || "episode"
        overlayTitle = detail.grandparentTitle || detail.title || ""
        audioStreams    = detail.audioStreams    || []
        subtitleStreams = detail.subtitleStreams || []
        isTranscoding   = detail.forceTranscode  || false

        // Recompute the image-subtitle IDs for THIS episode (stream IDs are
        // per-file), mirroring Item.qml's build before the initial hand-off.
        var imageSubs = []
        for (var k = 0; k < subtitleStreams.length; k++) {
            if (subtitleStreams[k] && subtitleStreams[k].imageSubtitle)
                imageSubs.push(subtitleStreams[k].id)
        }
        imageSubtitleIds = imageSubs

        // Fresh-start state for the new episode.
        viewOffset           = 0
        stoppedReported      = false
        lastKnownPositionMs  = 0
        lastKnownDurationMs  = 0
        sessionId            = newSessionId()

        // Repoint the BACK target so exiting returns to THIS episode's detail
        // screen, not the one we auto-advanced from. Item.qml reloads from
        // item.ratingKey, so a minimal item carrying the new keys suffices.
        updateBackItem({
            ratingKey: detail.ratingKey,
            type: detail.type || "episode",
            title: detail.title || "",
            grandparentTitle: detail.grandparentTitle || "",
            parentIndex: detail.parentIndex,
            index: detail.index
        })

        // Match the carried languages onto this episode's stream lists, then
        // remember the resulting selection for the episode after this one.
        applyCarryLanguages()
        var audioId = (audioStreams[audioIdx] && audioStreams[audioIdx].id) ? audioStreams[audioIdx].id : ""
        var subId   = (subtitleStreams[subtitleIdx] && subtitleStreams[subtitleIdx].id) ? subtitleStreams[subtitleIdx].id : "0"
        selectedAudioId    = audioId
        selectedSubtitleId = subId
        captureCarryLanguages()

        // Let the backend persist chosen tracks when the provider supports
        // server-side preferences.
        if (partId) {
            if (audioId) embyBackend.set_audio_stream(audioId, partId)
            embyBackend.set_subtitle_stream(subId, partId)
        }

        // Both paths resolve asynchronously through onStreamUrlReady, which checks this flag.
        pendingNextEpisode = true
        if (isTranscoding) {
            embyBackend.request_transcode(ratingKey, partKey, sessionId, audioId, subId, 0)
        } else {
            embyBackend.build_stream_url(ratingKey, partKey, sessionId)
        }
    }

    Connections {
        target: mpvController

        function onPositionChanged(ms) {
            if (ms > 0) {
                playerRoot.lastKnownPositionMs = ms
                // First position update means mpv is up and playing — drop the
                // loading indicator (mpv's own window now covers the screen).
                playerRoot.playbackStarted = true
            }
        }
        function onDurationChanged(ms) {
            if (ms > 0) playerRoot.lastKnownDurationMs = ms
        }

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (playingTaterBumper) {
                playingTaterBumper = false
                bumperContinuation = ""
                pendingEpisodeDetail = ({})
                goBack()
                return
            }
            // mpv exited because the user quit/stopped — return to the detail view.
            reportStopped(finalPositionMs, finalDurationMs)
            goBack()
        }

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (playingTaterBumper) {
                finishTaterBumper()
                return
            }
            // mpv reached the end of the file. Mark it stopped (watched) in Emby/Jellyfin,
            // then auto-advance to the next episode if the feature is enabled.
            reportStopped(finalPositionMs, finalDurationMs)
            if (!autoplayNext) { goBack(); return }
            pendingNextEpisode = true
            embyBackend.load_next_episode(ratingKey)
        }

        function onPlaybackFailed() {
            if (playingTaterBumper) {
                finishTaterBumper()
                return
            }
            if (!isTranscoding) {
                // Direct play failed (e.g. HTTP 500 from PMS on WAN). Retry
                // transparently with transcoding at the same resume offset.
                pendingRetryTranscode = true
                embyBackend.request_transcode(ratingKey, partKey, sessionId,
                                              selectedAudioId, selectedSubtitleId,
                                              0)
            } else {
                noSignalVisible = true
                playbackStarted = false
                if (mpvController.running)
                    mpvController.stop()
            }
        }
    }

    Timer {
        interval: 10000
        repeat:   true
        running:  true
        onTriggered: {
            if (!playingTaterBumper && mpvController.position > 0)
                embyBackend.update_timeline(ratingKey, partKey, "playing",
                                            mpvController.position, mpvController.duration)
        }
    }

    Component.onCompleted: {
        if (menuSoundPlayer)
            menuSoundPlayer.setContextActive("qml:emby-player", true)
        initStreamIndices()
        if (streamUrl === "") return
        resumeSetting = appCore.get_setting(moduleRoot.moduleId, "resume_playback") || "ask"
        // Match ModuleSettings.qml's reading of a toggle: stored as a real bool
        // once the user touches it, but accept the legacy "ON" string too.
        var autoplayRaw = appCore.get_setting(moduleRoot.moduleId, "autoplay_next_episode")
        autoplayNext  = toggleEnabledByDefault(autoplayRaw)

        if (resumeSetting === "ask" && viewOffset > 0) {
            overlayVisible = true
        } else {
            beginPlayback(viewOffset)
        }
    }

    Component.onDestruction: {
        if (menuSoundPlayer)
            menuSoundPlayer.setContextActive("qml:emby-player", false)
        if (mpvController.running)
            mpvController.stop()
    }

    Rectangle {
        anchors.fill: parent
        color: "black"

        // Shown while mpv launches and buffers the stream (before its window
        // takes over). Hidden once the first position update arrives, or while
        // the resume prompt is up.
        Text {
            text: "LOADING..."
            // White to match mpv's own overlay text color.
            color: "white"
            font.family: root.globalFont
            anchors.centerIn: parent
            font.pixelSize: root.sh * 0.05 //24
            visible: streamUrl !== "" && !overlayVisible && !noSignalVisible && !playbackStarted
        }
    }

    NoSignalScreen {
        anchors.fill: parent
        visible: noSignalVisible
        inputLabel: "VIDEO 1"
        message: "NO SIGNAL"
        detail: "PLAYBACK FAILED"
        z: 4
    }

    Rectangle {
        anchors.fill: parent
        color: root.staticBackgroundEnabled ? "transparent" : root.surfaceColor
        visible: overlayVisible

        StaticBackground {
            anchors.fill: parent
            themeName: root.currentTheme
            visible: root.staticBackgroundEnabled
            running: visible
        }

        Rectangle {
            id: dialogRect
            color: root.staticBackgroundEnabled ? "transparent" : root.surfaceColor
            anchors.centerIn: parent
            width: root.sw * 0.76875
            height: root.sh * 0.2833333

            Column {
                id: dialogColumn
                anchors.fill: parent
                spacing: root.sh * 0.05

                Text {
                    text: "RESUME PLAYBACK?"
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    Repeater {
                        model: [
                            "Resume from " + formatTime(viewOffset),
                            "Start from the beginning"
                        ]
                        delegate: Item {
                            width: dialogColumn.width
                            height: root.sh * 0.0583333

                            Rectangle {
                                anchors.fill: delegateText
                                color: root.accentColor
                                visible: index === choiceIndex
                            }

                            Text {
                                id: delegateText
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData
                                color: index === choiceIndex ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                topPadding: root.sh * 0.0041667
                                leftPadding: root.sw * 0.009375
                                rightPadding: root.sw * 0.009375
                                bottomPadding: root.sh * 0.00625
                                font.pixelSize: root.sh * 0.0416667
                            }
                        }
                    }
                }

            }
        }
    }
}
