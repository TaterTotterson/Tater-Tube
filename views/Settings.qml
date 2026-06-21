import QtQuick
import Components

FocusScope {
    id: settingsRoot

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var navParams: ({})
    property var navListState: ({})

    property var appSettings: ({})
    property var installedModules: []

    // Flat model: mix of section headers and rows
    property var settingsItems: []

    property bool updateOverlayVisible: false
    property bool updateBusy: false
    property int updateChoiceIndex: 0
    property string updateMessage: ""
    property string updateDetail: ""
    property var updateOptions: []
    property var sshInfo: ({})

    function hourOptions() {
        var opts = []
        for (var i = 1; i <= 12; i++) opts.push("" + i)
        return opts
    }

    function minuteOptions() {
        var opts = []
        for (var i = 0; i < 60; i++) opts.push(i < 10 ? "0" + i : "" + i)
        return opts
    }

    function buildModel() {
        var cfg = appCore.get_settings()
        appSettings = cfg.app || {}
        installedModules = appCore.get_installed_modules()

        var items = []

        // APPLICATION section
        var colorOpts = ["Off Air","Video 1","Late Night","Synthwave","Terminal","T-120","Amber","Kinescope"]
        var custom = appCore.getCustomColorScheme()
        if (Object.keys(custom).length === 5) colorOpts.push("Custom")
        items.push({
            type: "list_single",
            key: "color_scheme",
            label: "Color Scheme",
            options: colorOpts,
            value: appSettings["color_scheme"] || "Off Air",
            moduleId: ""
        })
        if ((appSettings["color_scheme"] || "Off Air") === "Off Air") {
            items.push({
                type: "list_single",
                key: "off_air_highlight_color",
                label: "Highlight Color",
                options: ["Orange","Cyan","Green","Magenta","Red","Blue","Amber","White"],
                value: appSettings["off_air_highlight_color"] || "Orange",
                moduleId: ""
            })
        }
        items.push({
            type: "list_single",
            key: "sleep_timer_mode",
            label: "Sleep Timer",
            options: ["Off","30 Min","60 Min","90 Min"],
            value: root.sleepTimerMode || "Off",
            moduleId: ""
        })

        var clockParts = root.vcrClockParts()
        items.push({ type: "section", label: "Clock:" })
        items.push({
            type: "clock_part",
            part: "hour",
            label: "Clock Hour",
            options: hourOptions(),
            value: "" + clockParts.hour
        })
        items.push({
            type: "clock_part",
            part: "minute",
            label: "Clock Minute",
            options: minuteOptions(),
            value: clockParts.minute < 10 ? "0" + clockParts.minute : "" + clockParts.minute
        })
        items.push({
            type: "clock_part",
            part: "period",
            label: "Clock AM/PM",
            options: ["AM","PM"],
            value: clockParts.period
        })

        // MODULES section — only show modules with has_settings
        var hasModuleSettings = false
        for (var i = 0; i < installedModules.length; i++) {
            if (installedModules[i].has_settings) { hasModuleSettings = true; break }
        }

        if (hasModuleSettings) {
            items.push({ type: "section", label: "Modules:" })
            for (var j = 0; j < installedModules.length; j++) {
                var m = installedModules[j]
                if (m.has_settings) {
                    items.push({ type: "submenu", label: m.name, moduleId: m.id })
                }
            }
        }

        // SYSTEM section
        var ssh = settingsRoot.refreshSshInfo()
        items.push({ type: "section", label: "System:" })
        items.push({
            type: "ssh_toggle",
            label: "SSH Access",
            value: settingsRoot.sshRowValue(ssh),
            available: !!ssh.available,
            enabled: !!ssh.enabled
        })
        items.push({ type: "action", action: "check_updates", label: "Check For Updates", value: root.appVersion })

        settingsItems = items

        // Restore saved position, or default to first selectable row
        if (navListState.currentIndex !== undefined) {
            settingsList.currentIndex = Math.min(navListState.currentIndex, items.length - 1)
        } else {
            for (var k = 0; k < items.length; k++) {
                if (items[k].type !== "section") {
                    settingsList.currentIndex = k
                    break
                }
            }
        }
        settingsList.positionViewAtIndex(settingsList.currentIndex, ListView.Contain)
    }

    function sshRowValue(info) {
        if (!info || !info.available) return "N/A"
        return info.enabled ? "On" : "Off"
    }

    function refreshSshInfo() {
        sshInfo = appCore.getSshInfo()
        return sshInfo
    }

    function replaceSettingsRow(rowIndex, values) {
        var updated = settingsItems.slice()
        updated[rowIndex] = Object.assign({}, updated[rowIndex], values)
        var savedIndex = settingsList.currentIndex
        settingsItems = updated
        settingsList.currentIndex = savedIndex
    }

    function setSshEnabled(rowIndex, enabled) {
        var row = settingsItems[rowIndex]
        if (!row || !row.available) return

        replaceSettingsRow(rowIndex, { value: "..." })
        var result = appCore.setSshEnabled(enabled)
        sshInfo = result
        replaceSettingsRow(rowIndex, {
            value: settingsRoot.sshRowValue(result),
            available: !!result.available,
            enabled: !!result.enabled
        })
    }

    function setListSingleValue(rowIndex, row, newVal) {
        if (row.type === "clock_part") {
            setClockPartValue(rowIndex, row, newVal)
            return
        }

        var updated = settingsItems.slice()
        updated[rowIndex] = Object.assign({}, row, { value: newVal })
        var savedIndex = rowIndex
        settingsItems = updated
        settingsList.currentIndex = savedIndex
        if (row.moduleId === "" && row.key === "sleep_timer_mode")
            root.setSleepTimerMode(newVal)
        else
            appCore.save_setting(row.moduleId, row.key, newVal)

        if (row.moduleId === "" && row.key === "color_scheme") {
            buildModel()
            settingsList.currentIndex = 0
        }
    }

    function setClockPartValue(rowIndex, row, newVal) {
        var parts = root.vcrClockParts()
        var hour = row.part === "hour" ? parseInt(newVal) : parts.hour
        var minute = row.part === "minute" ? parseInt(newVal) : parts.minute
        var period = row.part === "period" ? newVal : parts.period
        root.setVcrClock(hour, minute, period)
        buildModel()
        settingsList.currentIndex = rowIndex
        settingsList.positionViewAtIndex(settingsList.currentIndex, ListView.Contain)
    }

    function firstSelectableAfter(idx) {
        for (var i = idx + 1; i < settingsItems.length; i++) {
            if (settingsItems[i].type !== "section") return i
        }
        return settingsList.currentIndex
    }

    function firstSelectableBefore(idx) {
        for (var i = idx - 1; i >= 0; i--) {
            if (settingsItems[i].type !== "section") return i
        }
        return settingsList.currentIndex
    }

    function beginUpdateCheck() {
        updateBusy = true
        updateChoiceIndex = 0
        updateMessage = "CHECKING FOR UPDATES..."
        updateDetail = "CURRENT " + root.appVersion
        updateOptions = []
        updateOverlayVisible = true
        appCore.checkForUpdates()
    }

    function handleUpdateCheckResult(result) {
        updateBusy = false
        var status = result.status || "error"
        var currentVersion = result.currentVersion || root.appVersion
        var latestVersion = result.latestVersion || ""
        updateMessage = result.message || "UPDATE CHECK FAILED."
        updateDetail = latestVersion.length > 0
            ? "CURRENT " + currentVersion + "  LATEST " + latestVersion
            : "CURRENT " + currentVersion

        if (status === "available" && result.canInstall) {
            updateOptions = [
                { label: "Install Update", action: "install" },
                { label: "Cancel", action: "cancel" }
            ]
        } else {
            if (status === "available" && !result.canInstall)
                updateMessage = updateMessage + " INSTALL FROM THE PI IMAGE."
            updateOptions = [{ label: "OK", action: "cancel" }]
        }
        updateChoiceIndex = 0
    }

    function handleUpdateInstallResult(result) {
        if ((result.status || "") === "started") {
            updateBusy = true
            updateMessage = result.message || "INSTALLING UPDATE. 240-MP WILL RESTART."
            updateDetail = "LEAVE POWER CONNECTED"
            updateOptions = []
        } else {
            updateBusy = false
            updateMessage = result.message || "COULD NOT START UPDATE."
            updateDetail = "CURRENT " + root.appVersion
            updateOptions = [{ label: "OK", action: "cancel" }]
            updateChoiceIndex = 0
        }
    }

    function closeUpdateOverlay() {
        updateOverlayVisible = false
        updateBusy = false
        updateOptions = []
        settingsList.forceActiveFocus()
    }

    Component.onCompleted: buildModel()

    Connections {
        target: appCore
        function onUpdateCheckFinished(result) {
            settingsRoot.handleUpdateCheckResult(result)
        }
        function onUpdateInstallFinished(result) {
            settingsRoot.handleUpdateInstallResult(result)
        }
    }

    // Header
    AppBar {
        iconSource: "../../assets/images/settings.svg"
        title: "Settings"
        subtitle: root.appVersion
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    ListView {
        id: settingsList
        model: settingsItems
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true
        focus: true

        Keys.onUpPressed: {
            var prev = settingsRoot.firstSelectableBefore(currentIndex)
            if (prev !== currentIndex) currentIndex = prev
        }
        Keys.onDownPressed: {
            var next = settingsRoot.firstSelectableAfter(currentIndex)
            if (next !== currentIndex) currentIndex = next
        }

        Keys.onLeftPressed: {
            var row = settingsItems[currentIndex]
            if (row && (row.type === "list_single" || row.type === "clock_part")) {
                var opts = row.options
                var idx = opts.indexOf(row.value)
                var newIdx = (idx - 1 + opts.length) % opts.length
                settingsRoot.setListSingleValue(currentIndex, row, opts[newIdx])
            } else if (row && row.type === "ssh_toggle") {
                settingsRoot.setSshEnabled(currentIndex, false)
            }
        }

        Keys.onRightPressed: {
            var row = settingsItems[currentIndex]
            if (row && (row.type === "list_single" || row.type === "clock_part")) {
                var opts = row.options
                var idx = opts.indexOf(row.value)
                var newIdx = (idx + 1) % opts.length
                settingsRoot.setListSingleValue(currentIndex, row, opts[newIdx])
            } else if (row && row.type === "ssh_toggle") {
                settingsRoot.setSshEnabled(currentIndex, true)
            }
        }

        Keys.onReturnPressed: {
            var row = settingsItems[currentIndex]
            if (row && row.type === "submenu") {
                settingsRoot.navigateTo("views/ModuleSettings.qml", { moduleId: row.moduleId }, { currentIndex: settingsList.currentIndex })
            } else if (row && row.type === "action" && row.action === "check_updates") {
                settingsRoot.beginUpdateCheck()
            } else if (row && row.type === "ssh_toggle") {
                settingsRoot.setSshEnabled(currentIndex, !row.enabled)
            }
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                settingsRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: settingsList.width
            height: root.sh * 0.0583333 //28

            // --- SECTION LABEL ---
            Text {
                visible: modelData.type == "section"
                text: modelData.label || ""
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                topPadding: root.sh * 0.0020833 //1
                leftPadding: root.sw * 0.009375 //6
                rightPadding: root.sw * 0.009375 //6
                font.pixelSize: root.sh * 0.0291667 //14
            }

            // --- SELECTABLE ROW ---
            Rectangle {
                visible: modelData.type !== "section"
                anchors.fill: parent
                color: settingsList.currentIndex === index ? root.accentColor : "transparent"

                // Label
                Text {
                    text: modelData.label || ""
                    color: settingsList.currentIndex === index ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    topPadding: root.sh * 0.0041667 //2
                    leftPadding: root.sw * 0.009375 //6
                    rightPadding: root.sw * 0.009375 //6
                    bottomPadding: root.sh * 0.00625 //3
                    font.pixelSize: root.sh * 0.05 //24
                }

                // Value / arrow indicator
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: root.sw * 0.009375 //6
                    spacing: root.sw * 0.00625 //4

                    Text {
                        visible: modelData.type === "list_single" || modelData.type === "clock_part" || (modelData.type === "ssh_toggle" && modelData.available === true)
                        text: "\u25C4"
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize: root.sh * 0.0375 //18
                    }
                    Text {
                        visible: modelData.type === "list_single" || modelData.type === "clock_part" || modelData.value !== undefined
                        text: modelData.value || ""
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        leftPadding: root.sw * 0.009375 //6
                        rightPadding: root.sw * 0.009375 //6
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize:root.sh * 0.05 //24
                    }
                    Text {
                        visible: modelData.type === "submenu" || modelData.type === "list_single" || modelData.type === "clock_part" || modelData.type === "action" || (modelData.type === "ssh_toggle" && modelData.available === true)
                        text: "\u25BA"
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize: root.sh * 0.0375 //18
                    }
                }
            }
        }
    }

    // --- UPDATE OVERLAY ---
    Rectangle {
        anchors.fill: parent
        color: root.staticBackgroundEnabled ? "transparent" : root.surfaceColor
        visible: updateOverlayVisible
        focus: updateOverlayVisible

        StaticBackground {
            anchors.fill: parent
            visible: root.staticBackgroundEnabled
            running: visible
        }

        Keys.onUpPressed: {
            if (updateOptions.length > 0) updateChoiceIndex = Math.max(0, updateChoiceIndex - 1)
        }
        Keys.onDownPressed: {
            if (updateOptions.length > 0) updateChoiceIndex = Math.min(updateOptions.length - 1, updateChoiceIndex + 1)
        }
        Keys.onReturnPressed: {
            if (updateOptions.length > 0) {
                var act = updateOptions[updateChoiceIndex].action
                if (act === "install") {
                    updateBusy = true
                    updateMessage = "STARTING UPDATE..."
                    updateDetail = "CURRENT " + root.appVersion
                    updateOptions = []
                    appCore.installUpdate()
                } else {
                    settingsRoot.closeUpdateOverlay()
                }
            }
        }
        Keys.onPressed: function(event) {
            if (!updateBusy && (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back)) {
                settingsRoot.closeUpdateOverlay()
                event.accepted = true
            }
        }

        Rectangle {
            color: root.staticBackgroundEnabled ? "transparent" : root.surfaceColor
            anchors.centerIn: parent
            width: root.sw * 0.76875 //492
            height: root.sh * 0.4166667 //200

            Column {
                id: updateDialogColumn
                anchors.fill: parent
                spacing: root.sh * 0.0270833 //13

                Text {
                    text: "SOFTWARE UPDATE"
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333 //16
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: updateMessage
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    width: updateDialogColumn.width
                    font.pixelSize: root.sh * 0.0416667 //20
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: updateDetail
                    color: root.tertiaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    width: updateDialogColumn.width
                    font.pixelSize: root.sh * 0.0333333 //16
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    visible: updateOptions.length > 0
                    Repeater {
                        model: updateOptions
                        delegate: Item {
                            width: updateDialogColumn.width
                            height: root.sh * 0.0583333 //28

                            Rectangle {
                                anchors.fill: updateOptionText
                                color: root.accentColor
                                visible: index === updateChoiceIndex
                            }

                            Text {
                                id: updateOptionText
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.label
                                color: index === updateChoiceIndex ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                topPadding: root.sh * 0.0041667 //2
                                leftPadding: root.sw * 0.009375 //6
                                rightPadding: root.sw * 0.009375 //6
                                bottomPadding: root.sh * 0.00625 //3
                                font.pixelSize: root.sh * 0.05 //24
                            }
                        }
                    }
                }

            }
        }
    }
}
