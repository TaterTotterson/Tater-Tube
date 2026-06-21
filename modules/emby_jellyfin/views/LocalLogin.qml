import QtQuick
import Components

FocusScope {
    id: loginRoot

    property var navParams: ({})

    signal replaceWith(string path, var params)
    signal goBack()

    property int focusRow: 0
    property bool isSigningIn: false
    property string errorMessage: ""

    function focusCurrentField() {
        if (focusRow === 0) serverField.forceInputFocus()
        else if (focusRow === 1) userField.forceInputFocus()
        else if (focusRow === 2) passwordField.forceInputFocus()
        else signInButton.forceActiveFocus()
    }

    function focusPrevious() {
        if (focusRow > 0) {
            focusRow--
            focusCurrentField()
        }
    }

    function focusNext() {
        if (focusRow < 3) {
            focusRow++
            focusCurrentField()
        }
    }

    function submit() {
        if (isSigningIn) return
        errorMessage = ""
        isSigningIn = true
        embyBackend.login(serverField.text, userField.text, passwordField.text)
    }

    Connections {
        target: embyBackend
        function onAuthSuccess() {
            loginRoot.isSigningIn = false
            loginRoot.replaceWith("Libraries.qml", {})
        }
        function onErrorOccurred(msg) {
            loginRoot.isSigningIn = false
            loginRoot.errorMessage = msg
        }
    }

    Component.onCompleted: {
        serverField.text = embyBackend.get_saved_server_url() || "http://"
        focusCurrentField()
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            loginRoot.goBack()
            event.accepted = true
        }
    }

    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: "LOCAL SERVER SIGN IN"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Column {
        id: form
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        spacing: root.sh * 0.025

        LoginField {
            id: serverField
            label: "SERVER URL"
            selected: loginRoot.focusRow === 0
        }

        LoginField {
            id: userField
            label: "USERNAME"
            selected: loginRoot.focusRow === 1
        }

        LoginField {
            id: passwordField
            label: "PASSWORD"
            selected: loginRoot.focusRow === 2
            password: true
        }

        Rectangle {
            id: signInButton
            width: form.width
            height: root.sh * 0.0583333
            color: loginRoot.focusRow === 3 ? root.accentColor : "transparent"
            focus: loginRoot.focusRow === 3

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.009375
                text: loginRoot.isSigningIn ? "SIGNING IN..." : "SIGN IN"
                color: loginRoot.focusRow === 3 ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.05
            }

            Keys.onUpPressed: loginRoot.focusPrevious()
            Keys.onDownPressed: loginRoot.focusNext()
            Keys.onReturnPressed: loginRoot.submit()
            Keys.onEnterPressed: loginRoot.submit()
        }
    }

    Text {
        visible: errorMessage !== ""
        text: errorMessage
        color: root.tertiaryColor
        font.family: root.globalFont
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        anchors.left: form.left
        anchors.right: form.right
        anchors.top: form.bottom
        anchors.topMargin: root.sh * 0.035
        font.pixelSize: root.sh * 0.0333333
    }

    component LoginField: Item {
        property alias text: fieldInput.text
        property string label: ""
        property bool selected: false
        property bool password: false

        function forceInputFocus() {
            fieldInput.forceActiveFocus()
        }

        width: form.width
        height: root.sh * 0.0916667

        Rectangle {
            anchors.fill: parent
            color: selected ? root.accentColor : "transparent"
        }

        Text {
            id: fieldLabel
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: root.sw * 0.009375
            text: label
            color: selected ? root.surfaceColor : root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.0291667
        }

        TextInput {
            id: fieldInput
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: fieldLabel.bottom
            anchors.leftMargin: root.sw * 0.009375
            anchors.rightMargin: root.sw * 0.009375
            height: root.sh * 0.05
            focus: selected
            echoMode: password ? TextInput.Password : TextInput.Normal
            color: selected ? root.surfaceColor : root.primaryColor
            selectedTextColor: root.surfaceColor
            selectionColor: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.0416667
            clip: true

            Keys.onUpPressed: loginRoot.focusPrevious()
            Keys.onDownPressed: loginRoot.focusNext()
            Keys.onReturnPressed: loginRoot.focusNext()
            Keys.onEnterPressed: loginRoot.focusNext()
        }
    }
}
