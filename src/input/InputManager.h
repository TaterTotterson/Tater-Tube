#pragma once
#include <QObject>
#include <QEvent>
#include <QTimer>
#include <QHash>
#include <QPair>
#include <QSet>
#include <QList>
#include <QDateTime>
#include <QVariantMap>
#include <QFileSystemWatcher>
#include <SDL.h>

class QQuickWindow;
class QKeyEvent;
#ifdef Q_OS_LINUX
class QSocketNotifier;
#endif

// Centralized gamepad input. SDL controller buttons/axes are mapped to a small
// set of named actions (up/down/left/right/select/back/play_pause), and each
// action is delivered to QML as an ordinary synthesized key event posted to the
// root window — so every existing Keys.onPressed handler (including the Player
// views that forward keys to mpv over IPC) works without gamepad-specific code.
// Defaults can be overridden per-input in $DATA_ROOT/input.cfg (live-reloaded).
class InputManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool gamepadConnected READ gamepadConnected NOTIFY gamepadConnectedChanged)
    Q_PROPERTY(QString lastInputDevice READ lastInputDevice NOTIFY lastInputDeviceChanged)
    Q_PROPERTY(QVariantMap hints READ hints NOTIFY hintsChanged)

public:
    explicit InputManager(const QString &dataRoot, QObject *parent = nullptr);
    ~InputManager() override;

    void setTargetWindow(QQuickWindow *window);

    bool gamepadConnected() const { return !m_controllers.isEmpty() || !m_rawJoystickNames.isEmpty(); }
    Q_INVOKABLE QVariantMap getControllerMapping() const;
    Q_INVOKABLE bool saveControllerMapping(const QVariantMap &mapping);
    Q_INVOKABLE void beginControllerMapping();
    Q_INVOKABLE void endControllerMapping();
    QString lastInputDevice() const { return m_lastInputDevice; }
    QVariantMap hints() const { return m_hints; }

signals:
    void gamepadConnectedChanged();
    void lastInputDeviceChanged();
    void hintsChanged();
    void homeRequested();
    void powerRequested();
    void controllerMappingInput(const QVariantMap &input);
    // Emitted instead of posting a key event when the Qt window is inactive
    // (fullscreen mpv holds OS focus on macOS, which clears QML active focus).
    // main.cpp connects this to MpvController::sendKey.
    void mpvKeyRequested(const QString &key);

protected:
    bool eventFilter(QObject *obj, QEvent *event) override;

private slots:
    void pollSdl();
    void onRepeatDelayElapsed();
    void onRepeatTick();
    void onDataDirChanged(const QString &path);

private:
    enum class Action { None, Up, Down, Left, Right, Select, Back, Menu, PlayPause };

    void initSdl();
    void openController(int deviceIndex);
    void closeController(SDL_JoystickID instanceId);
    void openJoystick(int deviceIndex);
    void closeJoystick(SDL_JoystickID instanceId);
    void rebuildMapping();
    void loadDefaultMapping();
    void loadUserMapping();
    void noteActiveController(SDL_JoystickID which);
    bool controllerMappingNeedsDefault() const;
    void ensureDefaultControllerMapping(SDL_JoystickID which, SDL_GameController *controller);
    void ensureDefaultJoystickMapping(SDL_JoystickID which);
    void handleButton(SDL_JoystickID which, Uint8 button, bool pressed);
    void handleAxis(SDL_JoystickID which, Uint8 axis, Sint16 value);
    void handleJoystickButton(SDL_JoystickID which, Uint8 button, bool pressed);
    void handleJoystickAxis(SDL_JoystickID which, Uint8 axis, Sint16 value);
    void handleJoystickHat(SDL_JoystickID which, Uint8 hat, Uint8 value);
    QVariantMap mappingInputForButton(SDL_GameController *controller, Uint8 button) const;
    QVariantMap mappingInputForAxis(SDL_GameController *controller, Uint8 axis, int direction) const;
    QVariantMap mappingInputForJoystickButton(Uint8 button) const;
    QVariantMap mappingInputForJoystickAxis(Uint8 axis, int direction) const;
    QVariantMap mappingInputForJoystickHat(Uint8 hat, Uint8 hatMask) const;
    void primeControllerMappingState();
    bool captureMappingInput(const QVariantMap &input, SDL_JoystickID which, bool markControllerSeen);
    void loadGameExitCombo(const QVariantMap &bindings);
    bool updatePressedInputToken(const QString &token, bool pressed);
    bool checkGameExitCombo();
    void pressAction(Action a, const QString &device);
    void releaseAction(Action a);
    void deliverPress(Action a, bool autoRepeat);
    void postKey(int qtKey, QEvent::Type type, bool autoRepeat);
    bool windowActive() const;
    void setLastInputDevice(const QString &device);
    void updateHints();
    QString labelForButton(int button) const;
    QString labelForJoystickButton(int button) const;
    static int qtKeyForAction(Action a);
    static QString mpvKeyForAction(Action a);
    // Maps a HID media-key event to the canonical mpv key name media-keys.lua
    // binds, or an empty string for non-media keys.
    static QString mpvKeyForMediaEvent(const QKeyEvent *ke);
    static Action remoteActionForKey(const QKeyEvent *ke);
    static Action actionFromString(const QString &name, bool *ok);
    static int buttonFromToken(const QString &token);
    static bool isDirectional(Action a);
    static QString axisToken(Uint8 axis, int direction);
    static QString retroHatDirection(Uint8 hatMask);
    static QVariantMap retroBindingFromSdlBind(const SDL_GameControllerButtonBind &bind, int direction);
    static bool shouldIgnoreJoystickName(const QString &name);
    static int joystickButtonFromToken(const QString &token);
    static bool joystickAxisFromToken(const QString &token, int *axis, int *direction);
    static bool joystickHatFromToken(const QString &token, int *hat, Uint8 *hatMask);
    static qint64 joystickInputKey(SDL_JoystickID which, int input);
    static int joystickHatConfigKey(int hat, Uint8 hatMask);

#ifdef Q_OS_LINUX
    void initIrReceiver();
    void scanIrReceiver();
    bool openIrDevice(const QString &path);
    void closeIrDevice();
    void onIrDeviceReady();
    void handleIrKey(quint16 code, int value);
    static Action actionForLinuxKey(quint16 code);
    static QString mpvKeyForLinuxKey(quint16 code);
#endif

    QQuickWindow *m_window = nullptr;
    QString m_dataRoot;
    bool m_sdlReady = false;
    bool m_controllerMappingActive = false;

    QTimer m_pollTimer;
    QTimer m_repeatDelayTimer;
    QTimer m_repeatTimer;
    QFileSystemWatcher m_watcher;
    QDateTime m_cfgLastModified;

#ifdef Q_OS_LINUX
    QTimer m_irScanTimer;
    QSocketNotifier *m_irNotifier = nullptr;
    int m_irFd = -1;
    QString m_irDevicePath;
#endif

    QHash<SDL_JoystickID, SDL_GameController*> m_controllers;
    QHash<SDL_JoystickID, SDL_Joystick*> m_joysticks;
    QHash<SDL_JoystickID, QString> m_rawJoystickNames;
    QSet<SDL_JoystickID> m_controllerInputSeen;
    QHash<int, Action> m_buttonMap;                  // SDL_GameControllerButton → Action
    QHash<int, QPair<Action, Action>> m_axisMap;     // SDL_GameControllerAxis → (negative, positive)
    QHash<int, Action> m_joystickButtonMap;          // raw SDL joystick button → Action
    QHash<int, QPair<Action, Action>> m_joystickAxisMap; // raw SDL joystick axis → (negative, positive)
    QHash<int, Action> m_joystickHatMap;             // raw SDL joystick hat+direction → Action
    QHash<int, int> m_axisState;                     // per-axis engaged direction: -1 / 0 / +1
    QHash<int, int> m_mappingAxisState;              // per-axis mapper latch: -1 / 0 / +1
    QHash<qint64, int> m_joystickAxisState;          // per raw joystick+axis engaged direction
    QHash<qint64, int> m_mappingJoystickAxisState;   // per raw joystick+axis mapper latch
    QHash<qint64, Uint8> m_joystickHatState;         // per raw joystick+hat direction mask
    QHash<qint64, Uint8> m_mappingJoystickHatState;  // per raw joystick+hat mapper latch
    QSet<QString> m_pressedInputTokens;
    QSet<QString> m_mappingCapturedTokens;
    QSet<int> m_mappingCapturedPositiveAxes;
    QSet<qint64> m_mappingCapturedPositiveJoystickAxes;
    QList<QSet<QString>> m_gameExitComboTokenGroups;
    bool m_gameExitComboLatched = false;
    QHash<int, QString> m_labelOverrides;            // SDL button → user display label (input.cfg)
    SDL_JoystickID m_lastActiveController = -1;      // labels follow the pad last touched
    Action m_heldDirection = Action::None;

    QString m_lastInputDevice = "keyboard";
    QVariantMap m_hints;
};
