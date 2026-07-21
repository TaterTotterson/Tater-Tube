#include "MenuSoundPlayer.h"

#include "AppCore.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QMetaObject>
#include <QTimer>

namespace {
constexpr int kSampleRate = 48000;
constexpr Uint8 kOutputChannels = 2;
constexpr int kMinimumSoundIntervalMs = 38;

QString connectedPiAlsaDevice()
{
#ifdef Q_OS_LINUX
    // Composite output on the Pi uses the analogue Headphones device.
    if (QFile::exists(QStringLiteral("/sys/class/drm/card1-Composite-1"))
            && QFile::exists(QStringLiteral("/proc/asound/Headphones"))) {
        return QStringLiteral("sysdefault:CARD=Headphones");
    }

    QDir drmDir(QStringLiteral("/sys/class/drm"));
    const QStringList connectors = drmDir.entryList(
        QStringList{QStringLiteral("card*-HDMI-A-*")},
        QDir::Dirs | QDir::NoDotAndDotDot,
        QDir::Name);
    for (const QString &connector : connectors) {
        QFile statusFile(drmDir.absoluteFilePath(
            connector + QStringLiteral("/status")));
        if (!statusFile.open(QIODevice::ReadOnly)
                || QString::fromLatin1(statusFile.readAll()).trimmed()
                    != QStringLiteral("connected")) {
            continue;
        }

        QString card;
        if (connector.endsWith(QStringLiteral("HDMI-A-1")))
            card = QStringLiteral("vc4hdmi0");
        else if (connector.endsWith(QStringLiteral("HDMI-A-2")))
            card = QStringLiteral("vc4hdmi1");

        if (!card.isEmpty()
                && QFile::exists(QStringLiteral("/proc/asound/") + card)) {
            return QStringLiteral("sysdefault:CARD=%1").arg(card);
        }
    }
#endif
    return {};
}

void configurePiSdlAudio()
{
#ifdef Q_OS_LINUX
    // An explicit device always wins. A non-ALSA driver also indicates that
    // the caller wants SDL to use its own desktop/session routing.
    if (!qEnvironmentVariableIsEmpty("SDL_AUDIO_ALSA_DEFAULT_DEVICE"))
        return;
    const QByteArray requestedDriver = qgetenv("SDL_AUDIODRIVER").trimmed();
    if (!requestedDriver.isEmpty()
            && requestedDriver.compare("alsa", Qt::CaseInsensitive) != 0) {
        return;
    }

    const QString device = connectedPiAlsaDevice();
    if (device.isEmpty())
        return;

    if (requestedDriver.isEmpty())
        qputenv("SDL_AUDIODRIVER", QByteArrayLiteral("alsa"));
    qputenv("SDL_AUDIO_ALSA_DEFAULT_DEVICE", device.toLocal8Bit());
    qInfo("[menu-sounds] using Pi ALSA output: %s", qPrintable(device));
#endif
}
}

MenuSoundPlayer::MenuSoundPlayer(const QString &appRoot, AppCore *appCore,
                                 QObject *parent)
    : QObject(parent)
    , m_appRoot(appRoot)
    , m_appCore(appCore)
{
    configurePiSdlAudio();
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) == 0) {
        m_audioSubsystemReady = true;
    } else {
        qWarning("[menu-sounds] SDL audio init failed: %s", SDL_GetError());
    }

    reloadSettings();
    if (m_appCore) {
        connect(m_appCore, &AppCore::appSettingChanged, this,
                [this](const QString &key, const QString &) {
            if (key == QStringLiteral("menu_sounds_enabled")
                    || key == QStringLiteral("menu_sound_pack")) {
                reloadSettings();
            }
        });
    }
    if (QCoreApplication::instance())
        QCoreApplication::instance()->installEventFilter(this);
}

MenuSoundPlayer::~MenuSoundPlayer()
{
    if (QCoreApplication::instance())
        QCoreApplication::instance()->removeEventFilter(this);
    closeAudioDevice();
    if (m_audioSubsystemReady)
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
}

void MenuSoundPlayer::setPlaybackActive(bool active)
{
    setContextActive(QStringLiteral("mpv"), active);
}

void MenuSoundPlayer::setContextActive(const QString &context, bool active)
{
    const QString key = context.trimmed();
    if (key.isEmpty())
        return;

    if (active)
        m_activeContexts.insert(key);
    else
        m_activeContexts.remove(key);

    if (!active || !m_audioDevice)
        return;

    // Block new cues immediately, but let the short Select cue that launched
    // the experience finish before releasing the menu audio device.
    QTimer::singleShot(250, this, [this]() {
        if (!m_activeContexts.isEmpty())
            closeAudioDevice();
    });
}

bool MenuSoundPlayer::eventFilter(QObject *watched, QEvent *event)
{
    Q_UNUSED(watched)
    if (!m_enabled || !m_activeContexts.isEmpty()
            || event->type() != QEvent::KeyPress) {
        return false;
    }

    const auto *keyEvent = static_cast<QKeyEvent *>(event);
    const Cue cue = cueForKey(keyEvent->key());
    if (cue == Cue::None)
        return false;
    if (keyEvent->isAutoRepeat() && (cue == Cue::Back || cue == Cue::Select))
        return false;
    if (isTextEditingFocus(QGuiApplication::focusObject()))
        return false;
    if (m_lastSoundTimer.isValid()
            && m_lastSoundTimer.elapsed() < kMinimumSoundIntervalMs) {
        return false;
    }

    m_lastSoundTimer.restart();
    play(cue);
    return false;
}

void MenuSoundPlayer::reloadSettings()
{
    bool enabled = true;
    QString packSlug = QStringLiteral("soft-touch");
    if (m_appCore) {
        enabled = settingEnabled(
            m_appCore->get_setting(QString(), QStringLiteral("menu_sounds_enabled")),
            true);
        packSlug = packSlugForSetting(
            m_appCore->get_setting(QString(), QStringLiteral("menu_sound_pack")).toString());
    }

    m_enabled = enabled;
    if (!m_enabled)
        closeAudioDevice();
    if (packSlug != m_packSlug || m_moveSound.isEmpty()) {
        m_packSlug = packSlug;
        closeAudioDevice();
        loadPack(m_packSlug);
    }
}

void MenuSoundPlayer::loadPack(const QString &packSlug)
{
    const QDir packDir(QDir(m_appRoot).absoluteFilePath(
        QStringLiteral("assets/audio/menu/%1").arg(packSlug)));
    m_moveSound = loadWave(packDir.absoluteFilePath(QStringLiteral("move.wav")));
    m_pageSound = loadWave(packDir.absoluteFilePath(QStringLiteral("page.wav")));
    m_backSound = loadWave(packDir.absoluteFilePath(QStringLiteral("back.wav")));
    m_selectSound = loadWave(packDir.absoluteFilePath(QStringLiteral("select.wav")));
}

QByteArray MenuSoundPlayer::loadWave(const QString &path) const
{
    SDL_AudioSpec spec{};
    Uint8 *buffer = nullptr;
    Uint32 length = 0;
    const QByteArray encodedPath = QFile::encodeName(path);
    if (!SDL_LoadWAV(encodedPath.constData(), &spec, &buffer, &length)) {
        qWarning("[menu-sounds] could not load %s: %s",
                 encodedPath.constData(), SDL_GetError());
        return {};
    }

    QByteArray sound;
    SDL_AudioCVT converter{};
    const int conversion = SDL_BuildAudioCVT(
        &converter, spec.format, spec.channels, spec.freq,
        AUDIO_S16SYS, kOutputChannels, kSampleRate);
    if (conversion < 0) {
        qWarning("[menu-sounds] could not prepare %s: %s",
                 encodedPath.constData(), SDL_GetError());
    } else if (conversion == 0) {
        sound = QByteArray(reinterpret_cast<const char *>(buffer), int(length));
    } else {
        converter.len = int(length);
        converter.buf = static_cast<Uint8 *>(
            SDL_malloc(size_t(converter.len) * size_t(converter.len_mult)));
        if (!converter.buf) {
            qWarning("[menu-sounds] could not allocate converted audio for %s",
                     encodedPath.constData());
        } else {
            SDL_memcpy(converter.buf, buffer, length);
            if (SDL_ConvertAudio(&converter) == 0) {
                sound = QByteArray(reinterpret_cast<const char *>(converter.buf),
                                   converter.len_cvt);
            } else {
                qWarning("[menu-sounds] could not convert %s: %s",
                         encodedPath.constData(), SDL_GetError());
            }
            SDL_free(converter.buf);
        }
    }
    SDL_FreeWAV(buffer);
    return sound;
}

bool MenuSoundPlayer::openAudioDevice()
{
    if (m_audioDevice)
        return true;
    if (!m_audioSubsystemReady)
        return false;

    SDL_AudioSpec desired{};
    SDL_AudioSpec obtained{};
    desired.freq = kSampleRate;
    desired.format = AUDIO_S16SYS;
    desired.channels = kOutputChannels;
    desired.samples = 1024;
    desired.callback = nullptr;
    m_audioDevice = SDL_OpenAudioDevice(nullptr, 0, &desired, &obtained, 0);
    if (!m_audioDevice) {
        if (!m_audioWarningShown) {
            qWarning("[menu-sounds] could not open audio output: %s", SDL_GetError());
            m_audioWarningShown = true;
        }
        return false;
    }
    SDL_PauseAudioDevice(m_audioDevice, 0);
    return true;
}

void MenuSoundPlayer::closeAudioDevice()
{
    if (!m_audioDevice)
        return;
    SDL_ClearQueuedAudio(m_audioDevice);
    SDL_CloseAudioDevice(m_audioDevice);
    m_audioDevice = 0;
}

void MenuSoundPlayer::play(Cue cue)
{
    const QByteArray &sound = soundForCue(cue);
    if (sound.isEmpty() || !openAudioDevice())
        return;

    SDL_ClearQueuedAudio(m_audioDevice);
    if (SDL_QueueAudio(m_audioDevice, sound.constData(), Uint32(sound.size())) != 0)
        qWarning("[menu-sounds] could not queue sound: %s", SDL_GetError());
}

const QByteArray &MenuSoundPlayer::soundForCue(Cue cue) const
{
    switch (cue) {
    case Cue::Move:   return m_moveSound;
    case Cue::Page:   return m_pageSound;
    case Cue::Back:   return m_backSound;
    case Cue::Select: return m_selectSound;
    case Cue::None:   break;
    }
    static const QByteArray empty;
    return empty;
}

MenuSoundPlayer::Cue MenuSoundPlayer::cueForKey(int key)
{
    switch (key) {
    case Qt::Key_Up:
    case Qt::Key_Down:
        return Cue::Move;
    case Qt::Key_Left:
    case Qt::Key_Right:
    case Qt::Key_PageUp:
    case Qt::Key_PageDown:
        return Cue::Page;
    case Qt::Key_Escape:
    case Qt::Key_Back:
    case Qt::Key_Backspace:
        return Cue::Back;
    case Qt::Key_Return:
    case Qt::Key_Enter:
    case Qt::Key_Select:
        return Cue::Select;
    default:
        return Cue::None;
    }
}

QString MenuSoundPlayer::packSlugForSetting(const QString &value)
{
    const QString normalized = value.trimmed().toLower();
    if (normalized == QStringLiteral("rental night")
            || normalized == QStringLiteral("rental-night")) {
        return QStringLiteral("rental-night");
    }
    if (normalized == QStringLiteral("haunted tape")
            || normalized == QStringLiteral("haunted-tape")) {
        return QStringLiteral("haunted-tape");
    }
    return QStringLiteral("soft-touch");
}

bool MenuSoundPlayer::settingEnabled(const QVariant &value, bool fallback)
{
    if (!value.isValid() || value.isNull() || value.toString().trimmed().isEmpty())
        return fallback;
    if (value.metaType().id() == QMetaType::Bool)
        return value.toBool();
    const QString normalized = value.toString().trimmed().toLower();
    return normalized != QStringLiteral("off")
        && normalized != QStringLiteral("false")
        && normalized != QStringLiteral("0")
        && normalized != QStringLiteral("no");
}

bool MenuSoundPlayer::isTextEditingFocus(QObject *focusObject)
{
    for (QObject *object = focusObject; object; object = object->parent()) {
        const QByteArray className = object->metaObject()->className();
        if (className.contains("TextInput") || className.contains("TextEdit")
                || className.contains("TextField")) {
            return true;
        }
    }
    return false;
}
