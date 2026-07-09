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
    property var bluetoothInfo: ({})
    property var bluetoothDevices: []
    property var argonFanInfo: ({})
    property bool bluetoothScanning: false
    property bool bluetoothBusy: false
    property int bluetoothPendingIndex: -1
    property string bluetoothPendingMode: ""
    property string bluetoothStatusMessage: ""
    property string settingsMode: "main"
    property string activeSection: ""
    property int mainSettingsIndex: 0
    property var sectionSettingsIndexes: ({})

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
        var restoreSection = navListState.sectionKey || ""
        var restoreIndex = navListState.currentIndex !== undefined ? navListState.currentIndex : -1
        navListState = ({})

        if (restoreSection.length > 0) {
            buildSectionModel(restoreSection, restoreIndex)
            return
        }

        buildMainMenu(restoreIndex)
    }

    function refreshSettingsContext() {
        var cfg = appCore.get_settings()
        appSettings = cfg.app || {}
        installedModules = appCore.get_installed_modules()
    }

    function buildMainMenu(preferredIndex) {
        settingsMode = "main"
        activeSection = ""
        refreshSettingsContext()
        var items = []

        items.push({ type: "settings_category", label: "Appearance", sectionKey: "appearance" })
        items.push({ type: "settings_category", label: "Features", sectionKey: "features" })
        items.push({ type: "settings_category", label: "Gamepad", sectionKey: "bluetooth" })
        items.push({ type: "settings_category", label: "System", sectionKey: "system" })

        settingsItems = items
        selectSettingsIndex(preferredIndex >= 0 ? preferredIndex : mainSettingsIndex)
    }

    function sectionTitle(sectionKey) {
        if (sectionKey === "appearance") return "Appearance"
        if (sectionKey === "system") return "System"
        if (sectionKey === "features") return "Features"
        if (sectionKey === "bluetooth") return "Gamepad"
        return "Settings"
    }

    function buildSectionModel(sectionKey, preferredIndex) {
        settingsMode = "section"
        activeSection = sectionKey
        refreshSettingsContext()

        var items = []
        items.push({ type: "section", label: sectionTitle(sectionKey) + ":" })

        if (sectionKey === "appearance") {
            buildAppearanceItems(items)
        } else if (sectionKey === "system") {
            buildSystemItems(items)
        } else if (sectionKey === "features") {
            buildFeatureItems(items)
        } else if (sectionKey === "bluetooth") {
            buildBluetoothItems(items)
        }

        settingsItems = items
        var savedIndex = sectionSettingsIndexes[sectionKey]
        selectSettingsIndex(preferredIndex >= 0 ? preferredIndex : (savedIndex === undefined ? 0 : savedIndex))
    }

    function buildAppearanceItems(items) {
        var colorOpts = ["Off Air","Video 1","Late Night","Synthwave","Terminal","T-120","Amber","Kinescope"]
        var custom = appCore.getCustomColorScheme()
        if (Object.keys(custom).length === 5) colorOpts.push("Custom")
        var showMascots = appSettings["show_module_mascots"]
        if (showMascots === undefined || showMascots === null || showMascots === "")
            showMascots = true
        showMascots = showMascots === true || showMascots === "ON" || showMascots === "true" || showMascots === "1"
        items.push({
            type: "list_single",
            key: "color_scheme",
            label: "Color Scheme",
            options: colorOpts,
            value: appSettings["color_scheme"] || "Off Air",
            moduleId: ""
        })
        items.push({
            type: "toggle",
            key: "show_module_mascots",
            label: "Menu Mascots",
            value: showMascots ? "ON" : "OFF",
            enabled: showMascots,
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
    }

    function buildSystemItems(items) {
        items.push({
            type: "list_single",
            key: "sleep_timer_mode",
            label: "Sleep Timer",
            options: ["Off","30 Min","60 Min","90 Min"],
            value: root.sleepTimerMode || "Off",
            moduleId: ""
        })

        var clockParts = root.vcrClockParts()
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

        var ssh = settingsRoot.refreshSshInfo()
        items.push({
            type: "ssh_toggle",
            label: "SSH Access",
            value: settingsRoot.sshRowValue(ssh),
            available: !!ssh.available,
            enabled: !!ssh.enabled
        })

        var fan = settingsRoot.refreshArgonFanInfo()
        items.push({
            type: "argon_fan",
            label: "Argon Fan",
            value: settingsRoot.argonFanRowValue(fan),
            available: !!fan.available,
            options: ["AUTO","OFF","25%","50%","75%","100%"]
        })
        items.push({ type: "action", action: "check_updates", label: "Check For Updates", value: root.appVersion })
    }

    function buildFeatureItems(items) {
        // MODULES section — only show modules with has_settings
        var hasModuleSettings = false
        for (var i = 0; i < installedModules.length; i++) {
            if (installedModules[i].has_settings) { hasModuleSettings = true; break }
        }

        if (hasModuleSettings) {
            for (var j = 0; j < installedModules.length; j++) {
                var m = installedModules[j]
                if (m.has_settings) {
                    items.push({ type: "submenu", label: m.name, moduleId: m.id })
                }
            }
        } else {
            items.push({ type: "status", label: "No Feature Settings", value: "" })
        }
    }

    function buildBluetoothItems(items) {
        var bt = settingsRoot.refreshBluetoothInfo()
        var knownDevices = []
        var devices = bt.devices || []
        for (var d = 0; d < devices.length; d++) {
            var device = devices[d]
            if (device.connected || device.paired)
                knownDevices.push(device)
        }

        items.push({
            type: "bluetooth_toggle",
            label: "Gamepad",
            value: settingsRoot.bluetoothRowValue(bt),
            available: !!bt.available,
            enabled: !!bt.enabled,
            powered: !!bt.powered
        })
        if (bluetoothStatusMessage.length > 0)
            items.push({ type: "status", label: bluetoothStatusMessage, value: bluetoothBusy ? "..." : "" })
        items.push({ type: "section", label: "Paired Controllers:" })
        if (knownDevices.length === 0) {
            items.push({ type: "status", label: "No Paired Controllers", value: "" })
        } else {
            for (var k = 0; k < knownDevices.length; k++) {
                var known = knownDevices[k]
                items.push({
                    type: "bluetooth_known",
                    label: settingsRoot.bluetoothDeviceName(known),
                    value: settingsRoot.bluetoothActionValue(known),
                    address: known.address || "",
                    connected: !!known.connected,
                    paired: !!known.paired,
                    trusted: !!known.trusted
                })
                items.push({
                    type: "bluetooth_forget",
                    label: "Remove " + settingsRoot.bluetoothDeviceName(known),
                    value: "",
                    address: known.address || ""
                })
            }
        }
        items.push({
            type: "action",
            action: "scan_bluetooth",
            label: "Scan Controllers",
            value: (bluetoothScanning || bluetoothBusy) ? "..." : (bt.available ? "OK" : "N/A")
        })
        items.push({
            type: "action",
            action: "map_controller",
            label: "Map Controller",
            value: inputManager.gamepadConnected ? "READY" : "NO PAD"
        })
    }

    function sshRowValue(info) {
        if (!info || !info.available) return "N/A"
        return info.enabled ? "On" : "Off"
    }

    function refreshSshInfo() {
        sshInfo = appCore.getSshInfo()
        return sshInfo
    }

    function argonFanRowValue(info) {
        if (!info || !info.available) return "N/A"
        return info.display || "Auto"
    }

    function refreshArgonFanInfo() {
        argonFanInfo = appCore.getArgonFanInfo()
        return argonFanInfo
    }

    function bluetoothRowValue(info) {
        if (!info || !info.available) return "N/A"
        if (info.active && info.powered) return "On"
        return info.enabled ? "On" : "Off"
    }

    function refreshBluetoothInfo() {
        bluetoothInfo = appCore.getBluetoothInfo()
        return bluetoothInfo
    }

    function bluetoothDeviceName(device) {
        var name = (device && device.name) ? device.name : ((device && device.address) ? device.address : "Controller")
        name = ("" + name).trim()
        if (name.length > 18)
            return name.slice(0, 15) + "..."
        return name
    }

    function bluetoothActionValue(device) {
        if (!device) return ""
        if (device.connected) return "CONNECTED"
        if (device.paired) return "CONNECT"
        if (device.trusted) return "PAIR AGAIN"
        return "PAIR"
    }

    function isSelectableRow(row) {
        return row && row.type !== "section" && row.type !== "status"
    }

    function selectSettingsIndex(preferredIndex) {
        var idx = preferredIndex
        if (idx >= 0 && idx < settingsItems.length && isSelectableRow(settingsItems[idx])) {
            settingsList.currentIndex = idx
        } else {
            settingsList.currentIndex = settingsItems.length > 0 ? 0 : -1
            for (var i = 0; i < settingsItems.length; i++) {
                if (isSelectableRow(settingsItems[i])) {
                    settingsList.currentIndex = i
                    break
                }
            }
        }
        if (settingsList.currentIndex >= 0)
            settingsList.positionViewAtIndex(settingsList.currentIndex, ListView.Contain)
    }

    function rememberSettingsIndex(rowIndex) {
        if (settingsMode === "main") {
            mainSettingsIndex = rowIndex
        } else if (settingsMode === "section" && activeSection.length > 0) {
            var saved = Object.assign({}, sectionSettingsIndexes)
            saved[activeSection] = rowIndex
            sectionSettingsIndexes = saved
        }
    }

    function openSettingsSection(sectionKey, rowIndex) {
        mainSettingsIndex = rowIndex
        var savedIndex = sectionSettingsIndexes[sectionKey]
        buildSectionModel(sectionKey, savedIndex === undefined ? 0 : savedIndex)
    }

    function returnToSectionSettings() {
        if (activeSection.length > 0)
            buildSectionModel(activeSection, sectionSettingsIndexes[activeSection] || 0)
        else
            buildMainMenu(mainSettingsIndex)
        settingsList.forceActiveFocus()
    }

    function replaceSettingsRow(rowIndex, values) {
        var updated = settingsItems.slice()
        updated[rowIndex] = Object.assign({}, updated[rowIndex], values)
        var savedIndex = settingsList.currentIndex
        settingsItems = updated
        settingsList.currentIndex = savedIndex
    }

    function buildBluetoothScanModel(message, preferredIndex) {
        settingsMode = "bluetooth_scan"
        activeSection = "bluetooth"
        var items = []
        items.push({ type: "section", label: "Gamepad Scan:" })

        if (bluetoothScanning || bluetoothBusy) {
            items.push({
                type: "status",
                label: bluetoothStatusMessage.length > 0 ? bluetoothStatusMessage : "Scanning Controllers",
                value: "..."
            })
        } else {
            if (message && message.length > 0)
                items.push({ type: "status", label: message, value: "" })

            for (var b = 0; b < bluetoothDevices.length; b++) {
                var device = bluetoothDevices[b]
                items.push({
                    type: "bluetooth_device",
                    label: settingsRoot.bluetoothDeviceName(device),
                    value: settingsRoot.bluetoothActionValue(device),
                    address: device.address || "",
                    connected: !!device.connected,
                    paired: !!device.paired,
                    trusted: !!device.trusted
                })
                if (device.paired || device.trusted || device.connected) {
                    items.push({
                        type: "bluetooth_forget",
                        label: "Forget " + settingsRoot.bluetoothDeviceName(device),
                        value: "",
                        address: device.address || ""
                    })
                }
            }

            items.push({
                type: "action",
                action: "scan_bluetooth",
                label: bluetoothDevices.length > 0 ? "Scan Again" : "Scan Controllers",
                value: "OK"
            })
        }

        settingsItems = items
        selectSettingsIndex(preferredIndex === undefined ? 0 : preferredIndex)
    }

    function returnToMainSettings() {
        buildMainMenu(mainSettingsIndex)
        settingsList.forceActiveFocus()
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

    function setBluetoothEnabled(rowIndex, enabled) {
        var row = settingsItems[rowIndex]
        if (!row || !row.available) return

        replaceSettingsRow(rowIndex, { value: "..." })
        var result = appCore.setBluetoothEnabled(enabled)
        bluetoothInfo = result
        replaceSettingsRow(rowIndex, {
            value: settingsRoot.bluetoothRowValue(result),
            available: !!result.available,
            enabled: !!result.enabled,
            powered: !!result.powered
        })
    }

    function setArgonFanMode(rowIndex, mode) {
        var row = settingsItems[rowIndex]
        if (!row || !row.available) return

        replaceSettingsRow(rowIndex, { value: "..." })
        var result = appCore.setArgonFanMode(mode)
        argonFanInfo = result
        replaceSettingsRow(rowIndex, {
            value: settingsRoot.argonFanRowValue(result),
            available: !!result.available
        })
    }

    function scanBluetooth(rowIndex) {
        if (bluetoothScanning || bluetoothBusy) return

        rememberSettingsIndex(rowIndex)
        settingsMode = "bluetooth_scan"
        activeSection = "bluetooth"
        bluetoothScanning = true
        bluetoothStatusMessage = "Scanning Controllers"
        bluetoothDevices = []
        buildBluetoothScanModel("", 0)
        appCore.scanBluetoothDevicesAsync()
    }

    function finishBluetoothScan(result) {
        bluetoothScanning = false
        bluetoothStatusMessage = ""
        bluetoothInfo = result
        bluetoothDevices = result.devices || []
        if (settingsMode === "bluetooth_scan") {
            buildBluetoothScanModel(result.message || "NO CONTROLLERS FOUND.", 1)
        } else {
            buildModel()
        }
    }

    function beginBluetoothAction(rowIndex, message) {
        bluetoothBusy = true
        bluetoothPendingIndex = rowIndex
        bluetoothPendingMode = settingsMode
        bluetoothStatusMessage = message
        replaceSettingsRow(rowIndex, { value: "..." })
    }

    function finishBluetoothAction(action, result) {
        bluetoothBusy = false
        bluetoothInfo = result
        bluetoothDevices = result.devices || bluetoothDevices
        bluetoothStatusMessage = result.message || ""

        var rowIndex = bluetoothPendingIndex >= 0 ? bluetoothPendingIndex : 1
        var wasScan = bluetoothPendingMode === "bluetooth_scan" || settingsMode === "bluetooth_scan"
        bluetoothPendingIndex = -1
        bluetoothPendingMode = ""

        if (wasScan)
            buildBluetoothScanModel(bluetoothStatusMessage, rowIndex)
        else
            buildSectionModel("bluetooth", rowIndex)
        selectSettingsIndex(rowIndex)
    }

    function pairBluetooth(rowIndex, row) {
        if (bluetoothBusy || bluetoothScanning || !row || !row.address) return

        beginBluetoothAction(rowIndex, "Pairing Controller")
        appCore.pairBluetoothDeviceAsync(row.address)
    }

    function connectBluetooth(rowIndex, row) {
        if (bluetoothBusy || bluetoothScanning || !row || !row.address) return

        if (row.connected) {
            if (settingsMode === "bluetooth_scan")
                buildBluetoothScanModel("CONTROLLER CONNECTED.", rowIndex)
            else
                buildSectionModel("bluetooth", rowIndex)
            selectSettingsIndex(rowIndex)
            return
        }

        beginBluetoothAction(rowIndex, "Connecting Controller")
        appCore.connectBluetoothDeviceAsync(row.address)
    }

    function activateBluetoothDevice(rowIndex, row) {
        if (!row || !row.address) return

        if (row.paired || row.connected) {
            connectBluetooth(rowIndex, row)
            return
        }

        pairBluetooth(rowIndex, row)
    }

    function forgetBluetooth(rowIndex, row) {
        if (bluetoothBusy || bluetoothScanning || !row || !row.address) return

        beginBluetoothAction(rowIndex, "Removing Controller")
        appCore.forgetBluetoothDeviceAsync(row.address)
    }

    function setListSingleValue(rowIndex, row, newVal) {
        if (row.type === "clock_part") {
            setClockPartValue(rowIndex, row, newVal)
            return
        }

        if (row.type === "argon_fan") {
            setArgonFanMode(rowIndex, newVal)
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
            buildSectionModel("appearance", rowIndex)
            selectSettingsIndex(rowIndex)
        }
    }

    function setToggleValue(rowIndex, row, enabled) {
        if (!row || row.type !== "toggle") return

        replaceSettingsRow(rowIndex, {
            value: enabled ? "ON" : "OFF",
            enabled: enabled
        })
        appCore.save_setting(row.moduleId || "", row.key, enabled)
    }

    function setClockPartValue(rowIndex, row, newVal) {
        var parts = root.vcrClockParts()
        var hour = row.part === "hour" ? parseInt(newVal) : parts.hour
        var minute = row.part === "minute" ? parseInt(newVal) : parts.minute
        var period = row.part === "period" ? newVal : parts.period
        root.setVcrClock(hour, minute, period)
        buildSectionModel("system", rowIndex)
        settingsList.currentIndex = rowIndex
        settingsList.positionViewAtIndex(settingsList.currentIndex, ListView.Contain)
    }

    function firstSelectableAfter(idx) {
        for (var i = idx + 1; i < settingsItems.length; i++) {
            if (isSelectableRow(settingsItems[i])) return i
        }
        return settingsList.currentIndex
    }

    function firstSelectableBefore(idx) {
        for (var i = idx - 1; i >= 0; i--) {
            if (isSelectableRow(settingsItems[i])) return i
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
            updateMessage = result.message || "INSTALLING UPDATE. TATER TUBE WILL RESTART."
            updateDetail = "SWITCHING TO UPDATE PROGRESS"
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
        function onBluetoothScanFinished(result) {
            settingsRoot.finishBluetoothScan(result)
        }
        function onBluetoothActionFinished(action, result) {
            settingsRoot.finishBluetoothAction(action, result)
        }
        function onAppSettingChanged(key, value) {
            if (updateOverlayVisible || bluetoothScanning || bluetoothBusy)
                return
            if (settingsMode === "section")
                buildSectionModel(activeSection, settingsList.currentIndex)
            else if (settingsMode === "main")
                buildMainMenu(settingsList.currentIndex)
        }
        function onModuleSettingChanged(mid, key, value) {
            if (updateOverlayVisible || bluetoothScanning || bluetoothBusy)
                return
            if (settingsMode === "section" && activeSection === "features")
                buildSectionModel(activeSection, settingsList.currentIndex)
        }
    }

    // Header
    AppBar {
        iconSource: "../../assets/images/settings.svg"
        iconHeight: root.sh * 0.075
        title: "Settings"
        subtitle: settingsMode === "bluetooth_scan"
            ? "Gamepad Scan"
            : (settingsMode === "section" ? sectionTitle(activeSection) : root.appVersion)
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
            if (row && (row.type === "list_single" || row.type === "clock_part" || row.type === "argon_fan")) {
                var opts = row.options
                var idx = opts.indexOf(row.value)
                var newIdx = (idx - 1 + opts.length) % opts.length
                settingsRoot.setListSingleValue(currentIndex, row, opts[newIdx])
            } else if (row && row.type === "toggle") {
                settingsRoot.setToggleValue(currentIndex, row, false)
            } else if (row && row.type === "ssh_toggle") {
                settingsRoot.setSshEnabled(currentIndex, false)
            } else if (row && row.type === "bluetooth_toggle") {
                settingsRoot.setBluetoothEnabled(currentIndex, false)
            }
        }

        Keys.onRightPressed: {
            var row = settingsItems[currentIndex]
            if (row && (row.type === "list_single" || row.type === "clock_part" || row.type === "argon_fan")) {
                var opts = row.options
                var idx = opts.indexOf(row.value)
                var newIdx = (idx + 1) % opts.length
                settingsRoot.setListSingleValue(currentIndex, row, opts[newIdx])
            } else if (row && row.type === "toggle") {
                settingsRoot.setToggleValue(currentIndex, row, true)
            } else if (row && row.type === "ssh_toggle") {
                settingsRoot.setSshEnabled(currentIndex, true)
            } else if (row && row.type === "bluetooth_toggle") {
                settingsRoot.setBluetoothEnabled(currentIndex, true)
            }
        }

        Keys.onReturnPressed: {
            var row = settingsItems[currentIndex]
            if (row && row.type === "settings_category") {
                settingsRoot.openSettingsSection(row.sectionKey, currentIndex)
            } else if (row && row.type === "submenu") {
                settingsRoot.rememberSettingsIndex(currentIndex)
                settingsRoot.navigateTo("views/ModuleSettings.qml", { moduleId: row.moduleId }, {
                    currentIndex: settingsList.currentIndex,
                    sectionKey: activeSection
                })
            } else if (row && row.type === "action" && row.action === "check_updates") {
                settingsRoot.beginUpdateCheck()
            } else if (row && row.type === "action" && row.action === "scan_bluetooth") {
                settingsRoot.scanBluetooth(currentIndex)
            } else if (row && row.type === "action" && row.action === "map_controller") {
                settingsRoot.rememberSettingsIndex(currentIndex)
                settingsRoot.navigateTo("views/ControllerMapper.qml", {}, {
                    currentIndex: settingsList.currentIndex,
                    sectionKey: activeSection
                })
            } else if (row && row.type === "toggle") {
                settingsRoot.setToggleValue(currentIndex, row, !row.enabled)
            } else if (row && row.type === "ssh_toggle") {
                settingsRoot.setSshEnabled(currentIndex, !row.enabled)
            } else if (row && row.type === "bluetooth_toggle") {
                settingsRoot.setBluetoothEnabled(currentIndex, !(row.enabled && row.powered))
            } else if (row && row.type === "argon_fan") {
                var fanOpts = row.options
                var fanIdx = fanOpts.indexOf(row.value)
                settingsRoot.setListSingleValue(currentIndex, row, fanOpts[(fanIdx + 1) % fanOpts.length])
            } else if (row && (row.type === "bluetooth_device" || row.type === "bluetooth_known")) {
                settingsRoot.activateBluetoothDevice(currentIndex, row)
            } else if (row && row.type === "bluetooth_forget") {
                settingsRoot.forgetBluetooth(currentIndex, row)
            }
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                if (bluetoothScanning || bluetoothBusy) {
                    event.accepted = true
                    return
                }
                if (settingsMode === "bluetooth_scan")
                    settingsRoot.returnToSectionSettings()
                else if (settingsMode === "section")
                    settingsRoot.returnToMainSettings()
                else
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
                    width: parent.width * 0.62
                    elide: Text.ElideRight
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
                        visible: modelData.type === "list_single" || modelData.type === "clock_part" || modelData.type === "toggle" || (modelData.type === "argon_fan" && modelData.available === true) || (modelData.type === "ssh_toggle" && modelData.available === true) || (modelData.type === "bluetooth_toggle" && modelData.available === true)
                        text: "\u25C4"
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize: root.sh * 0.0375 //18
                    }
                    Text {
                        visible: modelData.type === "list_single" || modelData.type === "clock_part" || modelData.type === "toggle" || modelData.type === "argon_fan" || modelData.value !== undefined
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
                        visible: modelData.type === "settings_category" || modelData.type === "submenu" || modelData.type === "list_single" || modelData.type === "clock_part" || modelData.type === "toggle" || (modelData.type === "argon_fan" && modelData.available === true) || modelData.type === "action" || modelData.type === "bluetooth_device" || modelData.type === "bluetooth_known" || modelData.type === "bluetooth_forget" || (modelData.type === "ssh_toggle" && modelData.available === true) || (modelData.type === "bluetooth_toggle" && modelData.available === true)
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
                    updateDetail = "PREPARING UPDATE CONSOLE"
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
