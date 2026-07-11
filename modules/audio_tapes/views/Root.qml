import QtQuick
import Components

FocusScope {
    id: tapeRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.audio_tapes"
    property var libraries: []
    property var albums: []
    property var tracks: []
    property int currentLibraryIndex: 0
    property int currentAlbumIndex: 0
    property int trackIndex: 0
    property string mode: "loading"
    property string statusText: "LOADING TAPES..."
    property string currentLibraryTitle: "TAPE DECK"
    property string currentAlbumTitle: "TAPE"
    property string currentAlbumArtist: "UNKNOWN ARTIST"
    property bool skippedLibraryPicker: false
    property string pendingItemId: ""
    property bool playing: false
    property bool paused: false
    property bool fastForwarding: false
    property bool ignoringPreviousTrackExit: false
    property int fastForwardTargetIndex: -1
    property int visualTick: 0
    property string musicProvider: "Video on Demand"

    focus: true

    function currentTrack() {
        if (trackIndex < 0 || trackIndex >= tracks.length) return ({})
        return tracks[trackIndex] || ({})
    }

    function currentTitle() {
        var track = currentTrack()
        return track.title || "NO TAPE"
    }

    function currentArtist() {
        var track = currentTrack()
        return track.artist || currentAlbumArtist || currentLibraryTitle || "UNKNOWN ARTIST"
    }

    function currentAlbum() {
        var track = currentTrack()
        return track.album || currentAlbumTitle || "TAPE"
    }

    function refreshProvider() {
        var provider = appCore.get_setting(moduleId, "music_provider") || "Video on Demand"
        musicProvider = provider
    }

    function usesTaterServer() {
        return String(musicProvider).toLowerCase() === "tater tube server"
    }

    function formatTime(ms) {
        var total = Math.max(0, Math.floor((ms || 0) / 1000))
        var m = Math.floor(total / 60)
        var s = total % 60
        return m + ":" + (s < 10 ? "0" + s : "" + s)
    }

    function vuLift(index) {
        if (!playing)
            return 0.06
        if (paused)
            return 0.10

        var level = Math.max(0, Math.min(1, mpvController.audioLevel || 0))
        var fallbackDriven = 0
        if (!fastForwarding && level < 0.012) {
            fallbackDriven = 0.18
                + Math.abs(Math.sin((visualTick * 0.22) + index * 0.51)) * 0.26
                + Math.abs(Math.sin((visualTick * 0.09) + index * 1.31)) * 0.14
        }
        var driven = fallbackDriven > 0 ? fallbackDriven : Math.pow(Math.min(1, level * 1.35), 0.78)
        var bandShape = 0.48 + Math.abs(Math.sin(index * 0.42)) * 0.52
        var flicker = 0.88 + Math.abs(Math.sin((visualTick * 0.26) + index * 0.55)) * 0.12
        var floor = fastForwarding ? 0.28 : 0.07
        var lift = floor + driven * bandShape * flicker

        if (fastForwarding)
            lift = Math.max(lift, 0.45 + Math.abs(Math.sin((visualTick * 0.35) + index * 0.65)) * 0.40)

        return Math.min(1.0, lift)
    }

    function loadLibraries() {
        refreshProvider()
        if (usesTaterServer()) {
            if (usenetBackend.get_auth_state() !== "authed") {
                mode = "message"
                statusText = "PAIR TATER TUBE SERVER"
                return
            }

            mode = "loading"
            statusText = "LOADING SERVER TAPES..."
            skippedLibraryPicker = false
            usenetBackend.load_music_libraries()
            return
        }

        if (embyBackend.get_auth_state() !== "authed") {
            mode = "message"
            statusText = "SIGN IN FROM VIDEO ON DEMAND"
            return
        }

        mode = "loading"
        statusText = "LOADING TAPES..."
        skippedLibraryPicker = false
        embyBackend.load_music_libraries()
    }

    function selectLibrary(index) {
        if (index < 0 || index >= libraries.length) return
        currentLibraryIndex = index
        var library = libraries[index] || ({})
        currentLibraryTitle = library.title || "TAPE DECK"
        currentAlbumIndex = 0
        albums = []
        tracks = []
        mode = "loading"
        statusText = "SCANNING TAPES..."
        if (usesTaterServer())
            usenetBackend.load_music_albums(library.sectionId || library.key || library.ratingKey || "")
        else
            embyBackend.load_music_albums(library.sectionId || library.key || "")
    }

    function selectAlbum(index) {
        if (index < 0 || index >= albums.length) return
        currentAlbumIndex = index
        albumList.currentIndex = index
        var album = albums[index] || ({})
        currentAlbumTitle = album.title || "TAPE"
        currentAlbumArtist = album.artist || "UNKNOWN ARTIST"
        tracks = []
        mode = "loading"
        statusText = "LOADING " + currentAlbumTitle
        if (usesTaterServer())
            usenetBackend.load_music_tracks(album.ratingKey || album.key || "")
        else
            embyBackend.load_music_tracks(album.ratingKey || album.key || "")
    }

    function playTrack(index) {
        if (index < 0 || index >= tracks.length) return
        fastForwardTimer.stop()
        fastForwarding = false
        fastForwardTargetIndex = -1
        trackIndex = index
        trackList.currentIndex = index
        var track = currentTrack()
        pendingItemId = track.ratingKey || track.key || ""
        if (pendingItemId === "") return
        statusText = "THREADING TAPE..."
        if (usesTaterServer()) {
            if (!track.streamUrl) {
                mode = "message"
                statusText = "TAPE STREAM MISSING"
                return
            }
            mode = "deck"
            playing = true
            paused = false
            ignoringPreviousTrackExit = false
            mpvController.loadAudioAndPlay(track.streamUrl, 0.0, "", track.title || "TAPE")
        } else {
            embyBackend.build_audio_stream_url(pendingItemId, track.partKey || "")
        }
    }

    function stopDeck(returnToTracks) {
        cancelFastForward()
        if (mpvController.running)
            mpvController.stop()
        playing = false
        paused = false
        pendingItemId = ""
        ignoringPreviousTrackExit = false
        if (returnToTracks)
            mode = "tracks"
    }

    function nextTrack() {
        if (tracks.length === 0) return
        var targetIndex = (fastForwarding && fastForwardTargetIndex >= 0)
            ? (fastForwardTargetIndex + 1) % tracks.length
            : (trackIndex + 1) % tracks.length
        if (mode === "deck" && playing && mpvController.running) {
            startFastForward(targetIndex)
            return
        }
        playTrack(targetIndex)
    }

    function previousTrack() {
        if (tracks.length === 0) return
        if (fastForwarding && fastForwardTargetIndex >= 0) {
            fastForwardTargetIndex = (fastForwardTargetIndex + tracks.length - 1) % tracks.length
            return
        }
        cancelFastForward()
        playTrack((trackIndex + tracks.length - 1) % tracks.length)
    }

    function startFastForward(targetIndex) {
        if (targetIndex < 0 || targetIndex >= tracks.length) return

        if (fastForwarding) {
            fastForwardTargetIndex = targetIndex
            return
        }

        var position = Math.max(0, mpvController.position || 0)
        var duration = Math.max(0, mpvController.duration || 0)
        if (duration <= 0 || duration - position < 900) {
            playTrack(targetIndex)
            return
        }

        var remaining = Math.max(900, duration - position)
        var speed = Math.max(8.0, Math.min(80.0, remaining / 1800.0))
        var waitMs = Math.max(850, Math.min(5200, Math.floor(remaining / speed) + 650))
        fastForwarding = true
        fastForwardTargetIndex = targetIndex
        pendingItemId = ""
        paused = false
        mpvController.setPaused(false)
        mpvController.setAudioPitchCorrection(false)
        mpvController.setPlaybackSpeed(speed)
        fastForwardTimer.interval = waitMs
        fastForwardTimer.restart()
    }

    function cancelFastForward() {
        if (!fastForwarding) return
        fastForwardTimer.stop()
        fastForwarding = false
        fastForwardTargetIndex = -1
        ignoringPreviousTrackExit = false
        mpvController.setPlaybackSpeed(1.0)
        mpvController.setAudioPitchCorrection(true)
    }

    function finishFastForward() {
        if (!fastForwarding) return
        var targetIndex = fastForwardTargetIndex
        fastForwardTimer.stop()
        fastForwarding = false
        fastForwardTargetIndex = -1
        mpvController.setPlaybackSpeed(1.0)
        mpvController.setAudioPitchCorrection(true)
        ignoringPreviousTrackExit = true
        if (mpvController.running)
            mpvController.stop()
        if (targetIndex >= 0 && targetIndex < tracks.length)
            playTrack(targetIndex)
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            if (mode === "deck") {
                stopDeck(true)
            } else if (mode === "tracks") {
                mode = "albums"
                albumList.currentIndex = currentAlbumIndex
            } else if (mode === "albums") {
                if (skippedLibraryPicker)
                    goBack()
                else
                    mode = "libraries"
            } else {
                goBack()
            }
            event.accepted = true
            return
        }

        if (mode === "libraries") {
            if (event.key === Qt.Key_Up) {
                libraryList.currentIndex = Math.max(0, libraryList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                libraryList.currentIndex = Math.min(libraryList.count - 1, libraryList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                selectLibrary(libraryList.currentIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "albums") {
            if (event.key === Qt.Key_Up) {
                albumList.currentIndex = Math.max(0, albumList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                albumList.currentIndex = Math.min(albumList.count - 1, albumList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                if (skippedLibraryPicker)
                    goBack()
                else
                    mode = "libraries"
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                selectAlbum(albumList.currentIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "tracks") {
            if (event.key === Qt.Key_Up) {
                trackList.currentIndex = Math.max(0, trackList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                trackList.currentIndex = Math.min(trackList.count - 1, trackList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                mode = "albums"
                albumList.currentIndex = currentAlbumIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                playTrack(trackList.currentIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "deck") {
            if (event.key === Qt.Key_Left) {
                previousTrack()
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                nextTrack()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Menu) {
                mpvController.togglePause()
                event.accepted = true
            }
        }
    }

    Component.onCompleted: loadLibraries()

    Component.onDestruction: {
        if (mpvController.running)
            mpvController.stop()
    }

    Connections {
        target: embyBackend

        function onMusicLibrariesLoaded(items) {
            libraries = items || []
            if (libraries.length === 0) {
                mode = "message"
                statusText = "NO MUSIC LIBRARIES FOUND"
                return
            }
            if (libraries.length === 1) {
                skippedLibraryPicker = true
                selectLibrary(0)
                return
            }
            mode = "libraries"
            libraryList.currentIndex = Math.min(currentLibraryIndex, libraries.length - 1)
        }

        function onMusicAlbumsLoaded(items) {
            albums = items || []
            if (albums.length === 0) {
                mode = "message"
                statusText = "NO ALBUMS FOUND"
                return
            }
            mode = "albums"
            currentAlbumIndex = Math.min(currentAlbumIndex, albums.length - 1)
            albumList.currentIndex = currentAlbumIndex
        }

        function onMusicTracksLoaded(items) {
            tracks = items || []
            if (tracks.length === 0) {
                mode = "message"
                statusText = "NO TRACKS FOUND"
                return
            }
            mode = "tracks"
            trackIndex = 0
            trackList.currentIndex = 0
        }

        function onAudioStreamUrlReady(itemId, url, httpHeaderFields) {
            if (itemId !== pendingItemId) return
            var track = currentTrack()
            mode = "deck"
            playing = true
            paused = false
            ignoringPreviousTrackExit = false
            mpvController.loadAudioAndPlay(url, 0.0, httpHeaderFields || "", track.title || "TAPE")
        }

        function onErrorOccurred(message) {
            ignoringPreviousTrackExit = false
            if (mode === "loading" || mode === "deck") {
                playing = false
                mode = "message"
                statusText = message || "TAPE ERROR"
            }
        }
    }

    Connections {
        target: usenetBackend

        function onMusicLibrariesLoaded(items) {
            if (!usesTaterServer()) return
            libraries = items || []
            if (libraries.length === 0) {
                mode = "message"
                statusText = "NO SERVER MUSIC FOUND"
                return
            }
            if (libraries.length === 1) {
                skippedLibraryPicker = true
                selectLibrary(0)
                return
            }
            mode = "libraries"
            libraryList.currentIndex = Math.min(currentLibraryIndex, libraries.length - 1)
        }

        function onMusicAlbumsLoaded(items) {
            if (!usesTaterServer()) return
            albums = items || []
            if (albums.length === 0) {
                mode = "message"
                statusText = "NO SERVER ALBUMS FOUND"
                return
            }
            mode = "albums"
            currentAlbumIndex = Math.min(currentAlbumIndex, albums.length - 1)
            albumList.currentIndex = currentAlbumIndex
        }

        function onMusicTracksLoaded(items) {
            if (!usesTaterServer()) return
            tracks = items || []
            if (tracks.length === 0) {
                mode = "message"
                statusText = "NO SERVER TRACKS FOUND"
                return
            }
            mode = "tracks"
            trackIndex = 0
            trackList.currentIndex = 0
        }

        function onErrorOccurred(message) {
            if (!usesTaterServer()) return
            ignoringPreviousTrackExit = false
            if (mode === "loading" || mode === "deck") {
                playing = false
                mode = "message"
                statusText = message || "TATER SERVER ERROR"
            }
        }
    }

    Connections {
        target: appCore

        function onModuleSettingChanged(mid, key, value) {
            if (mid !== tapeRoot.moduleId || key !== "music_provider")
                return
            loadLibraries()
        }
    }

    Connections {
        target: mpvController

        function onPausedChanged(value) {
            tapeRoot.paused = value
        }

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (ignoringPreviousTrackExit)
                return
            if (fastForwarding) {
                finishFastForward()
                return
            }
            if (mode === "deck")
                nextTrack()
        }

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (ignoringPreviousTrackExit)
                return
            if (fastForwarding) {
                finishFastForward()
                return
            }
            if (mode === "deck" && !pendingItemId) {
                playing = false
                mode = "tracks"
            }
        }

        function onPlaybackFailed() {
            if (ignoringPreviousTrackExit)
                return
            if (fastForwarding) {
                finishFastForward()
                return
            }
            if (mode !== "deck") return
            playing = false
            mode = "message"
            statusText = "TAPE JAMMED"
        }
    }

    Timer {
        interval: fastForwarding ? 35 : 80
        running: mode === "deck" && playing && !paused
        repeat: true
        onTriggered: visualTick++
    }

    Timer {
        id: fastForwardTimer
        interval: 1800
        repeat: false
        onTriggered: finishFastForward()
    }

    StaticBackground {
        anchors.fill: parent
        visible: root.staticBackgroundEnabled
        running: visible && mode !== "deck"
    }

    Rectangle {
        anchors.fill: parent
        color: root.staticBackgroundEnabled && mode !== "deck" ? "transparent" : root.surfaceColor
    }

    AppBar {
        title: "TAPE DECK"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Text {
        visible: mode === "loading" || mode === "message"
        text: statusText
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.78
        wrapMode: Text.WordWrap
        font.pixelSize: root.sh * 0.045
    }

    ListView {
        id: libraryList
        visible: mode === "libraries"
        model: tapeRoot.libraries
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible

        delegate: Item {
            width: libraryList.width
            height: root.sh * 0.065

            Rectangle {
                anchors.fill: tapeText
                color: root.accentColor
                visible: libraryList.currentIndex === index
            }

            Text {
                id: tapeText
                text: "LIBRARY " + (index + 1) + "  " + modelData.title
                color: libraryList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.05
            }
        }
    }

    ListView {
        id: albumList
        visible: mode === "albums"
        model: tapeRoot.albums
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.22
        anchors.leftMargin: root.sw * 0.09
        width: root.sw * 0.82
        height: root.sh * 0.62
        clip: true
        focus: visible

        header: Text {
            width: albumList.width
            height: root.sh * 0.065
            text: currentLibraryTitle
            color: root.accentColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.045
        }

        delegate: Item {
            width: albumList.width
            height: root.sh * 0.064

            Rectangle {
                anchors.fill: albumTitle
                color: root.accentColor
                visible: albumList.currentIndex === index
            }

            Text {
                id: albumTitle
                text: "TAPE " + (index + 1 < 10 ? "0" : "") + (index + 1) + "  " + modelData.title
                color: albumList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.62
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.041
            }

            Text {
                text: modelData.artist || ""
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.left: albumTitle.right
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.sw * 0.012
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
                font.pixelSize: root.sh * 0.031
            }
        }
    }

    ListView {
        id: trackList
        visible: mode === "tracks"
        model: tapeRoot.tracks
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.22
        anchors.leftMargin: root.sw * 0.09
        width: root.sw * 0.82
        height: root.sh * 0.62
        clip: true
        focus: visible

        header: Text {
            width: trackList.width
            height: root.sh * 0.065
            text: currentAlbumTitle + " / " + currentAlbumArtist
            color: root.accentColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            elide: Text.ElideRight
            font.pixelSize: root.sh * 0.045
        }

        delegate: Item {
            width: trackList.width
            height: root.sh * 0.058

            Rectangle {
                anchors.fill: trackTitle
                color: root.accentColor
                visible: trackList.currentIndex === index
            }

            Text {
                id: trackTitle
                text: (index + 1 < 10 ? "0" : "") + (index + 1) + "  " + modelData.title
                color: trackList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.72
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.041
            }

            Text {
                text: modelData.durationDisplay || ""
                color: root.secondaryColor
                font.family: root.globalFont
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: root.sh * 0.033
            }
        }
    }

    Item {
        visible: mode === "deck"
        anchors.fill: parent

        Rectangle {
            id: cassette
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: root.sh * 0.21
            width: root.sw * 0.72
            height: root.sh * 0.38
            color: root.currentTheme === "Off Air" ? "#161616" : root.surfaceColor
            border.color: root.primaryColor
            border.width: 3
            radius: 4

            Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: root.sh * 0.035
                anchors.leftMargin: root.sw * 0.045
                anchors.rightMargin: root.sw * 0.045
                height: root.sh * 0.085
                color: root.accentColor

                Text {
                    text: currentTitle()
                    color: root.surfaceColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: root.sw * 0.012
                    anchors.rightMargin: root.sw * 0.012
                    elide: Text.ElideRight
                    font.pixelSize: root.sh * 0.042
                }
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: root.sh * 0.16
                width: root.sw * 0.42
                height: root.sh * 0.10
                color: "black"
                border.color: root.secondaryColor
                border.width: 2

                Text {
                    text: fastForwarding ? "FF >>" : (paused ? "PAUSE" : "PLAY")
                    color: root.primaryColor
                    font.family: root.globalFont
                    anchors.centerIn: parent
                    font.pixelSize: root.sh * 0.045
                }
            }

            Repeater {
                model: 2
                Rectangle {
                    width: root.sh * 0.13
                    height: width
                    radius: width / 2
                    color: "black"
                    border.color: root.primaryColor
                    border.width: 3
                    x: index === 0 ? cassette.width * 0.18 : cassette.width * 0.70
                    y: cassette.height * 0.52

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.32
                        height: width
                        radius: width / 2
                        color: root.accentColor
                    }

                    Text {
                        text: paused ? "II" : (fastForwarding ? ">>" : ((visualTick + index) % 2 === 0 ? "/" : "\\"))
                        color: root.secondaryColor
                        font.family: root.globalFont
                        anchors.centerIn: parent
                        font.pixelSize: root.sh * 0.05
                    }
                }
            }
        }

        Text {
            anchors.top: cassette.bottom
            anchors.left: cassette.left
            anchors.right: cassette.right
            anchors.topMargin: root.sh * 0.035
            text: currentArtist() + " / " + currentAlbum()
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: root.sh * 0.033
        }

        Text {
            anchors.top: cassette.bottom
            anchors.right: cassette.right
            anchors.topMargin: root.sh * 0.09
            text: formatTime(mpvController.position) + " / " + (currentTrack().durationDisplay || "--:--")
            color: root.primaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.042
        }

        Row {
            id: vuRow
            anchors.left: cassette.left
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.sh * 0.12
            spacing: root.sw * 0.008

            Repeater {
                model: 24
                Rectangle {
                    width: root.sw * 0.018
                    height: {
                        var lift = vuLift(index)
                        return root.sh * (0.022 + lift * 0.13)
                    }
                    anchors.bottom: parent.bottom
                    color: index > 19 || vuLift(index) > 0.82 ? root.accentColor : root.primaryColor

                    Behavior on height {
                        NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
                    }
                }
            }
        }
    }
}
