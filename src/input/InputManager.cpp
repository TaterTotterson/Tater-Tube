#include "InputManager.h"

#include <QCoreApplication>
#include <QDir>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSocketNotifier>
#include <QTextStream>

#include <cstring>

#ifdef Q_OS_LINUX
#include <cerrno>
#include <fcntl.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <unistd.h>
#endif

namespace {
// Planted in nativeScanCode of synthesized events so the keyboard detector in
// eventFilter() can tell our gamepad-originated key events from real key presses.
constexpr quint32 kSyntheticScanCode = 0x240F00D;

// Analog stick thresholds (of ±32768). Engage above one, release below the
// other — the gap prevents flutter when the stick rests near the threshold.
constexpr Sint16 kAxisEngage  = 16384;
constexpr Sint16 kAxisRelease = 12000;

// Held-direction auto-repeat, tuned to feel like keyboard repeat in lists.
constexpr int kRepeatDelayMs    = 400;
constexpr int kRepeatIntervalMs = 100;
constexpr const char *kControllerMappingFile = "controller-map.json";
constexpr const char *kGeneratedInputStart = "# --- Tater Tube controller mapper start ---";
constexpr const char *kGeneratedInputEnd = "# --- Tater Tube controller mapper end ---";

// Qt reports both shift keys as Qt::Key_Shift; telling them apart takes the
// platform code. Linux keymaps (eglfs/evdev, X11, Wayland) report evdev's
// KEY_RIGHTSHIFT, with or without the X11-style +8 offset; macOS reports
// kVK_RightShift in the virtual key.
bool isRightShift(const QKeyEvent *ke) {
#ifdef Q_OS_MACOS
    return ke->nativeVirtualKey() == 0x3C;   // kVK_RightShift
#else
    const quint32 sc = ke->nativeScanCode();
    return sc == 54 || sc == 62;             // KEY_RIGHTSHIFT, +8 offset
#endif
}

QString buttonToken(Uint8 button)
{
    const char *name = SDL_GameControllerGetStringForButton(
        static_cast<SDL_GameControllerButton>(button));
    return name ? QString::fromLatin1(name).toLower() : QString();
}

QString axisName(Uint8 axis)
{
    const char *name = SDL_GameControllerGetStringForAxis(
        static_cast<SDL_GameControllerAxis>(axis));
    return name ? QString::fromLatin1(name).toLower() : QString();
}

QString displayToken(QString value)
{
    value.replace('_', ' ');
    value.replace('-', " -");
    value.replace('+', " +");
    return value.toUpper();
}

Uint8 hatMaskForDirection(const QString &direction)
{
    if (direction == QStringLiteral("up"))    return SDL_HAT_UP;
    if (direction == QStringLiteral("down"))  return SDL_HAT_DOWN;
    if (direction == QStringLiteral("left"))  return SDL_HAT_LEFT;
    if (direction == QStringLiteral("right")) return SDL_HAT_RIGHT;
    return SDL_HAT_CENTERED;
}

bool isLikelyRawTriggerAxis(Uint8 axis)
{
    return axis == 2 || axis == 5;
}
}

InputManager::InputManager(const QString &dataRoot, QObject *parent)
    : QObject(parent)
    , m_dataRoot(dataRoot)
{
    m_repeatDelayTimer.setSingleShot(true);
    m_repeatDelayTimer.setInterval(kRepeatDelayMs);
    m_repeatTimer.setInterval(kRepeatIntervalMs);
    connect(&m_pollTimer,        &QTimer::timeout, this, &InputManager::pollSdl);
    connect(&m_repeatDelayTimer, &QTimer::timeout, this, &InputManager::onRepeatDelayElapsed);
    connect(&m_repeatTimer,      &QTimer::timeout, this, &InputManager::onRepeatTick);

    rebuildMapping();
    initSdl();
#ifdef Q_OS_LINUX
    initIrReceiver();
#endif

    // Watch the data dir (not the file) so input.cfg can appear later and so
    // replace-on-save editors are caught; mtime check filters unrelated writes
    // (e.g. config.json saves land in the same dir).
    m_cfgLastModified = QFileInfo(m_dataRoot + "/input.cfg").lastModified();
    m_watcher.addPath(m_dataRoot);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged,
            this, &InputManager::onDataDirChanged);

    // App-wide filter: any real key press marks the keyboard as the active device.
    QCoreApplication::instance()->installEventFilter(this);
}

InputManager::~InputManager() {
#ifdef Q_OS_LINUX
    closeIrDevice();
#endif
    for (SDL_GameController *gc : std::as_const(m_controllers))
        SDL_GameControllerClose(gc);
    m_controllers.clear();
    for (SDL_Joystick *joy : std::as_const(m_joysticks))
        SDL_JoystickClose(joy);
    m_joysticks.clear();
    m_rawJoystickNames.clear();
    if (m_sdlReady)
        SDL_Quit();
}

QVariantMap InputManager::getControllerMapping() const
{
    QFile file(QDir(m_dataRoot).absoluteFilePath(QString::fromUtf8(kControllerMappingFile)));
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    return doc.object().toVariantMap();
}

bool InputManager::saveControllerMapping(const QVariantMap &mapping)
{
    QVariantMap payload = mapping;
    payload["version"] = 1;
    payload["updated_at"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    QVariantMap bindings = payload.value(QStringLiteral("bindings")).toMap();
    bindings.remove(QStringLiteral("exit"));
    payload[QStringLiteral("bindings")] = bindings;

    QDir().mkpath(m_dataRoot);
    const QString mappingPath = QDir(m_dataRoot).absoluteFilePath(QString::fromUtf8(kControllerMappingFile));
    QSaveFile mappingFile(mappingPath);
    if (!mappingFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[input] could not write controller map: %s", qPrintable(mappingFile.errorString()));
        return false;
    }
    mappingFile.write(QJsonDocument(QJsonObject::fromVariantMap(payload)).toJson(QJsonDocument::Indented));
    if (!mappingFile.commit()) {
        qWarning("[input] could not commit controller map: %s", qPrintable(mappingFile.errorString()));
        return false;
    }

    const QList<QPair<QString, QString>> appBindings{
        {QStringLiteral("up"), QStringLiteral("up")},
        {QStringLiteral("down"), QStringLiteral("down")},
        {QStringLiteral("left"), QStringLiteral("left")},
        {QStringLiteral("right"), QStringLiteral("right")},
        {QStringLiteral("b"), QStringLiteral("select")},
        {QStringLiteral("a"), QStringLiteral("back")},
        {QStringLiteral("menu"), QStringLiteral("menu")},
        {QStringLiteral("start"), QStringLiteral("play_pause")},
        {QStringLiteral("home"), QStringLiteral("home")}
    };

    QString generated;
    QTextStream generatedStream(&generated);
    generatedStream << kGeneratedInputStart << '\n';
    generatedStream << "# Generated from Settings > Controller Mapper.\n";
    for (const auto &pair : appBindings) {
        const QVariantMap binding = bindings.value(pair.first).toMap();
        const QString token = binding.value(QStringLiteral("inputToken")).toString();
        if (!token.isEmpty())
            generatedStream << token << ' ' << pair.second << '\n';
    }
    generatedStream << kGeneratedInputEnd << '\n';

    const QString inputPath = QDir(m_dataRoot).absoluteFilePath(QStringLiteral("input.cfg"));
    QString existing;
    {
        QFile inputFile(inputPath);
        if (inputFile.open(QIODevice::ReadOnly | QIODevice::Text))
            existing = QString::fromUtf8(inputFile.readAll());
    }

    const int start = existing.indexOf(QString::fromUtf8(kGeneratedInputStart));
    const int end = existing.indexOf(QString::fromUtf8(kGeneratedInputEnd));
    QString next = existing;
    if (start >= 0 && end >= start) {
        const int blockEnd = end + int(strlen(kGeneratedInputEnd));
        next.replace(start, blockEnd - start, generated.trimmed());
    } else {
        if (!next.isEmpty() && !next.endsWith('\n'))
            next.append('\n');
        if (!next.isEmpty())
            next.append('\n');
        next.append(generated);
    }

    QSaveFile inputFile(inputPath);
    if (!inputFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[input] could not write input.cfg: %s", qPrintable(inputFile.errorString()));
        return false;
    }
    inputFile.write(next.toUtf8());
    if (!inputFile.commit()) {
        qWarning("[input] could not commit input.cfg: %s", qPrintable(inputFile.errorString()));
        return false;
    }

    m_cfgLastModified = QFileInfo(inputPath).lastModified();
    rebuildMapping();
    return true;
}

void InputManager::beginControllerMapping()
{
    m_controllerMappingActive = true;
    m_controllerInputSeen.clear();
    m_pressedInputTokens.clear();
    primeControllerMappingState();
    m_gameExitComboLatched = false;
    m_repeatDelayTimer.stop();
    m_repeatTimer.stop();
    m_heldDirection = Action::None;
}

void InputManager::endControllerMapping()
{
    m_controllerMappingActive = false;
    m_mappingAxisState.clear();
    m_mappingJoystickAxisState.clear();
    m_mappingJoystickHatState.clear();
    m_mappingCapturedTokens.clear();
    m_mappingCapturedPositiveAxes.clear();
    m_mappingCapturedPositiveJoystickAxes.clear();
    m_pressedInputTokens.clear();
    m_gameExitComboLatched = false;
}

void InputManager::setTargetWindow(QQuickWindow *window) {
    m_window = window;
}

// ── SDL lifecycle ─────────────────────────────────────────────────────────────

void InputManager::initSdl() {
    // Keep receiving controller events while another window (mpv fullscreen)
    // has OS focus, and don't let SDL steal SIGINT/SIGTERM from Qt.
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    // Force positional button semantics on Nintendo-type pads (default is
    // label-based there): "a" always means the SOUTH position, on every pad.
    SDL_SetHint(SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0");

    // No video subsystem, so this works headless (EGLFS). Keep raw joystick
    // events enabled as a fallback for pads SDL can open but not map cleanly.
    if (SDL_Init(SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK) != 0) {
        qWarning("[input] SDL init failed: %s — gamepad support disabled", SDL_GetError());
        return;
    }
    m_sdlReady = true;
    SDL_GameControllerEventState(SDL_ENABLE);
    SDL_JoystickEventState(SDL_ENABLE);

    const QString dbPath = m_dataRoot + "/gamecontrollerdb.txt";
    if (QFile::exists(dbPath)) {
        int added = SDL_GameControllerAddMappingsFromFile(dbPath.toUtf8().constData());
        if (added >= 0)
            qInfo("[input] loaded %d controller mappings from gamecontrollerdb.txt", added);
        else
            qWarning("[input] could not parse gamecontrollerdb.txt: %s", SDL_GetError());
    }

    // SDL emits CONTROLLERDEVICEADDED for already-connected pads on init,
    // so the poll loop handles initial enumeration and hotplug identically.
    m_pollTimer.start(16);
    qInfo("[input] SDL controller/joystick subsystem ready");
}

void InputManager::pollSdl() {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
        case SDL_CONTROLLERDEVICEADDED:   openController(e.cdevice.which);  break;
        case SDL_CONTROLLERDEVICEREMOVED: closeController(e.cdevice.which); break;
        case SDL_JOYDEVICEADDED:          openJoystick(e.jdevice.which);    break;
        case SDL_JOYDEVICEREMOVED:        closeJoystick(e.jdevice.which);   break;
        case SDL_CONTROLLERBUTTONDOWN:
            handleButton(e.cbutton.which, e.cbutton.button, true);
            break;
        case SDL_CONTROLLERBUTTONUP:
            handleButton(e.cbutton.which, e.cbutton.button, false);
            break;
        case SDL_CONTROLLERAXISMOTION:
            handleAxis(e.caxis.which, e.caxis.axis, e.caxis.value);
            break;
        case SDL_JOYBUTTONDOWN:
            handleJoystickButton(e.jbutton.which, e.jbutton.button, true);
            break;
        case SDL_JOYBUTTONUP:
            handleJoystickButton(e.jbutton.which, e.jbutton.button, false);
            break;
        case SDL_JOYAXISMOTION:
            handleJoystickAxis(e.jaxis.which, e.jaxis.axis, e.jaxis.value);
            break;
        case SDL_JOYHATMOTION:
            handleJoystickHat(e.jhat.which, e.jhat.hat, e.jhat.value);
            break;
        default: break;
        }
    }
}

void InputManager::openController(int deviceIndex) {
    SDL_GameController *gc = SDL_GameControllerOpen(deviceIndex);
    if (!gc) {
        qWarning("[input] could not open controller %d: %s", deviceIndex, SDL_GetError());
        return;
    }
    SDL_JoystickID id = SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(gc));
    m_controllers.insert(id, gc);
    const char *controllerName = SDL_GameControllerName(gc);
    const QString name = controllerName ? QString::fromUtf8(controllerName) : QStringLiteral("Controller");
    if (!shouldIgnoreJoystickName(name))
        m_rawJoystickNames.insert(id, name);
    qInfo("[input] controller added: %s", qPrintable(name));
    ensureDefaultControllerMapping(id, gc);
    emit gamepadConnectedChanged();
}

void InputManager::closeController(SDL_JoystickID instanceId) {
    SDL_GameController *gc = m_controllers.take(instanceId);
    if (!gc)
        return;
    qInfo("[input] controller removed: %s", SDL_GameControllerName(gc));
    SDL_GameControllerClose(gc);
    m_rawJoystickNames.remove(instanceId);
    m_controllerInputSeen.remove(instanceId);

    // Don't leave a direction repeating (or an axis latched) after unplug.
    if (m_heldDirection != Action::None)
        releaseAction(m_heldDirection);
    m_axisState.clear();
    m_joystickAxisState.clear();
    m_mappingJoystickAxisState.clear();
    m_joystickHatState.clear();
    m_mappingJoystickHatState.clear();
    m_pressedInputTokens.clear();
    m_gameExitComboLatched = false;
    if (m_lastActiveController == instanceId) {
        m_lastActiveController = -1;
        updateHints();
    }
    emit gamepadConnectedChanged();
}

void InputManager::openJoystick(int deviceIndex) {
    const char *rawName = SDL_JoystickNameForIndex(deviceIndex);
    const QString name = rawName ? QString::fromUtf8(rawName) : QStringLiteral("Joystick");
    if (shouldIgnoreJoystickName(name)) {
        qInfo("[input] ignoring auxiliary joystick: %s", qPrintable(name));
        return;
    }

    const SDL_JoystickID deviceId = SDL_JoystickGetDeviceInstanceID(deviceIndex);
    if (deviceId >= 0 && m_controllers.contains(deviceId)) {
        m_rawJoystickNames.insert(deviceId, name);
        qInfo("[input] raw joystick fallback attached to controller: %s", qPrintable(name));
        emit gamepadConnectedChanged();
        return;
    }

    if (SDL_IsGameController(deviceIndex)) {
        // The matching controller-added event will attach the raw fallback via
        // SDL_GameControllerGetJoystick(), avoiding a double-open of the pad.
        return;
    }

    SDL_Joystick *joy = SDL_JoystickOpen(deviceIndex);
    if (!joy) {
        qWarning("[input] could not open joystick %d: %s", deviceIndex, SDL_GetError());
        return;
    }

    const SDL_JoystickID id = SDL_JoystickInstanceID(joy);
    m_joysticks.insert(id, joy);
    m_rawJoystickNames.insert(id, name);
    qInfo("[input] raw joystick added: %s", qPrintable(name));
    ensureDefaultJoystickMapping(id);
    emit gamepadConnectedChanged();
}

void InputManager::closeJoystick(SDL_JoystickID instanceId) {
    const bool hadRaw = m_rawJoystickNames.remove(instanceId) > 0;
    SDL_Joystick *joy = m_joysticks.take(instanceId);
    if (joy) {
        const char *name = SDL_JoystickName(joy);
        qInfo("[input] raw joystick removed: %s", name ? name : "Joystick");
        SDL_JoystickClose(joy);
    }
    m_controllerInputSeen.remove(instanceId);

    if (m_heldDirection != Action::None)
        releaseAction(m_heldDirection);
    m_joystickAxisState.clear();
    m_mappingJoystickAxisState.clear();
    m_joystickHatState.clear();
    m_mappingJoystickHatState.clear();
    m_pressedInputTokens.clear();
    m_gameExitComboLatched = false;
    if (m_lastActiveController == instanceId) {
        m_lastActiveController = -1;
        updateHints();
    }
    if (hadRaw || joy)
        emit gamepadConnectedChanged();
}

// ── Mapping ───────────────────────────────────────────────────────────────────

void InputManager::rebuildMapping() {
    loadDefaultMapping();
    loadUserMapping();
    loadGameExitCombo(getControllerMapping().value(QStringLiteral("bindings")).toMap());
    updateHints();
}

void InputManager::loadDefaultMapping() {
    m_buttonMap.clear();
    m_axisMap.clear();
    m_joystickButtonMap.clear();
    m_joystickAxisMap.clear();
    m_joystickHatMap.clear();
    m_labelOverrides.clear();
    m_buttonMap[SDL_CONTROLLER_BUTTON_DPAD_UP]       = Action::Up;
    m_buttonMap[SDL_CONTROLLER_BUTTON_DPAD_DOWN]     = Action::Down;
    m_buttonMap[SDL_CONTROLLER_BUTTON_DPAD_LEFT]     = Action::Left;
    m_buttonMap[SDL_CONTROLLER_BUTTON_DPAD_RIGHT]    = Action::Right;
    m_buttonMap[SDL_CONTROLLER_BUTTON_A]             = Action::Select;
    m_buttonMap[SDL_CONTROLLER_BUTTON_B]             = Action::Back;
    m_buttonMap[SDL_CONTROLLER_BUTTON_BACK]          = Action::Back;
    m_buttonMap[SDL_CONTROLLER_BUTTON_START]         = Action::PlayPause;
    m_buttonMap[SDL_CONTROLLER_BUTTON_GUIDE]         = Action::Home;
    m_buttonMap[SDL_CONTROLLER_BUTTON_LEFTSHOULDER]  = Action::Left;
    m_buttonMap[SDL_CONTROLLER_BUTTON_RIGHTSHOULDER] = Action::Right;
    m_axisMap[SDL_CONTROLLER_AXIS_LEFTX] = { Action::Left, Action::Right };
    m_axisMap[SDL_CONTROLLER_AXIS_LEFTY] = { Action::Up,   Action::Down  };

    // Raw Linux joystick fallback. DualSense reports D-pad as axes 6/7 on the
    // Pi, while many generic pads use a hat or left-stick axes 0/1.
    m_joystickButtonMap[0]  = Action::Select;     // south face
    m_joystickButtonMap[1]  = Action::Back;       // east face
    m_joystickButtonMap[4]  = Action::Left;       // L1
    m_joystickButtonMap[5]  = Action::Right;      // R1
    m_joystickButtonMap[8]  = Action::Back;       // select/share
    m_joystickButtonMap[9]  = Action::PlayPause;  // start/options
    m_joystickButtonMap[10] = Action::Home;       // guide/home
    m_joystickAxisMap[0] = { Action::Left, Action::Right };
    m_joystickAxisMap[1] = { Action::Up,   Action::Down  };
    m_joystickAxisMap[6] = { Action::Left, Action::Right };
    m_joystickAxisMap[7] = { Action::Up,   Action::Down  };
    m_joystickHatMap[joystickHatConfigKey(0, SDL_HAT_UP)]    = Action::Up;
    m_joystickHatMap[joystickHatConfigKey(0, SDL_HAT_DOWN)]  = Action::Down;
    m_joystickHatMap[joystickHatConfigKey(0, SDL_HAT_LEFT)]  = Action::Left;
    m_joystickHatMap[joystickHatConfigKey(0, SDL_HAT_RIGHT)] = Action::Right;
}

InputManager::Action InputManager::actionFromString(const QString &name, bool *ok) {
    *ok = true;
    if (name == "up")         return Action::Up;
    if (name == "down")       return Action::Down;
    if (name == "left")       return Action::Left;
    if (name == "right")      return Action::Right;
    if (name == "select")     return Action::Select;
    if (name == "back")       return Action::Back;
    if (name == "menu")       return Action::Menu;
    if (name == "play_pause" || name == "playpause") return Action::PlayPause;
    if (name == "home")       return Action::Home;
    if (name == "none")       return Action::None;
    *ok = false;
    return Action::None;
}

// Button names are POSITIONAL (Xbox reference layout): "a" is always the
// south face button regardless of what's printed on the pad. The positional
// aliases south/east/west/north and the long SDL_CONTROLLER_BUTTON_* forms
// (including SDL3-style SOUTH/EAST/…) resolve to the same buttons.
// Returns the SDL button, or -1 if the token isn't a button.
int InputManager::buttonFromToken(const QString &token) {
    QString name = token.toLower();
    name.remove(QStringLiteral("sdl_controller_button_"));
    if (name == "south")      name = QStringLiteral("a");
    else if (name == "east")  name = QStringLiteral("b");
    else if (name == "west")  name = QStringLiteral("x");
    else if (name == "north") name = QStringLiteral("y");
    const SDL_GameControllerButton button =
        SDL_GameControllerGetButtonFromString(name.toUtf8().constData());
    return button == SDL_CONTROLLER_BUTTON_INVALID ? -1 : int(button);
}

bool InputManager::shouldIgnoreJoystickName(const QString &name)
{
    const QString normalized = name.toLower();
    return normalized.contains(QStringLiteral("motion sensor"))
        || normalized.contains(QStringLiteral("motion sensors"))
        || normalized.contains(QStringLiteral("touchpad"));
}

int InputManager::joystickButtonFromToken(const QString &token)
{
    QString name = token.toLower();
    if (name.startsWith(QStringLiteral("joy_button_")))
        name.remove(0, QStringLiteral("joy_button_").size());
    else if (name.startsWith(QStringLiteral("joystick_button_")))
        name.remove(0, QStringLiteral("joystick_button_").size());
    else if (name.startsWith(QStringLiteral("joy_btn_")))
        name.remove(0, QStringLiteral("joy_btn_").size());
    else
        return -1;

    bool ok = false;
    const int button = name.toInt(&ok);
    return ok && button >= 0 ? button : -1;
}

bool InputManager::joystickAxisFromToken(const QString &token, int *axis, int *direction)
{
    QString name = token.toLower();
    if (!name.startsWith(QStringLiteral("joy_axis_")))
        return false;

    name.remove(0, QStringLiteral("joy_axis_").size());
    int sign = 0;
    if (name.endsWith('+')) {
        sign = +1;
        name.chop(1);
    } else if (name.endsWith('-')) {
        sign = -1;
        name.chop(1);
    } else {
        return false;
    }

    bool ok = false;
    const int parsedAxis = name.toInt(&ok);
    if (!ok || parsedAxis < 0)
        return false;
    if (axis)
        *axis = parsedAxis;
    if (direction)
        *direction = sign;
    return true;
}

bool InputManager::joystickHatFromToken(const QString &token, int *hat, Uint8 *hatMask)
{
    const QStringList parts = token.toLower().split('_', Qt::SkipEmptyParts);
    if (parts.size() != 4 || parts[0] != QStringLiteral("joy") || parts[1] != QStringLiteral("hat"))
        return false;

    bool ok = false;
    const int parsedHat = parts[2].toInt(&ok);
    if (!ok || parsedHat < 0)
        return false;

    const Uint8 mask = hatMaskForDirection(parts[3]);
    if (mask == SDL_HAT_CENTERED)
        return false;
    if (hat)
        *hat = parsedHat;
    if (hatMask)
        *hatMask = mask;
    return true;
}

qint64 InputManager::joystickInputKey(SDL_JoystickID which, int input)
{
    return (qint64(quint32(which)) << 32) | quint32(input);
}

int InputManager::joystickHatConfigKey(int hat, Uint8 hatMask)
{
    return (hat << 8) | int(hatMask);
}

// $DATA_ROOT/input.cfg — case-insensitive, # comments, merged over defaults,
// bad lines skipped with a warning. Two line forms:
//   <input> <action>   bind a button/axis ("a", "south", "dpup", "lefty-"…)
//   label <button> <text>   override the footer label for a button
void InputManager::loadUserMapping() {
    QFile f(m_dataRoot + "/input.cfg");
    if (!f.exists())
        return;
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qWarning("[input] could not read input.cfg: %s", qPrintable(f.errorString()));
        return;
    }

    QStringList rawLines;
    QTextStream in(&f);
    while (!in.atEnd())
        rawLines.append(in.readLine());

    bool hasHomeBinding = false;
    for (QString line : std::as_const(rawLines)) {
        const int hash = line.indexOf('#');
        if (hash >= 0)
            line.truncate(hash);
        line = line.simplified();
        const QStringList parts = line.split(' ');
        if (parts.size() == 2 && parts[1].compare(QStringLiteral("home"), Qt::CaseInsensitive) == 0) {
            hasHomeBinding = true;
            break;
        }
    }

    if (hasHomeBinding) {
        m_buttonMap.remove(SDL_CONTROLLER_BUTTON_GUIDE);
        m_joystickButtonMap.remove(10);
    }

    int lineNo = 0, applied = 0;
    for (QString line : std::as_const(rawLines)) {
        ++lineNo;
        int hash = line.indexOf('#');
        if (hash >= 0)
            line.truncate(hash);
        line = line.simplified();   // not lowercased: label text keeps its case
        if (line.isEmpty())
            continue;

        const QStringList parts = line.split(' ');

        if (parts[0].compare(QStringLiteral("label"), Qt::CaseInsensitive) == 0) {
            if (parts.size() != 3) {
                qWarning("[input] input.cfg line %d ignored (expected \"label <button> <text>\"): %s",
                         lineNo, qPrintable(line));
                continue;
            }
            const int button = buttonFromToken(parts[1]);
            if (button < 0) {
                qWarning("[input] input.cfg line %d ignored (unknown button \"%s\")",
                         lineNo, qPrintable(parts[1]));
                continue;
            }
            m_labelOverrides[button] = parts[2];
            ++applied;
            continue;
        }

        if (parts.size() != 2) {
            qWarning("[input] input.cfg line %d ignored (expected \"<input> <action>\"): %s",
                     lineNo, qPrintable(line));
            continue;
        }

        bool actionOk = false;
        const Action action = actionFromString(parts[1].toLower(), &actionOk);
        if (!actionOk) {
            qWarning("[input] input.cfg line %d ignored (unknown action \"%s\")",
                     lineNo, qPrintable(parts[1]));
            continue;
        }

        QString input = parts[0].toLower();

        const int joystickButton = joystickButtonFromToken(input);
        if (joystickButton >= 0) {
            m_joystickButtonMap[joystickButton] = action;
            ++applied;
            continue;
        }

        int joystickAxis = 0;
        int joystickAxisSign = 0;
        if (joystickAxisFromToken(input, &joystickAxis, &joystickAxisSign)) {
            auto pair = m_joystickAxisMap.value(joystickAxis, { Action::None, Action::None });
            (joystickAxisSign < 0 ? pair.first : pair.second) = action;
            m_joystickAxisMap[joystickAxis] = pair;
            ++applied;
            continue;
        }

        int joystickHat = 0;
        Uint8 joystickHatMask = SDL_HAT_CENTERED;
        if (joystickHatFromToken(input, &joystickHat, &joystickHatMask)) {
            m_joystickHatMap[joystickHatConfigKey(joystickHat, joystickHatMask)] = action;
            ++applied;
            continue;
        }

        input.remove(QStringLiteral("sdl_controller_axis_"));

        // Axis bindings carry a direction suffix (lefty-, triggerright+).
        int axisSign = 0;
        if (input.endsWith('+')) { axisSign = +1; input.chop(1); }
        else if (input.endsWith('-')) { axisSign = -1; input.chop(1); }

        // Accept the enum-style trigger names alongside SDL's string names.
        if (input == "triggerleft")  input = "lefttrigger";
        if (input == "triggerright") input = "righttrigger";

        if (axisSign != 0) {
            SDL_GameControllerAxis axis =
                SDL_GameControllerGetAxisFromString(input.toUtf8().constData());
            if (axis == SDL_CONTROLLER_AXIS_INVALID) {
                qWarning("[input] input.cfg line %d ignored (unknown axis \"%s\")",
                         lineNo, qPrintable(parts[0]));
                continue;
            }
            auto pair = m_axisMap.value(axis, { Action::None, Action::None });
            (axisSign < 0 ? pair.first : pair.second) = action;
            m_axisMap[axis] = pair;
        } else {
            const int button = buttonFromToken(input);
            if (button < 0) {
                qWarning("[input] input.cfg line %d ignored (unknown input \"%s\")",
                         lineNo, qPrintable(parts[0]));
                continue;
            }
            m_buttonMap[button] = action;
        }
        ++applied;
    }
    qInfo("[input] input.cfg: applied %d binding(s)", applied);
}

void InputManager::onDataDirChanged(const QString &) {
    const QFileInfo cfg(m_dataRoot + "/input.cfg");
    const QDateTime modified = cfg.exists() ? cfg.lastModified() : QDateTime();
    if (modified == m_cfgLastModified)
        return;
    m_cfgLastModified = modified;
    qInfo("[input] input.cfg changed — reloading mapping");
    rebuildMapping();
}

#ifdef Q_OS_LINUX
// ── GPIO IR receiver ──────────────────────────────────────────────────────────

void InputManager::initIrReceiver() {
    m_irScanTimer.setInterval(2000);
    connect(&m_irScanTimer, &QTimer::timeout, this, &InputManager::scanIrReceiver);
    scanIrReceiver();
    if (m_irFd < 0)
        m_irScanTimer.start();
}

void InputManager::scanIrReceiver() {
    if (m_irFd >= 0)
        return;

    QDir inputDir(QStringLiteral("/dev/input"));
    const QStringList entries = inputDir.entryList(QStringList{QStringLiteral("event*")},
                                                   QDir::System | QDir::Files,
                                                   QDir::Name);
    for (const QString &entry : entries) {
        if (openIrDevice(inputDir.absoluteFilePath(entry))) {
            m_irScanTimer.stop();
            return;
        }
    }

    if (!m_irScanTimer.isActive())
        m_irScanTimer.start();
}

bool InputManager::openIrDevice(const QString &path) {
    const int fd = ::open(path.toLocal8Bit().constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return false;

    char name[256] = {};
    if (::ioctl(fd, EVIOCGNAME(sizeof(name)), name) < 0) {
        ::close(fd);
        return false;
    }

    const QString deviceName = QString::fromLocal8Bit(name);
    if (deviceName != QStringLiteral("gpio_ir_recv")) {
        ::close(fd);
        return false;
    }

    if (::ioctl(fd, EVIOCGRAB, 1) < 0) {
        qWarning("[input] IR receiver found at %s, but exclusive grab failed: %s",
                 qPrintable(path), strerror(errno));
    }

    m_irFd = fd;
    m_irDevicePath = path;
    m_irNotifier = new QSocketNotifier(m_irFd, QSocketNotifier::Read, this);
    connect(m_irNotifier, &QSocketNotifier::activated,
            this, [this] { onIrDeviceReady(); });

    qInfo("[input] IR receiver ready: %s (%s)", qPrintable(path), qPrintable(deviceName));
    return true;
}

void InputManager::closeIrDevice() {
    if (m_irNotifier) {
        m_irNotifier->setEnabled(false);
        m_irNotifier->deleteLater();
        m_irNotifier = nullptr;
    }

    if (m_irFd >= 0) {
        ::ioctl(m_irFd, EVIOCGRAB, 0);
        ::close(m_irFd);
        m_irFd = -1;
    }
    m_irDevicePath.clear();
}

void InputManager::onIrDeviceReady() {
    if (m_irFd < 0)
        return;

    while (true) {
        input_event ev = {};
        const ssize_t bytes = ::read(m_irFd, &ev, sizeof(ev));
        if (bytes == sizeof(ev)) {
            if (ev.type == EV_KEY)
                handleIrKey(static_cast<quint16>(ev.code), ev.value);
            continue;
        }

        if (bytes < 0 && errno == EINTR)
            continue;
        if (bytes < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return;

        qWarning("[input] IR receiver disconnected: %s", qPrintable(m_irDevicePath));
        closeIrDevice();
        m_irScanTimer.start();
        return;
    }
}

void InputManager::handleIrKey(quint16 code, int value) {
    if (code == KEY_HOME) {
        if (value == 1) {
            setLastInputDevice(QStringLiteral("remote"));
            emit homeRequested();
        }
        return;
    }

    if (code == KEY_POWER) {
        if (value == 1) {
            setLastInputDevice(QStringLiteral("remote"));
            emit powerRequested();
        }
        return;
    }

    const Action action = actionForLinuxKey(code);
    if (action != Action::None) {
        if (value == 1) {
            pressAction(action, QStringLiteral("remote"));
        } else if (value == 0) {
            releaseAction(action);
        }
        return;
    }

    const QString mediaKey = mpvKeyForLinuxKey(code);
    if (!mediaKey.isEmpty() && (value == 1 || value == 2)) {
        setLastInputDevice(QStringLiteral("remote"));
        emit mpvKeyRequested(mediaKey);
    }
}

InputManager::Action InputManager::actionForLinuxKey(quint16 code) {
    switch (code) {
    case KEY_UP:        return Action::Up;
    case KEY_DOWN:      return Action::Down;
    case KEY_LEFT:      return Action::Left;
    case KEY_RIGHT:     return Action::Right;
    case KEY_OK:
    case KEY_SELECT:
    case KEY_ENTER:
    case KEY_KPENTER:   return Action::Select;
    case KEY_ESC:
    case KEY_BACK:
    case KEY_EXIT:      return Action::Back;
    case KEY_MENU:      return Action::Menu;
    case KEY_PLAY:
    case KEY_PAUSE:
    case KEY_PLAYPAUSE:
    case KEY_SPACE:     return Action::PlayPause;
    default:            return Action::None;
    }
}

QString InputManager::mpvKeyForLinuxKey(quint16 code) {
    switch (code) {
    case KEY_VOLUMEUP:     return QStringLiteral("VOLUME_UP");
    case KEY_VOLUMEDOWN:   return QStringLiteral("VOLUME_DOWN");
    case KEY_MUTE:         return QStringLiteral("MUTE");
    case KEY_STOP:         return QStringLiteral("STOP");
    case KEY_NEXT:         return QStringLiteral("NEXT");
    case KEY_PREVIOUS:     return QStringLiteral("PREV");
    case KEY_FASTFORWARD:  return QStringLiteral("FORWARD");
    case KEY_REWIND:       return QStringLiteral("REWIND");
    default:               return QString();
    }
}
#endif

// ── Input → action → synthesized key event ───────────────────────────────────

// Footer labels follow the controller last touched, so swapping between e.g.
// an Xbox pad and an 8BitDo keeps the face-button labels truthful.
void InputManager::noteActiveController(SDL_JoystickID which) {
    if (which == m_lastActiveController)
        return;
    m_lastActiveController = which;
    updateHints();
}

QString InputManager::axisToken(Uint8 axis, int direction)
{
    const QString name = axisName(axis);
    if (name.isEmpty())
        return QString();
    return name + (direction < 0 ? QStringLiteral("-") : QStringLiteral("+"));
}

QString InputManager::retroHatDirection(Uint8 hatMask)
{
    switch (hatMask) {
    case SDL_HAT_UP:    return QStringLiteral("up");
    case SDL_HAT_DOWN:  return QStringLiteral("down");
    case SDL_HAT_LEFT:  return QStringLiteral("left");
    case SDL_HAT_RIGHT: return QStringLiteral("right");
    default:            return QString();
    }
}

QVariantMap InputManager::retroBindingFromSdlBind(const SDL_GameControllerButtonBind &bind,
                                                  int direction)
{
    QVariantMap result;
    switch (bind.bindType) {
    case SDL_CONTROLLER_BINDTYPE_BUTTON:
        result["retroType"] = QStringLiteral("btn");
        result["retroValue"] = QString::number(bind.value.button);
        break;
    case SDL_CONTROLLER_BINDTYPE_AXIS:
        result["retroType"] = QStringLiteral("axis");
        result["retroValue"] = QStringLiteral("%1%2")
            .arg(direction < 0 ? QStringLiteral("-") : QStringLiteral("+"))
            .arg(bind.value.axis);
        break;
    case SDL_CONTROLLER_BINDTYPE_HAT: {
        const QString directionName = retroHatDirection(bind.value.hat.hat_mask);
        if (directionName.isEmpty())
            break;
        result["retroType"] = QStringLiteral("btn");
        result["retroValue"] = QStringLiteral("h%1%2").arg(bind.value.hat.hat).arg(directionName);
        break;
    }
    default:
        break;
    }
    return result;
}

QVariantMap InputManager::mappingInputForButton(SDL_GameController *controller, Uint8 button) const
{
    QVariantMap input;
    if (!controller)
        return input;

    const QString token = buttonToken(button);
    if (token.isEmpty())
        return input;

    input["inputToken"] = token;
    input["label"] = labelForButton(button).isEmpty() ? displayToken(token) : labelForButton(button);
    input["source"] = QStringLiteral("button");

    const SDL_GameControllerButtonBind bind = SDL_GameControllerGetBindForButton(
        controller, static_cast<SDL_GameControllerButton>(button));
    const QVariantMap retro = retroBindingFromSdlBind(bind, +1);
    for (auto it = retro.constBegin(); it != retro.constEnd(); ++it)
        input.insert(it.key(), it.value());

    return input;
}

QVariantMap InputManager::mappingInputForAxis(SDL_GameController *controller, Uint8 axis,
                                              int direction) const
{
    QVariantMap input;
    if (!controller || direction == 0)
        return input;

    const QString token = axisToken(axis, direction);
    if (token.isEmpty())
        return input;

    input["inputToken"] = token;
    input["label"] = displayToken(token);
    input["source"] = QStringLiteral("axis");

    const SDL_GameControllerButtonBind bind = SDL_GameControllerGetBindForAxis(
        controller, static_cast<SDL_GameControllerAxis>(axis));
    const QVariantMap retro = retroBindingFromSdlBind(bind, direction);
    for (auto it = retro.constBegin(); it != retro.constEnd(); ++it)
        input.insert(it.key(), it.value());

    return input;
}

QVariantMap InputManager::mappingInputForJoystickButton(Uint8 button) const
{
    QVariantMap input;
    input["inputToken"] = QStringLiteral("joy_button_%1").arg(int(button));
    input["label"] = labelForJoystickButton(button);
    input["source"] = QStringLiteral("joy_button");
    input["retroType"] = QStringLiteral("btn");
    input["retroValue"] = QString::number(button);
    return input;
}

QVariantMap InputManager::mappingInputForJoystickAxis(Uint8 axis, int direction) const
{
    QVariantMap input;
    if (direction == 0)
        return input;
    input["inputToken"] = QStringLiteral("joy_axis_%1%2")
        .arg(int(axis))
        .arg(direction < 0 ? QStringLiteral("-") : QStringLiteral("+"));
    input["label"] = QStringLiteral("AXIS %1%2")
        .arg(int(axis))
        .arg(direction < 0 ? QStringLiteral("-") : QStringLiteral("+"));
    input["source"] = QStringLiteral("joy_axis");
    input["retroType"] = QStringLiteral("axis");
    input["retroValue"] = QStringLiteral("%1%2")
        .arg(direction < 0 ? QStringLiteral("-") : QStringLiteral("+"))
        .arg(int(axis));
    return input;
}

QVariantMap InputManager::mappingInputForJoystickHat(Uint8 hat, Uint8 hatMask) const
{
    const QString direction = retroHatDirection(hatMask);
    if (direction.isEmpty())
        return {};

    QVariantMap input;
    input["inputToken"] = QStringLiteral("joy_hat_%1_%2").arg(int(hat)).arg(direction);
    input["label"] = QStringLiteral("HAT %1 %2").arg(int(hat)).arg(direction.toUpper());
    input["source"] = QStringLiteral("joy_hat");
    input["retroType"] = QStringLiteral("btn");
    input["retroValue"] = QStringLiteral("h%1%2").arg(int(hat)).arg(direction);
    return input;
}

void InputManager::primeControllerMappingState()
{
    m_mappingAxisState.clear();
    m_mappingJoystickAxisState.clear();
    m_mappingJoystickHatState.clear();
    m_mappingCapturedTokens.clear();
    m_mappingCapturedPositiveAxes.clear();
    m_mappingCapturedPositiveJoystickAxes.clear();

    const auto axisDirection = [](Sint16 value) -> int {
        if (value >= kAxisEngage)
            return +1;
        if (value <= -kAxisEngage)
            return -1;
        return 0;
    };

    for (auto it = m_controllers.constBegin(); it != m_controllers.constEnd(); ++it) {
        SDL_GameController *controller = it.value();
        if (!controller)
            continue;
        for (int axis = 0; axis < SDL_CONTROLLER_AXIS_MAX; ++axis) {
            const int direction = axisDirection(SDL_GameControllerGetAxis(
                controller, static_cast<SDL_GameControllerAxis>(axis)));
            if (direction != 0)
                m_mappingAxisState[axis] = direction;
        }
    }

    for (auto it = m_rawJoystickNames.constBegin(); it != m_rawJoystickNames.constEnd(); ++it) {
        const SDL_JoystickID id = it.key();
        SDL_Joystick *joy = m_joysticks.value(id, nullptr);
        if (!joy) {
            SDL_GameController *controller = m_controllers.value(id, nullptr);
            if (controller)
                joy = SDL_GameControllerGetJoystick(controller);
        }
        if (!joy)
            continue;

        const int axes = SDL_JoystickNumAxes(joy);
        for (int axis = 0; axis < axes; ++axis) {
            const int direction = axisDirection(SDL_JoystickGetAxis(joy, axis));
            if (direction != 0)
                m_mappingJoystickAxisState[joystickInputKey(id, axis)] = direction;
        }

        const int hats = SDL_JoystickNumHats(joy);
        for (int hat = 0; hat < hats; ++hat) {
            const Uint8 value = SDL_JoystickGetHat(joy, hat);
            if (value != SDL_HAT_CENTERED)
                m_mappingJoystickHatState[joystickInputKey(id, hat)] = value;
        }
    }
}

bool InputManager::captureMappingInput(const QVariantMap &input,
                                       SDL_JoystickID which,
                                       bool markControllerSeen)
{
    const QString token = input.value(QStringLiteral("inputToken")).toString();
    if (token.isEmpty() || m_mappingCapturedTokens.contains(token))
        return false;

    m_mappingCapturedTokens.insert(token);
    if (markControllerSeen)
        m_controllerInputSeen.insert(which);
    noteActiveController(which);
    setLastInputDevice(QStringLiteral("gamepad"));
    emit controllerMappingInput(input);
    return true;
}

bool InputManager::controllerMappingNeedsDefault() const
{
    const QVariantMap existing = getControllerMapping();
    return existing.value(QStringLiteral("bindings")).toMap().isEmpty();
}

void InputManager::ensureDefaultControllerMapping(SDL_JoystickID which,
                                                  SDL_GameController *controller)
{
    if (!controller || !controllerMappingNeedsDefault())
        return;

    const auto withStep = [](QVariantMap input, const QString &step, const QString &title) {
        if (input.isEmpty())
            return input;
        input[QStringLiteral("step")] = step;
        input[QStringLiteral("title")] = title;
        return input;
    };

    QVariantMap bindings;
    const auto addButton = [&](const QString &step, const QString &title, SDL_GameControllerButton button) {
        QVariantMap input = mappingInputForButton(controller, static_cast<Uint8>(button));
        if (!input.isEmpty())
            bindings[step] = withStep(input, step, title);
    };
    const auto addAxis = [&](const QString &step, const QString &title, SDL_GameControllerAxis axis, int direction) {
        QVariantMap input = mappingInputForAxis(controller, static_cast<Uint8>(axis), direction);
        if (!input.isEmpty())
            bindings[step] = withStep(input, step, title);
    };

    addButton(QStringLiteral("up"),     QStringLiteral("UP"),             SDL_CONTROLLER_BUTTON_DPAD_UP);
    addButton(QStringLiteral("down"),   QStringLiteral("DOWN"),           SDL_CONTROLLER_BUTTON_DPAD_DOWN);
    addButton(QStringLiteral("left"),   QStringLiteral("LEFT"),           SDL_CONTROLLER_BUTTON_DPAD_LEFT);
    addButton(QStringLiteral("right"),  QStringLiteral("RIGHT"),          SDL_CONTROLLER_BUTTON_DPAD_RIGHT);
    addButton(QStringLiteral("b"),      QStringLiteral("A BUTTON"),       SDL_CONTROLLER_BUTTON_A);
    addButton(QStringLiteral("a"),      QStringLiteral("B BUTTON"),       SDL_CONTROLLER_BUTTON_B);
    addButton(QStringLiteral("y"),      QStringLiteral("X BUTTON"),       SDL_CONTROLLER_BUTTON_X);
    addButton(QStringLiteral("x"),      QStringLiteral("Y BUTTON"),       SDL_CONTROLLER_BUTTON_Y);
    addButton(QStringLiteral("select"), QStringLiteral("SELECT"),         SDL_CONTROLLER_BUTTON_BACK);
    addButton(QStringLiteral("start"),  QStringLiteral("START"),          SDL_CONTROLLER_BUTTON_START);
    addButton(QStringLiteral("l"),      QStringLiteral("LEFT BUMPER"),    SDL_CONTROLLER_BUTTON_LEFTSHOULDER);
    addButton(QStringLiteral("r"),      QStringLiteral("RIGHT BUMPER"),   SDL_CONTROLLER_BUTTON_RIGHTSHOULDER);
    addAxis(QStringLiteral("l2"),       QStringLiteral("LEFT TRIGGER"),   SDL_CONTROLLER_AXIS_TRIGGERLEFT, +1);
    addAxis(QStringLiteral("r2"),       QStringLiteral("RIGHT TRIGGER"),  SDL_CONTROLLER_AXIS_TRIGGERRIGHT, +1);
    addButton(QStringLiteral("l3"),     QStringLiteral("LEFT STICK"),     SDL_CONTROLLER_BUTTON_LEFTSTICK);
    addButton(QStringLiteral("r3"),     QStringLiteral("RIGHT STICK"),    SDL_CONTROLLER_BUTTON_RIGHTSTICK);
    addButton(QStringLiteral("home"),   QStringLiteral("HOME"),           SDL_CONTROLLER_BUTTON_GUIDE);

    if (bindings.isEmpty())
        return;

    noteActiveController(which);
    if (saveControllerMapping({{QStringLiteral("bindings"), bindings}}))
        qInfo("[input] seeded default controller mapping from SDL controller");
}

void InputManager::ensureDefaultJoystickMapping(SDL_JoystickID which)
{
    if (!controllerMappingNeedsDefault())
        return;

    const auto withStep = [](QVariantMap input, const QString &step, const QString &title) {
        if (input.isEmpty())
            return input;
        input[QStringLiteral("step")] = step;
        input[QStringLiteral("title")] = title;
        return input;
    };

    QVariantMap bindings;
    const auto addButton = [&](const QString &step, const QString &title, Uint8 button) {
        bindings[step] = withStep(mappingInputForJoystickButton(button), step, title);
    };
    const auto addAxis = [&](const QString &step, const QString &title, Uint8 axis, int direction) {
        QVariantMap input = mappingInputForJoystickAxis(axis, direction);
        if (!input.isEmpty())
            bindings[step] = withStep(input, step, title);
    };
    const auto addHat = [&](const QString &step, const QString &title, Uint8 hatMask) {
        QVariantMap input = mappingInputForJoystickHat(0, hatMask);
        if (!input.isEmpty())
            bindings[step] = withStep(input, step, title);
    };

    addHat(QStringLiteral("up"),        QStringLiteral("UP"),             SDL_HAT_UP);
    addHat(QStringLiteral("down"),      QStringLiteral("DOWN"),           SDL_HAT_DOWN);
    addHat(QStringLiteral("left"),      QStringLiteral("LEFT"),           SDL_HAT_LEFT);
    addHat(QStringLiteral("right"),     QStringLiteral("RIGHT"),          SDL_HAT_RIGHT);
    addButton(QStringLiteral("b"),      QStringLiteral("A BUTTON"),       0);
    addButton(QStringLiteral("a"),      QStringLiteral("B BUTTON"),       1);
    addButton(QStringLiteral("y"),      QStringLiteral("X BUTTON"),       2);
    addButton(QStringLiteral("x"),      QStringLiteral("Y BUTTON"),       3);
    addButton(QStringLiteral("l"),      QStringLiteral("LEFT BUMPER"),    4);
    addButton(QStringLiteral("r"),      QStringLiteral("RIGHT BUMPER"),   5);
    addAxis(QStringLiteral("l2"),       QStringLiteral("LEFT TRIGGER"),   2, +1);
    addAxis(QStringLiteral("r2"),       QStringLiteral("RIGHT TRIGGER"),  5, +1);
    addButton(QStringLiteral("select"), QStringLiteral("SELECT"),         8);
    addButton(QStringLiteral("start"),  QStringLiteral("START"),          9);
    addButton(QStringLiteral("l3"),     QStringLiteral("LEFT STICK"),     11);
    addButton(QStringLiteral("r3"),     QStringLiteral("RIGHT STICK"),    12);
    addButton(QStringLiteral("home"),   QStringLiteral("HOME"),           10);

    noteActiveController(which);
    if (saveControllerMapping({{QStringLiteral("bindings"), bindings}}))
        qInfo("[input] seeded default controller mapping from raw joystick fallback");
}

void InputManager::loadGameExitCombo(const QVariantMap &bindings)
{
    m_gameExitComboTokenGroups.clear();

    const auto tokenFor = [&](const QString &key) {
        return bindings.value(key).toMap()
            .value(QStringLiteral("inputToken")).toString();
    };

    const auto addGroup = [&](const QString &mappedToken, std::initializer_list<QString> fallbacks) {
        QSet<QString> group;
        for (const QString &token : fallbacks) {
            if (!token.isEmpty())
                group.insert(token);
        }
        if (!mappedToken.isEmpty())
            group.insert(mappedToken);
        if (!group.isEmpty())
            m_gameExitComboTokenGroups.append(group);
    };

    // Physical combo: D-up + both bumpers + top face (Y/Triangle).
    // RetroArch uses retropad naming, while SDL/raw joystick paths report
    // different tokens, so each part accepts the saved token plus known aliases.
    addGroup(tokenFor(QStringLiteral("up")), {
        QStringLiteral("dpup"),
        QStringLiteral("joy_hat_0_up"),
        QStringLiteral("joy_axis_7-")
    });
    addGroup(tokenFor(QStringLiteral("l")), {
        QStringLiteral("leftshoulder"),
        QStringLiteral("joy_button_4")
    });
    addGroup(tokenFor(QStringLiteral("r")), {
        QStringLiteral("rightshoulder"),
        QStringLiteral("joy_button_5")
    });
    addGroup(tokenFor(QStringLiteral("x")), {
        QStringLiteral("y"),
        QStringLiteral("joy_button_3")
    });
}

bool InputManager::updatePressedInputToken(const QString &token, bool pressed)
{
    if (token.isEmpty() || m_controllerMappingActive)
        return false;

    if (pressed)
        m_pressedInputTokens.insert(token);
    else
        m_pressedInputTokens.remove(token);
    return checkGameExitCombo();
}

bool InputManager::checkGameExitCombo()
{
    if (m_gameExitComboTokenGroups.isEmpty())
        return false;

    for (const QSet<QString> &group : std::as_const(m_gameExitComboTokenGroups)) {
        bool groupPressed = false;
        for (const QString &token : group) {
            if (m_pressedInputTokens.contains(token)) {
                groupPressed = true;
                break;
            }
        }
        if (!groupPressed) {
            m_gameExitComboLatched = false;
            return false;
        }
    }
    if (m_gameExitComboLatched)
        return true;

    m_gameExitComboLatched = true;
    m_repeatDelayTimer.stop();
    m_repeatTimer.stop();
    m_heldDirection = Action::None;
    setLastInputDevice(QStringLiteral("gamepad"));
    emit homeRequested();
    return true;
}

void InputManager::handleButton(SDL_JoystickID which, Uint8 button, bool pressed) {
    updatePressedInputToken(buttonToken(button), pressed);
    if (m_controllerMappingActive) {
        if (m_rawJoystickNames.contains(which))
            return;
        if (!pressed)
            return;
        SDL_GameController *controller = m_controllers.value(which, nullptr);
        const QVariantMap input = mappingInputForButton(controller, button);
        if (!input.isEmpty())
            captureMappingInput(input, which, true);
        return;
    }

    const Action a = m_buttonMap.value(button, Action::None);
    if (a == Action::None)
        return;
    m_controllerInputSeen.insert(which);
    noteActiveController(which);
    if (pressed)
        pressAction(a, QStringLiteral("gamepad"));
    else
        releaseAction(a);
}

void InputManager::handleAxis(SDL_JoystickID which, Uint8 axis, Sint16 value) {
    if (m_controllerMappingActive) {
        if (m_rawJoystickNames.contains(which))
            return;
        const int old = m_mappingAxisState.value(axis, 0);
        int now = old;
        if (old == 0) {
            if (value >= kAxisEngage)       now = +1;
            else if (value <= -kAxisEngage) now = -1;
        } else if (old > 0) {
            if (value < kAxisRelease)       now = (value <= -kAxisEngage) ? -1 : 0;
        } else {
            if (value > -kAxisRelease)      now = (value >= kAxisEngage) ? +1 : 0;
        }
        if (now == old)
            return;
        m_mappingAxisState[axis] = now;
        if (now == 0)
            return;
        if (now < 0 && m_mappingCapturedPositiveAxes.contains(axis))
            return;

        SDL_GameController *controller = m_controllers.value(which, nullptr);
        const QVariantMap input = mappingInputForAxis(controller, axis, now);
        if (!input.isEmpty() && captureMappingInput(input, which, true) && now > 0)
            m_mappingCapturedPositiveAxes.insert(axis);
        return;
    }

    const auto it = m_axisMap.constFind(axis);
    if (it == m_axisMap.constEnd())
        return;

    const int old = m_axisState.value(axis, 0);
    int now = old;
    if (old == 0) {
        if (value >= kAxisEngage)       now = +1;
        else if (value <= -kAxisEngage) now = -1;
    } else if (old > 0) {
        if (value < kAxisRelease)       now = (value <= -kAxisEngage) ? -1 : 0;
    } else {
        if (value > -kAxisRelease)      now = (value >= kAxisEngage) ? +1 : 0;
    }
    if (now == old)
        return;
    m_axisState[axis] = now;
    m_controllerInputSeen.insert(which);
    if (old != 0)
        updatePressedInputToken(axisToken(axis, old), false);
    if (now != 0)
        updatePressedInputToken(axisToken(axis, now), true);

    // Only a real engage/release counts as "using" this controller — idle
    // stick jitter must not steal label ownership from the pad in use.
    noteActiveController(which);
    if (old != 0)
        releaseAction(old < 0 ? it->first : it->second);
    if (now != 0)
        pressAction(now < 0 ? it->first : it->second, QStringLiteral("gamepad"));
}

void InputManager::handleJoystickButton(SDL_JoystickID which, Uint8 button, bool pressed) {
    if (!m_rawJoystickNames.contains(which))
        return;
    updatePressedInputToken(QStringLiteral("joy_button_%1").arg(int(button)), pressed);
    if (m_controllerMappingActive) {
        if (!pressed)
            return;
        const QVariantMap input = mappingInputForJoystickButton(button);
        captureMappingInput(input, which, false);
        return;
    }

    if (m_controllerInputSeen.contains(which))
        return;

    const Action a = m_joystickButtonMap.value(button, Action::None);
    if (a == Action::None)
        return;
    noteActiveController(which);
    if (pressed)
        pressAction(a, QStringLiteral("gamepad"));
    else
        releaseAction(a);
}

void InputManager::handleJoystickAxis(SDL_JoystickID which, Uint8 axis, Sint16 value) {
    if (!m_rawJoystickNames.contains(which))
        return;
    if (!m_controllerMappingActive && m_controllerInputSeen.contains(which))
        return;

    const qint64 key = joystickInputKey(which, axis);
    if (m_controllerMappingActive) {
        const int old = m_mappingJoystickAxisState.value(key, 0);
        int now = old;
        if (old == 0) {
            if (value >= kAxisEngage)       now = +1;
            else if (value <= -kAxisEngage) now = -1;
        } else if (old > 0) {
            if (value < kAxisRelease)       now = (value <= -kAxisEngage) ? -1 : 0;
        } else {
            if (value > -kAxisRelease)      now = (value >= kAxisEngage) ? +1 : 0;
        }
        if (now == old)
            return;
        m_mappingJoystickAxisState[key] = now;
        if (now == 0 || (now < 0 && m_mappingCapturedPositiveJoystickAxes.contains(key))
            || (isLikelyRawTriggerAxis(axis) && now < 0))
            return;

        const QVariantMap input = mappingInputForJoystickAxis(axis, now);
        if (!input.isEmpty() && captureMappingInput(input, which, false) && now > 0)
            m_mappingCapturedPositiveJoystickAxes.insert(key);
        return;
    }

    const auto it = m_joystickAxisMap.constFind(axis);
    if (it == m_joystickAxisMap.constEnd())
        return;

    const int old = m_joystickAxisState.value(key, 0);
    int now = old;
    if (old == 0) {
        if (value >= kAxisEngage)       now = +1;
        else if (value <= -kAxisEngage) now = -1;
    } else if (old > 0) {
        if (value < kAxisRelease)       now = (value <= -kAxisEngage) ? -1 : 0;
    } else {
        if (value > -kAxisRelease)      now = (value >= kAxisEngage) ? +1 : 0;
    }
    if (now == old)
        return;
    m_joystickAxisState[key] = now;
    if (old != 0)
        updatePressedInputToken(QStringLiteral("joy_axis_%1%2")
                                    .arg(int(axis))
                                    .arg(old < 0 ? QStringLiteral("-") : QStringLiteral("+")),
                                false);
    if (now != 0)
        updatePressedInputToken(QStringLiteral("joy_axis_%1%2")
                                    .arg(int(axis))
                                    .arg(now < 0 ? QStringLiteral("-") : QStringLiteral("+")),
                                true);

    noteActiveController(which);
    if (old != 0)
        releaseAction(old < 0 ? it->first : it->second);
    if (now != 0)
        pressAction(now < 0 ? it->first : it->second, QStringLiteral("gamepad"));
}

void InputManager::handleJoystickHat(SDL_JoystickID which, Uint8 hat, Uint8 value) {
    if (!m_rawJoystickNames.contains(which))
        return;
    if (!m_controllerMappingActive && m_controllerInputSeen.contains(which))
        return;

    const qint64 key = joystickInputKey(which, hat);
    if (m_controllerMappingActive) {
        const Uint8 old = m_mappingJoystickHatState.value(key, SDL_HAT_CENTERED);
        if (value == old)
            return;
        m_mappingJoystickHatState[key] = value;
        const Uint8 masks[] = { SDL_HAT_UP, SDL_HAT_DOWN, SDL_HAT_LEFT, SDL_HAT_RIGHT };
        for (Uint8 mask : masks) {
            const QString direction = retroHatDirection(mask);
            if (direction.isEmpty())
                continue;
            if (!(old & mask) && (value & mask)) {
                const QVariantMap input = mappingInputForJoystickHat(hat, mask);
                if (!input.isEmpty() && captureMappingInput(input, which, false))
                    return;
            }
        }
        return;
    }

    const Uint8 old = m_joystickHatState.value(key, SDL_HAT_CENTERED);
    if (value == old)
        return;
    m_joystickHatState[key] = value;
    const Uint8 tokenMasks[] = { SDL_HAT_UP, SDL_HAT_DOWN, SDL_HAT_LEFT, SDL_HAT_RIGHT };
    for (Uint8 mask : tokenMasks) {
        const QString direction = retroHatDirection(mask);
        if (direction.isEmpty())
            continue;
        const QString token = QStringLiteral("joy_hat_%1_%2").arg(int(hat)).arg(direction);
        if ((old & mask) && !(value & mask))
            updatePressedInputToken(token, false);
        if (!(old & mask) && (value & mask))
            updatePressedInputToken(token, true);
    }
    noteActiveController(which);

    const Uint8 masks[] = { SDL_HAT_UP, SDL_HAT_DOWN, SDL_HAT_LEFT, SDL_HAT_RIGHT };
    for (Uint8 mask : masks) {
        const Action action = m_joystickHatMap.value(joystickHatConfigKey(hat, mask), Action::None);
        if (action == Action::None)
            continue;
        if ((old & mask) && !(value & mask))
            releaseAction(action);
        if (!(old & mask) && (value & mask))
            pressAction(action, QStringLiteral("gamepad"));
    }
}

void InputManager::pressAction(Action a, const QString &device) {
    if (a == Action::None)
        return;
    setLastInputDevice(device);
    if (a == Action::Home) {
        m_repeatDelayTimer.stop();
        m_repeatTimer.stop();
        m_heldDirection = Action::None;
        emit homeRequested();
        return;
    }

    deliverPress(a, false);

    if (isDirectional(a)) {
        // Most recent direction wins the repeat slot.
        m_heldDirection = a;
        m_repeatTimer.stop();
        m_repeatDelayTimer.start();
    }
}

void InputManager::releaseAction(Action a) {
    if (a == Action::None || a == Action::Home)
        return;
    if (m_heldDirection == a) {
        m_heldDirection = Action::None;
        m_repeatDelayTimer.stop();
        m_repeatTimer.stop();
    }
    // mpv's "keypress" command is one-shot — releases only matter for QML.
    if (windowActive())
        postKey(qtKeyForAction(a), QEvent::KeyRelease, false);
}

// While the Qt window is active, actions become posted key events into QML.
// When it isn't — fullscreen mpv owns OS focus on macOS, and a deactivated
// QQuickWindow has no activeFocusItem for key events to land on — actions go
// straight to mpv over IPC instead, mirroring what the Player views' key
// forwarding does on platforms where the window stays active (RPi/EGLFS).
// When mpv isn't running either, sendKey is a no-op, so background presses
// while the user is in another app do nothing — same as keyboard.
void InputManager::deliverPress(Action a, bool autoRepeat) {
    if (windowActive())
        postKey(qtKeyForAction(a), QEvent::KeyPress, autoRepeat);
    else
        emit mpvKeyRequested(mpvKeyForAction(a));
}

void InputManager::onRepeatDelayElapsed() {
    if (m_heldDirection == Action::None)
        return;
    onRepeatTick();
    m_repeatTimer.start();
}

void InputManager::onRepeatTick() {
    if (m_heldDirection == Action::None)
        return;
    deliverPress(m_heldDirection, true);
}

bool InputManager::windowActive() const {
#ifdef Q_OS_LINUX
    // EGLFS can report the kiosk window as inactive even while it owns the only
    // screen. Keep routing remote/gamepad actions through QML on Pi; Player
    // views forward those same keys to mpv during playback.
    return m_window != nullptr;
#else
    return m_window && m_window->isActive();
#endif
}

// Post to the root QQuickWindow, not QGuiApplication::focusWindow(): Qt Quick
// delivers posted key events to the window's activeFocusItem even when the
// window has no OS-level focus, which is exactly the state during fullscreen
// mpv playback on macOS.
void InputManager::postKey(int qtKey, QEvent::Type type, bool autoRepeat) {
    if (!m_window)
        return;
    QCoreApplication::postEvent(
        m_window,
        new QKeyEvent(type, qtKey, Qt::NoModifier,
                      kSyntheticScanCode, 0, 0, QString(), autoRepeat));
}

int InputManager::qtKeyForAction(Action a) {
    switch (a) {
    case Action::Up:        return Qt::Key_Up;
    case Action::Down:      return Qt::Key_Down;
    case Action::Left:      return Qt::Key_Left;
    case Action::Right:     return Qt::Key_Right;
    case Action::Select:    return Qt::Key_Return;
    case Action::Back:      return Qt::Key_Escape;
    case Action::Menu:      return Qt::Key_Menu;
    case Action::PlayPause: return Qt::Key_Space;
    case Action::Home:      return 0;
    case Action::None:      break;
    }
    return 0;
}

// Same key names the Player views pass to mpvController.sendKey().
QString InputManager::mpvKeyForAction(Action a) {
    switch (a) {
    case Action::Up:        return QStringLiteral("UP");
    case Action::Down:      return QStringLiteral("DOWN");
    case Action::Left:      return QStringLiteral("LEFT");
    case Action::Right:     return QStringLiteral("RIGHT");
    case Action::Select:    return QStringLiteral("ENTER");
    case Action::Back:      return QStringLiteral("ESC");
    case Action::Menu:      return QStringLiteral("MENU");
    case Action::PlayPause: return QStringLiteral("SPACE");
    case Action::Home:      return QString();
    case Action::None:      break;
    }
    return QString();
}

bool InputManager::isDirectional(Action a) {
    return a == Action::Up || a == Action::Down || a == Action::Left || a == Action::Right;
}

// HID media keys are a separate concern from navigation actions — they always
// target mpv, never QML — so they bypass the Action enum and map straight to the
// canonical mpv key names media-keys.lua binds.
QString InputManager::mpvKeyForMediaEvent(const QKeyEvent *ke) {
    switch (ke->key()) {
    case Qt::Key_VolumeUp:              return QStringLiteral("VOLUME_UP");
    case Qt::Key_VolumeDown:            return QStringLiteral("VOLUME_DOWN");
    case Qt::Key_VolumeMute:            return QStringLiteral("MUTE");
    case Qt::Key_MediaTogglePlayPause:
    case Qt::Key_MediaPlay:
    case Qt::Key_MediaPause:            return QStringLiteral("PLAYPAUSE");
    case Qt::Key_MediaStop:             return QStringLiteral("STOP");
    case Qt::Key_MediaNext:             return QStringLiteral("NEXT");
    case Qt::Key_MediaPrevious:         return QStringLiteral("PREV");
    case Qt::Key_AudioForward:          return QStringLiteral("FORWARD");
    case Qt::Key_AudioRewind:           return QStringLiteral("REWIND");
    default:                            return QString();
    }
}

InputManager::Action InputManager::remoteActionForKey(const QKeyEvent *ke) {
    switch (ke->key()) {
    case Qt::Key_Select: return Action::Select;
    case Qt::Key_Back:
        return Action::Back;
    case Qt::Key_Menu:   return Action::Menu;
    default:             return Action::None;
    }
}

// ── Active-device tracking & footer hints ─────────────────────────────────────

bool InputManager::eventFilter(QObject *obj, QEvent *event) {
    Q_UNUSED(obj)
    const QEvent::Type type = event->type();
    if (type != QEvent::KeyPress && type != QEvent::KeyRelease)
        return false;
    const auto *ke = static_cast<QKeyEvent *>(event);

    const bool synthetic = (ke->nativeScanCode() == kSyntheticScanCode);
    if (!synthetic && ke->key() == Qt::Key_Home) {
        if (type == QEvent::KeyPress && !ke->isAutoRepeat()) {
            setLastInputDevice(QStringLiteral("remote"));
            emit homeRequested();
        }
        return true;
    }

    const Action remoteAction = synthetic ? Action::None : remoteActionForKey(ke);
    if (remoteAction != Action::None) {
        setLastInputDevice(QStringLiteral("remote"));
        if (!ke->isAutoRepeat()) {
            if (type == QEvent::KeyPress)
                deliverPress(remoteAction, false);
            else
                releaseAction(remoteAction);
        }
        return true;
    }

    if (type == QEvent::KeyPress && !synthetic)
        setLastInputDevice(QStringLiteral("keyboard"));

    // Right shift acts as Back so the keyboard works one-handed: reuse the
    // gamepad Back path, which posts Escape into QML — or sends ESC to mpv
    // over IPC when fullscreen mpv holds OS focus and the window can't take
    // key events. The bare Shift event is consumed; no view binds Key_Shift.
    //
    // Known gap: during fullscreen playback on macOS the keyboard goes to
    // mpv, not us, and mpv can't bind a bare modifier — so right shift only
    // works in the player on platforms where the app keeps the keyboard
    // (RPi/EGLFS). Same asymmetry as gamepads, minus their SDL workaround.
    if (ke->key() == Qt::Key_Shift && isRightShift(ke)) {
        if (!ke->isAutoRepeat()) {
            if (type == QEvent::KeyPress)
                deliverPress(Action::Back, false);
            else
                releaseAction(Action::Back);
        }
        return true;
    }

    // HID media keys drive mpv directly over IPC (sendKey no-ops when mpv isn't
    // running, so they're harmless while browsing). Volume keys repeat while
    // held; the rest fire once per press so a held key is a single seek/chapter
    // jump. On macOS during fullscreen playback mpv holds the keyboard and these
    // never reach us — mpv binds the same names natively.
    const QString mediaKey = mpvKeyForMediaEvent(ke);
    if (!mediaKey.isEmpty()) {
        if (type == QEvent::KeyPress) {
            // Volume keys repeat while held; everything else fires once per press.
            // mediaKey is the single source of truth for which key this is.
            const bool isVolume = mediaKey.startsWith(QLatin1String("VOLUME"));
            if (isVolume || !ke->isAutoRepeat())
                emit mpvKeyRequested(mediaKey);
        }
        return true;
    }
    return false;
}

void InputManager::setLastInputDevice(const QString &device) {
    if (m_lastInputDevice == device)
        return;
    m_lastInputDevice = device;
    emit lastInputDeviceChanged();
    updateHints();
}

// Display text for a button: user override from input.cfg wins; otherwise the
// face buttons (positional a/b/x/y) are translated to what's printed on the
// last-touched controller via its SDL type (Nintendo swaps A/B and X/Y,
// PlayStation uses shapes); everything else uses SDL's name uppercased.
QString InputManager::labelForButton(int button) const {
    const QString override_ = m_labelOverrides.value(button);
    if (!override_.isEmpty())
        return override_;

    SDL_GameController *gc = m_controllers.value(m_lastActiveController, nullptr);
    if (!gc && !m_controllers.isEmpty())
        gc = m_controllers.constBegin().value();
    const SDL_GameControllerType type =
        gc ? SDL_GameControllerGetType(gc) : SDL_CONTROLLER_TYPE_UNKNOWN;

    bool nintendo = type == SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_PRO;
    bool playstation = type == SDL_CONTROLLER_TYPE_PS3
                    || type == SDL_CONTROLLER_TYPE_PS4
                    || type == SDL_CONTROLLER_TYPE_PS5;
#if SDL_VERSION_ATLEAST(2, 24, 0)
    nintendo = nintendo
            || type == SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_JOYCON_LEFT
            || type == SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT
            || type == SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_JOYCON_PAIR;
#endif

    switch (button) {
    case SDL_CONTROLLER_BUTTON_A:   // south
        if (nintendo)    return QStringLiteral("B");
        if (playstation) return QStringLiteral("X");
        return QStringLiteral("A");
    case SDL_CONTROLLER_BUTTON_B:   // east
        if (nintendo)    return QStringLiteral("A");
        if (playstation) return QStringLiteral("O");
        return QStringLiteral("B");
    case SDL_CONTROLLER_BUTTON_X:   // west
        if (nintendo)    return QStringLiteral("Y");
        if (playstation) return QStringLiteral("SQ");
        return QStringLiteral("X");
    case SDL_CONTROLLER_BUTTON_Y:   // north
        if (nintendo)    return QStringLiteral("X");
        if (playstation) return QStringLiteral("TR");
        return QStringLiteral("Y");
    default:
        break;
    }

    const char *name = SDL_GameControllerGetStringForButton(
        static_cast<SDL_GameControllerButton>(button));
    return name ? QString::fromLatin1(name).toUpper() : QString();
}

QString InputManager::labelForJoystickButton(int button) const {
    QString name = m_rawJoystickNames.value(m_lastActiveController).toLower();
    if (name.isEmpty() && !m_rawJoystickNames.isEmpty())
        name = m_rawJoystickNames.constBegin().value().toLower();

    const bool playstation = name.contains(QStringLiteral("dualsense"))
                          || name.contains(QStringLiteral("dualshock"))
                          || name.contains(QStringLiteral("wireless controller"));
    if (playstation) {
        switch (button) {
        case 0:  return QStringLiteral("X");
        case 1:  return QStringLiteral("O");
        case 2:  return QStringLiteral("SQ");
        case 3:  return QStringLiteral("TR");
        case 4:  return QStringLiteral("L1");
        case 5:  return QStringLiteral("R1");
        case 6:  return QStringLiteral("L2");
        case 7:  return QStringLiteral("R2");
        case 8:  return QStringLiteral("SHARE");
        case 9:  return QStringLiteral("OPT");
        case 10: return QStringLiteral("PS");
        case 11: return QStringLiteral("L3");
        case 12: return QStringLiteral("R3");
        default: break;
        }
    }

    return QStringLiteral("B%1").arg(button);
}

// hints drives the footer labels in every view. Keyboard values are the exact
// strings the footers used before this existed; gamepad values come from a
// reverse lookup of the active mapping (enum order puts face buttons first).
// Directional glyphs stay — they're d-pad-true on a controller.
void InputManager::updateHints() {
    QVariantMap h;
    h["navigate"]   = QStringLiteral("[▲▼]");
    h["change"]     = QStringLiteral("[◄►]");
    h["browse"]     = QStringLiteral("[►]");
    h["back"]       = QStringLiteral("[ESC]");
    h["select"]     = QStringLiteral("[ENTER]");
    h["play_pause"] = QStringLiteral("[SPACE]");

    if (m_lastInputDevice == QStringLiteral("gamepad")) {
        const auto buttonLabel = [this](Action a) -> QString {
            for (int b = 0; b < SDL_CONTROLLER_BUTTON_MAX; ++b) {
                if (m_buttonMap.value(b, Action::None) == a) {
                    const QString label = labelForButton(b);
                    if (!label.isEmpty())
                        return "[" + label + "]";
                }
            }
            for (auto it = m_joystickButtonMap.constBegin(); it != m_joystickButtonMap.constEnd(); ++it) {
                if (it.value() == a) {
                    const QString label = labelForJoystickButton(it.key());
                    if (!label.isEmpty())
                        return "[" + label + "]";
                }
            }
            return QString();  // unbound → keep keyboard label
        };
        const QString back = buttonLabel(Action::Back);
        const QString select = buttonLabel(Action::Select);
        const QString playPause = buttonLabel(Action::PlayPause);
        if (!back.isEmpty())      h["back"]       = back;
        if (!select.isEmpty())    h["select"]     = select;
        if (!playPause.isEmpty()) h["play_pause"] = playPause;
    } else if (m_lastInputDevice == QStringLiteral("remote")) {
        h["back"]       = QStringLiteral("[BACK]");
        h["select"]     = QStringLiteral("[OK]");
        h["play_pause"] = QStringLiteral("[PLAY]");
    }

    if (h != m_hints) {
        m_hints = h;
        emit hintsChanged();
    }
}
