pragma ComponentBehavior: Bound

import QtQuick
import Components

FocusScope {
    id: showRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var item: navParams.item || {}
    property string libraryName: navParams.libraryName || "LOCAL"
    property var rows: []
    property bool isLoading: false
    property int focusRow: 0
    property string pendingLoad: "children"
    property var pendingSeason: ({})
    property int scanIndex: 0
    property var scanFirstEpisode: null

    readonly property bool rowsAreEpisodes: rows.length > 0 && (rows[0].type || "") === "localFile"

    function numericValue(value, fallback) {
        var number = Number(value)
        return isFinite(number) ? number : (fallback || 0)
    }

    function hasResume(row) {
        return numericValue(row && row.viewOffset, 0) > 0
                || numericValue(row && row.viewOffsetSeconds, 0) > 0
    }

    function playEpisode(row) {
        if (!row)
            return
        var episode = Object.assign({}, row)
        if (!episode.seriesTitle)
            episode.seriesTitle = item.title || ""
        navigateTo("LocalPlayer.qml", {
            item: episode,
            title: episode.title || "EPISODE"
        }, { currentIndex: childList.currentIndex })
    }

    function playBestEpisodeFromRows(list) {
        list = list || []
        for (var i = 0; i < list.length; i++) {
            if (hasResume(list[i])) {
                playEpisode(list[i])
                return true
            }
        }
        if (list.length > 0) {
            playEpisode(list[0])
            return true
        }
        return false
    }

    function startBestEpisodeScan() {
        if (rowsAreEpisodes) {
            playBestEpisodeFromRows(rows)
            return
        }
        if (rows.length === 0)
            return
        scanIndex = 0
        scanFirstEpisode = null
        pendingLoad = "scanEpisodes"
        scanNextSeason()
    }

    function scanNextSeason() {
        if (scanIndex >= rows.length) {
            if (scanFirstEpisode)
                playEpisode(scanFirstEpisode)
            pendingLoad = "children"
            isLoading = false
            return
        }
        pendingSeason = rows[scanIndex] || ({})
        isLoading = true
        usenetBackend.load_local_items(pendingSeason.categoryId || "", pendingSeason.path || "",
                                       pendingSeason.sourceIndex || 0, pendingSeason.title || "Season")
    }

    function handleScanRows(list) {
        list = list || []
        if (!scanFirstEpisode && list.length > 0)
            scanFirstEpisode = list[0]
        for (var i = 0; i < list.length; i++) {
            if (hasResume(list[i])) {
                isLoading = false
                pendingLoad = "children"
                playEpisode(list[i])
                return
            }
        }
        scanIndex++
        scanNextSeason()
    }

    function openRow(row) {
        if (!row)
            return
        if ((row.type || "") === "localFile") {
            playEpisode(row)
            return
        }
        navigateTo("LocalSeason.qml", {
            item: row,
            showTitle: item.title || "",
            libraryName: libraryName
        }, { currentIndex: childList.currentIndex })
    }

    function childLabel(row) {
        if (!row)
            return ""
        var title = row.title || ""
        if ((row.type || "") !== "localFile")
            return title
        if (title.match(/^S\d+E\d+/i))
            return title
        var path = row.path || ""
        var match = path.match(/s(\d+)[ ._-]*e(\d+)/i)
        if (match)
            return "S" + match[1] + "E" + match[2] + ": " + title
        return title
    }

    function showSubtitle() {
        var parts = []
        if (rows.length > 0) {
            if (rowsAreEpisodes)
                parts.push(rows.length + (rows.length === 1 ? " EPISODE" : " EPISODES"))
            else
                parts.push(rows.length + (rows.length === 1 ? " SEASON" : " SEASONS"))
        }
        if ((item.path || "") !== "")
            parts.push(item.path)
        return parts.join(" - ")
    }

    Connections {
        target: usenetBackend

        function onItemsLoaded(categoryTitle, loadedRows) {
            if (showRoot.pendingLoad === "scanEpisodes") {
                showRoot.handleScanRows(loadedRows || [])
                return
            }

            showRoot.isLoading = false
            showRoot.rows = loadedRows || []
            if (showRoot.rows.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                childList.currentIndex = Math.min(restore, showRoot.rows.length - 1)
                childList.positionViewAtIndex(childList.currentIndex, ListView.Contain)
            }
        }

        function onErrorOccurred(message) {
            showRoot.isLoading = false
            showRoot.pendingLoad = "children"
        }
    }

    Component.onCompleted: {
        isLoading = true
        focusRow = 0
        pendingLoad = "children"
        usenetBackend.load_local_items(item.categoryId || "", item.path || "",
                                       item.sourceIndex || 0, item.title || "Show")
    }

    focus: true

    Keys.onUpPressed: {
        if (focusRow === 1) {
            if (childList.currentIndex > 0)
                childList.currentIndex--
            else
                focusRow = 0
        }
    }
    Keys.onDownPressed: {
        if (focusRow === 0) {
            if (rows.length > 0)
                focusRow = 1
        } else if (childList.currentIndex < rows.length - 1) {
            childList.currentIndex++
        }
    }
    Keys.onLeftPressed: {
        if (focusRow === 1 && childList.count > 0) {
            var pageRows = Math.max(1, Math.floor(childList.height / (root.sh * 0.0583333)) - 1)
            childList.currentIndex = Math.max(0, childList.currentIndex - pageRows)
            childList.positionViewAtIndex(childList.currentIndex, ListView.Contain)
        }
    }
    Keys.onRightPressed: {
        if (focusRow === 1 && childList.count > 0) {
            var pageRows = Math.max(1, Math.floor(childList.height / (root.sh * 0.0583333)) - 1)
            childList.currentIndex = Math.min(childList.count - 1, childList.currentIndex + pageRows)
            childList.positionViewAtIndex(childList.currentIndex, ListView.Contain)
        }
    }
    Keys.onReturnPressed: {
        if (focusRow === 0)
            startBestEpisodeScan()
        else
            openRow(rows[childList.currentIndex])
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    StaticBackground {
        anchors.fill: parent
        visible: root.staticBackgroundEnabled
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: root.staticBackgroundEnabled ? "transparent" : root.surfaceColor
    }

    AppBar {
        iconSource: moduleRoot.moduleIcon
        iconHeight: root.sh * 0.075
        title: moduleRoot.moduleName
        subtitle: libraryName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Text {
        visible: isLoading
        text: "LOADING..."
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05
    }

    Item {
        visible: !isLoading
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true

        Row {
            id: showDetails
            height: root.sh * 0.2916667
            spacing: root.sw * 0.0375

            Rectangle {
                color: focusRow === 0 ? root.accentColor : root.surfaceColor
                border.color: focusRow === 0 ? root.accentColor : root.tertiaryColor
                width: root.sw * 0.1875
                height: root.sh * 0.1166667
                border.width: root.sh * 0.003125

                Text {
                    anchors.centerIn: parent
                    text: "PLAY \u25BA"
                    color: focusRow === 0 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.05
                }
            }

            Column {
                topPadding: root.sh * 0.0083333
                width: root.sw * 0.54375
                spacing: root.sh * 0.0166667

                Text {
                    text: item.title || ""
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.05
                }

                Text {
                    text: showSubtitle()
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.0333333
                }

                Item {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: root.sh * 0.1375
                    clip: true

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        text: rowsAreEpisodes
                              ? "SERVER LOCAL SERIES. PLAY RESUMES THE CURRENT EPISODE WHEN AVAILABLE."
                              : "SERVER LOCAL SERIES. SELECT A SEASON OR PRESS PLAY TO RESUME."
                        color: root.primaryColor
                        font.family: root.globalFont
                        wrapMode: Text.WordWrap
                        font.pixelSize: root.sh * 0.0291667
                        lineHeight: 1.3
                    }
                }
            }
        }

        Text {
            id: childListLabel
            anchors.top: showDetails.bottom
            text: rowsAreEpisodes ? "Episodes:" : "Seasons:"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.topMargin: root.sh * 0.0145833
            leftPadding: root.sw * 0.009375
            rightPadding: root.sw * 0.009375
            font.pixelSize: root.sh * 0.0291667
        }

        ListView {
            id: childList
            model: rows
            anchors.top: childListLabel.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.sh * 0.0145833
            height: root.sh * 0.175
            clip: true

            delegate: ScrollingRow {
                required property var modelData
                required property int index

                list: childList
                rowIndex: index
                focused: focusRow === 1
                text: showRoot.childLabel(modelData)
                detail: showRoot.hasResume(modelData) ? "RSUM" : (modelData.sizeText || "")
            }
        }
    }

    component ScrollingRow: Item {
        id: rowRoot

        property var list
        property int rowIndex: -1
        property bool focused: true
        property string text: ""
        property string detail: ""
        readonly property bool selected: list.currentIndex === rowIndex && focused

        width: list.width
        height: root.sh * 0.0583333

        Item {
            id: textClip
            width: Math.min(rowText.implicitWidth + detailText.width + root.sw * 0.035, parent.width)
            height: parent.height
            clip: true

            Rectangle {
                color: root.accentColor
                anchors.fill: rowText
                visible: selected
            }

            Text {
                id: rowText
                text: rowRoot.text
                color: rowRoot.selected ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                x: 0
                topPadding: root.sh * 0.0041667
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                bottomPadding: root.sh * 0.00625
                font.pixelSize: root.sh * 0.05
            }

            SequentialAnimation {
                running: rowRoot.selected && rowText.implicitWidth > textClip.width
                loops: Animation.Infinite
                onRunningChanged: if (!running) rowText.x = 0
                PauseAnimation { duration: 1500 }
                NumberAnimation {
                    target: rowText; property: "x"
                    to: textClip.width - rowText.implicitWidth
                    duration: Math.abs(to) * 20
                }
                PauseAnimation { duration: 2000 }
                PropertyAction { target: rowText; property: "x"; value: 0 }
            }
        }

        Text {
            id: detailText
            visible: rowRoot.detail !== ""
            text: rowRoot.detail
            color: rowRoot.selected ? root.secondaryColor : root.tertiaryColor
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
}
