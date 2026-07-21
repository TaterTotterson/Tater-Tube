import QtQuick
import Components
import "../../shared/TaterBumpers.js" as TaterBumpers

FocusScope {
    id: tvRoot

    property var navParams: ({})

    signal goBack()

    property string youtubeModuleId: "com.240mp.youtube_playlist"
    property string vodModuleId: "com.240mp.emby_jellyfin"
    property var sourceChannels: []
    property var channels: []
    property var commercialPool: []
    property var taterBumperPool: TaterBumpers.all()
    property var taterBumperDeck: []
    property string lastTaterBumperKey: ""
    property int currentIndex: -1
    property int previousIndex: -1
    property int currentScheduleIndex: -1
    property double startedAtMs: 0
    property bool loading: true
    property bool leaving: false
    property bool tuningStaticVisible: true
    property bool noSignalVisible: false
    property bool stoppingForTune: false
    property bool stoppingForScheduleAdvance: false
    property bool streamStarted: false
    property bool streamRequestActive: false
    property bool transitionBlankVisible: false
    property bool channelTunePending: false
    property string pendingRequestId: ""
    property var pendingPlayback: ({})
    property int requestSerial: 0
    property int tuneDelayMs: 1200
    property string statusText: "LOADING TV MODE"

    focus: true

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

    function sharedSettingValue(key, fallback) {
        var value = appCore.get_setting(youtubeModuleId, key)
        if (value === undefined || value === null || value === "")
            return fallback
        return value
    }

    function commercialsEnabled() {
        var value = sharedSettingValue("tv_mode_commercials", true)
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function midrollCommercialsEnabled() {
        var value = appCore.get_setting(vodModuleId, "vod_midroll_commercials")
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function durationSeconds(item, fallback) {
        var raw = item ? item.duration : 0
        var value = typeof raw === "number" ? raw : parseFloat(raw)
        if (isNaN(value) || value <= 0)
            value = fallback
        if (value > 10000)
            value = value / 1000.0
        return Math.max(5, value)
    }

    function channelLabel(channel) {
        if (!channel) return "CH --"
        var title = String(channel.title || "").trim()
        return "CH " + (channel.number || "--") + (title !== "" ? " " + title : "")
    }

    function mediaItemKey(item) {
        if (!item)
            return ""
        return String(item.ratingKey || item.key || item.partKey || item.streamUrl ||
                      item.url || item.path || item.title || "").trim()
    }

    function isInterstitialKind(kind) {
        var normalized = String(kind || "").toLowerCase()
        return normalized === "commercial" || normalized === "bumper" ||
               normalized === "tater_bumper"
    }

    function lastProgramKey(schedule) {
        for (var i = (schedule || []).length - 1; i >= 0; i--) {
            var item = schedule[i] || ({})
            if (!isInterstitialKind(item.kind)) {
                var key = mediaItemKey(item)
                if (key !== "")
                    return key
            }
        }
        return ""
    }

    function stateCanAvoidRepeat(state, previousKey) {
        if (!state || previousKey === "")
            return true
        var episodes = state.episodes || []
        if (episodes.length === 0)
            return false
        if (mediaItemKey(episodes[state.nextIndex % episodes.length]) !== previousKey)
            return true
        return episodes.length > 1
    }

    function chooseStateIndex(states, previousState, stickiness, previousKey) {
        if (!states || states.length === 0)
            return -1
        var stateIndex = Math.floor(Math.random() * states.length)
        if (previousState >= 0 && Math.random() < stickiness)
            stateIndex = previousState
        if (stateCanAvoidRepeat(states[stateIndex], previousKey))
            return stateIndex
        for (var i = 0; i < states.length; i++) {
            if (stateCanAvoidRepeat(states[i], previousKey))
                return i
        }
        return stateIndex
    }

    function nextEpisodeForState(state, previousKey) {
        if (!state)
            return null
        var episodes = state.episodes || []
        if (episodes.length === 0)
            return null
        for (var i = 0; i < episodes.length; i++) {
            var episode = episodes[state.nextIndex % episodes.length]
            state.nextIndex++
            if (mediaItemKey(episode) !== previousKey || episodes.length === 1)
                return episode
        }
        return episodes[(state.nextIndex - 1 + episodes.length) % episodes.length]
    }

    function takeNextMovie(movies, movieIndex, previousKey) {
        if (!movies || movieIndex >= movies.length)
            return null
        if (previousKey !== "" && mediaItemKey(movies[movieIndex]) === previousKey) {
            for (var i = movieIndex + 1; i < movies.length; i++) {
                if (mediaItemKey(movies[i]) !== previousKey) {
                    var tmp = movies[movieIndex]
                    movies[movieIndex] = movies[i]
                    movies[i] = tmp
                    break
                }
            }
        }
        return movies[movieIndex]
    }

    function commercialStatePool(state) {
        return state && state.pool ? state.pool : []
    }

    function randomCommercialFromState(state) {
        var pool = commercialStatePool(state)
        if (pool.length === 0)
            return null
        var deck = state.deck || []
        if (deck.length === 0)
            deck = shuffleList(pool)
        var previousKey = state.lastKey || ""
        for (var attempt = 0; attempt < Math.max(2, pool.length + 1); attempt++) {
            if (deck.length === 0)
                deck = shuffleList(pool)
            var commercial = deck.shift()
            var key = mediaItemKey(commercial)
            if (pool.length > 1 && key !== "" && key === previousKey) {
                deck.push(commercial)
                continue
            }
            state.deck = deck
            state.lastKey = key
            return commercial
        }
        var fallback = deck.length > 0 ? deck.shift() : pool[0]
        state.deck = deck
        state.lastKey = mediaItemKey(fallback)
        return fallback
    }

    function nextTaterBumper() {
        var pool = taterBumperPool || []
        if (pool.length === 0)
            return null
        var deck = taterBumperDeck || []
        if (deck.length === 0)
            deck = shuffleList(pool)
        if (deck.length > 1 && mediaItemKey(deck[0]) === lastTaterBumperKey) {
            var swap = deck[0]
            deck[0] = deck[1]
            deck[1] = swap
        }
        var bumper = deck.shift()
        taterBumperDeck = deck
        lastTaterBumperKey = mediaItemKey(bumper)
        return bumper
    }

    function commercialStateForChannel(channelSource, states) {
        var category = ""
        if (channelSource && channelSource.channelType === "custom")
            category = String(channelSource.commercialCategory || "").trim()
        var key = category === "" ? "__global__" : ("category:" + category)
        if (!states[key]) {
            states[key] = {
                pool: category === ""
                      ? commercialPool
                      : youtubePlaylistBackend.get_commercial_videos_for_category(category),
                deck: []
            }
        }
        return states[key]
    }

    function appendScheduleItem(schedule, source, kind, startAt, segmentDuration, mediaOffset, forceAdvance) {
        if (!source)
            return startAt
        if (isInterstitialKind(kind)) {
            if (!source.url)
                return startAt
        } else if (!source.ratingKey) {
            return startAt
        }

        var fallback = kind === "commercial"
            ? 30
            : (kind === "tater_bumper" ? 10.005 : (kind === "movie" ? 5400 : 1500))
        var fullDuration = durationSeconds(source, fallback)
        var duration = segmentDuration === undefined || segmentDuration === null
                       ? fullDuration
                       : Math.max(5, segmentDuration)
        var item = Object.assign({}, source)
        item.kind = kind
        item.duration = duration
        item.fullDuration = fullDuration
        item.mediaOffset = Math.max(0, mediaOffset || 0)
        item.forceAdvance = forceAdvance === true
        item.start = startAt
        item.end = startAt + duration
        schedule.push(item)
        return item.end
    }

    function appendCommercialItems(schedule, startAt, commercialState, targetCount) {
        var pool = commercialStatePool(commercialState)
        var total = startAt
        var added = 0
        var attempts = 0
        var maxAttempts = Math.max(targetCount * 3, pool.length * 2)
        while (added < targetCount && attempts < maxAttempts) {
            attempts++
            var commercial = randomCommercialFromState(commercialState)
            if (commercial) {
                var before = total
                total = appendScheduleItem(schedule, commercial, "commercial", total)
                if (total > before)
                    added++
            }
        }
        return { total: total, added: added }
    }

    function appendTaterBumper(schedule, startAt) {
        if (!TaterBumpers.enabledByDefault(
                    appCore.get_setting("", "tater_bumpers_live_tv")))
            return startAt
        var bumper = nextTaterBumper()
        return bumper
            ? appendScheduleItem(schedule, bumper, "tater_bumper", startAt)
            : startAt
    }

    function appendCommercialBreak(schedule, startAt, commercialState, includeTaterBumper) {
        var pool = commercialStatePool(commercialState)
        if (!commercialsEnabled() || pool.length === 0)
            return includeTaterBumper ? appendTaterBumper(schedule, startAt) : startAt

        var total = startAt
        var targetCount = 2 + Math.floor(Math.random() * 3)
        if (includeTaterBumper) {
            var beforeBumper = appendCommercialItems(schedule, total, commercialState, 1)
            total = beforeBumper.total
            total = appendTaterBumper(schedule, total)
            var afterBumper = appendCommercialItems(
                        schedule, total, commercialState,
                        Math.max(0, targetCount - beforeBumper.added))
            return afterBumper.total
        }
        return appendCommercialItems(schedule, total, commercialState, targetCount).total
    }

    function midrollOffsetsFor(source, kind, duration, commercialState) {
        if (!midrollCommercialsEnabled() || !commercialsEnabled() ||
                commercialStatePool(commercialState).length === 0)
            return []
        if (kind !== "movie" && kind !== "episode")
            return []
        if (duration < 1200)
            return []

        var count = 1
        if (kind === "movie") {
            count = duration >= 7200 ? 3 : (duration >= 3600 ? 2 : 1)
        } else {
            count = duration >= 2700 ? 2 : 1
        }

        var guard = Math.min(900, Math.max(420, duration * 0.15))
        var jitter = Math.min(360, Math.max(90, duration * 0.06))
        var minGap = Math.min(900, Math.max(420, duration / (count + 2)))
        var offsets = []
        for (var i = 1; i <= count; i++) {
            var center = duration * (i / (count + 1))
            var offset = center + ((Math.random() * 2.0 - 1.0) * jitter)
            offset = Math.max(guard, Math.min(duration - guard, offset))
            if (offsets.length > 0 && offset - offsets[offsets.length - 1] < minGap)
                offset = offsets[offsets.length - 1] + minGap
            if (offset > guard && offset < duration - guard)
                offsets.push(offset)
        }
        return offsets
    }

    function appendProgramWithMidroll(schedule, source, kind, startAt, commercialState) {
        var fallback = kind === "movie" ? 5400 : 1500
        var fullDuration = durationSeconds(source, fallback)
        var offsets = midrollOffsetsFor(source, kind, fullDuration, commercialState)
        if (offsets.length === 0)
            return appendScheduleItem(schedule, source, kind, startAt)

        var total = startAt
        var cursor = 0
        for (var i = 0; i < offsets.length; i++) {
            var offset = Math.max(cursor + 5, Math.min(fullDuration - 5, offsets[i]))
            total = appendScheduleItem(schedule, source, kind, total,
                                       offset - cursor, cursor, true)
            total = appendCommercialBreak(schedule, total, commercialState, false)
            cursor = offset
        }
        if (fullDuration - cursor >= 5)
            total = appendScheduleItem(schedule, source, kind, total,
                                       fullDuration - cursor, cursor, false)
        return total
    }

    function buildMovieSchedule(programs, commercialState) {
        var schedule = []
        var total = 0
        var movies = shuffleList(programs || [])
        for (var i = 0; i < movies.length; i++) {
            total = appendProgramWithMidroll(schedule, movies[i], "movie", total, commercialState)
            total = appendCommercialBreak(schedule, total, commercialState, true)
        }
        return { schedule: schedule, totalDuration: total }
    }

    function buildTvSchedule(groups, commercialState) {
        var schedule = []
        var total = 0
        var states = []
        var totalEpisodes = 0

        for (var i = 0; i < (groups || []).length; i++) {
            var group = groups[i] || ({})
            var episodes = group.episodes || []
            if (episodes.length === 0)
                continue
            states.push({
                group: group,
                episodes: episodes,
                nextIndex: Math.floor(Math.random() * episodes.length)
            })
            totalEpisodes += episodes.length
        }

        if (states.length === 0 || totalEpisodes <= 0)
            return { schedule: [], totalDuration: 0 }

        var previousState = -1
        for (var slot = 0; slot < totalEpisodes; slot++) {
            var stateIndex = chooseStateIndex(states, previousState, 0.28,
                                             lastProgramKey(schedule))

            var state = states[stateIndex]
            var episode = nextEpisodeForState(state, lastProgramKey(schedule))
            if (!episode)
                continue
            total = appendProgramWithMidroll(schedule, episode, "episode", total, commercialState)
            total = appendCommercialBreak(schedule, total, commercialState, true)
            previousState = stateIndex
        }

        return { schedule: schedule, totalDuration: total }
    }

    function buildCustomSchedule(programs, commercialState) {
        var schedule = []
        var total = 0
        var movies = []
        var states = []
        var totalSlots = 0

        for (var i = 0; i < (programs || []).length; i++) {
            var program = programs[i] || ({})
            var episodes = program.episodes || []
            if (episodes.length > 0) {
                states.push({
                    group: program,
                    episodes: episodes,
                    nextIndex: Math.floor(Math.random() * episodes.length)
                })
                totalSlots += episodes.length
            } else if (program.ratingKey) {
                movies.push(program)
                totalSlots += 1
            }
        }

        if (totalSlots <= 0)
            return { schedule: [], totalDuration: 0 }

        var shuffledMovies = shuffleList(movies)
        var movieIndex = 0
        var previousState = -1
        for (var slot = 0; slot < totalSlots; slot++) {
            var useSeries = states.length > 0 && (movieIndex >= shuffledMovies.length || Math.random() < 0.55)
            if (useSeries) {
                var stateIndex = chooseStateIndex(states, previousState, 0.34,
                                                 lastProgramKey(schedule))
                var state = states[stateIndex]
                var episode = nextEpisodeForState(state, lastProgramKey(schedule))
                if (!episode)
                    continue
                total = appendProgramWithMidroll(schedule, episode, "episode", total, commercialState)
                total = appendCommercialBreak(schedule, total, commercialState, true)
                previousState = stateIndex
            } else if (movieIndex < shuffledMovies.length) {
                var movie = takeNextMovie(shuffledMovies, movieIndex, lastProgramKey(schedule))
                total = appendProgramWithMidroll(schedule, movie, "movie", total, commercialState)
                total = appendCommercialBreak(schedule, total, commercialState, true)
                movieIndex++
                previousState = -1
            }
        }

        return { schedule: schedule, totalDuration: total }
    }

    function buildReadyChannels(loadedChannels) {
        var ready = []
        var customChannels = []
        var generatedChannels = []
        var commercialStates = ({})
        var allowGeneratedChannels = autoChannelsEnabled()
        for (var s = 0; s < (loadedChannels || []).length; s++) {
            var channelSource = loadedChannels[s] || ({})
            if (channelSource.channelType === "custom")
                customChannels.push(channelSource)
            else if (allowGeneratedChannels)
                generatedChannels.push(channelSource)
        }
        var shuffled = customChannels.concat(shuffleList(generatedChannels))
        for (var i = 0; i < shuffled.length; i++) {
            var source = shuffled[i] || ({})
            var commercialState = commercialStateForChannel(source, commercialStates)
            var scheduleData = source.channelType === "custom"
                ? buildCustomSchedule(source.programs || [], commercialState)
                : (source.channelType === "tv"
                ? buildTvSchedule(source.programs || [], commercialState)
                : buildMovieSchedule(source.programs || [], commercialState))
            if (!scheduleData.schedule || scheduleData.schedule.length === 0 ||
                    scheduleData.totalDuration <= 0) {
                continue
            }

            ready.push({
                number: padChannelNumber(ready.length + 2),
                title: source.title || "VIDEO",
                channelType: source.channelType || "movie",
                schedule: scheduleData.schedule,
                totalDuration: scheduleData.totalDuration
            })
        }

        channels = ready
        loading = false
        currentScheduleIndex = -1
        previousIndex = -1
        startedAtMs = Date.now()

        if (channels.length === 0) {
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "NO CHANNELS AVAILABLE"
            return
        }

        tuneIndex(0, false)
    }

    function startCommercialLoad(loadedChannels) {
        sourceChannels = loadedChannels || []
        commercialPool = commercialsEnabled()
            ? youtubePlaylistBackend.get_commercial_videos_for_setting("vod_commercial_categories")
            : []
        buildReadyChannels(sourceChannels)
    }

    function autoChannelsEnabled() {
        var value = appCore.get_setting(vodModuleId, "vod_auto_channels")
        if (value === undefined || value === null || value === "")
            return true
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function selectedChannel() {
        if (currentIndex < 0 || currentIndex >= channels.length)
            return null
        return channels[currentIndex]
    }

    function findScheduleItem(channel) {
        if (!channel || !channel.schedule || channel.schedule.length === 0 ||
                channel.totalDuration <= 0) {
            return null
        }

        var elapsed = Math.max(0, (Date.now() - startedAtMs) / 1000.0)
        var position = elapsed % channel.totalDuration
        for (var i = 0; i < channel.schedule.length; i++) {
            var item = channel.schedule[i]
            if (position >= item.start && position < item.end) {
                var segmentOffset = Math.max(0, position - item.start)
                var mediaOffset = Math.max(0, item.mediaOffset || 0)
                return {
                    item: item,
                    index: i,
                    offset: mediaOffset + segmentOffset,
                    segmentRemaining: Math.max(0, item.duration - segmentOffset)
                }
            }
        }

        return { item: channel.schedule[0], index: 0, offset: channel.schedule[0].mediaOffset || 0,
                 segmentRemaining: channel.schedule[0].duration || 0 }
    }

    function showStaticForChannel(channel) {
        scheduleAdvanceTimer.stop()
        channelTunePending = true
        transitionBlankVisible = mpvController.running
        tuningStaticVisible = !mpvController.running
        noSignalVisible = false
        streamStarted = false
        streamRequestActive = false
        stoppingForScheduleAdvance = false
        pendingRequestId = ""
        pendingPlayback = ({})
        youtubePlaylistBackend.cancel_video_stream_resolve()
        statusText = channelLabel(channel)

        if (mpvController.running) {
            stoppingForTune = false
            mpvController.sendScriptMessage("240mp-ota-tune-transition", statusText)
        }
    }

    function requestScheduleItem(channel, item, index, offset, segmentRemaining) {
        if (!channel || !item ||
                (isInterstitialKind(item.kind)
                 ? !item.url
                 : !item.ratingKey)) {
            transitionBlankVisible = false
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "VOD TV CHANNEL EMPTY"
            if (mpvController.running) {
                stoppingForTune = true
                mpvController.stop()
            }
            return
        }

        currentScheduleIndex = index
        if (String(item.kind || "").toLowerCase() === "tater_bumper") {
            var replacement = TaterBumpers.claimScheduled(
                        appCore, item, "vod-live-tv")
            if (replacement) {
                item = Object.assign({}, item, replacement, {
                    kind: "tater_bumper"
                })
            }
        }
        streamRequestActive = true
        var label = channelLabel(channel)
        statusText = label

        var requestId = "vodtv-" + (++requestSerial)
        pendingRequestId = requestId
        pendingPlayback = {
            item: item,
            offset: offset || 0.0,
            segmentRemaining: segmentRemaining || 0.0,
            label: label
        }
        if (isInterstitialKind(item.kind)) {
            pendingRequestId = ""
            pendingPlayback = ({})
            launchPlayback(item.url || "", "", offset || 0.0,
                           label, false, "", segmentRemaining || 0.0, item)
        } else {
            embyBackend.prepare_vod_tv_stream(requestId, item)
        }
    }

    function requestSelectedStream() {
        tuneTimer.stop()
        if (loading || channels.length === 0)
            return

        var channel = selectedChannel()
        var resolved = findScheduleItem(channel)
        if (!resolved) {
            requestScheduleItem(channel, null, -1, 0.0, 0.0)
            return
        }
        requestScheduleItem(channel, resolved.item, resolved.index,
                            resolved.offset || 0.0,
                            resolved.segmentRemaining || 0.0)
    }

    function launchPlayback(url, httpHeaderFields, offset, label, allowYtdl, format, segmentRemaining, item) {
        if (!url) {
            transitionBlankVisible = false
            noSignalVisible = true
            tuningStaticVisible = false
            streamRequestActive = false
            statusText = "VOD TV PLAYBACK FAILED"
            if (mpvController.running) {
                stoppingForTune = true
                mpvController.stop()
            }
            return
        }

        streamStarted = true
        stoppingForTune = false
        stoppingForScheduleAdvance = false
        streamRequestActive = false
        noSignalVisible = false
        var oscMode = channelTunePending ? "ota-tune" : "ota-quiet"
        mpvController.setViewingContext(
            isInterstitialKind(item ? item.kind : "")
                ? ({ suppress_viewing_event: true })
                : ({}))
        mpvController.loadAndPlay(url, offset || 0.0, 0, -1, [], false, -1, 0.0,
                                  httpHeaderFields || "", false, oscMode, false, label || statusText,
                                  false, !!allowYtdl, format || "")

        scheduleAdvanceTimer.stop()
        if (item && item.forceAdvance === true && (segmentRemaining || 0) > 1.0) {
            scheduleAdvanceTimer.interval = Math.max(1000, Math.round(segmentRemaining * 1000))
            scheduleAdvanceTimer.restart()
        }
    }

    function playNextScheduleItem() {
        scheduleAdvanceTimer.stop()
        if (channels.length === 0)
            return

        var channel = selectedChannel()
        if (!channel || !channel.schedule || channel.schedule.length === 0) {
            requestSelectedStream()
            return
        }

        var nextIndex = currentScheduleIndex + 1
        if (nextIndex < 0 || nextIndex >= channel.schedule.length)
            nextIndex = 0

        var nextItem = channel.schedule[nextIndex]
        startedAtMs = Date.now() - Math.max(0, nextItem.start) * 1000.0
        channelTunePending = false
        transitionBlankVisible = true
        tuningStaticVisible = false
        noSignalVisible = false
        streamStarted = false
        streamRequestActive = false
        pendingRequestId = ""
        pendingPlayback = ({})
        youtubePlaylistBackend.cancel_video_stream_resolve()
        requestScheduleItem(channel, nextItem, nextIndex,
                            nextItem.mediaOffset || 0.0,
                            nextItem.duration || 0.0)
    }

    function tuneIndex(index, immediate) {
        if (loading || channels.length === 0)
            return
        if (index < 0)
            index = channels.length - 1
        if (index >= channels.length)
            index = 0
        if (currentIndex >= 0 && currentIndex !== index)
            previousIndex = currentIndex

        currentIndex = index
        currentScheduleIndex = -1
        showStaticForChannel(channels[currentIndex])
        if (immediate)
            requestSelectedStream()
        else
            tuneTimer.restart()
    }

    function tuneRelative(delta, immediate) {
        tuneIndex(currentIndex + delta, immediate)
    }

    function tuneNow() {
        if (loading || transitionBlankVisible || !tuningStaticVisible)
            return
        tuneTimer.stop()
        requestSelectedStream()
    }

    function tuneLastChannel() {
        if (previousIndex < 0 || previousIndex >= channels.length)
            return
        tuneIndex(previousIndex, false)
    }

    function exitTvMode() {
        leaving = true
        channelTunePending = false
        tuneTimer.stop()
        scheduleAdvanceTimer.stop()
        pendingRequestId = ""
        youtubePlaylistBackend.cancel_video_stream_resolve()
        if (mpvController.running)
            mpvController.stop()
        goBack()
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            exitTvMode()
            event.accepted = true
        } else if (loading) {
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            tuneRelative(1, false)
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            tuneRelative(-1, false)
            event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            tuneNow()
            event.accepted = true
        } else if (event.key === Qt.Key_Menu) {
            mpvController.sendKey("MENU")
            event.accepted = true
        }
    }

    Timer {
        id: tuneTimer
        interval: tvRoot.tuneDelayMs
        repeat: false
        onTriggered: tvRoot.requestSelectedStream()
    }

    Timer {
        id: scheduleAdvanceTimer
        repeat: false
        onTriggered: {
            if (tvRoot.leaving)
                return
            tvRoot.stoppingForScheduleAdvance = true
            if (mpvController.running)
                mpvController.stop()
            else
                tvRoot.playNextScheduleItem()
        }
    }

    Connections {
        target: embyBackend

        function onVodTvChannelsLoaded(loadedChannels) {
            if (tvRoot.leaving)
                return
            tvRoot.startCommercialLoad(loadedChannels || [])
        }

        function onVodTvStreamReady(requestId, item, url, httpHeaderFields) {
            if (requestId !== tvRoot.pendingRequestId)
                return
            var pending = tvRoot.pendingPlayback || ({})
            tvRoot.pendingRequestId = ""
            tvRoot.pendingPlayback = ({})
            tvRoot.launchPlayback(url, httpHeaderFields,
                                  pending.offset || 0.0,
                                  pending.label || tvRoot.statusText,
                                  false,
                                  "",
                                  pending.segmentRemaining || 0.0,
                                  pending.item || ({}))
        }

        function onVodTvStreamFailed(requestId, message) {
            if (requestId !== tvRoot.pendingRequestId)
                return
            tvRoot.pendingRequestId = ""
            tvRoot.pendingPlayback = ({})
            tvRoot.streamRequestActive = false
            tvRoot.transitionBlankVisible = false
            tvRoot.tuningStaticVisible = false
            tvRoot.noSignalVisible = true
            tvRoot.statusText = message || "VOD TV PLAYBACK FAILED"
            if (mpvController.running) {
                tvRoot.stoppingForTune = true
                mpvController.stop()
            }
        }

        function onErrorOccurred(message) {
            if (!tvRoot.loading)
                return
            tvRoot.loading = false
            tvRoot.transitionBlankVisible = false
            tvRoot.tuningStaticVisible = false
            tvRoot.noSignalVisible = true
            tvRoot.statusText = message || "VOD TV FAILED"
            if (mpvController.running) {
                tvRoot.stoppingForTune = true
                mpvController.stop()
            }
        }
    }

    Connections {
        target: mpvController

        function onPositionChanged(ms) {
            if (ms > 0 && tvRoot.streamStarted)
                tvRoot.tuningStaticVisible = false
        }

        function onPlaybackFinishedNaturally(finalPositionMs, finalDurationMs) {
            if (tvRoot.leaving)
                return
            scheduleAdvanceTimer.stop()
            tvRoot.playNextScheduleItem()
        }

        function onPlaybackFinished(finalPositionMs, finalDurationMs) {
            if (tvRoot.stoppingForScheduleAdvance) {
                tvRoot.stoppingForScheduleAdvance = false
                tvRoot.playNextScheduleItem()
                return
            }
            if (tvRoot.stoppingForTune) {
                tvRoot.stoppingForTune = false
                return
            }
            if (!tvRoot.leaving && tvRoot.streamStarted)
                tvRoot.exitTvMode()
        }

        function onPlaybackFailed() {
            if (tvRoot.stoppingForTune) {
                tvRoot.stoppingForTune = false
                return
            }
            tvRoot.streamRequestActive = false
            scheduleAdvanceTimer.stop()
            tvRoot.transitionBlankVisible = false
            tvRoot.tuningStaticVisible = false
            tvRoot.noSignalVisible = true
            tvRoot.statusText = "VOD TV PLAYBACK FAILED"
            if (mpvController.running) {
                tvRoot.stoppingForTune = true
                mpvController.stop()
            }
        }

        function onScriptMessageReceived(message, arg) {
            if (message === "240mp-ota-file-loaded") {
                var showTunedChannel = tvRoot.channelTunePending
                tvRoot.channelTunePending = false
                tvRoot.transitionBlankVisible = false
                tvRoot.tuningStaticVisible = false
                tvRoot.streamStarted = true
                if (showTunedChannel)
                    mpvController.sendScriptMessage("240mp-ota-tuned-channel", tvRoot.statusText)
                return
            }

            if (message === "240mp-ota-tune-now") {
                tvRoot.tuneNow()
                return
            }

            if (message === "240mp-ota-last-channel") {
                tvRoot.tuneLastChannel()
                return
            }

            if (message !== "240mp-ota-channel-step")
                return

            var delta = parseInt(arg)
            if (isNaN(delta) || delta === 0)
                return
            tvRoot.tuneRelative(delta, false)
        }
    }

    Component.onCompleted: {
        if (menuSoundPlayer)
            menuSoundPlayer.setContextActive("qml:vod-tv", true)
        embyBackend.load_vod_tv_channels(false)
    }

    Component.onDestruction: {
        if (menuSoundPlayer)
            menuSoundPlayer.setContextActive("qml:vod-tv", false)
        if (!leaving && mpvController.running)
            mpvController.stop()
    }

    StaticBackground {
        anchors.fill: parent
        themeName: root.currentTheme
        visible: tvRoot.tuningStaticVisible
        running: visible
    }

    Rectangle {
        anchors.fill: parent
        color: tvRoot.tuningStaticVisible ? "transparent" : "black"
    }

    NoSignalScreen {
        anchors.fill: parent
        visible: tvRoot.noSignalVisible
        inputLabel: "VIDEO"
        message: "NO SIGNAL"
        detail: tvRoot.statusText
        z: 4
    }

    Text {
        visible: tvRoot.loading
        text: tvRoot.statusText
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.78
        wrapMode: Text.WordWrap
        font.pixelSize: root.sh * 0.045
        z: 6
    }

    Rectangle {
        visible: tvRoot.channelTunePending && tvRoot.tuningStaticVisible
                 && !tvRoot.loading && !tvRoot.transitionBlankVisible
        z: 5
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.sh * 0.09
        anchors.rightMargin: root.sw * 0.07
        width: Math.min(root.sw * 0.66,
                        Math.max(channelText.implicitWidth + root.sw * 0.04,
                                 root.sw * 0.18))
        height: root.sh * 0.085
        color: "#60000000"
        border.color: root.primaryColor
        border.width: Math.max(1, root.sh * 0.004)

        Text {
            id: channelText
            anchors.centerIn: parent
            width: parent.width - root.sw * 0.025
            text: tvRoot.statusText
            color: root.primaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.055
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
