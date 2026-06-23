import QtQuick
import Components

FocusScope {
    id: mixRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.youtube_playlist"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "PUBLIC ACCESS"
    property string moduleIcon: _moduleInfo.icon || ""

    property string mode: "loading"
    property string statusText: "LOADING PLAYLISTS..."
    property string playlistTitle: "YOUTUBE PLAYLIST"
    property string playlistInput: ""
    property var playlists: []
    property var playlistRows: []
    property var currentPlaylist: ({})
    property var videos: []
    property int currentPlaylistIndex: 0
    property int currentVideoIndex: 0
    property bool loadingPlaylist: false
    property bool addingPlaylist: false
    property bool stoppingPlayback: false

    focus: true

    function settingValue(key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "") return fallback
        return value
    }

    function autoplayNext() {
        var value = settingValue("autoplay_next", true)
        return value === true || value === "ON" || value === "true"
    }

    function playbackQuality() {
        return settingValue("playback_quality", "360p")
    }

    function buildPlaylistRows() {
        var rows = []
        for (var i = 0; i < playlists.length; i++) {
            var item = Object.assign({}, playlists[i])
            item.rowType = "playlist"
            rows.push(item)
        }
        rows.push({ rowType: "add", title: "+ ADD PLAYLIST" })
        playlistRows = rows
    }

    function loadPlaylistLibrary(preferredIndex) {
        playlists = youtubePlaylistBackend.get_saved_playlists()
        buildPlaylistRows()
        mode = "library"
        var idx = preferredIndex === undefined ? currentPlaylistIndex : preferredIndex
        libraryList.currentIndex = Math.max(0, Math.min(idx, playlistRows.length - 1))
        currentPlaylistIndex = libraryList.currentIndex
    }

    function showAdd(message) {
        mode = "add"
        statusText = message || "ADD PLAYLIST"
        playlistField.text = ""
        addFocusTimer.restart()
    }

    function savePlaylistRows(nextPlaylists) {
        appCore.save_setting(moduleId, "playlists", nextPlaylists)
        playlists = nextPlaylists
        buildPlaylistRows()
    }

    function updateCurrentPlaylistTitle(title) {
        title = (title || "").trim()
        if (title === "" || !currentPlaylist.url) return

        var changed = false
        var next = []
        for (var i = 0; i < playlists.length; i++) {
            var item = Object.assign({}, playlists[i])
            if (item.url === currentPlaylist.url && item.title !== title) {
                item.title = title
                changed = true
            }
            next.push(item)
        }
        if (changed) {
            currentPlaylist.title = title
            savePlaylistRows(next)
        }
    }

    function addPlaylist() {
        if (addingPlaylist) return
        var value = (playlistField.text || "").trim()
        if (value === "") {
            statusText = "ENTER PLAYLIST CODE"
            playlistField.forceActiveFocus()
            return
        }

        addingPlaylist = true
        statusText = "READING PLAYLIST INFO..."
        var info = youtubePlaylistBackend.resolve_playlist_info(value)
        addingPlaylist = false

        if (!info || info.ok !== true || !info.url) {
            statusText = (info && info.message) ? info.message : "PLAYLIST LOOKUP FAILED"
            playlistField.forceActiveFocus()
            return
        }

        for (var i = 0; i < playlists.length; i++) {
            if (playlists[i].url === info.url) {
                statusText = "PLAYLIST ALREADY ADDED"
                loadPlaylistLibrary(i)
                return
            }
        }

        var item = {
            id: info.id || info.url,
            input: info.input || value,
            url: info.url,
            title: info.title || ("PLAYLIST " + (playlists.length + 1))
        }
        var next = playlists.slice()
        next.push(item)
        savePlaylistRows(next)
        loadPlaylistLibrary(next.length - 1)
    }

    function selectPlaylist(index) {
        if (index < 0 || index >= playlistRows.length) return
        var row = playlistRows[index] || ({})
        if (row.rowType === "add") {
            showAdd("ADD PLAYLIST")
            return
        }

        currentPlaylistIndex = index
        currentPlaylist = row
        playlistInput = row.input || row.url || ""
        playlistTitle = row.title || "YOUTUBE PLAYLIST"
        loadPlaylist(playlistInput)
    }

    function loadPlaylist(input) {
        if (loadingPlaylist) return
        loadingPlaylist = true
        mode = "loading"
        statusText = "READING " + (playlistTitle || "PLAYLIST")
        youtubePlaylistBackend.load_playlist(input)
    }

    function refreshCurrentPlaylist() {
        if (!currentPlaylist || (!currentPlaylist.input && !currentPlaylist.url)) return
        loadingPlaylist = true
        mode = "loading"
        statusText = "REFRESHING " + (playlistTitle || "PLAYLIST")
        youtubePlaylistBackend.refresh_playlist(currentPlaylist.input || currentPlaylist.url)
    }

    function playIndex(index) {
        if (index < 0 || index >= videos.length) return
        currentVideoIndex = index
        videoList.currentIndex = index
        var item = videos[index] || ({})
        var title = item.title || "VIDEO"
        statusText = "LOADING " + title
        mode = "playing"
        stoppingPlayback = false
        var format = youtubePlaylistBackend.ytdl_format_for_quality(playbackQuality())
        mpvController.loadAndPlay(item.url || "", 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "", false, title, false, true, format)
    }

    function returnToVideoList() {
        mode = videos.length > 0 ? "list" : "message"
        if (videos.length > 0)
            videoList.currentIndex = currentVideoIndex
    }

    function pageVideoList(direction) {
        if (videos.length === 0) return
        var rowHeight = root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(videoList.height / rowHeight) - 1)
        var next = Math.max(0, Math.min(videoList.count - 1, videoList.currentIndex + direction * rows))
        videoList.currentIndex = next
        currentVideoIndex = next
        videoList.positionViewAtIndex(next, ListView.Contain)
    }

    Keys.onPressed: function(event) {
        if (mode === "library") {
            if (event.key === Qt.Key_Up) {
                libraryList.currentIndex = Math.max(0, libraryList.currentIndex - 1)
                currentPlaylistIndex = libraryList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                libraryList.currentIndex = Math.min(libraryList.count - 1, libraryList.currentIndex + 1)
                currentPlaylistIndex = libraryList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                selectPlaylist(libraryList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                showAdd("ADD PLAYLIST")
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (mode === "add") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "list") {
            if (event.key === Qt.Key_Up) {
                videoList.currentIndex = Math.max(0, videoList.currentIndex - 1)
                currentVideoIndex = videoList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                videoList.currentIndex = Math.min(videoList.count - 1, videoList.currentIndex + 1)
                currentVideoIndex = videoList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageVideoList(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageVideoList(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                playIndex(videoList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                refreshCurrentPlaylist()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "playing") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                stoppingPlayback = true
                mpvController.stop()
                returnToVideoList()
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                mpvController.sendKey("MENU")
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                mpvController.sendKey("LEFT")
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                mpvController.sendKey("RIGHT")
                event.accepted = true
            } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                mpvController.sendKey("SPACE")
                event.accepted = true
            }
            return
        }

        if (mode === "message") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                showAdd("ADD PLAYLIST")
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
        }
    }

    Component.onCompleted: loadPlaylistLibrary(0)

    Component.onDestruction: {
        if (mpvController.running)
            mpvController.stop()
    }

    Timer {
        id: addFocusTimer
        interval: 1
        repeat: false
        onTriggered: {
            playlistField.forceActiveFocus()
            playlistField.selectAll()
        }
    }

    Connections {
        target: youtubePlaylistBackend

        function onPlaylistLoaded(title, items) {
            loadingPlaylist = false
            playlistTitle = title || playlistTitle || "YOUTUBE PLAYLIST"
            updateCurrentPlaylistTitle(playlistTitle)
            videos = items || []
            if (videos.length === 0) {
                mode = "message"
                statusText = "PLAYLIST HAS NO VIDEOS"
                return
            }
            mode = "list"
            currentVideoIndex = Math.min(currentVideoIndex, videos.length - 1)
            videoList.currentIndex = currentVideoIndex
        }

        function onErrorOccurred(message) {
            loadingPlaylist = false
            mode = "message"
            statusText = message || "YOUTUBE PLAYLIST FAILED"
        }
    }

    Connections {
        target: mpvController

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (mode !== "playing") return
            if (autoplayNext() && currentVideoIndex + 1 < videos.length) {
                playIndex(currentVideoIndex + 1)
                return
            }
            returnToVideoList()
        }

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (stoppingPlayback) {
                stoppingPlayback = false
                return
            }
            if (mode === "playing")
                returnToVideoList()
        }

        function onPlaybackFailed() {
            mode = "message"
            statusText = "YOUTUBE PLAYBACK FAILED"
        }
    }

    StaticBackground {
        anchors.fill: parent
        visible: root.staticBackgroundEnabled && mode !== "playing"
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: root.staticBackgroundEnabled && mode !== "playing" ? "transparent" : root.surfaceColor
    }

    AppBar {
        iconSource: moduleIcon
        title: moduleName
        subtitle: mode === "list" ? playlistTitle : (mode === "library" ? "PLAYLISTS" : "PUBLIC")
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Text {
        visible: mode === "loading" || mode === "message" || mode === "playing"
        text: mode === "playing" ? statusText : statusText
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.78
        wrapMode: Text.WordWrap
        font.pixelSize: root.sh * 0.045
    }

    Column {
        visible: mode === "add"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.sw * 0.115625
        anchors.rightMargin: root.sw * 0.115625
        spacing: root.sh * 0.025

        Text {
            text: statusText
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
                id: playlistField
                anchors.fill: parent
                anchors.leftMargin: root.sw * 0.009375
                anchors.rightMargin: root.sw * 0.009375
                verticalAlignment: TextInput.AlignVCenter
                color: root.surfaceColor
                selectedTextColor: root.surfaceColor
                selectionColor: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.045
                clip: true

                Keys.onReturnPressed: mixRoot.addPlaylist()
                Keys.onEnterPressed: mixRoot.addPlaylist()
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        mixRoot.loadPlaylistLibrary(mixRoot.currentPlaylistIndex)
                        event.accepted = true
                    }
                }
            }
        }

        Text {
            text: "PASTE URL OR JUST THE LIST CODE"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.03
        }
    }

    ListView {
        id: libraryList
        visible: mode === "library"
        model: playlistRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentPlaylistIndex = currentIndex

        delegate: Item {
            width: libraryList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: playlistText
                color: root.accentColor
                visible: libraryList.currentIndex === index
            }

            Text {
                id: playlistText
                text: modelData.title || "PLAYLIST"
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
        id: videoList
        visible: mode === "list"
        model: videos
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible

        delegate: Item {
            width: videoList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: videoText
                color: root.accentColor
                visible: videoList.currentIndex === index
            }

            Text {
                id: videoText
                text: (index + 1 < 10 ? "0" : "") + (index + 1) + "  " + (modelData.title || "VIDEO")
                color: videoList.currentIndex === index ? root.surfaceColor : root.primaryColor
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
}
