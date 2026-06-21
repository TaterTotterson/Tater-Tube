import QtQuick

Rectangle {
    id: noSignalRoot

    property string inputLabel: "VIDEO 1"
    property string message: "NO SIGNAL"
    property string detail: ""

    color: "#001EA8"

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: "white"
        border.width: 2
        anchors.margins: root.sw * 0.035
    }

    Column {
        anchors.centerIn: parent
        spacing: root.sh * 0.035

        Text {
            text: noSignalRoot.inputLabel
            color: "white"
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.0333333
        }

        Text {
            text: noSignalRoot.message
            color: "white"
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.0833333
        }

        Text {
            visible: noSignalRoot.detail !== ""
            text: noSignalRoot.detail
            color: "white"
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.0333333
        }
    }
}
