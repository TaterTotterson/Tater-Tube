pragma ComponentBehavior: Bound

import QtQuick
import Components
import "../../shared/TaterBumpers.js" as TaterBumpers

FocusScope {
    id: usenetRoot

    signal goBack()
    signal navigateTo(string path, var params, var listState)

    property var navParams: ({})
    property string moduleId: "com.240mp.usenet"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "THE TUBE"
    property string moduleIcon: _moduleInfo.icon || ""

    property string mode: "loading"
    property string statusText: "LOADING THE TUBE..."
    property var categories: []
    property var subcategories: []
    property var categoryStack: []
    property var itemStack: []
    property var shortcutRows: []
    property var categoryRows: mode === "subcategories" ? subcategories : shortcutRows.concat(categories)
    property var items: []
    property var streams: []
    readonly property bool browsingSeries: mode === "items"
                                                   && items.length > 0
                                                   && String((items[0] || {}).mediaType || "").toLowerCase() === "show"
    property int currentCategoryIndex: 0
    property int currentSubcategoryIndex: 0
    property int currentItemIndex: 0
    property int currentStreamIndex: 0
    property int setupRow: 0
    readonly property int setupConnectRow: 2
    property string currentGroupTitle: ""
    property string currentCategoryTitle: ""
    property string searchQuery: ""
    property string pendingSearchMediaType: ""
    property string pendingRequestId: ""
    property string pendingTitle: ""
    property bool playbackStarted: false
    property string streamInfoText: ""
    property bool currentStreamUsesServer: false
    property var currentPlaybackItem: ({})
    property int currentPlaybackBaseOffsetMs: 0
    property bool currentPlaybackCompleted: false
    property var pendingPlaybackItem: ({})
    property bool nzbMovieBumperActive: false
    property bool nzbStreamResponseReady: false
    property string messageReturnMode: ""

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
        var rowHeight = list === seriesList ? root.sh * 0.0525 : root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(list.height / rowHeight) - 1)
        setListIndex(list, list.currentIndex + direction * rows)
    }

    function activeItemList() {
        return browsingSeries ? seriesList : itemList
    }

    function seriesTapeNumber(index) {
        var value = String(Math.max(0, index) + 1)
        while (value.length < 3)
            value = "0" + value
        return value
    }

    function focusSetupRow() {
        if (setupRow === 0) serverUrlField.forceInputFocus()
        else if (setupRow === 1) pairingPinField.forceInputFocus()
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
        serverUrlField.text = status.serverUrl || ""
        pairingPinField.text = ""
        statusText = message || "ENTER SERVER SETTINGS"
        mode = "setup"
        setupFocusTimer.restart()
    }

    function saveSetup() {
        var serverUrl = (serverUrlField.text || "").trim()
        var pairingPin = (pairingPinField.text || "").trim()

        if (serverUrl === "") {
            statusText = "ENTER SERVER URL"
            setupRow = 0
            focusSetupRow()
            return
        }
        if (pairingPin === "") {
            statusText = "ENTER PAIRING PIN"
            setupRow = 1
            focusSetupRow()
            return
        }

        mode = "loading"
        statusText = "PAIRING PLAYER..."
        usenetBackend.pair_server(serverUrl, pairingPin)
    }

    function refresh() {
        var status = usenetBackend.get_setup_status()
        if (!status.configured) {
            showSetup("ENTER SERVER SETTINGS")
            return
        }
        loadCategories()
    }

    function loadCategories() {
        if (mode === "categories" || mode === "subcategories" ||
                mode === "items" || mode === "search")
            messageReturnMode = mode
        mode = "loading"
        statusText = "LOADING CATEGORIES..."
        usenetBackend.load_categories()
    }

    function showSearch() {
        mode = "search"
        statusText = "SEARCH STREAM"
        searchField.text = searchQuery
        searchFocusTimer.restart()
    }

    function runSearch() {
        var query = (searchField.text || "").trim()
        searchForTitle(query, "")
    }

    function searchForTitle(query, mediaTypeHint) {
        query = (query || "").trim()
        searchQuery = query
        if (query.length < 3) {
            pendingSearchMediaType = ""
            statusText = "ENTER 3 OR MORE LETTERS"
            searchFocusTimer.restart()
            return
        }
        pendingSearchMediaType = String(mediaTypeHint || "").toLowerCase()
        currentCategoryTitle = "Search: " + query
        messageReturnMode = mode
        mode = "loading"
        statusText = "SEARCHING " + query
        usenetBackend.search_items(query)
    }

    function cleanUpper(value) {
        return String(value || "").trim().toUpperCase()
    }

    function queryValue(url, key) {
        var escaped = String(key || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
        var match = String(url || "").match(new RegExp("[?&]" + escaped + "=([^&]*)"))
        if (!match)
            return ""
        return decodeURIComponent(String(match[1]).replace(/\+/g, " "))
    }

    function profileLabel(value) {
        var profile = cleanUpper(value).replace(/_/g, " ")
        if (profile === "CRT 480P")
            return "CRT 480P"
        if (profile === "HDMI 1080P")
            return "HDMI 1080P"
        if (profile === "HDMI 4K")
            return "HDMI 4K"
        return profile
    }

    function formatRate(bytesPerSecond) {
        var value = Number(bytesPerSecond || 0)
        if (!isFinite(value) || value <= 0)
            return ""
        if (value >= 1024 * 1024)
            return (value / (1024 * 1024)).toFixed(1) + " MB/S"
        if (value >= 1024)
            return Math.round(value / 1024) + " KB/S"
        return Math.round(value) + " B/S"
    }

    function plannedStreamInfo(playbackUrl) {
        if (queryValue(playbackUrl, "transcode") === "0")
            return "SERVER STREAM | DIRECT PLAY"

        var profile = profileLabel(queryValue(playbackUrl, "profile"))
        var parts = ["SERVER TRANSCODE", "HW AUTO"]
        if (profile !== "")
            parts.push(profile)
        return parts.join(" | ")
    }

    function numericValue(value, fallback) {
        var number = Number(value)
        return isFinite(number) ? number : (fallback || 0)
    }

    function itemViewOffsetMs(item) {
        if (!item)
            return 0
        var offset = numericValue(item.viewOffset, 0)
        if (offset <= 0)
            offset = numericValue(item.viewOffsetSeconds, 0) * 1000
        return Math.max(0, Math.round(offset))
    }

    function itemDurationMs(item) {
        if (!item)
            return 0
        var duration = numericValue(item.duration, 0)
        if (duration > 0)
            return Math.round(duration * 1000)
        duration = numericValue(item.durationSeconds, 0)
        return duration > 0 ? Math.round(duration * 1000) : 0
    }

    function urlWithStartOffset(url, offset) {
        if (!url || !offset || offset <= 0)
            return url
        var hashIndex = url.indexOf("#")
        var base = hashIndex >= 0 ? url.slice(0, hashIndex) : url
        var hash = hashIndex >= 0 ? url.slice(hashIndex) : ""
        var separator = base.indexOf("?") >= 0 ? "&" : "?"
        return base + separator + "start=" + encodeURIComponent(offset.toFixed(3)) + hash
    }

    function itemDetail(row) {
        if (itemViewOffsetMs(row) > 0)
            return "RSUM"
        return row.sizeText || row.date || ""
    }

    function hasPlaybackStateItem() {
        return currentPlaybackItem
                && ((currentPlaybackItem.playStateId || "") !== ""
                    || (currentPlaybackItem.path || "") !== "")
                && (currentPlaybackItem.type || "") === "localFile"
    }

    function currentPlaybackPositionMs() {
        var position = numericValue(mpvController.position, 0)
        if (currentPlaybackBaseOffsetMs > 0 && position < currentPlaybackBaseOffsetMs)
            position += currentPlaybackBaseOffsetMs
        return Math.max(0, Math.round(position))
    }

    function currentPlaybackDurationMs() {
        var duration = numericValue(mpvController.duration, 0)
        var itemDuration = itemDurationMs(currentPlaybackItem)
        if (duration <= 0 || (itemDuration > 0 && duration < currentPlaybackPositionMs()))
            duration = itemDuration
        return Math.max(0, Math.round(duration))
    }

    function saveCurrentPlayState(completed) {
        if (!hasPlaybackStateItem() || currentPlaybackCompleted)
            return
        var positionMs = currentPlaybackPositionMs()
        var durationMs = currentPlaybackDurationMs()
        currentPlaybackCompleted = completed === true
        usenetBackend.save_play_state({
            playStateId: currentPlaybackItem.playStateId || "",
            seriesId: currentPlaybackItem.seriesStateId || "",
            title: currentPlaybackItem.title || "LOCAL",
            seriesTitle: currentPlaybackItem.seriesTitle || "",
            mediaType: currentPlaybackItem.mediaType || "",
            categoryId: currentPlaybackItem.categoryId || "",
            sourceIndex: currentPlaybackItem.sourceIndex || 0,
            path: currentPlaybackItem.path || "",
            positionMs: completed ? durationMs : positionMs,
            durationMs: durationMs,
            completed: completed === true
        })
    }

    function streamInfoFromActiveStream(row) {
        if (!row)
            return ""

        var status = cleanUpper(row["status"])
        var speed = formatRate(row["bytes_per_second"])
        var profile = profileLabel(row["transcode_name"] || row["transcode_profile"])
        var codec = cleanUpper(row["video_codec"])
        var accel = cleanUpper(row["hardware_acceleration"])
        var parts = []

        if (row["transcoded"] === true) {
            if (row["hardware_active"] === true && accel !== "")
                parts.push("HW " + accel)
            else
                parts.push("SOFTWARE")
            if (codec !== "")
                parts.push(codec)
            if (profile !== "")
                parts.push(profile)
        } else {
            parts.push(status === "STARTING" || status === "BUFFERING"
                       ? "SERVER STREAM" : "DIRECT PLAY")
        }

        if (speed !== "")
            parts.push(speed)
        if (status !== "" && status !== "TRANSCODING")
            parts.push(status)
        return parts.join(" | ")
    }

    function updateStreamOverlayInfo(info) {
        var text = cleanUpper(info)
        if (text === "")
            return
        streamInfoText = text
        if (mpvController.running)
            mpvController.sendScriptMessage("240mp-ota-stream-info", streamInfoText)
    }

    function refreshActiveStreamInfo() {
        if (!currentStreamUsesServer || !playbackStarted || mode !== "playing" || !mpvController.running)
            return
        usenetBackend.load_active_streams()
    }

    function browseCategory(row) {
        if (!row) return
        if (row.type === "tubeTv" || row.type === "localTvMenu") {
            navigateTo("TubeTvMenu.qml", { categories: categories }, { currentIndex: categoryList.currentIndex })
            return
        }
        messageReturnMode = mode
        currentCategoryTitle = row.fullTitle || row.title || "CATEGORY"
        mode = "loading"
        if (row.type === "trending") {
            statusText = "LOADING " + currentCategoryTitle
            usenetBackend.load_trending(row.category || "", row.time || "", currentCategoryTitle)
        } else if (row.type === "discover") {
            statusText = "LOADING " + currentCategoryTitle
            usenetBackend.load_discover(row.id || "", currentCategoryTitle)
        } else if (row.type === "continue") {
            statusText = "LOADING CONTINUE WATCHING"
            usenetBackend.load_continue_watching()
        } else if (row.type === "local") {
            statusText = "LOADING " + currentCategoryTitle
            itemStack = []
            usenetBackend.load_local_items(row.id || "", "", -1, currentCategoryTitle)
        } else if (row.type === "localDiscover") {
            statusText = "LOADING " + currentCategoryTitle
            itemStack = []
            usenetBackend.load_items(row.id || "", currentCategoryTitle)
        } else {
            statusText = "BROWSING " + currentCategoryTitle
            usenetBackend.load_items(row.id || "", currentCategoryTitle)
        }
    }

    function selectCategory(index) {
        if (index < 0 || index >= categoryRows.length) return
        var row = categoryRows[index] || ({})
        if (row.type === "tubeTv" || row.type === "localTvMenu") {
            if (mode === "subcategories") currentSubcategoryIndex = index
            else currentCategoryIndex = index
            browseCategory(row)
            return
        }
        if (row.type === "search") {
            if (mode === "subcategories") currentSubcategoryIndex = index
            else currentCategoryIndex = index
            showSearch()
            return
        }
        if (row.type === "continue") {
            if (mode === "subcategories") currentSubcategoryIndex = index
            else currentCategoryIndex = index
            browseCategory(row)
            return
        }
        var children = row.children || []
        if (children.length > 0) {
            if (mode === "subcategories") {
                categoryStack = categoryStack.concat([{
                    rows: subcategories,
                    title: currentGroupTitle,
                    index: index
                }])
                currentSubcategoryIndex = index
            } else {
                categoryStack = []
                currentCategoryIndex = index
            }
            currentGroupTitle = row.title || "CATEGORY"
            subcategories = children
            currentSubcategoryIndex = 0
            mode = "subcategories"
            setListIndex(categoryList, currentSubcategoryIndex)
            return
        }

        if (mode === "subcategories") currentSubcategoryIndex = index
        else currentCategoryIndex = index
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

    function returnFromMessage() {
        var targetMode = messageReturnMode
        messageReturnMode = ""
        if (targetMode === "search") {
            showSearch()
            return
        }
        if (targetMode === "items" && items.length > 0) {
            mode = "items"
            setListIndex(activeItemList(), currentItemIndex)
            return
        }
        if (targetMode === "subcategories" && subcategories.length > 0) {
            mode = "subcategories"
            setListIndex(categoryList, currentSubcategoryIndex)
            return
        }
        if (targetMode === "categories" &&
                (categories.length > 0 || shortcutRows.length > 0)) {
            mode = "categories"
            setListIndex(categoryList, currentCategoryIndex)
            return
        }
        if (items.length > 0) {
            mode = "items"
            setListIndex(activeItemList(), currentItemIndex)
            return
        }
        if (subcategories.length > 0) {
            mode = "subcategories"
            setListIndex(categoryList, currentSubcategoryIndex)
            return
        }
        if (categories.length > 0 || shortcutRows.length > 0) {
            mode = "categories"
            setListIndex(categoryList, currentCategoryIndex)
            return
        }
        goBack()
    }

    function resetCategoryDrilldown() {
        subcategories = []
        categoryStack = []
        itemStack = []
        currentSubcategoryIndex = 0
        currentGroupTitle = ""
        currentCategoryTitle = ""
    }

    function selectItem(index) {
        if (index < 0 || index >= items.length) return
        currentItemIndex = index
        var row = items[index] || ({})
        if (row.type === "discovery") {
            searchForTitle(row.searchQuery || row.title || "", row.mediaType || "")
            return
        }
        if (row.type === "localFolder") {
            if ((row.mediaType || "") === "show") {
                navigateTo("LocalShow.qml", {
                    item: row,
                    libraryName: currentCategoryTitle
                }, { currentIndex: currentItemIndex })
                return
            }
            if ((row.mediaType || "") === "season") {
                navigateTo("LocalSeason.qml", {
                    item: row,
                    showTitle: currentCategoryTitle,
                    libraryName: currentCategoryTitle
                }, { currentIndex: currentItemIndex })
                return
            }
            itemStack = itemStack.concat([{
                title: currentCategoryTitle,
                rows: items,
                index: index
            }])
            currentCategoryTitle = row.title || "Local"
            messageReturnMode = "items"
            mode = "loading"
            statusText = "LOADING " + currentCategoryTitle
            usenetBackend.load_local_items(row.categoryId || "", row.path || "", row.sourceIndex || 0, currentCategoryTitle)
            return
        }
        if (row.type === "localFile") {
            navigateTo("LocalPlayer.qml", {
                item: row,
                title: row.title || "LOCAL"
            }, {
                currentIndex: currentItemIndex
            })
            return
        }
        pendingPlaybackItem = row
        messageReturnMode = "items"
        nzbStreamResponseReady = false
        streams = []
        pendingRequestId = newRequestId()
        pendingTitle = row.title || "THE TUBE"
        mode = "loading"
        statusText = "TUNING " + pendingTitle
        if (isNzbMovieItem(row) &&
                TaterBumpers.enabledByDefault(
                    appCore.get_setting("", "tater_bumpers_nzb_movies")) &&
                usenetBackend.tater_bumper_enabled("nzb_movies", true))
            playNzbMovieBumper()
        usenetBackend.request_streams(pendingRequestId, row)
    }

    function isNzbMovieItem(item) {
        if (!item || (item.type || "") === "localFile")
            return false
        var mediaType = String(item.mediaType || "").toLowerCase()
        if (mediaType === "movie")
            return true
        if (mediaType === "series" || mediaType === "episode" ||
                mediaType === "tv" || mediaType === "audio")
            return false
        var categoryText = String(item.category || "") + " " + currentCategoryTitle
        return categoryText.toLowerCase().indexOf("movie") >= 0
    }

    function playNzbMovieBumper() {
        var bumper = TaterBumpers.next(appCore, "nzb-movie")
        if (!bumper || !bumper.url)
            return
        nzbMovieBumperActive = true
        playbackStarted = true
        currentStreamUsesServer = false
        currentPlaybackItem = ({})
        currentPlaybackBaseOffsetMs = 0
        mode = "playing"
        statusText = "TATER TUBE"
        streamInfoText = "NZB BUFFERING | TATER BUMPER"
        mpvController.setViewingContext({ suppress_viewing_event: true })
        mpvController.loadAndPlay(bumper.url, 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "tube", false, "TATER TUBE")
    }

    function beginPreparedNzbPlayback() {
        if (!nzbStreamResponseReady)
            return
        if (streams.length === 1) {
            playStream(streams[0], streams[0].title || pendingTitle,
                       pendingPlaybackItem)
            return
        }
        playbackStarted = false
        currentStreamUsesServer = false
        mode = "streams"
        setListIndex(streamList, 0)
    }

    function finishNzbMovieBumper() {
        nzbMovieBumperActive = false
        playbackStarted = false
        if (nzbStreamResponseReady) {
            beginPreparedNzbPlayback()
            return
        }
        mode = "loading"
        statusText = "BUFFERING " + (pendingTitle || "MOVIE")
    }

    function playStream(stream, title, item) {
        if (!stream || !stream.url) {
            mode = "message"
            statusText = "STREAM URL MISSING"
            return
        }
        var playbackItem = item || pendingPlaybackItem || ({})
        nzbMovieBumperActive = false
        nzbStreamResponseReady = false
        playbackStarted = true
        currentPlaybackCompleted = false
        currentPlaybackItem = playbackItem
        pendingPlaybackItem = ({})
        currentPlaybackBaseOffsetMs = 0
        mode = "playing"
        statusText = "PLAYING " + (title || stream.title || "THE TUBE")
        var rawUrl = stream.url
        var startOffsetMs = itemViewOffsetMs(playbackItem)
        var startOffset = startOffsetMs / 1000.0
        if (startOffset > 0 && usenetBackend.uses_server_seek()) {
            rawUrl = urlWithStartOffset(rawUrl, startOffset)
            currentPlaybackBaseOffsetMs = startOffsetMs
            startOffset = 0.0
        }
        var playbackUrl = usenetBackend.playback_url(rawUrl, Math.round(root.sw), Math.round(root.sh))
        currentStreamUsesServer = true
        updateStreamOverlayInfo(plannedStreamInfo(playbackUrl))
        mpvController.setViewingContext({
            module_id: moduleId,
            source: (playbackItem.type === "localFile") ? "local_media" : "stream",
            media_id: (playbackItem.playStateId || playbackItem.ratingKey ||
                       playbackItem.key || playbackItem.guid)
                      || (title || stream.title || "THE TUBE"),
            media_type: playbackItem.mediaType || "video",
            title: playbackItem.title || title || stream.title || "THE TUBE",
            series_title: playbackItem.seriesTitle || "",
            season: playbackItem.season || 0,
            episode: playbackItem.episode || 0
        })
        mpvController.loadAndPlay(playbackUrl, startOffset, 0, -1, [], false, -1, 0.0,
                                  "", false, "tube", false, title || stream.title || "THE TUBE")
    }

    function stopPlayback() {
        pendingRequestId = ""
        pendingPlaybackItem = ({})
        nzbMovieBumperActive = false
        nzbStreamResponseReady = false
        saveCurrentPlayState(false)
        playbackStarted = false
        currentStreamUsesServer = false
        currentPlaybackItem = ({})
        currentPlaybackBaseOffsetMs = 0
        mpvController.stop()
        mode = items.length > 0 ? "items" : (subcategories.length > 0 ? "subcategories" : "categories")
    }

    function returnFromItems() {
        if (itemStack.length > 0) {
            var previous = itemStack[itemStack.length - 1]
            itemStack = itemStack.slice(0, itemStack.length - 1)
            currentCategoryTitle = previous.title || currentCategoryTitle
            items = previous.rows || []
            mode = "items"
            setListIndex(activeItemList(), previous.index || 0)
            return
        }
        returnToCategoryMenu()
    }

    function rowsWithLocalContinueWatching(rows) {
        var next = []
        for (var i = 0; i < (rows || []).length; i++) {
            var row = Object.assign({}, rows[i] || ({}))
            if (row.type === "localRoot") {
                var children = (row.children || []).slice()
                var hasContinue = false
                for (var c = 0; c < children.length; c++) {
                    if ((children[c] || ({})).type === "continue") {
                        hasContinue = true
                        break
                    }
                }
                if (!hasContinue) {
                    children.unshift({
                        type: "continue",
                        title: "CONTINUE WATCHING",
                        detail: "LOCAL",
                        fullTitle: "Local / Continue Watching"
                    })
                }
                row.children = children
                row.count = children.length
            }
            next.push(row)
        }
        return next
    }

    Keys.onPressed: function(event) {
        if (mode === "search") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                returnToCategoryMenu()
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
                    if (categoryStack.length > 0) {
                        var previous = categoryStack[categoryStack.length - 1]
                        categoryStack = categoryStack.slice(0, categoryStack.length - 1)
                        subcategories = previous.rows || []
                        currentGroupTitle = previous.title || "CATEGORY"
                        currentSubcategoryIndex = previous.index || 0
                        setListIndex(categoryList, currentSubcategoryIndex)
                    } else {
                        mode = "categories"
                        setListIndex(categoryList, currentCategoryIndex)
                    }
                } else {
                    goBack()
                }
                event.accepted = true
            }
            return
        }

        if (mode === "items") {
            var activeList = activeItemList()
            if (event.key === Qt.Key_Up) {
                setListIndex(activeList, activeList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                setListIndex(activeList, activeList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageList(activeList, -1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageList(activeList, 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                selectItem(activeList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                returnFromItems()
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
                playStream(streams[currentStreamIndex],
                           streams[currentStreamIndex].title || pendingTitle,
                           pendingPlaybackItem)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                pendingPlaybackItem = ({})
                nzbStreamResponseReady = false
                mode = "items"
                setListIndex(activeItemList(), currentItemIndex)
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
                returnFromMessage()
                event.accepted = true
            }
        }
    }

    Component.onCompleted: {
        usenetBackend.load_tater_bumper_settings()
        refresh()
    }

    Component.onDestruction: {
        if (playbackStarted) {
            saveCurrentPlayState(false)
            mpvController.stop()
        }
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

    Timer {
        id: streamInfoPollTimer
        interval: 3000
        repeat: true
        running: usenetRoot.currentStreamUsesServer && usenetRoot.playbackStarted
                 && usenetRoot.mode === "playing"
        onTriggered: usenetRoot.refreshActiveStreamInfo()
    }

    Timer {
        id: playStateTimer
        interval: 15000
        repeat: true
        running: usenetRoot.playbackStarted && usenetRoot.hasPlaybackStateItem()
                 && usenetRoot.mode === "playing"
        onTriggered: usenetRoot.saveCurrentPlayState(false)
    }

    Connections {
        target: usenetBackend

        function onCategoriesLoaded(rows) {
            categories = rowsWithLocalContinueWatching(rows || [])
            shortcutRows = []
            resetCategoryDrilldown()
            if (categories.length === 0 && shortcutRows.length === 0) {
                mode = "message"
                statusText = "NO CATEGORIES FOUND"
                return
            }
            mode = "categories"
            setListIndex(categoryList, currentCategoryIndex)
        }

        function onItemsLoaded(categoryTitle, rows) {
            currentCategoryTitle = categoryTitle || currentCategoryTitle
            var loadedRows = rows || []
            if (pendingSearchMediaType !== "") {
                var annotatedRows = []
                for (var i = 0; i < loadedRows.length; i++) {
                    var annotated = Object.assign({}, loadedRows[i] || ({}))
                    if (!annotated.mediaType || annotated.mediaType === "nzb")
                        annotated.mediaType = pendingSearchMediaType
                    annotatedRows.push(annotated)
                }
                loadedRows = annotatedRows
                pendingSearchMediaType = ""
            }
            items = loadedRows
            if (items.length === 0) {
                mode = "message"
                statusText = "NO ITEMS IN " + currentCategoryTitle
                return
            }
            mode = "items"
            setListIndex(activeItemList(), 0)
        }

        function onStreamsReady(requestId, title, rows) {
            if (requestId !== pendingRequestId)
                return
            streams = rows || []
            nzbStreamResponseReady = true
            if (title)
                pendingTitle = title
            if (nzbMovieBumperActive)
                return
            beginPreparedNzbPlayback()
        }

        function onActiveStreamsLoaded(streams) {
            if (!usenetRoot.currentStreamUsesServer || usenetRoot.mode !== "playing")
                return
            var rows = streams || []
            if (rows.length === 0)
                return
            usenetRoot.updateStreamOverlayInfo(usenetRoot.streamInfoFromActiveStream(rows[0]))
        }

        function onPairingSucceeded(serverUrl, token, playerName) {
            appCore.save_setting(moduleId, "tater_server_url", serverUrl)
            appCore.save_setting(moduleId, "tater_server_token", token)
            statusText = "PAIRED " + (playerName || "PLAYER")
            loadCategories()
        }

        function onErrorOccurred(message) {
            pendingRequestId = ""
            pendingPlaybackItem = ({})
            pendingSearchMediaType = ""
            nzbStreamResponseReady = false
            if (nzbMovieBumperActive) {
                nzbMovieBumperActive = false
                playbackStarted = false
                if (mpvController.running)
                    mpvController.stop()
            }
            mode = "message"
            statusText = message || "THE TUBE FAILED"
        }
    }

    Connections {
        target: appCore
        function onModuleSettingChanged(mid, key, value) {
            if (mid !== usenetRoot.moduleId)
                return
            if (key !== "tater_server_url" && key !== "tater_server_token")
                return
            if (mode === "setup" || mode === "message")
                refresh()
        }
    }

    Connections {
        target: mpvController

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (nzbMovieBumperActive) {
                finishNzbMovieBumper()
                return
            }
            if (mode === "playing") {
                saveCurrentPlayState(false)
                playbackStarted = false
                currentStreamUsesServer = false
                currentPlaybackItem = ({})
                currentPlaybackBaseOffsetMs = 0
                mode = items.length > 0 ? "items" : (subcategories.length > 0 ? "subcategories" : "categories")
            }
        }

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (nzbMovieBumperActive) {
                finishNzbMovieBumper()
                return
            }
            if (mode === "playing") {
                saveCurrentPlayState(true)
                playbackStarted = false
                currentStreamUsesServer = false
                currentPlaybackItem = ({})
                currentPlaybackBaseOffsetMs = 0
                mode = items.length > 0 ? "items" : (subcategories.length > 0 ? "subcategories" : "categories")
                if (mpvController.running)
                    mpvController.stop()
            }
        }

        function onPlaybackFailed() {
            if (nzbMovieBumperActive) {
                finishNzbMovieBumper()
                return
            }
            if (mode === "playing") {
                saveCurrentPlayState(false)
                playbackStarted = false
                currentStreamUsesServer = false
                currentPlaybackItem = ({})
                currentPlaybackBaseOffsetMs = 0
                messageReturnMode = "items"
                mode = "message"
                statusText = "THE TUBE PLAYBACK FAILED"
                if (mpvController.running)
                    mpvController.stop()
            }
        }

        function onScriptMessageReceived(message, arg) {
            if (mode !== "playing")
                return
            if (message === "240mp-ota-file-loaded") {
                updateStreamOverlayInfo(streamInfoText)
                refreshActiveStreamInfo()
            }
        }
    }

    StaticBackground {
        anchors.fill: parent
        themeName: root.currentTheme
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
        subtitle: mode === "items" ? currentCategoryTitle : (mode === "subcategories" ? currentGroupTitle : "SERVER")
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

        SetupField { id: serverUrlField; label: "TATER SERVER URL"; selected: setupRow === 0 }
        SetupField { id: pairingPinField; label: "PAIRING PIN"; selected: setupRow === 1 }

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

                function openInputKeyboard() {
                    root.openTaterKeyboard(
                                searchField, "SEARCH", false,
                                function() { runSearch() },
                                function() { searchField.forceActiveFocus() })
                }

                Keys.onReturnPressed: searchField.openInputKeyboard()
                Keys.onEnterPressed: searchField.openInputKeyboard()
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        mode = "categories"
                        setListIndex(categoryList, currentCategoryIndex)
                        event.accepted = true
                    }
                }

                TapHandler {
                    onTapped: searchField.openInputKeyboard()
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

    Item {
        id: seriesArchive
        visible: browsingSeries
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
                text: items.length + (items.length === 1 ? " TAPE" : " TAPES")
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
            model: items
            clip: true
            focus: visible
            currentIndex: currentItemIndex
            onCurrentIndexChanged: currentItemIndex = currentIndex

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
                    text: "T-" + usenetRoot.seriesTapeNumber(seriesRow.index)
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

    ListView {
        id: itemList
        visible: mode === "items" && !browsingSeries
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
            detail: itemDetail(modelData)
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
        id: setupFieldControl
        property alias text: fieldInput.text
        property string label: ""
        property bool selected: false
        property bool password: false

        function forceInputFocus() {
            fieldInput.forceActiveFocus()
        }

        function finishInput() {
            if (setupRow === setupConnectRow - 1)
                saveSetup()
            else
                setupNext()
        }

        function openInputKeyboard() {
            root.openTaterKeyboard(
                        fieldInput, label, password,
                        function() { setupFieldControl.finishInput() },
                        function() { setupFieldControl.forceInputFocus() })
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
            Keys.onReturnPressed: setupFieldControl.openInputKeyboard()
            Keys.onEnterPressed: setupFieldControl.openInputKeyboard()
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                    goBack()
                    event.accepted = true
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: setupFieldControl.openInputKeyboard()
        }
    }
}
