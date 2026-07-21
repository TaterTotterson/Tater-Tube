.pragma library

var bumperDefinitions = [
    {
        title: "Tater Tube Etches",
        name: "etches-tater-tube-logo.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/etches-tater-tube-logo.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Flying and Landing",
        name: "flying-and-landing.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/flying-and-landing.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Juggling Potatoes",
        name: "juggling-potatoes.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/juggling-potatoes.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Archives Fun",
        name: "archives-fun-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/archives-fun-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Bicycle Kick",
        name: "bicycle-kick-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/bicycle-kick-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Launches Fireworks",
        name: "launches-fireworks-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/launches-fireworks-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Mixes Music",
        name: "mixes-music-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/mixes-music-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Parkour",
        name: "parkour-tater-tube-logo.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/parkour-tater-tube-logo.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Racing",
        name: "racing-on-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/racing-on-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Rakes Sand",
        name: "rakes-sand-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/rakes-sand-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Submersible Reveal",
        name: "submersible-reveals-tater-tube-logo.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/submersible-reveals-tater-tube-logo.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Cyberpunk Gaming",
        name: "cyberpunk-gaming-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/cyberpunk-gaming-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Motion Graphics",
        name: "motion-graphics-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/motion-graphics-tater-tube.mp4",
        duration: 8.0
    },
    {
        title: "Tater Tube Construction",
        name: "construction-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/construction-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Logo Formation",
        name: "logo-formation-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/logo-formation-tater-tube.mp4",
        duration: 10.005
    },
    {
        title: "Tater Tube Logo Inspection",
        name: "logo-inspection-tater-tube.mp4",
        relativeUrl: "../../assets/videos/tater-bumpers/logo-inspection-tater-tube.mp4",
        duration: 10.005
    }
]

var rotationSettingKey = "tater_bumper_rotation_log"
var rotationHistoryLimit = 100
var memoryRotationState = ({ version: 1, cycle: [], last: "", history: [] })
var episodeCountdowns = ({})

function enabledByDefault(raw) {
    return !(raw === false || raw === 0 || raw === "0" ||
             String(raw || "").trim().toLowerCase() === "off" ||
             String(raw || "").trim().toLowerCase() === "false")
}

function bumperItem(definition) {
    var duration = Number(definition.duration || 10.005)
    return {
        title: definition.title,
        name: definition.name,
        url: Qt.resolvedUrl(definition.relativeUrl).toString(),
        duration: duration,
        fullDuration: duration,
        durationKnown: true,
        local: true
    }
}

function all() {
    var items = []
    for (var i = 0; i < bumperDefinitions.length; i++)
        items.push(bumperItem(bumperDefinitions[i]))
    return items
}

function definitionFor(raw) {
    var name = ""
    var title = ""
    var url = ""
    if (typeof raw === "string") {
        name = raw
        title = raw
        url = raw
    } else if (raw) {
        name = String(raw.name || "")
        title = String(raw.title || "")
        url = String(raw.url || raw.streamUrl || "")
    }
    var normalizedName = name.trim().toLowerCase()
    var normalizedTitle = title.trim().toLowerCase()
    var normalizedUrl = url.trim().toLowerCase()
    for (var i = 0; i < bumperDefinitions.length; i++) {
        var definition = bumperDefinitions[i]
        if (normalizedName === definition.name.toLowerCase() ||
                normalizedTitle === definition.title.toLowerCase() ||
                normalizedUrl.indexOf("/" + definition.name.toLowerCase()) >= 0)
            return definition
    }
    return null
}

function sanitizeRotationState(raw) {
    var parsed = raw
    if (typeof raw === "string" && raw.trim() !== "") {
        try {
            parsed = JSON.parse(raw)
        } catch (error) {
            parsed = ({})
        }
    }
    if (!parsed || typeof parsed !== "object")
        parsed = ({})

    var cycle = []
    var rawCycle = parsed.cycle || []
    for (var i = 0; i < rawCycle.length; i++) {
        var definition = definitionFor(rawCycle[i])
        if (definition && cycle.indexOf(definition.name) < 0)
            cycle.push(definition.name)
    }

    var history = []
    var rawHistory = parsed.history || []
    for (var j = Math.max(0, rawHistory.length - rotationHistoryLimit);
         j < rawHistory.length; j++) {
        var entry = rawHistory[j] || ({})
        var historyDefinition = definitionFor(entry.name || entry)
        if (!historyDefinition)
            continue
        history.push({
            name: historyDefinition.name,
            title: historyDefinition.title,
            source: String(entry.source || ""),
            playedAt: Number(entry.playedAt || 0)
        })
    }

    var lastDefinition = definitionFor(parsed.last || "")
    return {
        version: 1,
        cycle: cycle,
        last: lastDefinition ? lastDefinition.name : "",
        history: history
    }
}

function loadRotationState(appCoreObject) {
    if (appCoreObject) {
        try {
            return sanitizeRotationState(
                        appCoreObject.get_setting("", rotationSettingKey))
        } catch (error) {
        }
    }
    memoryRotationState = sanitizeRotationState(memoryRotationState)
    return memoryRotationState
}

function saveRotationState(appCoreObject, state) {
    var clean = sanitizeRotationState(state)
    memoryRotationState = clean
    if (appCoreObject) {
        try {
            appCoreObject.save_setting(
                        "", rotationSettingKey, JSON.stringify(clean))
        } catch (error) {
        }
    }
}

function resetCompletedCycle(state) {
    if (state.cycle.length >= bumperDefinitions.length)
        state.cycle = []
}

function recordDefinition(state, definition, source) {
    if (state.cycle.indexOf(definition.name) < 0)
        state.cycle.push(definition.name)
    state.last = definition.name
    state.history.push({
        name: definition.name,
        title: definition.title,
        source: String(source || ""),
        playedAt: Date.now()
    })
    if (state.history.length > rotationHistoryLimit)
        state.history = state.history.slice(state.history.length - rotationHistoryLimit)
}

function chooseNextDefinition(state) {
    resetCompletedCycle(state)
    var available = []
    for (var i = 0; i < bumperDefinitions.length; i++) {
        if (state.cycle.indexOf(bumperDefinitions[i].name) < 0)
            available.push(bumperDefinitions[i])
    }
    if (available.length > 1 && state.cycle.length === 0 && state.last !== "") {
        var withoutLast = []
        for (var j = 0; j < available.length; j++) {
            if (available[j].name !== state.last)
                withoutLast.push(available[j])
        }
        if (withoutLast.length > 0)
            available = withoutLast
    }
    if (available.length === 0)
        return null
    return available[Math.floor(Math.random() * available.length)]
}

function next(appCoreObject, source) {
    if (bumperDefinitions.length === 0)
        return null
    var state = loadRotationState(appCoreObject)
    var definition = chooseNextDefinition(state)
    if (!definition)
        return null
    recordDefinition(state, definition, source)
    saveRotationState(appCoreObject, state)
    return bumperItem(definition)
}

// Record a bumper selected by a server-controlled schedule without replacing
// its URL. Live TV owns the item sequence and serves bumpers through the same
// endpoint as commercials, so substituting a bundled file would bypass that
// stream and can make the client timeline disagree with the server.
function recordScheduled(appCoreObject, scheduledItem, source) {
    var scheduled = definitionFor(scheduledItem)
    if (!scheduled)
        return

    var state = loadRotationState(appCoreObject)
    resetCompletedCycle(state)
    recordDefinition(state, scheduled, source)
    saveRotationState(appCoreObject, state)
}

// Claims a bumper selected by a TV schedule. If that bumper has already played
// in the current player-wide cycle, return a local replacement that has not.
// A null return means the scheduled bumper itself is safe to play.
function claimScheduled(appCoreObject, scheduledItem, source) {
    var scheduled = definitionFor(scheduledItem)
    if (!scheduled)
        return null

    var state = loadRotationState(appCoreObject)
    resetCompletedCycle(state)
    var repeatsLastAtCycleStart = state.cycle.length === 0 &&
            state.last === scheduled.name && bumperDefinitions.length > 1
    if (state.cycle.indexOf(scheduled.name) < 0 && !repeatsLastAtCycleStart) {
        recordDefinition(state, scheduled, source)
        saveRotationState(appCoreObject, state)
        return null
    }

    var replacement = chooseNextDefinition(state)
    if (!replacement)
        return null
    recordDefinition(state, replacement, source)
    saveRotationState(appCoreObject, state)
    return bumperItem(replacement)
}

function randomEpisodeInterval() {
    return 2 + Math.floor(Math.random() * 3)
}

function shouldPlayBetweenEpisodes(namespaceName, seriesKey) {
    var key = String(namespaceName || "series") + ":" + String(seriesKey || "unknown")
    var remaining = Number(episodeCountdowns[key])
    if (!isFinite(remaining) || remaining <= 0)
        remaining = randomEpisodeInterval()
    remaining--
    if (remaining <= 0) {
        episodeCountdowns[key] = randomEpisodeInterval()
        return true
    }
    episodeCountdowns[key] = remaining
    return false
}
