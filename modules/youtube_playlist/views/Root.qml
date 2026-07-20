import QtQuick
import Components
import "../../shared/TaterBumpers.js" as TaterBumpers

FocusScope {
    id: mixRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: "com.240mp.youtube_playlist"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || "PUBLIC ACCESS"
    property string moduleIcon: _moduleInfo.icon || ""

    property string mode: "loading"
    property string statusText: "LOADING PLAYLISTS..."
    property string playlistTitle: "YOUTUBE PLAYLIST"
    property string playlistInput: ""
    property var playlists: []
    property var commercialCategoryRows: []
    property var playlistRows: []
    property var tvMenuRows: []
    property var storePlaylists: [
        {
            title: "PUBLIC ACCESS STARTER",
            input: "PLejgWcMCJnnOxUaRCicf7-m3tz7flNgBU"
        }
    ]
    property var currentPlaylist: ({})
    property var videos: []
    property var videoRows: []
    property var playbackVideos: []
    property int currentPlaylistIndex: 0
    property int currentVideoIndex: 0
    property int playbackVideoIndex: 0
    property bool playingTaterBumper: false
    property int pendingBumperVideoIndex: -1
    property bool loadingPlaylist: false
    property bool addingPlaylist: false
    property bool stoppingPlayback: false
    property string addPlaylistKind: "regular"
    property string addReturnMode: "library"
    property string pendingPlaylistKind: "regular"
    property string pendingPlaylistInput: ""
    property bool tvModeActive: false
    property bool tvLoading: false
    property bool tvTuningStaticVisible: false
    property bool tvTransitionBlankVisible: false
    property bool tvStoppingForTune: false
    property bool tvStreamStarted: false
    property bool backgroundStaticVisible: (root.staticBackgroundEnabled && mode !== "playing" && mode !== "tv")
                                           || (mode === "tv" && tvTuningStaticVisible && !tvTransitionBlankVisible)
    property int tvCurrentChannelIndex: 0
    property int tvCurrentScheduleIndex: -1
    property int tvPreviousChannelIndex: -1
    property int tvResolveSerial: 0
    property string tvPendingResolveId: ""
    property int tvTuneDelayMs: 1200
    property double tvStartedAtMs: 0
    property var tvChannels: []
    property var tvCommercialPool: []
    property var tvCommercialDeck: []
    property var tvLoadQueue: []
    property var tvCurrentLoad: ({})
    property var tvPendingPlayback: ({})
    property var tvPendingChannels: []
    property var tvPendingCommercials: []

    focus: true

    function settingValue(key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "") return fallback
        return value
    }

    function autoplayNext() {
        var value = settingValue("autoplay_next", true)
        return value === true || value === "ON" || value === "true"
    }

    function tvCommercialsEnabled() {
        var value = settingValue("tv_mode_commercials", true)
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function tvAutoChannelsEnabled() {
        var value = settingValue("public_access_auto_channels", true)
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function playbackQuality() {
        return settingValue("playback_quality", "360p")
    }

    function listSetting(key) {
        var value = appCore.get_setting(moduleId, key)
        return Array.isArray(value) ? value : []
    }

    function mapSetting(key) {
        var value = appCore.get_setting(moduleId, key)
        return value && typeof value === "object" && !Array.isArray(value) ? value : ({})
    }

    function commercialCategoryEnabled(id) {
        var selected = mapSetting("public_access_commercial_categories")
        if (selected[id] === undefined || selected[id] === null)
            return true
        return selected[id] === true || selected[id] === "ON" || selected[id] === "true" || selected[id] === "1"
    }

    function buildCommercialCategoryRows() {
        var categories = youtubePlaylistBackend.get_commercial_categories()
        var rows = []
        for (var i = 0; i < categories.length; i++) {
            var category = Object.assign({}, categories[i] || ({}))
            category.rowType = "category"
            category.enabled = commercialCategoryEnabled(category.id || "")
            category.title = (category.enabled ? "ON  " : "OFF ") + (category.label || category.id || "COMMERCIALS")
            rows.push(category)
        }
        if (rows.length === 0)
            rows.push({ rowType: "empty", title: "NO COMMERCIALS UPLOADED" })
        commercialCategoryRows = rows
    }

    function buildPlaylistRows() {
        var rows = []
        rows.push({ rowType: "tvmode", title: "TV MODE" })
        for (var i = 0; i < playlists.length; i++) {
            var item = Object.assign({}, playlists[i])
            item.rowType = "playlist"
            rows.push(item)
        }
        if (playlists.length > 0)
            rows.push({ rowType: "refresh", title: "REFRESH ALL PLAYLISTS" })
        rows.push({ rowType: "add", title: "+ ADD PLAYLIST" })
        rows.push({ rowType: "store", title: "PLAYLIST STORE" })
        playlistRows = rows
    }

    function buildTvMenuRows() {
        tvMenuRows = [
            { rowType: "start", title: "START TV MODE" },
            { rowType: "auto_channels", title: "AUTO CHANNELS " + (tvAutoChannelsEnabled() ? "ON" : "OFF") },
            { rowType: "commercials", title: "COMMERCIALS " + (tvCommercialsEnabled() ? "ON" : "OFF") },
            { rowType: "commercial_categories", title: "COMMERCIAL CATEGORIES" }
        ]
    }

    function buildVideoRows() {
        var rows = []
        if (videos.length > 0)
            rows.push({ rowType: "shuffle", title: "SHUFFLE PLAYLIST" })
        for (var i = 0; i < videos.length; i++) {
            var item = Object.assign({}, videos[i])
            item.rowType = "video"
            item.videoIndex = i
            if (item.index === undefined || item.index === null)
                item.index = i
            rows.push(item)
        }
        videoRows = rows
    }

    function loadPlaylistLibrary(preferredIndex) {
        tvTuneTimer.stop()
        cancelTvResolve()
        tvModeActive = false
        tvLoading = false
        tvTuningStaticVisible = false
        tvTransitionBlankVisible = false
        tvStoppingForTune = false
        tvCurrentScheduleIndex = -1
        playlists = youtubePlaylistBackend.get_saved_playlists()
        buildPlaylistRows()
        mode = "library"
        var idx = preferredIndex === undefined ? currentPlaylistIndex : preferredIndex
        libraryList.currentIndex = Math.max(0, Math.min(idx, playlistRows.length - 1))
        currentPlaylistIndex = libraryList.currentIndex
    }

    function showTvMenu() {
        tvTuneTimer.stop()
        cancelTvResolve()
        tvModeActive = false
        tvLoading = false
        tvTuningStaticVisible = false
        tvTransitionBlankVisible = false
        tvStoppingForTune = false
        tvCurrentScheduleIndex = -1
        buildTvMenuRows()
        mode = "tvmenu"
        tvMenuList.currentIndex = Math.max(0, Math.min(tvMenuList.currentIndex, tvMenuRows.length - 1))
    }

    function showAdd(message, kind, returnMode) {
        mode = "add"
        addingPlaylist = false
        addPlaylistKind = kind || "regular"
        addReturnMode = returnMode || "library"
        pendingPlaylistKind = addPlaylistKind
        pendingPlaylistInput = ""
        addLookupTimer.stop()
        statusText = message || "ADD PLAYLIST"
        playlistField.text = ""
        addFocusTimer.restart()
    }

    function showStore(message) {
        mode = "store"
        addingPlaylist = false
        pendingPlaylistInput = ""
        addLookupTimer.stop()
        statusText = message || "PLAYLIST STORE"
        storeList.currentIndex = Math.max(0, Math.min(storeList.currentIndex, storePlaylists.length - 1))
    }

    function showCommercialCategories() {
        buildCommercialCategoryRows()
        mode = "commercialcategories"
        commercialCategoryList.currentIndex = Math.max(0, Math.min(commercialCategoryList.currentIndex,
                                                                   commercialCategoryRows.length - 1))
    }

    function cancelAdd() {
        addingPlaylist = false
        pendingPlaylistInput = ""
        addLookupTimer.stop()
        if (addReturnMode === "tvmenu")
            showTvMenu()
        else
            loadPlaylistLibrary(currentPlaylistIndex)
    }

    function savePlaylistRows(nextPlaylists) {
        appCore.save_setting(moduleId, "playlists", nextPlaylists)
        playlists = youtubePlaylistBackend.get_saved_playlists()
        if (playlists.length < nextPlaylists.length) {
            playlists = nextPlaylists
            buildPlaylistRows()
            return false
        }
        buildPlaylistRows()
        return true
    }

    function updateCurrentPlaylistTitle(title) {
        title = (title || "").trim()
        if (!currentPlaylist || currentPlaylist.rowType !== "playlist") return
        if (title === "" || !currentPlaylist.url) return

        var changed = false
        var next = []
        for (var i = 0; i < playlists.length; i++) {
            var item = Object.assign({}, playlists[i])
            if (item.url === currentPlaylist.url && item.title !== title) {
                item.title = title
                changed = true
            }
            next.push(item)
        }
        if (changed) {
            currentPlaylist.title = title
            savePlaylistRows(next)
        }
    }

    function addPlaylist(inputOverride, kindOverride) {
        if (addingPlaylist) return
        var value = ((inputOverride !== undefined ? inputOverride : playlistField.text) || "").trim()
        playlistField.text = value
        pendingPlaylistKind = kindOverride || addPlaylistKind || "regular"
        if (value === "") {
            statusText = "ENTER PLAYLIST CODE"
            if (mode === "add")
                playlistField.forceActiveFocus()
            return
        }

        addingPlaylist = true
        pendingPlaylistInput = value
        statusText = "READING PLAYLIST INFO..."
        addLookupTimer.restart()
    }

    function finishAddPlaylist(value) {
        if (!addingPlaylist)
            return
        var info = youtubePlaylistBackend.resolve_playlist_info(value)
        addingPlaylist = false
        pendingPlaylistInput = ""

        if (!info || info.ok !== true || !info.url) {
            statusText = (info && info.message) ? info.message : "PLAYLIST LOOKUP FAILED - TRY AGAIN"
            playlistField.text = value || playlistField.text
            if (mode === "add") {
                playlistField.forceActiveFocus()
                playlistField.selectAll()
            } else {
                mode = "message"
            }
            return
        }

        var targetPlaylists = playlists
        for (var i = 0; i < targetPlaylists.length; i++) {
            if (targetPlaylists[i].url === info.url) {
                statusText = "PLAYLIST ALREADY ADDED"
                loadPlaylistLibrary(i + 1)
                return
            }
        }

        var item = {
            id: info.id || info.url,
            input: info.input || value,
            url: info.url,
            title: info.title || ("PLAYLIST " + (targetPlaylists.length + 1))
        }
        var next = targetPlaylists.slice()
        next.push(item)
        var saved = savePlaylistRows(next)
        if (!saved) {
            mode = "add"
            statusText = "COULD NOT SAVE PLAYLIST"
            playlistField.text = value
            playlistField.forceActiveFocus()
            playlistField.selectAll()
            return
        }
        statusText = "PLAYLIST ADDED"
        loadPlaylistLibrary(next.length)
    }

    function selectPlaylist(index) {
        if (index < 0 || index >= playlistRows.length) return
        var row = playlistRows[index] || ({})
        if (row.rowType === "tvmode") {
            showTvMenu()
            return
        }
        if (row.rowType === "add") {
            showAdd("ADD PLAYLIST")
            return
        }
        if (row.rowType === "store") {
            showStore("PLAYLIST STORE")
            return
        }
        if (row.rowType === "refresh") {
            refreshAllPlaylists()
            return
        }

        currentPlaylistIndex = index
        currentPlaylist = row
        playlistInput = row.input || row.url || ""
        playlistTitle = row.rowType === "commercial"
                        ? (row.title || "COMMERCIALS")
                        : (row.title || "YOUTUBE PLAYLIST")
        loadPlaylist(playlistInput)
    }

    function toggleTvCommercials() {
        appCore.save_setting(moduleId, "tv_mode_commercials",
                             tvCommercialsEnabled() ? "OFF" : "ON")
        buildTvMenuRows()
    }

    function toggleTvAutoChannels() {
        appCore.save_setting(moduleId, "public_access_auto_channels",
                             tvAutoChannelsEnabled() ? "OFF" : "ON")
        buildTvMenuRows()
    }

    function selectTvMenu(index) {
        if (index < 0 || index >= tvMenuRows.length) return
        var row = tvMenuRows[index] || ({})
        if (row.rowType === "start") {
            startTvMode()
        } else if (row.rowType === "auto_channels") {
            toggleTvAutoChannels()
        } else if (row.rowType === "commercials") {
            toggleTvCommercials()
        } else if (row.rowType === "commercial_categories") {
            showCommercialCategories()
        }
    }

    function toggleCommercialCategory(index) {
        if (index < 0 || index >= commercialCategoryRows.length)
            return
        var row = commercialCategoryRows[index] || ({})
        if (row.rowType !== "category" || !row.id)
            return
        appCore.save_setting(moduleId, "public_access_commercial_categories." + row.id,
                             !commercialCategoryEnabled(row.id))
        buildCommercialCategoryRows()
        commercialCategoryList.currentIndex = Math.max(0, Math.min(index, commercialCategoryRows.length - 1))
    }

    function pageCommercialCategories(direction) {
        if (commercialCategoryRows.length === 0) return
        var rowHeight = root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(commercialCategoryList.height / rowHeight) - 1)
        var next = Math.max(0, Math.min(commercialCategoryList.count - 1,
                                        commercialCategoryList.currentIndex + direction * rows))
        commercialCategoryList.currentIndex = next
        commercialCategoryList.positionViewAtIndex(next, ListView.Contain)
    }

    function localCommercialPool() {
        if (!tvCommercialsEnabled())
            return []
        return youtubePlaylistBackend.get_commercial_videos_for_setting("public_access_commercial_categories")
    }

    function loadPlaylist(input) {
        if (loadingPlaylist) return
        loadingPlaylist = true
        mode = "loading"
        statusText = "READING " + (playlistTitle || "PLAYLIST")
        youtubePlaylistBackend.load_playlist(input)
    }

    function refreshAllPlaylists() {
        if (playlists.length === 0) {
            mode = "message"
            statusText = "NO PLAYLISTS SAVED"
            return
        }
        youtubePlaylistBackend.refresh_playlist_cache()
        mode = "message"
        statusText = "PLAYLISTS WILL REFRESH"
    }

    function refreshCurrentPlaylist() {
        if (!currentPlaylist || (!currentPlaylist.input && !currentPlaylist.url)) return
        loadingPlaylist = true
        mode = "loading"
        statusText = "REFRESHING " + (playlistTitle || "PLAYLIST")
        youtubePlaylistBackend.refresh_playlist(currentPlaylist.input || currentPlaylist.url)
    }

    function selectStorePlaylist(index) {
        if (index < 0 || index >= storePlaylists.length) return
        var row = storePlaylists[index] || ({})
        statusText = "ADDING " + (row.title || "PLAYLIST")
        mode = "loading"
        addPlaylist(row.input || row.url || "", "regular")
    }

    function padChannelNumber(value) {
        var text = String(value)
        return text.length < 2 ? "0" + text : text
    }

    function shuffleList(items) {
        var shuffled = (items || []).slice()
        for (var i = shuffled.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1))
            var tmp = shuffled[i]
            shuffled[i] = shuffled[j]
            shuffled[j] = tmp
        }
        return shuffled
    }

    function durationSeconds(item, fallback) {
        var raw = item ? item.duration : 0
        var value = typeof raw === "number" ? raw : parseFloat(raw)
        if (isNaN(value) || value <= 0)
            value = fallback
        return Math.max(5, value)
    }

    function isTvInterstitialItem(item) {
        var kind = String((item && item.kind) || "").toLowerCase()
        return kind === "commercial" || kind === "bumper" || kind === "tater_bumper"
    }

    function tvChannelLabel(channel) {
        if (!channel) return "CH --"
        return "CH " + (channel.number || "--")
    }

    function appendTvScheduleItem(schedule, source, kind, startAt) {
        if (!source || !source.url)
            return startAt

        var fallback = kind === "commercial" ? 30 : 300
        var duration = durationSeconds(source, fallback)
        var item = Object.assign({}, source)
        item.kind = kind
        item.duration = duration
        item.start = startAt
        item.end = startAt + duration
        schedule.push(item)
        return item.end
    }

    function randomCommercial() {
        if (tvCommercialPool.length === 0)
            return null
        var deck = tvCommercialDeck || []
        if (deck.length === 0)
            deck = shuffleList(tvCommercialPool)
        var commercial = deck.shift()
        tvCommercialDeck = deck
        return commercial
    }

    function buildTvSchedule(videos) {
        var schedule = []
        var total = 0
        var shuffled = shuffleList(videos || [])
        var includeCommercials = tvCommercialsEnabled() && tvCommercialPool.length > 0

        for (var i = 0; i < shuffled.length; i++) {
            total = appendTvScheduleItem(schedule, shuffled[i], "program", total)
            if (includeCommercials) {
                var targetCount = 2 + Math.floor(Math.random() * 3)
                var added = 0
                var attempts = 0
                var maxAttempts = Math.max(targetCount * 3, tvCommercialPool.length * 2)
                while (added < targetCount && attempts < maxAttempts) {
                    attempts++
                    var commercial = randomCommercial()
                    if (commercial) {
                        var before = total
                        total = appendTvScheduleItem(schedule, commercial, "commercial", total)
                        if (total > before)
                            added++
                    }
                }
            }
        }
        return { schedule: schedule, totalDuration: total }
    }

    function findTvScheduleItem(channel) {
        if (!channel || !channel.schedule || channel.schedule.length === 0 || channel.totalDuration <= 0)
            return null

        var elapsed = Math.max(0, (Date.now() - tvStartedAtMs) / 1000.0)
        var position = elapsed % channel.totalDuration
        for (var i = 0; i < channel.schedule.length; i++) {
            var item = channel.schedule[i]
            if (position >= item.start && position < item.end)
                return { item: item, index: i, offset: Math.max(0, position - item.start) }
        }

        return { item: channel.schedule[0], index: 0, offset: 0 }
    }

    function showTvStaticForChannel(channel) {
        tvTransitionBlankVisible = mpvController.running
        tvTuningStaticVisible = !mpvController.running
        tvStreamStarted = false
        cancelTvResolve()
        statusText = tvChannelLabel(channel)
        if (mpvController.running) {
            tvStoppingForTune = false
            mpvController.sendScriptMessage("240mp-ota-tune-transition", statusText)
        }
    }

    function cancelTvResolve() {
        tvPendingResolveId = ""
        tvPendingPlayback = ({})
        if (youtubePlaylistBackend.cancel_video_stream_resolve)
            youtubePlaylistBackend.cancel_video_stream_resolve()
    }

    function launchTvPlayback(url, offset, label, allowYtdl, format, item) {
        tvStreamStarted = true
        tvStoppingForTune = false
        var oscMode = tvTransitionBlankVisible ? "ota-quiet" : "ota"
        mpvController.setViewingContext(
            isTvInterstitialItem(item)
                ? ({ suppress_viewing_event: true })
                : ({}))
        mpvController.loadAndPlay(url || "", offset || 0.0, 0, -1, [],
                                  false, -1, 0.0, "", false, oscMode, false,
                                  label, false, !!allowYtdl, format || "")
    }

    function requestTvStream() {
        tvTuneTimer.stop()
        if (!tvModeActive || tvLoading || tvChannels.length === 0)
            return

        cancelTvResolve()
        var channel = tvChannels[tvCurrentChannelIndex]
        var resolved = findTvScheduleItem(channel)
        if (!resolved || !resolved.item || !resolved.item.url) {
            tvTuningStaticVisible = true
            tvTransitionBlankVisible = false
            tvStreamStarted = false
            statusText = tvChannelLabel(channel)
            if (mpvController.running) {
                tvStoppingForTune = true
                mpvController.stop()
            }
            return
        }

        var label = tvChannelLabel(channel)
        statusText = label
        tvStoppingForTune = false
        tvCurrentScheduleIndex = resolved.index
        var format = youtubePlaylistBackend.ytdl_format_for_quality(playbackQuality())
        if (resolved.item.kind === "commercial" && resolved.item.local === true) {
            launchTvPlayback(resolved.item.url || "", resolved.offset || 0.0,
                             label, false, "", resolved.item)
            return
        }
        var requestId = "tv-" + (++tvResolveSerial)
        tvPendingResolveId = requestId
        tvPendingPlayback = {
            url: resolved.item.url || "",
            offset: resolved.offset || 0.0,
            label: label,
            format: format,
            item: resolved.item
        }
        statusText = label
        youtubePlaylistBackend.resolve_video_stream(requestId, resolved.item.url || "", playbackQuality())
    }

    function handleTvStreamResolved(requestId, result) {
        if (!tvModeActive || requestId !== tvPendingResolveId)
            return

        var pending = tvPendingPlayback || ({})
        tvPendingResolveId = ""
        tvPendingPlayback = ({})
        var directUrl = result && result.ok === true ? (result.url || "") : ""
        if (directUrl !== "") {
            launchTvPlayback(directUrl, pending.offset || 0.0,
                             pending.label || statusText, false, "", pending.item)
            return
        }

        launchTvPlayback(pending.url || "", pending.offset || 0.0,
                         pending.label || statusText, true, pending.format || "",
                         pending.item)
    }

    function playNextTvScheduleItem() {
        if (!tvModeActive || tvChannels.length === 0)
            return
        var channel = tvChannels[tvCurrentChannelIndex]
        if (!channel || !channel.schedule || channel.schedule.length === 0) {
            requestTvStream()
            return
        }
        var nextIndex = tvCurrentScheduleIndex + 1
        if (nextIndex < 0 || nextIndex >= channel.schedule.length)
            nextIndex = 0
        var nextItem = channel.schedule[nextIndex]
        tvStartedAtMs = Date.now() - Math.max(0, nextItem.start) * 1000.0
        tvTransitionBlankVisible = true
        tvTuningStaticVisible = false
        tvStreamStarted = false
        requestTvStream()
    }

    function tuneTvIndex(index, immediate) {
        if (!tvModeActive || tvChannels.length === 0)
            return
        if (index < 0)
            index = tvChannels.length - 1
        if (index >= tvChannels.length)
            index = 0
        if (tvCurrentChannelIndex !== index)
            tvPreviousChannelIndex = tvCurrentChannelIndex
        tvCurrentChannelIndex = index
        tvCurrentScheduleIndex = -1

        showTvStaticForChannel(tvChannels[tvCurrentChannelIndex])
        if (immediate)
            requestTvStream()
        else
            tvTuneTimer.restart()
    }

    function tuneTvRelative(delta, immediate) {
        tuneTvIndex(tvCurrentChannelIndex + delta, immediate)
    }

    function tuneTvNow() {
        if (!tvModeActive || tvLoading || tvTransitionBlankVisible || !tvTuningStaticVisible)
            return
        tvTuneTimer.stop()
        requestTvStream()
    }

    function tuneLastTvChannel() {
        if (tvPreviousChannelIndex < 0 || tvPreviousChannelIndex >= tvChannels.length)
            return
        tuneTvIndex(tvPreviousChannelIndex, false)
    }

    function loadNextTvPlaylist() {
        if (!tvModeActive || !tvLoading)
            return
        if (tvLoadQueue.length === 0) {
            finalizeTvMode()
            return
        }

        var queue = tvLoadQueue.slice()
        tvCurrentLoad = queue.shift() || ({})
        tvLoadQueue = queue
        var playlist = tvCurrentLoad.playlist || ({})
        statusText = "LOADING " + (playlist.title || "PLAYLIST")
        loadingPlaylist = true
        youtubePlaylistBackend.load_playlist(playlist.input || playlist.url || "")
    }

    function handleTvPlaylistLoaded(title, items) {
        loadingPlaylist = false
        var load = tvCurrentLoad || ({})
        var playlistItems = items || []
        if (load.kind === "channel") {
            var channel = tvPendingChannels[load.index] || ({})
            channel.title = title || channel.title
            channel.videos = playlistItems
            tvPendingChannels[load.index] = channel
        } else if (load.kind === "commercial") {
            for (var i = 0; i < playlistItems.length; i++) {
                var commercial = Object.assign({}, playlistItems[i])
                commercial.commercial = true
                tvPendingCommercials.push(commercial)
            }
        }
        tvCurrentLoad = ({})
        loadNextTvPlaylist()
    }

    function handleTvPlaylistError(message) {
        loadingPlaylist = false
        tvCurrentLoad = ({})
        loadNextTvPlaylist()
    }

    function finalizeTvMode() {
        var commercials = []
        for (var i = 0; i < tvPendingCommercials.length; i++) {
            if (tvPendingCommercials[i] && tvPendingCommercials[i].url)
                commercials.push(tvPendingCommercials[i])
        }
        tvCommercialPool = commercials
        tvCommercialDeck = []

        var readyChannels = []
        for (var j = 0; j < tvPendingChannels.length; j++) {
            var channel = tvPendingChannels[j] || ({})
            if (!channel.videos || channel.videos.length === 0)
                continue
            var scheduleData = buildTvSchedule(channel.videos)
            if (scheduleData.schedule.length === 0 || scheduleData.totalDuration <= 0)
                continue
            channel.schedule = scheduleData.schedule
            channel.totalDuration = scheduleData.totalDuration
            readyChannels.push(channel)
        }

        if (readyChannels.length === 0) {
            tvModeActive = false
            tvLoading = false
            tvTuningStaticVisible = false
            tvTransitionBlankVisible = false
            mode = "message"
            statusText = "NO CHANNELS AVAILABLE"
            return
        }

        tvChannels = readyChannels
        tvCurrentChannelIndex = 0
        tvCurrentScheduleIndex = -1
        tvPreviousChannelIndex = -1
        tvStartedAtMs = Date.now()
        tvLoading = false
        tuneTvIndex(0, false)
    }

    function startTvMode() {
        if (!tvAutoChannelsEnabled() || playlists.length === 0) {
            mode = "message"
            statusText = !tvAutoChannelsEnabled() ? "NO CHANNELS AVAILABLE" : "ADD PLAYLISTS FIRST"
            return
        }

        tvTuneTimer.stop()
        addLookupTimer.stop()
        tvModeActive = true
        tvLoading = true
        tvTuningStaticVisible = true
        tvTransitionBlankVisible = false
        tvStoppingForTune = false
        tvStreamStarted = false
        tvCurrentChannelIndex = 0
        tvCurrentScheduleIndex = -1
        tvPreviousChannelIndex = -1
        tvStartedAtMs = Date.now()
        tvChannels = []
        tvCommercialPool = []
        tvCommercialDeck = []
        tvPendingChannels = []
        tvPendingCommercials = localCommercialPool()
        tvCurrentLoad = ({})
        tvLoadQueue = []
        statusText = "LOADING TV MODE"
        mode = "tv"

        if (mpvController.running) {
            tvStoppingForTune = true
            mpvController.stop()
        }

        var shuffledChannels = shuffleList(playlists)
        var queue = []
        for (var i = 0; i < shuffledChannels.length; i++) {
            var source = shuffledChannels[i] || ({})
            var channel = {
                number: padChannelNumber(i + 2),
                title: source.title || ("CHANNEL " + padChannelNumber(i + 2)),
                input: source.input || source.url || "",
                url: source.url || "",
                videos: [],
                schedule: [],
                totalDuration: 0
            }
            tvPendingChannels.push(channel)
            queue.push({ kind: "channel", index: i, playlist: channel })
        }

        tvLoadQueue = queue
        loadNextTvPlaylist()
    }

    function exitTvMode() {
        tvTuneTimer.stop()
        cancelTvResolve()
        tvModeActive = false
        tvLoading = false
        tvTuningStaticVisible = false
        tvTransitionBlankVisible = false
        tvStreamStarted = false
        tvCurrentScheduleIndex = -1
        if (mpvController.running)
            mpvController.stop()
        loadPlaylistLibrary(currentPlaylistIndex)
    }

    function videoIndexForItem(item, fallback) {
        var raw = item ? item.index : undefined
        if (typeof raw === "number" && !isNaN(raw))
            return raw
        var parsed = parseInt(raw)
        return isNaN(parsed) ? fallback : parsed
    }

    function videoRowForVideoIndex(index) {
        if (videoRows.length <= 1)
            return 0
        return Math.max(1, Math.min(videoRows.length - 1, index + 1))
    }

    function playPlaybackVideoIndex(index) {
        if (index < 0 || index >= playbackVideos.length) return
        playingTaterBumper = false
        pendingBumperVideoIndex = -1
        playbackVideoIndex = index
        var item = playbackVideos[index] || ({})
        currentVideoIndex = Math.max(0, Math.min(videos.length - 1, videoIndexForItem(item, index)))
        videoList.currentIndex = videoRowForVideoIndex(currentVideoIndex)

        var title = item.title || "VIDEO"
        statusText = "LOADING " + title
        mode = "playing"
        stoppingPlayback = false
        var format = youtubePlaylistBackend.ytdl_format_for_quality(playbackQuality())
        mpvController.setViewingContext({})
        mpvController.loadAndPlay(item.url || "", 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "", false, title, false, true, format)
    }

    function publicAccessSeriesKey() {
        return String(currentPlaylist.input || currentPlaylist.url ||
                      playlistInput || playlistTitle || "public-access").trim()
    }

    function playTaterBumperBeforeVideo(index) {
        var bumper = TaterBumpers.next(appCore, "public-access-series")
        if (!bumper || !bumper.url) {
            playPlaybackVideoIndex(index)
            return
        }
        playingTaterBumper = true
        pendingBumperVideoIndex = index
        mode = "playing"
        stoppingPlayback = false
        statusText = "TATER TUBE"
        mpvController.setViewingContext({ suppress_viewing_event: true })
        mpvController.loadAndPlay(bumper.url, 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "", false, "TATER TUBE")
    }

    function finishTaterBumper() {
        var nextIndex = pendingBumperVideoIndex
        playingTaterBumper = false
        pendingBumperVideoIndex = -1
        if (nextIndex >= 0 && nextIndex < playbackVideos.length) {
            playPlaybackVideoIndex(nextIndex)
            return
        }
        returnToVideoList()
    }

    function playIndex(index) {
        if (index < 0 || index >= videos.length) return
        playbackVideos = videos.slice()
        playPlaybackVideoIndex(index)
    }

    function shuffleVideos() {
        var shuffled = videos.slice()
        for (var i = shuffled.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1))
            var tmp = shuffled[i]
            shuffled[i] = shuffled[j]
            shuffled[j] = tmp
        }
        return shuffled
    }

    function playShuffle() {
        if (videos.length === 0) return
        playbackVideos = shuffleVideos()
        playPlaybackVideoIndex(0)
    }

    function selectVideoRow(index) {
        if (index < 0 || index >= videoRows.length) return
        var row = videoRows[index] || ({})
        if (row.rowType === "shuffle") {
            playShuffle()
            return
        }

        var videoIndex = row.videoIndex
        if (typeof videoIndex !== "number")
            videoIndex = index - 1
        playIndex(videoIndex)
    }

    function setVideoRowIndex(index) {
        var next = Math.max(0, Math.min(videoList.count - 1, index))
        videoList.currentIndex = next
        var row = videoRows[next] || ({})
        if (row.rowType === "video" && typeof row.videoIndex === "number")
            currentVideoIndex = row.videoIndex
    }

    function returnToVideoList() {
        mode = videos.length > 0 ? "list" : "message"
        if (videos.length > 0)
            setVideoRowIndex(videoRowForVideoIndex(currentVideoIndex))
        if (mpvController.running)
            mpvController.stop()
    }

    function pageVideoList(direction) {
        if (videos.length === 0) return
        var rowHeight = root.sh * 0.0583333
        var rows = Math.max(1, Math.floor(videoList.height / rowHeight) - 1)
        var next = Math.max(0, Math.min(videoList.count - 1, videoList.currentIndex + direction * rows))
        setVideoRowIndex(next)
        videoList.positionViewAtIndex(next, ListView.Contain)
    }

    Keys.onPressed: function(event) {
        if (mode === "library") {
            if (event.key === Qt.Key_Up) {
                libraryList.currentIndex = Math.max(0, libraryList.currentIndex - 1)
                currentPlaylistIndex = libraryList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                libraryList.currentIndex = Math.min(libraryList.count - 1, libraryList.currentIndex + 1)
                currentPlaylistIndex = libraryList.currentIndex
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                selectPlaylist(libraryList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                showAdd("ADD PLAYLIST")
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            }
            return
        }

        if (mode === "add") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                addPlaylist(playlistField.text)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                cancelAdd()
                event.accepted = true
            }
            return
        }

        if (mode === "tvmenu") {
            if (event.key === Qt.Key_Up) {
                tvMenuList.currentIndex = Math.max(0, tvMenuList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                tvMenuList.currentIndex = Math.min(tvMenuList.count - 1, tvMenuList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                selectTvMenu(tvMenuList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "commercialcategories") {
            if (event.key === Qt.Key_Up) {
                commercialCategoryList.currentIndex = Math.max(0, commercialCategoryList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                commercialCategoryList.currentIndex = Math.min(commercialCategoryList.count - 1,
                                                               commercialCategoryList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageCommercialCategories(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageCommercialCategories(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                toggleCommercialCategory(commercialCategoryList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                showTvMenu()
                event.accepted = true
            }
            return
        }

        if (mode === "store") {
            if (event.key === Qt.Key_Up) {
                storeList.currentIndex = Math.max(0, storeList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                storeList.currentIndex = Math.min(storeList.count - 1, storeList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                selectStorePlaylist(storeList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "tv") {
            if (event.key === Qt.Key_Up) {
                tuneTvRelative(1, false)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                tuneTvRelative(-1, false)
                event.accepted = true
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                tuneTvNow()
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                mpvController.sendKey("MENU")
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                exitTvMode()
                event.accepted = true
            }
            return
        }

        if (mode === "list") {
            if (event.key === Qt.Key_Up) {
                setVideoRowIndex(videoList.currentIndex - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                setVideoRowIndex(videoList.currentIndex + 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                pageVideoList(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                pageVideoList(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                selectVideoRow(videoList.currentIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                refreshCurrentPlaylist()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
            return
        }

        if (mode === "playing") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                playingTaterBumper = false
                pendingBumperVideoIndex = -1
                stoppingPlayback = true
                mpvController.stop()
                returnToVideoList()
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                mpvController.sendKey("MENU")
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                mpvController.sendKey("LEFT")
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                mpvController.sendKey("RIGHT")
                event.accepted = true
            } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                mpvController.sendKey("SPACE")
                event.accepted = true
            }
            return
        }

        if (mode === "message") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
                showAdd("ADD PLAYLIST")
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                loadPlaylistLibrary(currentPlaylistIndex)
                event.accepted = true
            }
        }
    }

    Component.onCompleted: loadPlaylistLibrary(0)

    Component.onDestruction: {
        if (mpvController.running)
            mpvController.stop()
    }

    Timer {
        id: addFocusTimer
        interval: 1
        repeat: false
        onTriggered: {
            playlistField.forceActiveFocus()
            playlistField.selectAll()
        }
    }

    Timer {
        id: addLookupTimer
        interval: 50
        repeat: false
        onTriggered: mixRoot.finishAddPlaylist(mixRoot.pendingPlaylistInput)
    }

    Timer {
        id: tvTuneTimer
        interval: mixRoot.tvTuneDelayMs
        repeat: false
        onTriggered: mixRoot.requestTvStream()
    }

    Connections {
        target: appCore

        function onModuleSettingChanged(mid, key, value) {
            if (mid !== mixRoot.moduleId || key !== "commercial_library_updated_ms")
                return
            if (mixRoot.mode === "commercialcategories")
                mixRoot.buildCommercialCategoryRows()
        }
    }

    Connections {
        target: youtubePlaylistBackend

        function onPlaylistLoaded(title, items) {
            if (tvModeActive && tvLoading) {
                handleTvPlaylistLoaded(title, items || [])
                return
            }

            loadingPlaylist = false
            playlistTitle = title || playlistTitle || "YOUTUBE PLAYLIST"
            updateCurrentPlaylistTitle(playlistTitle)
            videos = items || []
            buildVideoRows()
            if (videos.length === 0) {
                mode = "message"
                statusText = "PLAYLIST HAS NO VIDEOS"
                return
            }
            mode = "list"
            currentVideoIndex = Math.min(currentVideoIndex, videos.length - 1)
            setVideoRowIndex(videoRowForVideoIndex(currentVideoIndex))
        }

        function onErrorOccurred(message) {
            if (tvModeActive && tvLoading) {
                handleTvPlaylistError(message)
                return
            }

            loadingPlaylist = false
            mode = "message"
            statusText = message || "YOUTUBE PLAYLIST FAILED"
        }

        function onVideoStreamResolved(requestId, result) {
            handleTvStreamResolved(requestId, result)
        }
    }

    Connections {
        target: mpvController

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (tvModeActive) {
                playNextTvScheduleItem()
                return
            }
            if (mode !== "playing") return
            if (playingTaterBumper) {
                finishTaterBumper()
                return
            }
            if (autoplayNext() && playbackVideoIndex + 1 < playbackVideos.length) {
                var nextIndex = playbackVideoIndex + 1
                if (TaterBumpers.enabledByDefault(
                            appCore.get_setting("", "tater_bumpers_public_access_series")) &&
                        TaterBumpers.shouldPlayBetweenEpisodes(
                            "public-access", publicAccessSeriesKey())) {
                    playTaterBumperBeforeVideo(nextIndex)
                } else {
                    playPlaybackVideoIndex(nextIndex)
                }
                return
            }
            returnToVideoList()
        }

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (tvModeActive) {
                if (tvStoppingForTune) {
                    tvStoppingForTune = false
                    return
                }
                exitTvMode()
                return
            }
            if (stoppingPlayback) {
                stoppingPlayback = false
                return
            }
            if (playingTaterBumper) {
                finishTaterBumper()
                return
            }
            if (mode === "playing")
                returnToVideoList()
        }

        function onPlaybackFailed() {
            if (tvModeActive) {
                if (tvStoppingForTune) {
                    tvStoppingForTune = false
                    return
                }
                tvTransitionBlankVisible = false
                tvTuningStaticVisible = true
                tvStreamStarted = false
                statusText = tvChannels.length > 0 ? tvChannelLabel(tvChannels[tvCurrentChannelIndex]) : "TV MODE"
                if (mpvController.running) {
                    tvStoppingForTune = true
                    mpvController.stop()
                }
                tvTuneTimer.restart()
                return
            }
            if (playingTaterBumper) {
                finishTaterBumper()
                return
            }
            mode = "message"
            statusText = "YOUTUBE PLAYBACK FAILED"
            if (mpvController.running)
                mpvController.stop()
        }

        function onScriptMessageReceived(message, arg) {
            if (!tvModeActive)
                return
            if (message === "240mp-ota-file-loaded") {
                tvTransitionBlankVisible = false
                tvTuningStaticVisible = false
                tvStreamStarted = true
                return
            }
            if (message === "240mp-ota-tune-now") {
                tuneTvNow()
                return
            }
            if (message === "240mp-ota-last-channel") {
                tuneLastTvChannel()
                return
            }
            if (message !== "240mp-ota-channel-step")
                return

            var delta = parseInt(arg)
            if (isNaN(delta) || delta === 0)
                return
            tuneTvRelative(delta, false)
        }
    }

    StaticBackground {
        anchors.fill: parent
        themeName: root.currentTheme
        visible: mixRoot.backgroundStaticVisible
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: mixRoot.backgroundStaticVisible ? "transparent" : (mode === "tv" ? "black" : root.surfaceColor)
    }

    AppBar {
        visible: mode !== "tv"
        iconSource: moduleIcon
        iconHeight: root.sh * 0.075
        title: moduleName
        subtitle: mode === "list" ? playlistTitle
                  : (mode === "library" ? "PLAYLISTS"
                     : (mode === "tvmenu" ? "TV MODE"
                     : (mode === "commercialcategories" ? "COMMERCIALS"
                     : (mode === "store" ? "STORE" : "PUBLIC")))
                    )
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    Text {
        visible: mode === "loading" || mode === "message" || mode === "playing" || (mode === "tv" && tvLoading)
        text: mode === "playing" ? statusText : statusText
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.78
        wrapMode: Text.WordWrap
        font.pixelSize: root.sh * 0.045
    }

    Rectangle {
        visible: mode === "tv" && tvTuningStaticVisible && !tvLoading && !tvTransitionBlankVisible
        z: 5
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.sh * 0.09
        anchors.rightMargin: root.sw * 0.07
        width: Math.max(tvChannelText.implicitWidth + root.sw * 0.04, root.sw * 0.18)
        height: root.sh * 0.085
        color: "#60000000"
        border.color: root.primaryColor
        border.width: Math.max(1, root.sh * 0.004)

        Text {
            id: tvChannelText
            anchors.centerIn: parent
            text: statusText
            color: root.primaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.055
        }
    }

    Column {
        visible: mode === "add"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.sw * 0.115625
        anchors.rightMargin: root.sw * 0.115625
        spacing: root.sh * 0.025

        Text {
            text: statusText
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.0333333
        }

        Rectangle {
            width: parent.width
            height: root.sh * 0.075
            color: root.accentColor

            TextInput {
                id: playlistField
                anchors.fill: parent
                anchors.leftMargin: root.sw * 0.009375
                anchors.rightMargin: root.sw * 0.009375
                verticalAlignment: TextInput.AlignVCenter
                color: root.surfaceColor
                selectedTextColor: root.surfaceColor
                selectionColor: root.tertiaryColor
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.045
                clip: true

                function openInputKeyboard() {
                    root.openTaterKeyboard(
                                playlistField, "YOUTUBE PLAYLIST", false,
                                function() {
                                    mixRoot.addPlaylist(playlistField.text)
                                },
                                function() {
                                    playlistField.forceActiveFocus()
                                })
                }

                Keys.onReturnPressed: playlistField.openInputKeyboard()
                Keys.onEnterPressed: playlistField.openInputKeyboard()
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        mixRoot.cancelAdd()
                        event.accepted = true
                    }
                }

                TapHandler {
                    onTapped: playlistField.openInputKeyboard()
                }
            }
        }

        Text {
            text: "PASTE URL OR JUST THE LIST CODE"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.03
        }
    }

    ListView {
        id: libraryList
        visible: mode === "library"
        model: playlistRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible
        onCurrentIndexChanged: currentPlaylistIndex = currentIndex

        delegate: Item {
            width: libraryList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: playlistText
                color: root.accentColor
                visible: libraryList.currentIndex === index
            }

            Text {
                id: playlistText
                text: modelData.title || "PLAYLIST"
                color: libraryList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.05
            }
        }
    }

    ListView {
        id: tvMenuList
        visible: mode === "tvmenu"
        model: tvMenuRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible

        delegate: Item {
            width: tvMenuList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: tvMenuText
                color: root.accentColor
                visible: tvMenuList.currentIndex === index
            }

            Text {
                id: tvMenuText
                text: modelData.title || "TV MODE"
                color: tvMenuList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.05
            }
        }
    }

    ListView {
        id: commercialCategoryList
        visible: mode === "commercialcategories"
        model: commercialCategoryRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible

        delegate: Item {
            width: commercialCategoryList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: commercialCategoryText
                color: root.accentColor
                visible: commercialCategoryList.currentIndex === index
            }

            Text {
                id: commercialCategoryText
                text: modelData.title || "COMMERCIALS"
                color: commercialCategoryList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.05
            }
        }
    }

    ListView {
        id: storeList
        visible: mode === "store"
        model: storePlaylists
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible

        delegate: Item {
            width: storeList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: storeText
                color: root.accentColor
                visible: storeList.currentIndex === index
            }

            Text {
                id: storeText
                text: modelData.title || "PLAYLIST"
                color: storeList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.05
            }
        }
    }

    ListView {
        id: videoList
        visible: mode === "list"
        model: videoRows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625
        width: root.sw * 0.76875
        height: root.sh * 0.525
        clip: true
        focus: visible

        delegate: Item {
            width: videoList.width
            height: root.sh * 0.0583333

            Rectangle {
                anchors.fill: videoText
                color: root.accentColor
                visible: videoList.currentIndex === index
            }

            Text {
                id: videoText
                text: modelData.rowType === "shuffle"
                      ? "SHUFFLE"
                      : ((modelData.videoIndex + 1 < 10 ? "0" : "") + (modelData.videoIndex + 1) + "  " + (modelData.title || "VIDEO"))
                color: videoList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                elide: Text.ElideRight
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                font.pixelSize: root.sh * 0.05
            }
        }
    }
}
