import QtQuick
import Components

FocusScope { 
    id: appRoot

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var navParams: ({})
    property var navListState: ({})
    property bool showModuleMascots: true
    property var mascotByModuleId: ({
        "com.240mp.ota": "../assets/images/mascots/over-the-air.png",
        "com.240mp.emby_jellyfin": "../assets/images/mascots/video-on-demand.png",
        "com.240mp.youtube_playlist": "../assets/images/mascots/public-access.png",
        "com.240mp.usenet": "../assets/images/mascots/usenet.png",
        "com.240mp.audio_tapes": "../assets/images/mascots/tape-deck.png",
        "com.240mp.retro": "../assets/images/mascots/game-center.png",
        "com.240mp.local_files": "../assets/images/mascots/local-files.png",
        "com.240mp.moonlight": "../assets/images/mascots/pc-link.png"
    })

    function selectedModule() {
        if (!menuList.model || menuList.currentIndex < 0 || menuList.currentIndex >= menuList.count)
            return ({})
        return menuList.model[menuList.currentIndex] || ({})
    }

    function selectedMascotSource() {
        if (!showModuleMascots)
            return ""
        var moduleId = selectedModule().id || ""
        return mascotByModuleId[moduleId] || ""
    }

    function loadMascotSetting() {
        var value = appCore.get_setting("", "show_module_mascots")
        if (value === undefined || value === null || value === "") {
            showModuleMascots = true
            return
        }
        if (value === true || value === false) {
            showModuleMascots = value
            return
        }
        var normalized = ("" + value).toUpperCase()
        showModuleMascots = !(normalized === "OFF" || normalized === "FALSE" || normalized === "0" || normalized === "NO")
    }

    Component.onCompleted: {
        loadMascotSetting()
        appCore.scan_for_modules()
    }

    Connections {
        target: appCore;
        function onAppSettingChanged(key, value) {
            if (key === "show_module_mascots")
                appRoot.loadMascotSetting()
        }
        function onModuleSettingChanged(mid, key, value) {
            if (key === "enabled")
                appCore.scan_for_modules()
        }
        function onModulesLoaded(moduleData) {
            menuList.model = moduleData
            if (moduleData.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                menuList.currentIndex = Math.min(restore, moduleData.length - 1)
                menuList.positionViewAtIndex(menuList.currentIndex, ListView.Contain)
            }
        }
    }

    // Header
    AppBar {
        title: root.vcrClockText
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Empty state
    Column {
        anchors.centerIn: parent
        spacing: root.sh * 0.0333333 //16
        visible: menuList.count === 0
        Text {
            text: "No modules enabled"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.05 //24
        }
        Text {
            text: "Please enable one in settings"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.0333333 //16
        }
    }

    Image {
        id: moduleMascot
        source: appRoot.selectedMascotSource()
        visible: source !== ""
        anchors.verticalCenter: menuList.verticalCenter
        anchors.right: parent.right
        anchors.rightMargin: root.sw * 0.0625
        width: root.sw * 0.32
        height: root.sh * 0.55
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        opacity: 0.96
    }

    ListView {
        id: menuList;
        model: [];
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true;
        focus: true;

        delegate: Item {
            width: menuList.width;
            height: root.sh * 0.0583333 //28

            Item {
                id: textClipContainer;
                width: Math.min(rowText.implicitWidth, menuList.width);
                height: parent.height;
                clip: true;

                Rectangle {
                    color: root.accentColor;
                    anchors.fill: rowText;
                    visible: menuList.currentIndex === index;
                }

                Text {
                    id: rowText;
                    text: modelData.name;
                    color: menuList.currentIndex === index ? root.surfaceColor : root.primaryColor;
                    font.family: root.globalFont;
                    font.capitalization: Font.AllUppercase;
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    topPadding: root.sh * 0.0041667 //2
                    leftPadding: root.sw * 0.009375 //6
                    rightPadding: root.sw * 0.009375 //6
                    bottomPadding: root.sh * 0.00625 //3
                    font.pixelSize: root.sh * 0.05 //24
                }

                SequentialAnimation {
                    id: marqueeAnim;
                    running: (menuList.currentIndex === index) && (rowText.implicitWidth > textClipContainer.width);
                    loops: Animation.Infinite;

                    onRunningChanged: {
                        if (!running) rowText.x = 0;
                    }

                    PauseAnimation { 
                        duration: 1500;
                    }
                    
                    NumberAnimation {
                        target: rowText;
                        property: "x";
                        to: textClipContainer.width - rowText.implicitWidth;
                        duration: Math.abs(to) * 20;
                    }

                    PauseAnimation { 
                        duration: 2000;
                    }

                    PropertyAction { 
                        target: rowText; 
                        property: "x"; 
                        value: 0;
                    }
                }
            }
        }

        Keys.onReturnPressed: {
            var selectedModulePath = menuList.model[menuList.currentIndex].entry_point
            console.log("Routing to: " + selectedModulePath)
            appRoot.navigateTo(selectedModulePath, {}, { currentIndex: menuList.currentIndex })
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                appRoot.navigateTo("views/Settings.qml", {}, { currentIndex: menuList.currentIndex })
                event.accepted = true
            }
        }
    }

}
