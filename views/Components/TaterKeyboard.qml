pragma ComponentBehavior: Bound

import QtQuick

FocusScope {
    id: keyboard

    property var target: null
    property string prompt: "ENTER TEXT"
    property bool password: false
    property var acceptedCallback: null
    property var canceledCallback: null
    property int currentRow: 0
    property int currentColumn: 0
    property bool uppercase: false
    property real screenWidth: width
    property real screenHeight: height
    property color primaryColor: "#FFFFFF"
    property color secondaryColor: "#E8E8E8"
    property color surfaceColor: "#050505"
    property color accentColor: "#FF4A00"
    property string fontFamily: ""
    property var keyRows: [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
        [".", "-", "_", "@", ":", "/", "\\", "!", "#", "$"],
        ["SHIFT", "SPACE", "BACK", "CLEAR", "DONE"]
    ]

    visible: false
    focus: visible

    function open(targetItem, label, hideText, onAccepted, onCanceled) {
        keyboard.target = targetItem
        keyboard.prompt = label || "ENTER TEXT"
        keyboard.password = !!hideText
        keyboard.acceptedCallback = onAccepted || null
        keyboard.canceledCallback = onCanceled || null
        keyboard.currentRow = 0
        keyboard.currentColumn = 0
        keyboard.uppercase = false
        keyboard.visible = true
        Qt.callLater(function() {
            keyboard.forceActiveFocus()
        })
    }

    function dismiss() {
        keyboard.visible = false
        keyboard.target = null
        keyboard.acceptedCallback = null
        keyboard.canceledCallback = null
    }

    function close(accepted) {
        var callback = accepted
                ? keyboard.acceptedCallback : keyboard.canceledCallback
        var focusTarget = keyboard.target
        keyboard.dismiss()
        if (typeof callback === "function")
            callback()
        else if (focusTarget && focusTarget.forceActiveFocus)
            focusTarget.forceActiveFocus()
    }

    function selectedKey() {
        var row = keyboard.keyRows[keyboard.currentRow] || []
        return row[keyboard.currentColumn] || ""
    }

    function activateSelectedKey() {
        if (!keyboard.target) {
            keyboard.close(false)
            return
        }

        var key = keyboard.selectedKey()
        if (key === "DONE") {
            keyboard.close(true)
        } else if (key === "SHIFT") {
            keyboard.uppercase = !keyboard.uppercase
        } else if (key === "SPACE") {
            keyboard.target.text += " "
        } else if (key === "BACK") {
            keyboard.target.text = keyboard.target.text.substring(
                        0, Math.max(0, keyboard.target.text.length - 1))
        } else if (key === "CLEAR") {
            keyboard.target.text = ""
        } else {
            keyboard.target.text += keyboard.uppercase
                    ? key.toUpperCase() : key
        }
    }

    function moveRow(direction) {
        keyboard.currentRow = Math.max(
                    0, Math.min(keyboard.keyRows.length - 1,
                                keyboard.currentRow + direction))
        keyboard.currentColumn = Math.min(
                    keyboard.currentColumn,
                    (keyboard.keyRows[keyboard.currentRow] || []).length - 1)
    }

    function moveColumn(direction) {
        var row = keyboard.keyRows[keyboard.currentRow] || []
        keyboard.currentColumn = Math.max(
                    0, Math.min(row.length - 1,
                                keyboard.currentColumn + direction))
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Left) {
            keyboard.moveColumn(-1)
        } else if (event.key === Qt.Key_Right) {
            keyboard.moveColumn(1)
        } else if (event.key === Qt.Key_Up) {
            keyboard.moveRow(-1)
        } else if (event.key === Qt.Key_Down) {
            keyboard.moveRow(1)
        } else if (event.key === Qt.Key_Return
                   || event.key === Qt.Key_Enter
                   || event.key === Qt.Key_Space) {
            keyboard.activateSelectedKey()
        } else if (event.key === Qt.Key_Backspace) {
            if (keyboard.target) {
                keyboard.target.text = keyboard.target.text.substring(
                            0, Math.max(0, keyboard.target.text.length - 1))
            }
        } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            keyboard.close(false)
        } else {
            return
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        color: keyboard.surfaceColor
        opacity: 0.98
    }

    Column {
        id: keyboardPanel
        anchors.centerIn: parent
        width: keyboard.screenWidth * 0.82
        spacing: keyboard.screenHeight * 0.012

        Text {
            text: keyboard.prompt
            width: keyboardPanel.width
            horizontalAlignment: Text.AlignHCenter
            color: keyboard.secondaryColor
            font.family: keyboard.fontFamily
            font.capitalization: Font.AllUppercase
            font.pixelSize: keyboard.screenHeight * 0.034
        }

        Rectangle {
            width: keyboardPanel.width
            height: keyboard.screenHeight * 0.065
            color: "transparent"
            border.color: keyboard.secondaryColor
            border.width: Math.max(1, keyboard.screenHeight * 0.002)

            Text {
                anchors.fill: parent
                anchors.leftMargin: keyboard.screenWidth * 0.012
                anchors.rightMargin: keyboard.screenWidth * 0.012
                verticalAlignment: Text.AlignVCenter
                text: keyboard.target
                      ? (keyboard.password
                         ? "\u2022".repeat(keyboard.target.text.length)
                         : keyboard.target.text)
                      : ""
                color: keyboard.primaryColor
                font.family: keyboard.fontFamily
                font.pixelSize: keyboard.screenHeight * 0.038
                elide: Text.ElideLeft
            }
        }

        Repeater {
            model: keyboard.keyRows

            delegate: Row {
                id: keyboardRowDelegate
                required property int index
                required property var modelData
                property int rowIndex: index
                property var rowKeys: modelData
                width: keyboardPanel.width
                height: keyboard.screenHeight * 0.064
                spacing: keyboard.screenWidth * 0.005

                Repeater {
                    model: keyboardRowDelegate.rowKeys

                    delegate: Rectangle {
                        id: keyboardKeyDelegate
                        required property int index
                        required property string modelData
                        property bool selected:
                            keyboard.currentRow === keyboardRowDelegate.rowIndex
                            && keyboard.currentColumn === index
                        width: (keyboardPanel.width
                                - keyboardRowDelegate.spacing
                                  * (keyboardRowDelegate.rowKeys.length - 1))
                               / keyboardRowDelegate.rowKeys.length
                        height: keyboardRowDelegate.height
                        color: selected ? keyboard.accentColor : "transparent"
                        border.color: keyboard.secondaryColor
                        border.width: selected
                                      ? 0 : Math.max(
                                          1, keyboard.screenHeight * 0.001)

                        Text {
                            anchors.centerIn: parent
                            text: {
                                if (keyboardKeyDelegate.modelData === "SHIFT")
                                    return keyboard.uppercase ? "LOWER" : "SHIFT"
                                if (keyboardKeyDelegate.modelData.length === 1
                                        && keyboard.uppercase) {
                                    return keyboardKeyDelegate.modelData.toUpperCase()
                                }
                                return keyboardKeyDelegate.modelData
                            }
                            color: keyboardKeyDelegate.selected
                                   ? keyboard.surfaceColor : keyboard.primaryColor
                            font.family: keyboard.fontFamily
                            font.pixelSize:
                                keyboardKeyDelegate.modelData.length > 1
                                ? keyboard.screenHeight * 0.024
                                : keyboard.screenHeight * 0.036
                        }
                    }
                }
            }
        }

        Text {
            text: "D-PAD: MOVE   A: SELECT   B: CANCEL"
            width: keyboardPanel.width
            horizontalAlignment: Text.AlignHCenter
            color: keyboard.secondaryColor
            font.family: keyboard.fontFamily
            font.pixelSize: keyboard.screenHeight * 0.022
        }
    }
}
