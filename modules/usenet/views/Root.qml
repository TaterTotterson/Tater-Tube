pragma ComponentBehavior: Bound

import QtQuick
import Components

FocusScope {
    id: usenetRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.usenet"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "USENET"
    property string moduleIcon: _moduleInfo.icon || ""

    property string mode: "loading"
    property string statusText: "LOADING USENET..."
    property var categories: []
    property var subcategories: []
    property var trendingRows: [
        { type: "trending", title: "Movies Today", detail: "MOVIE", category: "movie", time: "today" },
        { type: "trending", title: "Movies Week", detail: "MOVIE", category: "movie", time: "week" },
        { type: "trending", title: "Movies Month", detail: "MOVIE", category: "movie", time: "month" },
        { type: "trending", title: "Movies Year", detail: "MOVIE", category: "movie", time: "year" },
        { type: "trending", title: "TV Today", detail: "TV", category: "tv", time: "today" },
        { type: "trending", title: "TV Week", detail: "TV", category: "tv", time: "week" },
        { type: "trending", title: "TV Month", detail: "TV", category: "tv", time: "month" },
        { type: "trending", title: "TV Year", detail: "TV", category: "tv", time: "year" }
    ]
    property var shortcutRows: [
        { type: "search", title: "Search", detail: "ALL MEDIA" },
        { type: "trendingRoot", title: "Trending", detail: "OMG", children: trendingRows }
    ]
    property var categoryRows: mode === "subcategories" ? subcategories : shortcutRows.concat(categories)
    property var items: []
    property var streams: []
    property int currentCategoryIndex: 0
    property int currentSubcategoryIndex: 0
    property int currentItemIndex: 0
    property int currentStreamIndex: 0
    property int setupRow: 0
    readonly property int setupConnectRow: 5
    property string currentGroupTitle: ""
    property string currentCategoryTitle: ""
    property string searchQuery: ""
    property string pendingRequestId: ""
    property string pendingTitle: ""
    property bool playbackStarted: false

    focus: true

    function settingValue(key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "") return fallback
        return value
    }

    function newRequestId() {
        return Date.now().toString() + "-" + Math.floor(Math.random() * 1000000).toString()
    }

    function setListIndex(list, index) {
        if (!list || list.count <= 0) return
        list.currentIndex = Math.max(0, Math.min(list.count - 1, index))
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }

    function pageList(list, direction) {
        if (!list || list.count <= 0) return
        var rowHeight = root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(list.height / rowHeight) - 1)
        setListIndex(list, list.currentIndex + direction * rows)
    }

    function focusSetupRow() {
        if (setupRow === 0) newznabUrlField.forceInputFocus()
        else if (setupRow === 1) newznabKeyField.forceInputFocus()
        else if (setupRow === 2) omgUsernameField.forceInputFocus()
        else if (setupRow === 3) altmountUrlField.forceInputFocus()
        else if (setupRow === 4) altmountKeyField.forceInputFocus()
        else connectButton.forceActiveFocus()
    }

    function setupPrevious() {
        if (setupRow > 0) {
            setupRow--
            focusSetupRow()
        }
    }

    function setupNext() {
        if (setupRow < setupConnectRow) {
            setupRow++
            focusSetupRow()
        }
    }

    function showSetup(message) {
        var status = usenetBackend.get_setup_status()
        newznabUrlField.text = status.newznabUrl || ""
        newznabKeyField.text = status.newznabApiKey || ""
        omgUsernameField.text = status.omgUsername || ""
        altmountUrlField.text = status.altmountUrl || ""
        altmountKeyField.text = status.altmountApiKey || ""
        statusText = message || "ENTER USENET SETTINGS"
        mode = "setup"
        setupFocusTimer.restart()
    }

    function saveSetup() {
        var newznabUrl = (newznabUrlField.text || "").trim()
        var newznabKey = (newznabKeyField.text || "").trim()
        var omgUsername = (omgUsernameField.text || "").trim()
        var altmountUrl = (altmountUrlField.text || "").trim()
        var altmountKey = (altmountKeyField.text || "").trim()

        if (newznabUrl === "") {
            statusText = "ENTER NEWZNAB URL"
            setupRow = 0
            focusSetupRow()
            return
        }
        if (newznabKey === "") {
            statusText = "ENTER NEWZNAB API KEY"
            setupRow = 1
            focusSetupRow()
            return
        }
        if (altmountUrl === "") {
            statusText = "ENTER ALTMOUNT URL"
            setupRow = 3
            focusSetupRow()
            return
        }
        if (altmountKey === "") {
            statusText = "ENTER ALTMOUNT KEY"
            setupRow = 4
            focusSetupRow()
            return
        }

        appCore.save_setting(moduleId, "newznab_url", newznabUrl)
        appCore.save_setting(moduleId, "newznab_api_key", newznabKey)
        appCore.save_setting(moduleId, "omg_username", omgUsername)
        appCore.save_setting(moduleId, "altmount_url", altmountUrl)
        appCore.save_setting(moduleId, "altmount_api_key", altmountKey)
        loadCategories()
    }

    function refresh() {
        var status = usenetBackend.get_setup_status()
        if (!status.configured) {
            showSetup("ENTER USENET SETTINGS")
            return
        }
        loadCategories()
    }

    function loadCategories() {
        mode = "loading"
        statusText = "LOADING CATEGORIES..."
        usenetBackend.load_categories()
    }

    function showSearch() {
        resetCategoryDrilldown()
        mode = "search"
        statusText = "SEARCH NEWGROUPS"
        searchField.text = searchQuery
        searchFocusTimer.restart()
    }

    function runSearch() {
        var query = (searchField.text || "").trim()
        searchQuery = query
        if (query.length < 3) {
            statusText = "ENTER 3 OR MORE LETTERS"
            searchFocusTimer.restart()
            return
        }
        currentCategoryTitle = "Search: " + query
        mode = "loading"
        statusText = "SEARCHING " + query
        usenetBackend.search_items(query)
    }

    function browseCategory(row) {
        if (!row) return
        currentCategoryTitle = row.fullTitle || row.title || "CATEGORY"
        mode = "loading"
        if (row.type === "trending") {
            statusText = "LOADING " + currentCategoryTitle
            usenetBackend.load_trending(row.category || "", row.time || "", currentCategoryTitle)
        } else {
            statusText = "BROWSING " + currentCategoryTitle
            usenetBackend.load_items(row.id || "", currentCategoryTitle)
        }
    }

    function selectCategory(index) {
        if (index < 0 || index >= categoryRows.length) return
        var row = categoryRows[index] || ({})
        if (row.type === "search") {
            currentCategoryIndex = index
            showSearch()
            return
        }
        if (mode === "subcategories") {
            currentSubcategoryIndex = index
            browseCategory(row)
            return
        }

        currentCategoryIndex = index
        currentGroupTitle = row.title || "CATEGORY"
        subcategories = row.children || []
        currentSubcategoryIndex = 0
        if (subcategories.length > 0) {
            mode = "subcategories"
            setListIndex(categoryList, currentSubcategoryIndex)
            return
        }
        browseCategory(row)
    }

    function returnToCategoryMenu() {
        if (subcategories.length > 0) {
            mode = "subcategories"
            setListIndex(categoryList, currentSubcategoryIndex)
            return
        }
        mode = "categories"
        setListIndex(categoryList, currentCategoryIndex)
    }

    function resetCategoryDrilldown() {
        subcategories = []
        currentSubcategoryIndex = 0
        currentGroupTitle = ""
        currentCategoryTitle = ""
    }

    function selectItem(index) {
        if (index < 0 || index >= items.length) return
        currentItemIndex = index
        var row = items[index] || ({})
        pendingRequestId = newRequestId()
        pendingTitle = row.title || "USENET"
        mode = "loading"
        statusText = "TUNING " + pendingTitle
        usenetBackend.request_streams(pendingRequestId, row)
    }

    function playStream(stream, title) {
        if (!stream || !stream.url) {
            mode = "message"
            statusText = "STREAM URL MISSING"
            return
        }
        playbackStarted = true
        mode = "playing"
        statusText = "PLAYING " + (title || stream.title || "USENET")
        mpvController.loadAndPlay(stream.url, 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "", false, title || stream.title || "USENET")
    }

    function stopPlayback() {
        playbackStarted = false
        mpvController.stop()
        mode = items.length > 0 ? "items" : (subcategories.length > 0 ? "subcategories" : "categories")
    }

    Keys.onPressed: function(event) {
        if (mode === "search") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                mode = "categories"
                setListIndex(categoryList, currentCategoryIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "categories" || mode === "subcategories") {
            if (event.key === Qt.Key_Up) {
                setListIndex(categoryList, categoryList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                setListIndex(categoryList, categoryList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageList(categoryList, -1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageList(categoryList, 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                selectCategory(categoryList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                if (mode === "subcategories") {
                    mode = "categories"
                    setListIndex(categoryList, currentCategoryIndex)
                } else {
                    goBack()
                }
                event.accepted = true
            }
            return
        }

        if (mode === "items") {
            if (event.key === Qt.Key_Up) {
                setListIndex(itemList, itemList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                setListIndex(itemList, itemList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageList(itemList, -1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageList(itemList, 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                selectItem(itemList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                returnToCategoryMenu()
                event.accepted = true
            }
            return
        }

        if (mode === "streams") {
            if (event.key === Qt.Key_Up) {
                setListIndex(streamList, streamList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                setListIndex(streamList, streamList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                currentStreamIndex = streamList.currentIndex
                playStream(streams[currentStreamIndex], streams[currentStreamIndex].title || pendingTitle)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                mode = "items"
                setListIndex(itemList, currentItemIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "playing") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                stopPlayback()
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
        if (playbackStarted)
            mpvController.stop()
    }

    Timer {
        id: setupFocusTimer
        interval: 1
        repeat: false
        onTriggered: focusSetupRow()
    }

    Timer {
        id: searchFocusTimer
        interval: 1
        repeat: false
        onTriggered: {
            searchField.forceActiveFocus()
        }
    }

    Connections {
        target: usenetBackend

        function onCategoriesLoaded(rows) {
            categories = rows || []
            resetCategoryDrilldown()
            if (categories.length === 0) {
                mode = "message"
                statusText = "NO CATEGORIES FOUND"
                return
            }
            mode = "categories"
            setListIndex(categoryList, currentCategoryIndex)
        }

        function onItemsLoaded(categoryTitle, rows) {
            currentCategoryTitle = categoryTitle || currentCategoryTitle
            items = rows || []
            if (items.length === 0) {
                mode = "message"
                statusText = "NO ITEMS IN " + currentCategoryTitle
                return
            }
            mode = "items"
            setListIndex(itemList, 0)
        }

        function onStreamsReady(requestId, title, rows) {
            if (requestId !== pendingRequestId)
                return
            streams = rows || []
            if (streams.length === 1) {
                playStream(streams[0], title || pendingTitle)
                return
            }
            mode = "streams"
            setListIndex(streamList, 0)
        }

        function onErrorOccurred(message) {
            mode = "message"
            statusText = message || "USENET FAILED"
        }
    }

    Connections {
        target: appCore
        function onModuleSettingChanged(mid, key, value) {
            if (mid !== usenetRoot.moduleId)
                return
            if (key !== "newznab_url" && key !== "newznab_api_key"
                    && key !== "omg_username" && key !== "altmount_url"
                    && key !== "altmount_api_key")
                return
            if (mode === "setup" || mode === "message")
                refresh()
        }
    }

    Connections {
        target: mpvController

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (mode === "playing") {
                playbackStarted = false
                mode = items.length > 0 ? "items" : (subcategories.length > 0 ? "subcategories" : "categories")
            }
        }

        function onPlaybackFailed() {
            if (mode === "playing") {
                playbackStarted = false
                mode = "message"
                statusText = "USENET PLAYBACK FAILED"
            }
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
        visible: mode !== "playing"
        iconSource: moduleIcon
        iconHeight: root.sh * 0.075
        title: moduleName
        subtitle: mode === "items" ? currentCategoryTitle : (mode === "subcategories" ? currentGroupTitle : "NEWZNAB")
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

    Column {
        id: setupForm
        visible: mode === "setup"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.2
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        spacing: root.sh * 0.016

        Text {
            text: statusText
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.031
            width: setupForm.width
            elide: Text.ElideRight
        }

        SetupField { id: newznabUrlField; label: "NEWZNAB URL"; selected: setupRow === 0 }
        SetupField { id: newznabKeyField; label: "NEWZNAB API KEY"; selected: setupRow === 1; password: true }
        SetupField { id: omgUsernameField; label: "OMG USERNAME"; selected: setupRow === 2 }
        SetupField { id: altmountUrlField; label: "ALTMOUNT URL"; selected: setupRow === 3 }
        SetupField { id: altmountKeyField; label: "ALTMOUNT KEY OR STREMIO URL"; selected: setupRow === 4; password: true }

        Rectangle {
            id: connectButton
            width: setupForm.width
            height: root.sh * 0.0583333
            color: setupRow === setupConnectRow ? root.accentColor : "transparent"
            focus: setupRow === setupConnectRow

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.009375
                text: "CONNECT"
                color: setupRow === setupConnectRow ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.05
            }

            Keys.onUpPressed: setupPrevious()
            Keys.onDownPressed: setupNext()
            Keys.onReturnPressed: saveSetup()
            Keys.onEnterPressed: saveSetup()
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                    goBack()
                    event.accepted = true
                }
            }
        }
    }

    Column {
        id: searchForm
        visible: mode === "search"
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
            width: searchForm.width
            elide: Text.ElideRight
        }

        Rectangle {
            width: searchForm.width
            height: root.sh * 0.076
            color: root.accentColor

            Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: root.sw * 0.009375
                text: "SEARCH"
                color: root.surfaceColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.026
            }

            TextInput {
                id: searchField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: root.sw * 0.009375
                anchors.rightMargin: root.sw * 0.009375
                height: root.sh * 0.047
                color: root.surfaceColor
                selectedTextColor: root.surfaceColor
                selectionColor: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.04
                clip: true

                Keys.onReturnPressed: runSearch()
                Keys.onEnterPressed: runSearch()
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        mode = "categories"
                        setListIndex(categoryList, currentCategoryIndex)
                        event.accepted = true
                    }
                }
            }
        }
    }

    ListView {
        id: categoryList
        visible: mode === "categories" || mode === "subcategories"
        model: categoryRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: {
            if (mode === "subcategories")
                currentSubcategoryIndex = currentIndex
            else
                currentCategoryIndex = currentIndex
        }

        delegate: MenuRow {
            required property var modelData
            required property int index

            list: categoryList
            rowIndex: index
            text: modelData.title || "CATEGORY"
            detail: modelData.detail || (mode === "categories" && modelData.count ? (modelData.count + " CAT") : (modelData.id || ""))
        }
    }

    ListView {
        id: itemList
        visible: mode === "items"
        model: items
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentItemIndex = currentIndex

        delegate: MenuRow {
            required property var modelData
            required property int index

            list: itemList
            rowIndex: index
            text: modelData.title || "ITEM"
            detail: modelData.sizeText || modelData.date || ""
        }
    }

    ListView {
        id: streamList
        visible: mode === "streams"
        model: streams
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentStreamIndex = currentIndex

        delegate: MenuRow {
            required property var modelData
            required property int index

            list: streamList
            rowIndex: index
            text: modelData.title || modelData.name || "STREAM"
            detail: "PLAY"
        }
    }

    component MenuRow: Item {
        property var list
        property int rowIndex: -1
        property string text: ""
        property string detail: ""
        readonly property bool selected: list.currentIndex === rowIndex

        width: list.width
        height: root.sh * 0.0583333

        Rectangle {
            anchors.fill: parent
            color: root.accentColor
            opacity: selected ? 0.32 : 0.0
            visible: selected
        }

        Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root.sw * 0.00625
            height: parent.height * 0.82
            color: root.accentColor
            visible: selected
        }

        Text {
            id: rowText
            text: parent.text
            color: root.primaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - root.sw * 0.17
            elide: Text.ElideRight
            leftPadding: root.sw * 0.009375
            rightPadding: root.sw * 0.009375
            font.pixelSize: root.sh * 0.05
        }

        Text {
            visible: detail !== ""
            text: detail
            color: selected ? root.secondaryColor : root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: root.sw * 0.009375
            horizontalAlignment: Text.AlignRight
            width: root.sw * 0.16
            elide: Text.ElideRight
            font.pixelSize: root.sh * 0.032
        }
    }

    component SetupField: Item {
        property alias text: fieldInput.text
        property string label: ""
        property bool selected: false
        property bool password: false

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
            anchors.bottom: parent.bottom
            anchors.leftMargin: root.sw * 0.009375
            anchors.rightMargin: root.sw * 0.009375
            height: root.sh * 0.047
            color: selected ? root.surfaceColor : root.primaryColor
            selectedTextColor: root.surfaceColor
            selectionColor: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.04
            echoMode: password ? TextInput.Password : TextInput.Normal
            clip: true

            Keys.onUpPressed: setupPrevious()
            Keys.onDownPressed: setupNext()
            Keys.onReturnPressed: {
                if (setupRow === setupConnectRow - 1) saveSetup()
                else setupNext()
            }
            Keys.onEnterPressed: {
                if (setupRow === setupConnectRow - 1) saveSetup()
                else setupNext()
            }
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                    goBack()
                    event.accepted = true
                }
            }
        }
    }
}
