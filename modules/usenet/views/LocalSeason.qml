pragma ComponentBehavior: Bound

import QtQuick
import Components

FocusScope {
    id: seasonRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var item: navParams.item || {}
    property string showTitle: navParams.showTitle || item.seriesTitle || ""
    property string libraryName: navParams.libraryName || "LOCAL"
    property var episodes: []
    property bool isLoading: false
    property int focusRow: 0

    function numericValue(value, fallback) {
        var number = Number(value)
        return isFinite(number) ? number : (fallback || 0)
    }

    function hasResume(row) {
        return numericValue(row && row.viewOffset, 0) > 0
                || numericValue(row && row.viewOffsetSeconds, 0) > 0
    }

    function bestEpisode(rows) {
        rows = rows || []
        for (var i = 0; i < rows.length; i++) {
            if (hasResume(rows[i]))
                return rows[i]
        }
        return rows.length > 0 ? rows[0] : null
    }

    function episodeLabel(row) {
        if (!row)
            return ""
        var title = row.title || ""
        if (title.match(/^S\d+E\d+/i))
            return title
        var path = row.path || ""
        var match = path.match(/s(\d+)[ ._-]*e(\d+)/i)
        if (match)
            return "S" + match[1] + "E" + match[2] + ": " + title
        return title
    }

    function seasonSubtitle() {
        var parts = []
        if ((item.title || "") !== "")
            parts.push(item.title)
        if (episodes.length > 0)
            parts.push(episodes.length + (episodes.length === 1 ? " EPISODE" : " EPISODES"))
        return parts.join(" - ")
    }

    function playEpisode(row) {
        if (!row)
            return
        var episode = Object.assign({}, row)
        if (!episode.seriesTitle)
            episode.seriesTitle = showTitle
        navigateTo("LocalPlayer.qml", {
            item: episode,
            title: episode.title || "EPISODE"
        }, { currentIndex: episodeList.currentIndex })
    }

    function playBestEpisode() {
        playEpisode(bestEpisode(episodes))
    }

    Connections {
        target: usenetBackend

        function onItemsLoaded(categoryTitle, rows) {
            seasonRoot.isLoading = false
            seasonRoot.episodes = rows || []
            if (seasonRoot.episodes.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                episodeList.currentIndex = Math.min(restore, seasonRoot.episodes.length - 1)
                episodeList.positionViewAtIndex(episodeList.currentIndex, ListView.Contain)
            }
        }

        function onErrorOccurred(message) {
            seasonRoot.isLoading = false
        }
    }

    Component.onCompleted: {
        isLoading = true
        focusRow = 0
        usenetBackend.load_local_items(item.categoryId || "", item.path || "",
                                       item.sourceIndex || 0, item.title || "Season")
    }

    focus: true

    Keys.onUpPressed: {
        if (focusRow === 1) {
            if (episodeList.currentIndex > 0)
                episodeList.currentIndex--
            else
                focusRow = 0
        }
    }
    Keys.onDownPressed: {
        if (focusRow === 0) {
            if (episodes.length > 0)
                focusRow = 1
        } else if (episodeList.currentIndex < episodes.length - 1) {
            episodeList.currentIndex++
        }
    }
    Keys.onLeftPressed: {
        if (focusRow === 1 && episodeList.count > 0) {
            var rows = Math.max(1, Math.floor(episodeList.height / (root.sh * 0.0583333)) - 1)
            episodeList.currentIndex = Math.max(0, episodeList.currentIndex - rows)
            episodeList.positionViewAtIndex(episodeList.currentIndex, ListView.Contain)
        }
    }
    Keys.onRightPressed: {
        if (focusRow === 1 && episodeList.count > 0) {
            var rows = Math.max(1, Math.floor(episodeList.height / (root.sh * 0.0583333)) - 1)
            episodeList.currentIndex = Math.min(episodeList.count - 1, episodeList.currentIndex + rows)
            episodeList.positionViewAtIndex(episodeList.currentIndex, ListView.Contain)
        }
    }
    Keys.onReturnPressed: {
        if (focusRow === 0) {
            playBestEpisode()
        } else {
            playEpisode(episodes[episodeList.currentIndex])
        }
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
            id: seasonDetails
            height: root.sh * 0.175
            spacing: root.sw * 0.0375

            Rectangle {
                color: focusRow === 0 ? root.accentColor : root.surfaceColor
                border.color: focusRow === 0 ? root.accentColor : root.tertiaryColor
                width: root.sw * 0.1875
                height: root.sh * 0.1166667
                border.width: root.sh * 0.003125

                Text {
                    anchors.centerIn: parent
                    text: {
                        for (var i = 0; i < seasonRoot.episodes.length; i++) {
                            if (seasonRoot.hasResume(seasonRoot.episodes[i]))
                                return "RSUM \u25BA"
                        }
                        return "PLAY \u25BA"
                    }
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
                    text: showTitle || item.title || ""
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.05
                }

                Text {
                    text: seasonSubtitle()
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.0333333
                }
            }
        }

        Text {
            id: episodeListLabel
            anchors.top: seasonDetails.bottom
            text: "Episodes:"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.topMargin: root.sh * 0.0145833
            leftPadding: root.sw * 0.009375
            rightPadding: root.sw * 0.009375
            font.pixelSize: root.sh * 0.0291667
        }

        ListView {
            id: episodeList
            model: episodes
            anchors.top: episodeListLabel.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.sh * 0.0145833
            height: root.sh * 0.2916667
            clip: true

            delegate: ScrollingRow {
                required property var modelData
                required property int index

                list: episodeList
                rowIndex: index
                focused: focusRow === 1
                text: seasonRoot.episodeLabel(modelData)
                detail: seasonRoot.hasResume(modelData) ? "RSUM" : (modelData.durationDisplay || modelData.sizeText || "")
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
