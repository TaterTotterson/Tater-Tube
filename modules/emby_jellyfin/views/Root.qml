import QtQuick

FocusScope {
    id: moduleRoot

    // Exit signal — emitted to leave the module entirely
    signal goBack()

    property var navParams: ({})

    // The module's manifest id — the single place it appears in this module's QML.
    // Child views reference it via moduleRoot.moduleId.
    property string moduleId: "com.240mp.emby_jellyfin"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || ""
    property string moduleIcon: _moduleInfo.icon || ""

    // Internal navigation state
    property var navStack: []
    property var currentParams: ({})

    function loginView() {
        return embyBackend.get_media_provider() === "PLEX" ? "PlexLogin.qml" : "LocalLogin.qml"
    }

    function navigateTo(viewPath, params, fromState) {
        var resolved = Qt.resolvedUrl(viewPath)
        navStack.push({ source: internalLoader.source, params: currentParams, listState: fromState || {} })
        currentParams = params || {}
        internalLoader.setSource(resolved, { "navParams": params || {} })
    }

    function replaceWith(viewPath, params) {
        var resolved = Qt.resolvedUrl(viewPath)
        currentParams = params || {}
        internalLoader.setSource(resolved, { "navParams": params || {} })
    }

    // Repoint the BACK target after autoplay advances in place. The top of the
    // stack is the detail view the player was launched from; swap its item so
    // exiting the player returns to the now-playing episode's detail screen.
    function updateBackItem(item) {
        if (navStack.length === 0) return
        var top = navStack[navStack.length - 1]
        top.params = Object.assign({}, top.params, { item: item })
    }

    function navigateBack() {
        if (navStack.length === 0) {
            moduleRoot.goBack()
            return
        }
        var prev = navStack.pop()
        if (!prev.source || prev.source.toString() === "") {
            moduleRoot.goBack()
            return
        }
        var restored = Object.assign({}, prev.params)
        restored.navListState = prev.listState || {}
        currentParams = restored
        internalLoader.setSource(prev.source, { "navParams": restored })
    }

    Loader {
        id: internalLoader
        anchors.fill: parent
        focus: true
        onLoaded: { if (item) item.forceActiveFocus() }

        Connections {
            target: internalLoader.item
            ignoreUnknownSignals: true
            function onNavigateTo(path, params, listState) { moduleRoot.navigateTo(path, params, listState) }
            function onReplaceWith(path, params) { moduleRoot.replaceWith(path, params) }
            function onGoBack() { moduleRoot.navigateBack() }
            function onUpdateBackItem(item) { moduleRoot.updateBackItem(item) }
        }
    }

    // Handle logout signal from backend: clear stack and go to local sign-in
    Connections {
        target: embyBackend
        function onLogoutComplete() {
            moduleRoot.navStack = []
            moduleRoot.navigateTo(moduleRoot.loginView(), {})
        }
        function onAuthStateChanged() {
            if (embyBackend.get_auth_state() === "authed") {
                moduleRoot.navStack = []
                moduleRoot.replaceWith("Libraries.qml", {})
            }
        }
    }

    Connections {
        target: appCore
        function onModuleSettingChanged(mid, key, value) {
            if (mid !== moduleRoot.moduleId || key !== "media_provider")
                return
            if (embyBackend.get_auth_state() !== "authed") {
                moduleRoot.navStack = []
                moduleRoot.replaceWith(moduleRoot.loginView(), {})
            }
        }
    }

    Component.onCompleted: {
        var state = embyBackend.get_auth_state()
        if (state === "authed") {
            navigateTo("Libraries.qml", {})
        } else {
            navigateTo(loginView(), {})
        }
    }
}
