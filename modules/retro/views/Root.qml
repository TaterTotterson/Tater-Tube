import QtQuick
import Components

FocusScope {
    id: retroRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.retro"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "GAME CENTER"
    property string moduleIcon: _moduleInfo.icon || ""

    property string mode: "loading"
    property string statusText: "LOADING GAME CENTER..."
    property var systems: []
    property var games: []
    property var gameRows: []
    property int currentSystemIndex: 0
    property int currentGameIndex: 0
    property int setupRow: 0
    property bool mounting: false
    property string messageReturnMode: ""
    property string selectedSystemId: ""
    property string selectedSystemTitle: ""
    property string currentGameFolder: ""
    property bool gameSessionActive: false
    property bool scanningLibrary: false
    property int loadingFrame: 0
    property int scanMessageIndex: 0
    readonly property var scanMessages: [
        "CHECKING RETRONAS...",
        "READING GAME FOLDERS...",
        "VERIFYING GAME PORTS...",
        "BUILDING GAME LIST..."
    ]

    focus: true

    onGameSessionActiveChanged: {
        if (menuSoundPlayer)
            menuSoundPlayer.setContextActive("qml:retro-game", gameSessionActive)
    }

    function settingValue(key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "") return fallback
        return value
    }

    function truthySetting(key, fallback) {
        var value = settingValue(key, fallback)
        return value === true || value === "ON" || value === "on" || value === "true" || value === "1"
    }

    function keepDirectoryStructure() {
        return truthySetting("keep_directory_structure", false)
    }

    function normalizedFolder(folder) {
        var value = ((folder || "") + "").replace(/\\/g, "/").trim()
        while (value.charAt(0) === "/")
            value = value.substring(1)
        while (value.length > 0 && value.charAt(value.length - 1) === "/")
            value = value.substring(0, value.length - 1)
        return value === "." ? "" : value
    }

    function childFolderFor(baseFolder, gameFolder) {
        var base = normalizedFolder(baseFolder)
        var folder = normalizedFolder(gameFolder)
        if (folder === "" || folder === base)
            return ""

        var rest = folder
        if (base !== "") {
            var prefix = base + "/"
            if (folder.indexOf(prefix) !== 0)
                return ""
            rest = folder.substring(prefix.length)
        }

        var slash = rest.indexOf("/")
        return slash < 0 ? rest : rest.substring(0, slash)
    }

    function parentFolder(folder) {
        var value = normalizedFolder(folder)
        var slash = value.lastIndexOf("/")
        return slash < 0 ? "" : value.substring(0, slash)
    }

    function compareRows(left, right) {
        var a = ((left.title || "") + "").toUpperCase()
        var b = ((right.title || "") + "").toUpperCase()
        if (a < b) return -1
        if (a > b) return 1
        return 0
    }

    function buildGameRows() {
        var rows = []
        if (!keepDirectoryStructure()) {
            for (var i = 0; i < games.length; i++) {
                var flatGame = Object.assign({}, games[i])
                flatGame.rowType = "game"
                flatGame.gameIndex = i
                rows.push(flatGame)
            }
            gameRows = rows
            return
        }

        var base = normalizedFolder(currentGameFolder)
        var folderSeen = ({})
        var folders = []
        var directGames = []

        for (var j = 0; j < games.length; j++) {
            var game = Object.assign({}, games[j])
            game.rowType = "game"
            game.gameIndex = j

            var folder = normalizedFolder(game.folder)
            if (folder === base) {
                directGames.push(game)
                continue
            }

            var child = childFolderFor(base, folder)
            if (child !== "" && folderSeen[child] !== true) {
                folderSeen[child] = true
                folders.push({
                    rowType: "folder",
                    title: child + "/",
                    folderPath: base === "" ? child : base + "/" + child
                })
            }
        }

        folders.sort(compareRows)
        directGames.sort(compareRows)
        gameRows = folders.concat(directGames)
    }

    function setGameRowIndex(index) {
        var next = Math.max(0, Math.min(gameList.count - 1, index))
        gameList.currentIndex = next
        currentGameIndex = next
    }

    function focusSetupRow() {
        if (setupRow === 0) hostField.forceInputFocus()
        else if (setupRow === 1) shareField.forceInputFocus()
        else if (setupRow === 2) pathField.forceInputFocus()
        else if (setupRow === 3) userField.forceInputFocus()
        else if (setupRow === 4) passwordField.forceInputFocus()
        else connectButton.forceActiveFocus()
    }

    function setupPrevious() {
        if (setupRow > 0) {
            setupRow--
            focusSetupRow()
        }
    }

    function setupNext() {
        if (setupRow < 5) {
            setupRow++
            focusSetupRow()
        }
    }

    function showSetup(message) {
        var status = retroBackend.get_setup_status()
        hostField.text = status.host || "retronas.local"
        shareField.text = status.share || "mister"
        pathField.text = status.remotePath || "games"
        userField.text = status.username || ""
        passwordField.text = settingValue("retronas_password", "")
        statusText = message || "ENTER RETRONAS INFO"
        mounting = false
        mode = "setup"
        setupFocusTimer.restart()
    }

    function loadSystems() {
        mode = "loading"
        scanningLibrary = true
        scanMessageIndex = 0
        statusText = "SCANNING GAME LIBRARY"
        retroBackend.load_systems()
    }

    function refresh() {
        var status = retroBackend.get_setup_status()
        if (!status.retroarchAvailable && !status.portsAvailable) {
            mode = "message"
            statusText = "NO GAME RUNTIME IS AVAILABLE"
            return
        }
        if (!status.gamesRootExists && !status.portsReady) {
            showSetup("ENTER RETRONAS INFO")
            return
        }
        loadSystems()
    }

    function saveSetup() {
        if (mounting) return
        var host = (hostField.text || "").trim()
        var share = (shareField.text || "").trim()
        var remotePath = (pathField.text || "").trim()
        var username = (userField.text || "").trim()
        var password = passwordField.text || ""

        if (host === "") {
            statusText = "ENTER RETRONAS ADDRESS"
            setupRow = 0
            focusSetupRow()
            return
        }
        if (share === "") share = "mister"
        if (remotePath === "") remotePath = "games"

        appCore.save_setting(moduleId, "retronas_host", host)
        appCore.save_setting(moduleId, "retronas_share", share)
        appCore.save_setting(moduleId, "retronas_path", remotePath)
        appCore.save_setting(moduleId, "retronas_username", username)
        appCore.save_setting(moduleId, "retronas_password", password)

        mounting = true
        scanningLibrary = false
        statusText = "MOUNTING RETRONAS..."
        retroBackend.mount_retronas(host, share, remotePath, username, password)
    }

    function selectSystem(index) {
        if (index < 0 || index >= systems.length) return
        messageReturnMode = "systems"
        currentSystemIndex = index
        systemList.currentIndex = index
        var system = systems[index] || ({})
        selectedSystemId = system.id || ""
        selectedSystemTitle = system.label || "RETRO"
        currentGameFolder = ""
        mode = "loading"
        scanningLibrary = false
        statusText = "LOADING " + selectedSystemTitle
        retroBackend.load_games(selectedSystemId)
    }

    function launchSelectedGame() {
        var index = gameList.currentIndex
        if (index < 0 || index >= gameRows.length) return
        var row = gameRows[index] || ({})
        if (row.rowType === "folder") {
            currentGameFolder = row.folderPath || ""
            buildGameRows()
            setGameRowIndex(0)
            return
        }
        if (row.rowType !== "game") return

        currentGameIndex = index
        messageReturnMode = "games"
        var title = row.title || "GAME"
        statusText = "LOADING " + title
        mode = "loading"
        scanningLibrary = false
        gameSessionActive = true
        if (row.portId)
            retroBackend.launch_port(row.portId, row.romPath || "")
        else
            retroBackend.launch_game(selectedSystemId, row.path || "")
    }

    function pageGameList(direction) {
        if (gameRows.length === 0) return
        var rowHeight = root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(gameList.height / rowHeight) - 1)
        var next = Math.max(0, Math.min(gameList.count - 1, gameList.currentIndex + direction * rows))
        setGameRowIndex(next)
        gameList.positionViewAtIndex(next, ListView.Contain)
    }

    function returnFromMessage() {
        var targetMode = messageReturnMode
        messageReturnMode = ""
        if (targetMode === "games" && gameRows.length > 0) {
            mode = "games"
            setGameRowIndex(currentGameIndex)
            return
        }
        if (targetMode === "systems" && systems.length > 0) {
            mode = "systems"
            systemList.currentIndex = Math.max(
                        0, Math.min(currentSystemIndex, systems.length - 1))
            return
        }
        if (gameRows.length > 0) {
            mode = "games"
            setGameRowIndex(currentGameIndex)
            return
        }
        if (systems.length > 0) {
            mode = "systems"
            systemList.currentIndex = Math.max(
                        0, Math.min(currentSystemIndex, systems.length - 1))
            return
        }
        goBack()
    }

    Keys.onPressed: function(event) {
        if (mode === "setup") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (mode === "systems") {
            if (event.key === Qt.Key_Up) {
                systemList.currentIndex = Math.max(0, systemList.currentIndex - 1)
                currentSystemIndex = systemList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                systemList.currentIndex = Math.min(systemList.count - 1, systemList.currentIndex + 1)
                currentSystemIndex = systemList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                selectSystem(systemList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (mode === "games") {
            if (event.key === Qt.Key_Up) {
                setGameRowIndex(gameList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                setGameRowIndex(gameList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp) {
                pageGameList(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown) {
                pageGameList(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                if (keepDirectoryStructure() && normalizedFolder(currentGameFolder) !== "") {
                    currentGameFolder = parentFolder(currentGameFolder)
                    buildGameRows()
                    setGameRowIndex(0)
                } else {
                    mode = "systems"
                    systemList.currentIndex = currentSystemIndex
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                launchSelectedGame()
                event.accepted = true
            }
            return
        }

        if (mode === "message") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                refresh()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                returnFromMessage()
                event.accepted = true
            }
        }
    }

    Component.onCompleted: refresh()

    Component.onDestruction: {
        if (menuSoundPlayer)
            menuSoundPlayer.setContextActive("qml:retro-game", false)
        if (retroBackend.running)
            retroBackend.stop_game()
    }

    Timer {
        id: setupFocusTimer
        interval: 1
        repeat: false
        onTriggered: focusSetupRow()
    }

    Timer {
        interval: 90
        repeat: true
        running: mode === "loading"
        onTriggered: loadingFrame = (loadingFrame + 1) % 120
    }

    Timer {
        interval: 1150
        repeat: true
        running: mode === "loading" && scanningLibrary
        onTriggered: scanMessageIndex = (scanMessageIndex + 1) % scanMessages.length
    }

    Connections {
        target: retroBackend

        function onMountFinished(ok, message) {
            mounting = false
            if (!ok) {
                scanningLibrary = false
                statusText = message || "RETRONAS MOUNT FAILED"
                mode = "setup"
                setupFocusTimer.restart()
                return
            }
            loadSystems()
        }

        function onSystemsLoaded(items) {
            scanningLibrary = false
            systems = items || []
            if (systems.length === 0) {
                mode = "message"
                statusText = "NO SUPPORTED ROM FOLDERS"
                return
            }
            mode = "systems"
            currentSystemIndex = Math.min(currentSystemIndex, systems.length - 1)
            systemList.currentIndex = currentSystemIndex
        }

        function onGamesLoaded(items) {
            scanningLibrary = false
            games = items || []
            currentGameFolder = ""
            buildGameRows()
            if (gameRows.length === 0) {
                mode = "message"
                statusText = "NO ROMS IN " + selectedSystemTitle
                return
            }
            mode = "games"
            currentGameIndex = 0
            setGameRowIndex(0)
        }

        function onGameStarted(title) {
            scanningLibrary = false
            statusText = "PLAYING " + (title || "GAME")
            mode = "playing"
        }

        function onGameFinished() {
            gameSessionActive = false
            if (mode === "playing" || mode === "loading")
                mode = gameRows.length > 0 ? "games" : "systems"
        }

        function onErrorOccurred(message) {
            gameSessionActive = false
            scanningLibrary = false
            mode = "message"
            statusText = message || "RETRO PLAYBACK FAILED"
        }
    }

    Connections {
        target: appCore
        function onModuleSettingChanged(mid, key, value) {
            if (mid !== retroRoot.moduleId)
                return
            if (key !== "retronas_host" && key !== "retronas_share"
                    && key !== "retronas_path" && key !== "retronas_username"
                    && key !== "retronas_password" && key !== "local_path"
                    && key !== "ports_path")
                return
            if (mode === "setup" || mode === "message")
                refresh()
        }
    }

    StaticBackground {
        anchors.fill: parent
        themeName: root.currentTheme
        visible: root.staticBackgroundEnabled && mode !== "playing"
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: root.staticBackgroundEnabled && mode !== "playing" ? "transparent" : root.surfaceColor
    }

    AppBar {
        iconSource: moduleIcon
        iconHeight: root.sh * 0.075
        title: moduleName
        subtitle: mode === "games" ? selectedSystemTitle : "MISTER"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Item {
        id: loadingScreen
        visible: mode === "loading"
        anchors.centerIn: parent
        width: root.sw * 0.72
        height: root.sh * 0.42

        Item {
            id: scanSpinner
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            width: root.sh * 0.15
            height: width

            Repeater {
                model: 12

                Rectangle {
                    required property int index
                    readonly property real markerAngle: index * Math.PI / 6
                    readonly property int markerAge: (index - (loadingFrame % 12) + 12) % 12
                    width: root.sh * 0.012
                    height: root.sh * 0.035
                    radius: width / 2
                    x: scanSpinner.width / 2
                       + Math.sin(markerAngle) * root.sh * 0.055 - width / 2
                    y: scanSpinner.height / 2
                       - Math.cos(markerAngle) * root.sh * 0.055 - height / 2
                    rotation: index * 30
                    color: markerAge < 3 ? root.accentColor : root.primaryColor
                    opacity: markerAge === 0 ? 1.0
                             : markerAge === 1 ? 0.72
                             : markerAge === 2 ? 0.45 : 0.18
                }
            }

            Rectangle {
                anchors.centerIn: parent
                width: root.sh * 0.047
                height: width
                radius: width / 2
                color: "transparent"
                border.width: Math.max(2, root.sh * 0.004)
                border.color: root.secondaryColor

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.32
                    height: width
                    radius: width / 2
                    color: root.accentColor
                }
            }
        }

        Text {
            anchors.top: scanSpinner.bottom
            anchors.topMargin: root.sh * 0.025
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: statusText
            color: root.primaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.042
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }

        Text {
            anchors.bottom: scanTrack.top
            anchors.bottomMargin: root.sh * 0.018
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: scanningLibrary ? scanMessages[scanMessageIndex] : "PLEASE WAIT..."
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.026
            horizontalAlignment: Text.AlignHCenter
        }

        Rectangle {
            id: scanTrack
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width * 0.62
            height: Math.max(4, root.sh * 0.008)
            radius: height / 2
            color: root.secondaryColor
            opacity: 0.42
            clip: true

            Rectangle {
                width: scanTrack.width * 0.28
                height: parent.height
                radius: height / 2
                x: ((loadingFrame % 40) / 39) * (scanTrack.width + width) - width
                color: root.accentColor
                opacity: 1.0
            }
        }
    }

    Text {
        visible: mode === "message" || mode === "playing"
        text: mode === "playing" ? "GAME LOADING" : statusText
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
        id: setupForm
        visible: mode === "setup"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.22
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        spacing: root.sh * 0.018

        Text {
            text: statusText
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.031
            width: setupForm.width
            elide: Text.ElideRight
        }

        SetupField {
            id: hostField
            label: "RETRONAS ADDRESS"
            selected: setupRow === 0
        }
        SetupField {
            id: shareField
            label: "SHARE"
            selected: setupRow === 1
        }
        SetupField {
            id: pathField
            label: "MISTER ROM PATH"
            selected: setupRow === 2
        }
        SetupField {
            id: userField
            label: "USERNAME"
            selected: setupRow === 3
        }
        SetupField {
            id: passwordField
            label: "PASSWORD"
            selected: setupRow === 4
            password: true
        }

        Rectangle {
            id: connectButton
            width: setupForm.width
            height: root.sh * 0.0583333
            color: setupRow === 5 ? root.accentColor : "transparent"
            focus: setupRow === 5

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.009375
                text: mounting ? "MOUNTING..." : "CONNECT"
                color: setupRow === 5 ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.05
            }

            Keys.onUpPressed: setupPrevious()
            Keys.onDownPressed: setupNext()
            Keys.onReturnPressed: saveSetup()
            Keys.onEnterPressed: saveSetup()
        }
    }

    ListView {
        id: systemList
        visible: mode === "systems"
        model: systems
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentSystemIndex = currentIndex

        delegate: Item {
            width: systemList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: systemText
                color: root.accentColor
                visible: systemList.currentIndex === index
            }

            Text {
                id: systemText
                text: (modelData.label || "SYSTEM") + "  " + (modelData.gameCount || 0)
                color: systemList.currentIndex === index ? root.surfaceColor : root.primaryColor
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
        id: gameList
        visible: mode === "games"
        model: gameRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentGameIndex = currentIndex

        delegate: Item {
            width: gameList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: gameText
                color: root.accentColor
                visible: gameList.currentIndex === index
            }

            Text {
                id: gameText
                text: (modelData.title || "GAME")
                      + (modelData.status ? "  [" + modelData.status + "]" : "")
                color: gameList.currentIndex === index ? root.surfaceColor : root.primaryColor
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

    component SetupField: Item {
        id: setupFieldControl
        property alias text: fieldInput.text
        property string label: ""
        property bool selected: false
        property bool password: false

        function forceInputFocus() {
            fieldInput.forceActiveFocus()
        }

        function openInputKeyboard() {
            root.openTaterKeyboard(
                        fieldInput, label, password,
                        function() { setupNext() },
                        function() { setupFieldControl.forceInputFocus() })
        }

        width: setupForm.width
        height: root.sh * 0.076

        Rectangle {
            anchors.fill: parent
            color: selected ? root.accentColor : "transparent"
        }

        Text {
            id: fieldLabel
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: root.sw * 0.009375
            text: label
            color: selected ? root.surfaceColor : root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.026
        }

        TextInput {
            id: fieldInput
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: fieldLabel.bottom
            anchors.leftMargin: root.sw * 0.009375
            anchors.rightMargin: root.sw * 0.009375
            height: root.sh * 0.044
            focus: selected
            echoMode: password ? TextInput.Password : TextInput.Normal
            color: selected ? root.surfaceColor : root.primaryColor
            selectedTextColor: root.surfaceColor
            selectionColor: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.038
            clip: true

            Keys.onUpPressed: setupPrevious()
            Keys.onDownPressed: setupNext()
            Keys.onReturnPressed: setupFieldControl.openInputKeyboard()
            Keys.onEnterPressed: setupFieldControl.openInputKeyboard()
            Keys.onSpacePressed: setupFieldControl.openInputKeyboard()
        }

        MouseArea {
            anchors.fill: parent
            onClicked: setupFieldControl.openInputKeyboard()
        }
    }
}
