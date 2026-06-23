import QtQuick
import Components

FocusScope {
    id: pcRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.moonlight"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "PC LINK"
    property string moduleIcon: _moduleInfo.icon || ""

    property string mode: "loading"
    property string statusText: "LOADING PC LINK..."
    property string pairCode: "----"
    property var apps: []
    property int currentAppIndex: 0
    property int setupRow: 0
    property bool pairing: false
    property bool loadingApps: false

    focus: true

    function settingValue(key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "") return fallback
        return value
    }

    function showSetup(message) {
        var status = moonlightBackend.get_setup_status()
        hostField.text = status.host || ""
        statusText = message || "ENTER SUNSHINE HOST"
        pairing = false
        loadingApps = false
        pairCode = "----"
        setupRow = 0
        mode = "setup"
        setupFocusTimer.restart()
    }

    function focusSetupRow() {
        if (setupRow === 0) hostField.forceInputFocus()
        else pairButton.forceActiveFocus()
    }

    function setupPrevious() {
        if (setupRow > 0) {
            setupRow--
            focusSetupRow()
        }
    }

    function setupNext() {
        if (setupRow < 1) {
            setupRow++
            focusSetupRow()
        }
    }

    function refresh() {
        var status = moonlightBackend.get_setup_status()
        if (!status.moonlightAvailable) {
            mode = "message"
            statusText = "MOONLIGHT IS NOT INSTALLED"
            return
        }
        if (!status.host || status.host.length === 0) {
            showSetup("ENTER SUNSHINE HOST")
            return
        }
        loadApps()
    }

    function saveHostAndPair() {
        if (pairing) return
        var host = (hostField.text || "").trim()
        if (host === "") {
            statusText = "ENTER SUNSHINE HOST"
            setupRow = 0
            focusSetupRow()
            return
        }
        appCore.save_setting(moduleId, "sunshine_host", host)
        pairing = true
        pairCode = "----"
        statusText = "REQUESTING PAIR CODE"
        mode = "pairing"
        moonlightBackend.pair_host(host)
    }

    function loadApps() {
        loadingApps = true
        mode = "loading"
        statusText = "LOADING PC APPS..."
        moonlightBackend.load_apps()
    }

    function refreshApps() {
        loadingApps = true
        mode = "loading"
        statusText = "SCANNING SUNSHINE..."
        moonlightBackend.refresh_app_cache()
    }

    function launchSelectedApp() {
        var index = appList.currentIndex
        if (index < 0 || index >= apps.length) return
        currentAppIndex = index
        var item = apps[index] || ({})
        var name = item.name || item.title || ""
        if (name === "") return
        mode = "loading"
        statusText = "TUNING " + (item.title || name)
        moonlightBackend.launch_app(name)
    }

    function pageAppList(direction) {
        if (apps.length === 0) return
        var rowHeight = root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(appList.height / rowHeight) - 1)
        var next = Math.max(0, Math.min(appList.count - 1, appList.currentIndex + direction * rows))
        appList.currentIndex = next
        currentAppIndex = next
        appList.positionViewAtIndex(next, ListView.Contain)
    }

    Keys.onPressed: function(event) {
        if (mode === "setup") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (mode === "pairing") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                moonlightBackend.cancel_pairing()
                showSetup("PAIRING CANCELLED")
                event.accepted = true
            }
            return
        }

        if (mode === "apps") {
            if (event.key === Qt.Key_Up) {
                appList.currentIndex = Math.max(0, appList.currentIndex - 1)
                currentAppIndex = appList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                appList.currentIndex = Math.min(appList.count - 1, appList.currentIndex + 1)
                currentAppIndex = appList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageAppList(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageAppList(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                launchSelectedApp()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (mode === "playing") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                moonlightBackend.stop_stream()
                event.accepted = true
            }
            return
        }

        if (mode === "message") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                refresh()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
        }
    }

    Component.onCompleted: refresh()

    Component.onDestruction: {
        moonlightBackend.cancel_pairing()
        if (moonlightBackend.running)
            moonlightBackend.stop_stream()
    }

    Timer {
        id: setupFocusTimer
        interval: 1
        repeat: false
        onTriggered: focusSetupRow()
    }

    Connections {
        target: moonlightBackend

        function onPairCodeReady(code) {
            pairCode = code || "----"
            statusText = "ENTER PIN IN SUNSHINE"
        }

        function onPairFinished(ok, message) {
            pairing = false
            if (!ok) {
                showSetup(message || "PAIRING FAILED")
                return
            }
            statusText = message || "SUNSHINE PAIRED"
            loadApps()
        }

        function onAppsLoaded(items) {
            loadingApps = false
            apps = items || []
            if (apps.length === 0) {
                mode = "message"
                statusText = "NO PC APPS FOUND"
                return
            }
            mode = "apps"
            currentAppIndex = Math.min(currentAppIndex, apps.length - 1)
            appList.currentIndex = currentAppIndex
        }

        function onStreamStarted(title) {
            statusText = "PLAYING " + (title || "PC")
            mode = "playing"
        }

        function onStreamFinished() {
            mode = apps.length > 0 ? "apps" : "message"
            if (mode === "message")
                statusText = "PC LINK CLOSED"
        }

        function onErrorOccurred(message) {
            loadingApps = false
            mode = "message"
            statusText = message || "PC LINK FAILED"
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
        subtitle: mode === "apps" ? (settingValue("sunshine_host", "SUNSHINE")) : "SUNSHINE"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Text {
        visible: mode === "loading" || mode === "message" || mode === "playing"
        text: mode === "playing" ? "PC LINK ACTIVE" : statusText
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
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        spacing: root.sh * 0.025

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
            label: "SUNSHINE HOST"
            selected: setupRow === 0
        }

        Rectangle {
            id: pairButton
            width: setupForm.width
            height: root.sh * 0.0583333
            color: setupRow === 1 ? root.accentColor : "transparent"
            focus: setupRow === 1

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.009375
                text: pairing ? "PAIRING..." : "PAIR SUNSHINE"
                color: setupRow === 1 ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.05
            }

            Keys.onUpPressed: setupPrevious()
            Keys.onDownPressed: setupNext()
            Keys.onReturnPressed: saveHostAndPair()
            Keys.onEnterPressed: saveHostAndPair()
        }
    }

    Column {
        visible: mode === "pairing"
        anchors.centerIn: parent
        width: root.sw * 0.78
        spacing: root.sh * 0.035

        Text {
            text: statusText
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            font.pixelSize: root.sh * 0.0375
        }

        Rectangle {
            width: parent.width
            height: root.sh * 0.19
            color: "black"
            border.color: root.primaryColor
            border.width: 2

            Text {
                anchors.centerIn: parent
                text: pairCode
                color: root.accentColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.145
                font.capitalization: Font.AllUppercase
            }
        }

        Text {
            text: "OPEN SUNSHINE ON YOUR PC"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            font.pixelSize: root.sh * 0.0333333
        }
    }

    ListView {
        id: appList
        visible: mode === "apps"
        model: apps
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentAppIndex = currentIndex

        delegate: Item {
            width: appList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: appText
                color: root.accentColor
                visible: appList.currentIndex === index
            }

            Text {
                id: appText
                text: modelData.title || modelData.name || "PC APP"
                color: appList.currentIndex === index ? root.surfaceColor : root.primaryColor
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
        property alias text: fieldInput.text
        property string label: ""
        property bool selected: false

        function forceInputFocus() {
            fieldInput.forceActiveFocus()
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
            color: selected ? root.surfaceColor : root.primaryColor
            selectedTextColor: root.surfaceColor
            selectionColor: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.038
            clip: true

            Keys.onUpPressed: setupPrevious()
            Keys.onDownPressed: setupNext()
            Keys.onReturnPressed: setupNext()
            Keys.onEnterPressed: setupNext()
        }
    }
}
