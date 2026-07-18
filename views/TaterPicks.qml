pragma ComponentBehavior: Bound

import QtQuick
import Components

FocusScope {
    id: picksRoot

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var navParams: ({})
    property var navListState: ({})
    property var picks: []
    property var batch: ({})
    property string narratedBatchId: ""

    focus: true

    function narrationEnabled() {
        var value = appCore.get_setting("com.240mp.usenet", "tater_picks_narration")
        if (value === undefined || value === null || value === "")
            return true
        if (value === true || value === false)
            return value
        var normalized = ("" + value).toUpperCase()
        return normalized !== "OFF" && normalized !== "FALSE"
                && normalized !== "0" && normalized !== "NO"
    }

    function sourceLabel(source) {
        var value = (source || "").toString().toLowerCase()
        if (value === "over_the_air")
            return "LIVE TV"
        if (value === "local_media")
            return "TATER TUBE"
        if (value === "public_access")
            return "PUBLIC ACCESS"
        if (value === "tape_deck")
            return "TAPE DECK"
        return value === "" ? "TATER" : value.replace(/_/g, " ")
    }

    function scheduleBriefing() {
        briefingTimer.stop()
        var batchId = (batch.id || "").toString()
        if (!narrationEnabled() || batchId === "" || batchId === narratedBatchId)
            return
        narratedBatchId = batchId
        briefingTimer.restart()
    }

    function reloadPicks() {
        picks = (appCore.taterRecommendations || []).slice()
        batch = appCore.taterRecommendationBatch || ({})
        if (pickList.count > 0) {
            pickList.currentIndex = Math.max(0, Math.min(pickList.currentIndex, pickList.count - 1))
            pickList.positionViewAtIndex(pickList.currentIndex, ListView.Contain)
        }
        Qt.callLater(scheduleBriefing)
    }

    function selectedPick() {
        if (pickList.currentIndex < 0 || pickList.currentIndex >= picks.length)
            return ({})
        return picks[pickList.currentIndex] || ({})
    }

    function playSelected() {
        var recommendation = selectedPick()
        if (!recommendation.id)
            return
        appCore.stopTaterNarration()
        appCore.sendTaterRecommendationFeedback(recommendation.id, "played")
        var launch = recommendation.launch || ({})
        if (launch.type === "module" && launch.moduleId === "com.240mp.ota") {
            navigateTo("modules/ota/views/Root.qml",
                       { recommendation: recommendation },
                       {
                           currentIndex: pickList.currentIndex,
                           narratedBatchId: batch.id || narratedBatchId
                       })
        } else {
            navigateTo("modules/usenet/views/Root.qml",
                       { recommendation: recommendation },
                       {
                           currentIndex: pickList.currentIndex,
                           narratedBatchId: batch.id || narratedBatchId
                       })
        }
    }

    function dismissSelected() {
        var recommendation = selectedPick()
        if (!recommendation.id)
            return
        appCore.stopTaterNarration()
        appCore.sendTaterRecommendationFeedback(recommendation.id, "not_for_me")
        var next = picks.slice()
        next.splice(pickList.currentIndex, 1)
        picks = next
        if (picks.length === 0) {
            goBack()
            return
        }
        pickList.currentIndex = Math.min(pickList.currentIndex, picks.length - 1)
    }

    function returnToMenu() {
        appCore.stopTaterNarration()
        goBack()
    }

    Component.onCompleted: {
        narratedBatchId = navListState.narratedBatchId || ""
        reloadPicks()
        if (pickList.count > 0 && navListState.currentIndex !== undefined)
            pickList.currentIndex = Math.max(
                        0, Math.min(navListState.currentIndex, pickList.count - 1))
        appCore.refreshTaterRecommendations()
    }
    Component.onDestruction: appCore.stopTaterNarration()

    Timer {
        id: briefingTimer
        interval: 700
        repeat: false
        onTriggered: {
            var batchId = (picksRoot.batch.id || "").toString()
            if (batchId !== "")
                appCore.speakTaterBriefing(batchId)
        }
    }

    Connections {
        target: appCore
        function onTaterRecommendationsChanged() {
            picksRoot.reloadPicks()
        }
    }

    AppBar {
        title: "TATER'S PICKS"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Text {
        id: collectionSummary
        anchors.left: parent.left
        anchors.leftMargin: root.sw * 0.115625
        anchors.top: parent.top
        anchors.topMargin: root.sh * 0.195
        width: root.sw * 0.45
        height: root.sh * 0.065
        text: picksRoot.batch.summary
              || "A HAND-PICKED MIX FROM ACROSS YOUR WATCH HISTORY."
        color: root.secondaryColor
        font.family: root.globalFont
        font.pixelSize: root.sh * 0.021
        font.capitalization: Font.AllUppercase
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
    }

    Image {
        id: picksMascot
        source: "../assets/images/mascots/tater-picks.png"
        anchors.right: parent.right
        anchors.rightMargin: root.sw * 0.035
        anchors.top: narrationStatus.bottom
        anchors.topMargin: root.sh * 0.012
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.sh * 0.035
        width: root.sw * 0.38
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

    Rectangle {
        id: summaryBubble
        anchors.right: parent.right
        anchors.rightMargin: root.sw * 0.055
        anchors.top: parent.top
        anchors.topMargin: root.sh * 0.125
        width: root.sw * 0.36
        height: root.sh * 0.16
        color: root.surfaceColor
        border.color: root.accentColor
        border.width: Math.max(2, root.sh * 0.005)

        Column {
            anchors.fill: parent
            anchors.margins: root.sh * 0.022
            spacing: root.sh * 0.008

            Text {
                width: parent.width
                text: "WHY THIS PICK"
                color: root.accentColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.018
                font.bold: true
            }

            Text {
                width: parent.width
                text: picksRoot.selectedPick().reason
                      || "I FOUND A FEW THINGS WORTH PUTTING ON."
                color: root.primaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.024
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }
    }

    Text {
        id: narrationStatus
        anchors.right: summaryBubble.right
        anchors.top: summaryBubble.bottom
        anchors.topMargin: root.sh * 0.012
        text: appCore.taterNarrating ? "TATER IS TALKING..." : ""
        color: root.secondaryColor
        font.family: root.globalFont
        font.pixelSize: root.sh * 0.019
    }

    ListView {
        id: pickList
        model: picksRoot.picks
        anchors.left: parent.left
        anchors.leftMargin: root.sw * 0.115625
        anchors.top: collectionSummary.bottom
        anchors.topMargin: root.sh * 0.022
        width: root.sw * 0.47
        height: root.sh * 0.43
        clip: true
        focus: true
        currentIndex: 0

        delegate: Item {
            id: pickDelegate
            required property var modelData
            required property int index
            width: pickList.width
            height: root.sh * 0.074

            Rectangle {
                anchors.fill: parent
                anchors.rightMargin: root.sw * 0.025
                color: pickList.currentIndex === pickDelegate.index ? root.accentColor : "transparent"
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.01
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - root.sw * 0.045
                spacing: root.sh * 0.003

                Text {
                    width: parent.width
                    text: pickDelegate.modelData.title || "UNTITLED"
                    color: pickList.currentIndex === pickDelegate.index ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    font.pixelSize: root.sh * 0.041
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: ((pickDelegate.modelData.media_type || "VIDEO") + "  •  "
                           + picksRoot.sourceLabel(pickDelegate.modelData.source))
                    color: pickList.currentIndex === pickDelegate.index ? root.surfaceColor : root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    font.pixelSize: root.sh * 0.021
                    elide: Text.ElideRight
                }
            }
        }

        Keys.onReturnPressed: picksRoot.playSelected()
        Keys.onEnterPressed: picksRoot.playSelected()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_D || event.key === Qt.Key_Delete) {
                picksRoot.dismissSelected()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                picksRoot.returnToMenu()
                event.accepted = true
            }
        }
    }

    Text {
        anchors.left: pickList.left
        anchors.top: pickList.bottom
        anchors.topMargin: root.sh * 0.03
        text: "[ENTER] PLAY    [D] NOT FOR ME    [BACK] RETURN"
        color: root.secondaryColor
        font.family: root.globalFont
        font.pixelSize: root.sh * 0.022
    }
}
