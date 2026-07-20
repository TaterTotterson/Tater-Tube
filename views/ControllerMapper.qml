import QtQuick
import Components

FocusScope {
    id: mapperRoot

    signal goBack()

    property var navParams: ({})
    property var navListState: ({})

    property var steps: [
        { id: "up",     title: "UP",             symbol: "↑",      note: "PRESS DPAD UP" },
        { id: "down",   title: "DOWN",           symbol: "↓",      note: "PRESS DPAD DOWN" },
        { id: "left",   title: "LEFT",           symbol: "←",      note: "PRESS DPAD LEFT" },
        { id: "right",  title: "RIGHT",          symbol: "→",      note: "PRESS DPAD RIGHT" },
        { id: "b",      title: "A BUTTON",       symbol: "A",      note: "BOTTOM FACE / CONFIRM" },
        { id: "a",      title: "B BUTTON",       symbol: "B",      note: "RIGHT FACE / BACK" },
        { id: "y",      title: "X BUTTON",       symbol: "X",      note: "LEFT FACE" },
        { id: "x",      title: "Y BUTTON",       symbol: "Y",      note: "TOP FACE" },
        { id: "select", title: "SELECT",         symbol: "SELECT", note: "COIN / SELECT" },
        { id: "start",  title: "START",          symbol: "START",  note: "START / PAUSE" },
        { id: "l",      title: "LEFT BUMPER",    symbol: "L1",     note: "LEFT SHOULDER" },
        { id: "r",      title: "RIGHT BUMPER",   symbol: "R1",     note: "RIGHT SHOULDER" },
        { id: "l2",     title: "LEFT TRIGGER",   symbol: "L2",     note: "PULL FOR PAGE UP" },
        { id: "r2",     title: "RIGHT TRIGGER",  symbol: "R2",     note: "PULL FOR PAGE DOWN" },
        { id: "l3",     title: "LEFT STICK",     symbol: "L3",     note: "CLICK LEFT STICK" },
        { id: "r3",     title: "RIGHT STICK",    symbol: "R3",     note: "CLICK RIGHT STICK" },
        { id: "menu",   title: "MENU",           symbol: "MENU",   note: "ON SCREEN DISPLAY" },
        { id: "home",   title: "HOME",           symbol: "HOME",   note: "RETURN TO TATER TUBE" }
    ]
    property var bindings: ({})
    property int stepIndex: 0
    property bool saved: false
    property string statusText: inputManager.gamepadConnected ? "READY" : "NO CONTROLLER SIGNAL"

    focus: true

    function currentStep() {
        if (stepIndex < 0 || stepIndex >= steps.length) return null
        return steps[stepIndex]
    }

    function copyInput(input, step) {
        var mapped = {}
        for (var key in input)
            mapped[key] = input[key]
        mapped.step = step.id
        mapped.title = step.title
        return mapped
    }

    function bindingLabel(id) {
        var binding = bindings[id]
        return binding && binding.label ? binding.label : "--"
    }

    function acceptInput(input) {
        if (saved) return
        var step = currentStep()
        if (!step) return

        var updated = Object.assign({}, bindings)
        updated[step.id] = copyInput(input, step)
        bindings = updated
        statusText = "REC " + step.title + " = " + (input.label || input.inputToken || "INPUT")

        if (stepIndex >= steps.length - 1) {
            saveMapping()
        } else {
            stepIndex++
        }
    }

    function skipStep() {
        if (saved) {
            mapperRoot.goBack()
            return
        }
        if (stepIndex >= steps.length - 1)
            saveMapping()
        else
            stepIndex++
    }

    function previousStep() {
        if (!saved)
            stepIndex = Math.max(0, stepIndex - 1)
    }

    function saveMapping() {
        inputManager.endControllerMapping()
        saved = inputManager.saveControllerMapping({ bindings: bindings })
        statusText = saved ? "MAPPING SAVED" : "MAPPING SAVE FAILED"
    }

    Component.onCompleted: {
        var existing = inputManager.getControllerMapping()
        bindings = existing.bindings || {}
        inputManager.beginControllerMapping()
    }

    Component.onDestruction: {
        inputManager.endControllerMapping()
    }

    Connections {
        target: inputManager
        function onControllerMappingInput(input) {
            mapperRoot.acceptInput(input)
        }
        function onGamepadConnectedChanged() {
            if (!mapperRoot.saved)
                mapperRoot.statusText = inputManager.gamepadConnected ? "READY" : "NO CONTROLLER SIGNAL"
        }
    }

    Keys.onLeftPressed: previousStep()
    Keys.onReturnPressed: skipStep()
    Keys.onEnterPressed: skipStep()
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            mapperRoot.goBack()
            event.accepted = true
        }
    }

    AppBar {
        title: "Controller Map"
        subtitle: saved ? "Saved" : "Global"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Rectangle {
        id: tapeDeck
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.sw * 0.115625
        anchors.rightMargin: root.sw * 0.115625
        height: root.sh * 0.52
        color: "black"
        border.color: root.primaryColor
        border.width: 2

        Rectangle {
            anchors.fill: parent
            anchors.margins: root.sw * 0.0125
            color: "transparent"
            border.color: root.tertiaryColor
            border.width: 1
        }

        Text {
            id: counterText
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: root.sh * 0.035
            text: saved ? "MAPPING COMPLETE" : ("INPUT " + (stepIndex + 1) + " / " + steps.length)
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: root.sh * 0.0333333
        }

        Text {
            id: promptSymbol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: counterText.bottom
            anchors.topMargin: root.sh * 0.005
            anchors.leftMargin: root.sw * 0.04
            anchors.rightMargin: root.sw * 0.04
            height: root.sh * 0.205
            text: saved ? "OK" : (currentStep() ? currentStep().symbol : "")
            color: saved ? root.secondaryColor : root.primaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            fontSizeMode: Text.Fit
            minimumPixelSize: root.sh * 0.08
            font.pixelSize: root.sh * 0.19
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: promptSymbol.bottom
            anchors.topMargin: root.sh * 0.01
            anchors.leftMargin: root.sw * 0.05
            anchors.rightMargin: root.sw * 0.05
            spacing: root.sh * 0.018

            Text {
                text: saved ? "SAVED" : (currentStep() ? currentStep().title : "DONE")
                color: root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                fontSizeMode: Text.Fit
                minimumPixelSize: root.sh * 0.035
                elide: Text.ElideRight
                font.pixelSize: root.sh * 0.07
            }

            Text {
                text: saved ? "ALL CORES WILL USE THIS MAP" : (currentStep() ? currentStep().note : "")
                color: root.tertiaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                elide: Text.ElideRight
                font.pixelSize: root.sh * 0.0333333
            }

            Rectangle {
                width: parent.width
                height: root.sh * 0.08
                color: root.accentColor

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: root.sw * 0.018
                    anchors.rightMargin: root.sw * 0.018
                    text: saved ? "PRESS OK" : bindingLabel(currentStep() ? currentStep().id : "")
                    color: root.surfaceColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    fontSizeMode: Text.Fit
                    minimumPixelSize: root.sh * 0.028
                    font.pixelSize: root.sh * 0.05
                }
            }

            Text {
                text: saved ? statusText : (statusText + "  /  OK SKIPS  /  BACK EXITS")
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                elide: Text.ElideRight
                fontSizeMode: Text.Fit
                minimumPixelSize: root.sh * 0.021
                font.pixelSize: root.sh * 0.0291667
            }
        }
    }

    Row {
        anchors.left: tapeDeck.left
        anchors.right: tapeDeck.right
        anchors.top: tapeDeck.bottom
        anchors.topMargin: root.sh * 0.03
        spacing: root.sw * 0.004

        Repeater {
            model: steps.length
            Rectangle {
                width: (tapeDeck.width - (steps.length - 1) * root.sw * 0.004) / steps.length
                height: root.sh * 0.014
                color: index < stepIndex || mapperRoot.saved
                    ? root.accentColor
                    : (index === stepIndex ? root.primaryColor : root.tertiaryColor)
            }
        }
    }
}
