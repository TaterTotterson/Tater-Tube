pragma ComponentBehavior: Bound

import QtQuick
import Components

FocusScope {
    id: showRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack

    property var item: navParams.item || {}
    property string libraryName: navParams.libraryName || "LOCAL"
    property var rows: []
    property bool isLoading: false
    property string errorText: ""

    readonly property bool rowsAreEpisodes: rows.length > 0 && (rows[0].type || "") === "localFile"
    readonly property bool rowsAreSeries: containsSeries(rows)

    function containsSeries(sourceRows) {
        for (var i = 0; i < (sourceRows || []).length; i++) {
            var row = sourceRows[i] || {};
            if ((row.type || "") === "localFolder"
                    && String(row.mediaType || "").toLowerCase() === "show")
                return true;
        }
        return false;
    }

    function activeList() {
        return rowsAreSeries ? seriesList : childList;
    }

    function seriesTapeNumber(index) {
        var value = String(Math.max(0, index) + 1);
        while (value.length < 3)
            value = "0" + value;
        return value;
    }

    function numericValue(value, fallback) {
        var number = Number(value);
        return isFinite(number) ? number : (fallback || 0);
    }

    function hasResume(row) {
        return numericValue(row && row.viewOffset, 0) > 0 || numericValue(row && row.viewOffsetSeconds, 0) > 0;
    }

    function playEpisode(row) {
        if (!row)
            return;
        var episode = Object.assign({}, row);
        if (!episode.seriesTitle)
            episode.seriesTitle = item.title || "";
        navigateTo("LocalPlayer.qml", {
            item: episode,
            title: episode.title || "EPISODE"
        }, {
            currentIndex: activeList().currentIndex
        });
    }

    function openRow(row) {
        if (!row)
            return;
        var type = String(row.type || "");
        if (type === "localFile") {
            playEpisode(row);
            return;
        }
        if (type === "localFolder") {
            if (String(row.mediaType || "").toLowerCase() === "show") {
                navigateTo("LocalShow.qml", {
                    item: row,
                    libraryName: libraryName
                }, {
                    currentIndex: activeList().currentIndex
                });
                return;
            }
            navigateTo("LocalSeason.qml", {
                item: row,
                showTitle: item.title || "",
                libraryName: libraryName
            }, {
                currentIndex: activeList().currentIndex
            });
            return;
        }
        errorText = "SEASON UNAVAILABLE";
    }

    function childLabel(row) {
        if (!row)
            return "";
        var title = row.title || "";
        if ((row.type || "") !== "localFile")
            return title;
        if (title.match(/^S\d+E\d+/i))
            return title;
        var path = row.path || "";
        var match = path.match(/s(\d+)[ ._-]*e(\d+)/i);
        if (match)
            return "S" + match[1] + "E" + match[2] + ": " + title;
        return title;
    }

    function showSubtitle() {
        var parts = [];
        if (rows.length > 0) {
            if (rowsAreEpisodes)
                parts.push(rows.length + (rows.length === 1 ? " EPISODE" : " EPISODES"));
            else
                parts.push(rows.length + (rows.length === 1 ? " SEASON" : " SEASONS"));
        }
        if ((item.path || "") !== "")
            parts.push(item.path);
        return parts.join(" - ");
    }

    Connections {
        target: usenetBackend

        function onItemsLoaded(categoryTitle, loadedRows) {
            showRoot.isLoading = false;
            showRoot.rows = loadedRows || [];
            showRoot.errorText = showRoot.rows.length === 0 ? "NO SEASONS FOUND" : "";
            if (showRoot.rows.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0;
                var list = showRoot.activeList();
                list.currentIndex = Math.min(restore, showRoot.rows.length - 1);
                list.positionViewAtIndex(list.currentIndex, ListView.Contain);
            }
        }

        function onErrorOccurred(message) {
            showRoot.isLoading = false;
            showRoot.errorText = message || "SERIES LOAD FAILED";
        }
    }

    Component.onCompleted: {
        isLoading = true;
        errorText = "";
        usenetBackend.load_local_items(item.categoryId || "", item.path || "", item.sourceIndex || 0, item.title || "Show");
    }

    focus: true

    Keys.onUpPressed: {
        var list = activeList();
        if (list.currentIndex > 0)
            list.currentIndex--;
    }
    Keys.onDownPressed: {
        var list = activeList();
        if (list.currentIndex < rows.length - 1)
            list.currentIndex++;
    }
    Keys.onLeftPressed: {
        var list = activeList();
        if (list.count > 0) {
            var rowHeight = rowsAreSeries ? root.sh * 0.0525 : root.sh * 0.0583333;
            var pageRows = Math.max(1, Math.floor(list.height / rowHeight) - 1);
            list.currentIndex = Math.max(0, list.currentIndex - pageRows);
            list.positionViewAtIndex(list.currentIndex, ListView.Contain);
        }
    }
    Keys.onRightPressed: {
        var list = activeList();
        if (list.count > 0) {
            var rowHeight = rowsAreSeries ? root.sh * 0.0525 : root.sh * 0.0583333;
            var pageRows = Math.max(1, Math.floor(list.height / rowHeight) - 1);
            list.currentIndex = Math.min(list.count - 1, list.currentIndex + pageRows);
            list.positionViewAtIndex(list.currentIndex, ListView.Contain);
        }
    }
    Keys.onReturnPressed: {
        openRow(rows[activeList().currentIndex]);
    }
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack();
            event.accepted = true;
        }
    }

    StaticBackground {
        anchors.fill: parent
        themeName: root.currentTheme
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
        visible: !isLoading && !rowsAreSeries
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true

        Row {
            id: showDetails
            height: root.sh * 0.2416667
            spacing: root.sw * 0.0375

            Rectangle {
                color: root.surfaceColor
                border.color: root.accentColor
                width: root.sw * 0.1875
                height: root.sh * 0.1166667
                border.width: root.sh * 0.003125

                Text {
                    anchors.centerIn: parent
                    text: "SERIES"
                    color: root.primaryColor
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
                        text: rowsAreEpisodes ? "SERVER LOCAL EPISODE INDEX" : "SERVER LOCAL SEASON INDEX"
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
            id: showError
            visible: errorText !== ""
            anchors.top: showDetails.bottom
            text: errorText
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            leftPadding: root.sw * 0.009375
            font.pixelSize: root.sh * 0.0291667
        }

        Text {
            id: childListLabel
            visible: rows.length > 0
            anchors.top: showError.visible ? showError.bottom : showDetails.bottom
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
            visible: rows.length > 0
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
                focused: true
                text: showRoot.childLabel(modelData)
                detail: (modelData.type || "") === "localFolder" ? "OPEN" : (showRoot.hasResume(modelData) ? "RSUM" : (modelData.durationDisplay || modelData.sizeText || ""))
            }
        }
    }

    Item {
        id: seriesArchive
        visible: !isLoading && rowsAreSeries
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.235
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.555

        Rectangle {
            id: seriesArchiveHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.062
            color: root.surfaceColor
            border.color: root.accentColor
            border.width: Math.max(1, root.sh * 0.0025)

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: root.sw * 0.012
                color: root.accentColor
            }

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.sw * 0.028
                text: "SERIES ARCHIVE"
                color: root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.04
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: root.sw * 0.014
                text: rows.length + (rows.length === 1 ? " TAPE" : " TAPES")
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.027
            }
        }

        Item {
            id: seriesColumnHeader
            anchors.top: seriesArchiveHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.036

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.sw * 0.014
                text: "TAPE"
                color: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.022
            }

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.sw * 0.13
                text: "PROGRAM TITLE"
                color: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.022
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: root.sw * 0.014
                text: "MODE"
                color: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.022
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(1, root.sh * 0.0015)
                color: root.tertiaryColor
                opacity: 0.65
            }
        }

        ListView {
            id: seriesList
            anchors.top: seriesColumnHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            model: rows
            clip: true

            delegate: Item {
                id: seriesRow
                required property var modelData
                required property int index
                readonly property bool selected: seriesList.currentIndex === index

                width: seriesList.width
                height: root.sh * 0.0525

                Rectangle {
                    anchors.fill: parent
                    color: root.accentColor
                    opacity: seriesRow.selected ? 0.88 : (seriesRow.index % 2 === 0 ? 0.07 : 0)
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: root.sw * 0.007
                    color: seriesRow.selected ? root.secondaryColor : "transparent"
                }

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: root.sw * 0.014
                    width: root.sw * 0.1
                    text: "T-" + showRoot.seriesTapeNumber(seriesRow.index)
                    color: seriesRow.selected ? root.surfaceColor : root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.028
                }

                Text {
                    anchors.left: parent.left
                    anchors.right: modeText.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: root.sw * 0.13
                    anchors.rightMargin: root.sw * 0.016
                    text: seriesRow.modelData.title || "UNTITLED SERIES"
                    color: seriesRow.selected ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    font.pixelSize: root.sh * 0.038
                }

                Text {
                    id: modeText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: root.sw * 0.014
                    width: root.sw * 0.105
                    text: seriesRow.selected ? "OPEN \u25BA" : "SERIES"
                    color: seriesRow.selected ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    horizontalAlignment: Text.AlignRight
                    font.pixelSize: root.sh * 0.026
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Math.max(1, root.sh * 0.001)
                    color: root.tertiaryColor
                    opacity: seriesRow.selected ? 0 : 0.24
                }
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
                onRunningChanged: if (!running)
                    rowText.x = 0
                PauseAnimation {
                    duration: 1500
                }
                NumberAnimation {
                    target: rowText
                    property: "x"
                    to: textClip.width - rowText.implicitWidth
                    duration: Math.abs(to) * 20
                }
                PauseAnimation {
                    duration: 2000
                }
                PropertyAction {
                    target: rowText
                    property: "x"
                    value: 0
                }
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
