import QtQuick
import Components

FocusScope {
    id: tvRoot

    property var navParams: ({})

    signal goBack()

    property string tubeModuleId: "com.240mp.usenet"
    property var sourceCategories: navParams.categories || []
    property var channels: []
    property var commercialPool: []
    property var tvLoadQueue: []
    property var tvCurrentLoad: ({})
    property var tvChannelMap: ({})
    property var tvChannelOrder: []
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

    function settingEnabled(moduleId, key, fallback) {
        var value = appCore.get_setting(moduleId, key)
        if (value === undefined || value === null || value === "")
            return fallback
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function commercialsEnabled() {
        return settingEnabled(tubeModuleId, "tube_tv_mode_commercials", true)
    }

    function midrollCommercialsEnabled() {
        return settingEnabled(tubeModuleId, "tube_midroll_commercials", false)
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

    function mediaKind(row) {
        return String((row && (row.mediaType || row.type)) || "").toLowerCase()
    }

    function intOrDefault(value, fallback) {
        if (value === undefined || value === null || value === "")
            return fallback
        var parsed = parseInt(value)
        return isNaN(parsed) ? fallback : parsed
    }

    function localCategoryRows() {
        for (var i = 0; i < sourceCategories.length; i++) {
            var row = sourceCategories[i] || ({})
            if (row.type === "localRoot")
                return (row.children || []).filter(function(child) { return child.type === "local" })
        }
        return []
    }

    function savedCustomChannels() {
        var saved = appCore.get_setting(tubeModuleId, "tube_custom_tv_channels")
        return Array.isArray(saved) ? saved : []
    }

    function autoChannelsEnabled() {
        var value = appCore.get_setting(tubeModuleId, "tube_auto_channels")
        if (value === undefined || value === null || value === "")
            return true
        return value === true || value === "ON" || value === "true" || value === "1"
    }

    function cleanUpper(value) {
        return String(value || "").trim().toUpperCase()
    }

    function sourceSearchText(item) {
        if (!item)
            return ""
        var parts = [
            item.title || "",
            item.name || "",
            item.detail || "",
            item.description || "",
            item.category || "",
            item.path || "",
            item.date || "",
            item.year || "",
            item.mediaType || "",
            item.type || ""
        ]
        var genres = item.genres || item.genre || []
        if (Array.isArray(genres))
            parts.push(genres.join(" "))
        else
            parts.push(genres)
        return parts.join(" ").toLowerCase()
    }

    function itemYear(item) {
        var candidates = [
            item ? item.year : "",
            item ? item.date : "",
            item ? item.title : "",
            item ? item.path : ""
        ]
        for (var i = 0; i < candidates.length; i++) {
            var match = String(candidates[i] || "").match(/(19[0-9]{2}|20[0-9]{2})/)
            if (match)
                return parseInt(match[1])
        }
        return 0
    }

    function textHasAnyTerm(text, terms) {
        var haystack = String(text || "").toLowerCase()
        for (var i = 0; i < terms.length; i++) {
            if (haystack.indexOf(String(terms[i]).toLowerCase()) >= 0)
                return true
        }
        return false
    }

    function programHasAnyTerm(program, terms) {
        return textHasAnyTerm(sourceSearchText(program), terms)
    }

    function groupHasAnyTerm(group, terms) {
        if (textHasAnyTerm(group ? group.title : "", terms))
            return true
        var episodes = group ? (group.episodes || []) : []
        for (var i = 0; i < episodes.length; i++) {
            if (programHasAnyTerm(episodes[i], terms))
                return true
        }
        return false
    }

    function groupYear(group) {
        var episodes = group ? (group.episodes || []) : []
        for (var i = 0; i < episodes.length; i++) {
            var year = itemYear(episodes[i])
            if (year > 0)
                return year
        }
        var match = String(group ? group.title : "").match(/(19[0-9]{2}|20[0-9]{2})/)
        return match ? parseInt(match[1]) : 0
    }

    function filteredPrograms(programs, predicate) {
        var rows = []
        for (var i = 0; i < (programs || []).length; i++) {
            var program = programs[i] || ({})
            if (predicate(program))
                rows.push(program)
        }
        return rows
    }

    function filteredGroups(groups, predicate) {
        var rows = []
        for (var i = 0; i < (groups || []).length; i++) {
            var group = groups[i] || ({})
            if (predicate(group))
                rows.push(group)
        }
        return rows
    }

    function decadeLabel(decade) {
        return decade >= 2000 ? (String(decade) + "S") : (String(decade).slice(2) + "S")
    }

    function themedTitle(sourceTitle, channelTitle) {
        var source = cleanUpper(sourceTitle)
        var title = cleanUpper(channelTitle)
        var generic = ["", "LOCAL", "MOVIES", "MOVIE", "TV", "TELEVISION", "SHOWS", "SERIES", "VIDEO"]
        for (var i = 0; i < generic.length; i++) {
            if (source === generic[i])
                return title
        }
        if (title.indexOf(source) === 0)
            return title
        return source + " " + title
    }

    function channelSignature(programs, groups) {
        var keys = []
        for (var i = 0; i < (programs || []).length; i++) {
            var program = programs[i] || ({})
            keys.push("p:" + (program.streamUrl || program.path || program.title || i))
        }
        for (var g = 0; g < (groups || []).length; g++) {
            var group = groups[g] || ({})
            keys.push("g:" + (group.title || g))
        }
        keys.sort()
        return keys.join("|")
    }

    function appendThemedSource(rows, signatures, title, sourceType, programs, groups, minCount, commercialCategory) {
        var programRows = programs || []
        var groupRows = groups || []
        var count = sourceType === "tv" ? groupRows.length : programRows.length
        if (count < minCount)
            return
        var signature = sourceType + ":" + channelSignature(programRows, groupRows)
        if (signature === sourceType + ":" || signatures[signature])
            return
        signatures[signature] = true
        rows.push({
            title: title,
            sourceType: "auto_theme",
            commercialCategory: commercialCategory || "",
            programs: programRows,
            groups: groupRows
        })
    }

    function themedSourcesFor(source) {
        var rows = []
        var signatures = ({})
        var programs = source.programs || []
        var groups = source.groups || []
        var baseTitle = source.title || "LOCAL"
        var commercialCategory = source.commercialCategory || ""
        var movieRules = [
            { title: "ACTION MOVIES", terms: ["action", "adventure", "thriller"], min: 2 },
            { title: "COMEDY MOVIES", terms: ["comedy"], min: 2 },
            { title: "HORROR MOVIES", terms: ["horror"], min: 2 },
            { title: "SCI-FI MOVIES", terms: ["science fiction", "sci-fi", "sci fi", "scifi"], min: 2 },
            { title: "FANTASY MOVIES", terms: ["fantasy"], min: 2 },
            { title: "FAMILY MOVIES", terms: ["family", "children", "kids", "disney", "pixar"], min: 2 },
            { title: "CARTOON MOVIES", terms: ["animation", "animated", "anime", "cartoon"], min: 2 },
            { title: "DOCUMENTARY MOVIES", terms: ["documentary", "docu"], min: 2 },
            { title: "DRAMA MOVIES", terms: ["drama"], min: 2 },
            { title: "CRIME MOVIES", terms: ["crime", "mystery"], min: 2 }
        ]
        for (var i = 0; i < movieRules.length; i++) {
            var rule = movieRules[i]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, rule.title), "movie",
                               filteredPrograms(programs, function(program) { return programHasAnyTerm(program, rule.terms) }),
                               [], rule.min, commercialCategory)
        }

        appendThemedSource(rows, signatures, themedTitle(baseTitle, "CLASSIC MOVIES"), "movie",
                           filteredPrograms(programs, function(program) {
                               var year = itemYear(program)
                               return year > 0 && year <= 1979
                           }), [], 2, commercialCategory)

        var decades = [1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
        for (var d = 0; d < decades.length; d++) {
            var decade = decades[d]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, decadeLabel(decade) + " MOVIES"), "movie",
                               filteredPrograms(programs, function(program) {
                                   var year = itemYear(program)
                                   return year >= decade && year < decade + 10
                               }), [], 2, commercialCategory)
        }

        var tvRules = [
            { title: "CARTOON CHANNEL", terms: ["animation", "animated", "anime", "cartoon", "children", "kids"], min: 1 },
            { title: "COMEDY CHANNEL", terms: ["comedy"], min: 1 },
            { title: "DRAMA CHANNEL", terms: ["drama"], min: 1 },
            { title: "SCI-FI CHANNEL", terms: ["science fiction", "sci-fi", "sci fi", "scifi"], min: 1 },
            { title: "ACTION CHANNEL", terms: ["action", "adventure"], min: 1 },
            { title: "CRIME CHANNEL", terms: ["crime", "mystery"], min: 1 },
            { title: "REALITY CHANNEL", terms: ["reality"], min: 1 },
            { title: "DOCUMENTARY CHANNEL", terms: ["documentary", "docu"], min: 1 }
        ]
        for (var r = 0; r < tvRules.length; r++) {
            var tvRule = tvRules[r]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, tvRule.title), "tv",
                               [], filteredGroups(groups, function(group) { return groupHasAnyTerm(group, tvRule.terms) }),
                               tvRule.min, commercialCategory)
        }

        appendThemedSource(rows, signatures, themedTitle(baseTitle, "CLASSIC TV"), "tv", [],
                           filteredGroups(groups, function(group) {
                               var year = groupYear(group)
                               return year > 0 && year <= 1979
                           }), 1, commercialCategory)

        for (var td = 0; td < decades.length; td++) {
            var tvDecade = decades[td]
            appendThemedSource(rows, signatures, themedTitle(baseTitle, decadeLabel(tvDecade) + " TV"), "tv", [],
                               filteredGroups(groups, function(group) {
                                   var year = groupYear(group)
                                   return year >= tvDecade && year < tvDecade + 10
                               }), 1, commercialCategory)
        }
        return rows
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
        var commercial = deck.shift()
        state.deck = deck
        return commercial
    }

    function commercialStateForChannel(channelSource, states) {
        var category = String((channelSource && channelSource.commercialCategory) || "").trim()
        var key = category === "" ? "__global__" : ("category:" + category)
        if (!states[key]) {
            states[key] = {
                pool: category === ""
                      ? commercialPool
                      : usenetBackend.get_commercial_videos_for_category(category),
                deck: []
            }
        }
        return states[key]
    }

    function appendScheduleItem(schedule, source, kind, startAt, segmentDuration, mediaOffset, forceAdvance) {
        if (!source)
            return startAt
        if (kind === "commercial") {
            if (!source.url)
                return startAt
        } else if (!source.streamUrl) {
            return startAt
        }

        var fallback = kind === "commercial" ? 30 : (kind === "movie" ? 5400 : 1500)
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

    function appendCommercialBreak(schedule, startAt, commercialState) {
        if (!commercialsEnabled() || commercialStatePool(commercialState).length === 0)
            return startAt

        var total = startAt
        var count = 1 + Math.floor(Math.random() * 3)
        for (var i = 0; i < count; i++) {
            var commercial = randomCommercialFromState(commercialState)
            if (commercial)
                total = appendScheduleItem(schedule, commercial, "commercial", total)
        }
        return total
    }

    function midrollOffsetsFor(kind, duration, commercialState) {
        if (!midrollCommercialsEnabled() || !commercialsEnabled() ||
                commercialStatePool(commercialState).length === 0)
            return []
        if (kind !== "movie" && kind !== "episode")
            return []
        if (duration < 1200)
            return []

        var count = kind === "movie"
            ? (duration >= 7200 ? 3 : (duration >= 3600 ? 2 : 1))
            : (duration >= 2700 ? 2 : 1)
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
        var offsets = midrollOffsetsFor(kind, fullDuration, commercialState)
        if (offsets.length === 0)
            return appendScheduleItem(schedule, source, kind, startAt)

        var total = startAt
        var cursor = 0
        for (var i = 0; i < offsets.length; i++) {
            var offset = Math.max(cursor + 5, Math.min(fullDuration - 5, offsets[i]))
            total = appendScheduleItem(schedule, source, kind, total,
                                       offset - cursor, cursor, true)
            total = appendCommercialBreak(schedule, total, commercialState)
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
            total = appendCommercialBreak(schedule, total, commercialState)
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
            var stateIndex = Math.floor(Math.random() * states.length)
            if (previousState >= 0 && Math.random() < 0.28)
                stateIndex = previousState

            var state = states[stateIndex]
            var episode = state.episodes[state.nextIndex % state.episodes.length]
            state.nextIndex++
            total = appendProgramWithMidroll(schedule, episode, "episode", total, commercialState)
            total = appendCommercialBreak(schedule, total, commercialState)
            previousState = stateIndex
        }

        return { schedule: schedule, totalDuration: total }
    }

    function buildMixedSchedule(programs, groups, commercialState) {
        var schedule = []
        var total = 0
        var movies = shuffleList(programs || [])
        var states = []
        var totalSlots = movies.length

        for (var i = 0; i < (groups || []).length; i++) {
            var group = groups[i] || ({})
            var episodes = group.episodes || []
            if (episodes.length > 0) {
                states.push({
                    group: group,
                    episodes: episodes,
                    nextIndex: Math.floor(Math.random() * episodes.length)
                })
                totalSlots += episodes.length
            }
        }

        var movieIndex = 0
        var previousState = -1
        for (var slot = 0; slot < totalSlots; slot++) {
            var useSeries = states.length > 0 && (movieIndex >= movies.length || Math.random() < 0.55)
            if (useSeries) {
                var stateIndex = Math.floor(Math.random() * states.length)
                if (previousState >= 0 && Math.random() < 0.34)
                    stateIndex = previousState
                var state = states[stateIndex]
                var episode = state.episodes[state.nextIndex % state.episodes.length]
                state.nextIndex++
                total = appendProgramWithMidroll(schedule, episode, "episode", total, commercialState)
                total = appendCommercialBreak(schedule, total, commercialState)
                previousState = stateIndex
            } else if (movieIndex < movies.length) {
                total = appendProgramWithMidroll(schedule, movies[movieIndex], "movie", total, commercialState)
                total = appendCommercialBreak(schedule, total, commercialState)
                movieIndex++
                previousState = -1
            }
        }
        return { schedule: schedule, totalDuration: total }
    }

    function ensureChannel(load) {
        var key = load.channelKey || load.categoryId || load.title || "local"
        if (!tvChannelMap[key]) {
            tvChannelMap[key] = {
                key: key,
                title: load.channelTitle || load.title || "LOCAL",
                sourceType: load.sourceType || "auto",
                commercialCategory: load.commercialCategory || "",
                programs: [],
                groups: []
            }
            tvChannelOrder.push(key)
        }
        return tvChannelMap[key]
    }

    function addFileToChannel(load, row) {
        if (!row || !row.streamUrl)
            return
        var channel = ensureChannel(load)
        var item = Object.assign({}, row)
        item.title = row.title || "LOCAL"
        var kind = mediaKind(row)
        if (kind === "episode") {
            var showTitle = load.showTitle || channel.title || "TV"
            var group = null
            for (var i = 0; i < channel.groups.length; i++) {
                if (channel.groups[i].title === showTitle) {
                    group = channel.groups[i]
                    break
                }
            }
            if (!group) {
                group = { title: showTitle, episodes: [] }
                channel.groups.push(group)
            }
            group.episodes.push(item)
        } else {
            channel.programs.push(item)
        }
    }

    function enqueueLoad(load) {
        if (!load || !load.categoryId)
            return
        tvLoadQueue.push(load)
    }

    function enqueueFolder(load, row) {
        var kind = mediaKind(row)
        var next = Object.assign({}, load, {
            title: row.title || load.title,
            path: row.path || "",
            sourceIndex: intOrDefault(row.sourceIndex, intOrDefault(load.sourceIndex, -1))
        })
        if (kind === "show")
            next.showTitle = row.title || load.showTitle || load.title
        enqueueLoad(next)
    }

    function processLoadedRows(rows) {
        var load = tvCurrentLoad || ({})
        for (var i = 0; i < (rows || []).length; i++) {
            var row = rows[i] || ({})
            if (row.type === "localFile")
                addFileToChannel(load, row)
            else if (row.type === "localFolder")
                enqueueFolder(load, row)
        }
    }

    function loadNextLocalBatch() {
        if (tvLoadQueue.length === 0) {
            buildReadyChannels()
            return
        }
        tvCurrentLoad = tvLoadQueue.shift()
        statusText = "SCANNING " + (tvCurrentLoad.title || tvCurrentLoad.channelTitle || "LOCAL")
        usenetBackend.load_local_items(tvCurrentLoad.categoryId || "",
                                       tvCurrentLoad.path || "",
                                       intOrDefault(tvCurrentLoad.sourceIndex, -1),
                                       tvCurrentLoad.title || tvCurrentLoad.channelTitle || "LOCAL")
    }

    function queueCustomChannels() {
        var custom = savedCustomChannels()
        for (var i = 0; i < custom.length; i++) {
            var channel = custom[i] || ({})
            var channelKey = "custom:" + (channel.id || channel.title || i)
            var items = channel.items || []
            ensureChannel({
                channelKey: channelKey,
                channelTitle: channel.title || "CUSTOM",
                sourceType: "custom",
                commercialCategory: channel.commercialCategory || ""
            })
            for (var j = 0; j < items.length; j++) {
                var item = items[j] || ({})
                var load = {
                    channelKey: channelKey,
                    channelTitle: channel.title || "CUSTOM",
                    sourceType: "custom",
                    commercialCategory: channel.commercialCategory || "",
                    categoryId: item.categoryId || item.id || "",
                    path: item.path || "",
                    sourceIndex: intOrDefault(item.sourceIndex, -1),
                    title: item.title || channel.title || "CUSTOM",
                    showTitle: item.mediaType === "show" ? item.title : ""
                }
                if (item.type === "localFile" && item.streamUrl)
                    addFileToChannel(load, item)
                else
                    enqueueLoad(load)
            }
        }
    }

    function startLocalLoad() {
        loading = true
        noSignalVisible = false
        tuningStaticVisible = true
        statusText = "SCANNING LOCAL"
        tvLoadQueue = []
        tvCurrentLoad = ({})
        tvChannelMap = ({})
        tvChannelOrder = []
        channels = []

        queueCustomChannels()

        if (autoChannelsEnabled()) {
            var localRows = localCategoryRows()
            for (var i = 0; i < localRows.length; i++) {
                var row = localRows[i] || ({})
                enqueueLoad({
                    channelKey: "auto:" + (row.id || row.categoryId || row.title || i),
                    channelTitle: row.title || "LOCAL",
                    sourceType: "auto",
                    categoryId: row.id || row.categoryId || "",
                    path: "",
                    sourceIndex: -1,
                    title: row.title || "LOCAL"
                })
            }
        }

        if (tvLoadQueue.length === 0 && tvChannelOrder.length === 0) {
            loading = false
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "NO CHANNELS AVAILABLE"
            return
        }
        loadNextLocalBatch()
    }

    function buildReadyChannels() {
        var ready = []
        var commercialStates = ({})
        var orderedSources = []
        for (var i = 0; i < tvChannelOrder.length; i++) {
            var source = tvChannelMap[tvChannelOrder[i]]
            if (source) {
                orderedSources.push(source)
                if (source.sourceType !== "custom") {
                    var themed = themedSourcesFor(source)
                    for (var t = 0; t < themed.length; t++)
                        orderedSources.push(themed[t])
                }
            }
        }

        for (var s = 0; s < orderedSources.length; s++) {
            var channelSource = orderedSources[s] || ({})
            var commercialState = commercialStateForChannel(channelSource, commercialStates)
            var groups = channelSource.groups || []
            var programs = channelSource.programs || []
            var scheduleData = groups.length > 0 && programs.length === 0
                ? buildTvSchedule(groups, commercialState)
                : (groups.length > 0
                   ? buildMixedSchedule(programs, groups, commercialState)
                   : buildMovieSchedule(programs, commercialState))
            if (!scheduleData.schedule || scheduleData.schedule.length === 0 ||
                    scheduleData.totalDuration <= 0) {
                continue
            }
            ready.push({
                number: padChannelNumber(ready.length + 2),
                title: channelSource.title || "LOCAL",
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

    function startCommercialLoad() {
        commercialPool = commercialsEnabled()
            ? usenetBackend.get_commercial_videos_for_setting("tube_commercial_categories")
            : []
        startLocalLoad()
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

    function usesServerSeek(item) {
        if (!item)
            return false
        return item.serverSeek === true || String(item.seekMode || "").toLowerCase() === "server"
    }

    function urlWithStartOffset(url, offset) {
        if (!url || offset <= 0.5)
            return url
        var hashIndex = url.indexOf("#")
        var base = hashIndex >= 0 ? url.slice(0, hashIndex) : url
        var hash = hashIndex >= 0 ? url.slice(hashIndex) : ""
        var separator = base.indexOf("?") >= 0 ? "&" : "?"
        return base + separator + "start=" + encodeURIComponent(offset.toFixed(3)) + hash
    }

    function showStaticForChannel(channel) {
        scheduleAdvanceTimer.stop()
        tuningStaticVisible = true
        noSignalVisible = false
        streamStarted = false
        stoppingForScheduleAdvance = false
        statusText = channelLabel(channel)

        if (mpvController.running) {
            stoppingForTune = true
            mpvController.stop()
        }
    }

    function requestSelectedStream() {
        tuneTimer.stop()
        if (loading || channels.length === 0)
            return

        var channel = selectedChannel()
        var resolved = findScheduleItem(channel)
        if (!resolved || !resolved.item ||
                (resolved.item.kind === "commercial"
                 ? !resolved.item.url
                 : !resolved.item.streamUrl)) {
            tuningStaticVisible = false
            noSignalVisible = true
            statusText = "LOCAL TV CHANNEL EMPTY"
            return
        }

        currentScheduleIndex = resolved.index
        var label = channelLabel(channel)
        statusText = label
        var url = resolved.item.kind === "commercial"
            ? resolved.item.url
            : resolved.item.streamUrl
        var offset = resolved.offset || 0.0
        if (resolved.item.kind !== "commercial" && usesServerSeek(resolved.item)) {
            url = urlWithStartOffset(url, offset)
            offset = 0.0
        }
        launchPlayback(url, offset, label,
                       resolved.segmentRemaining || 0.0, resolved.item)
    }

    function launchPlayback(url, offset, label, segmentRemaining, item) {
        if (!url) {
            noSignalVisible = true
            tuningStaticVisible = false
            statusText = "LOCAL TV PLAYBACK FAILED"
            return
        }

        streamStarted = true
        stoppingForTune = false
        stoppingForScheduleAdvance = false
        noSignalVisible = false
        mpvController.loadAndPlay(url, offset || 0.0, 0, -1, [], false, -1, 0.0,
                                  "", false, "ota", false, label || statusText)

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
        showStaticForChannel(channel)
        requestSelectedStream()
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
        if (loading)
            return
        requestSelectedStream()
    }

    function tuneLastChannel() {
        if (previousIndex < 0 || previousIndex >= channels.length)
            return
        tuneIndex(previousIndex, false)
    }

    function exitTvMode() {
        leaving = true
        tuneTimer.stop()
        scheduleAdvanceTimer.stop()
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
        } else if (event.key === Qt.Key_Left) {
            tuneLastChannel()
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            mpvController.sendKey("RIGHT")
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
        target: usenetBackend

        function onItemsLoaded(categoryTitle, rows) {
            if (!tvRoot.loading)
                return
            tvRoot.processLoadedRows(rows || [])
            tvRoot.loadNextLocalBatch()
        }

        function onErrorOccurred(message) {
            if (!tvRoot.loading)
                return
            tvRoot.loading = false
            tvRoot.tuningStaticVisible = false
            tvRoot.noSignalVisible = true
            tvRoot.statusText = message || "LOCAL TV FAILED"
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
            scheduleAdvanceTimer.stop()
            tvRoot.tuningStaticVisible = false
            tvRoot.noSignalVisible = true
            tvRoot.statusText = "LOCAL TV PLAYBACK FAILED"
        }

        function onScriptMessageReceived(message, arg) {
            if (message === "240mp-ota-file-loaded") {
                tvRoot.tuningStaticVisible = false
                tvRoot.streamStarted = true
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

    Component.onCompleted: startCommercialLoad()

    Component.onDestruction: {
        if (!leaving && mpvController.running)
            mpvController.stop()
    }

    StaticBackground {
        anchors.fill: parent
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
        visible: tvRoot.tuningStaticVisible && !tvRoot.loading
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
