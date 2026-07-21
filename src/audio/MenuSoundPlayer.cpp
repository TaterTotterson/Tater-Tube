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

class ScopedEnvironmentOverride {
public:
    ScopedEnvironmentOverride(const QByteArray &name, const QByteArray &value,
                              bool enabled)
        : m_name(name)
        , m_wasSet(qEnvironmentVariableIsSet(name.constData()))
        , m_previousValue(qgetenv(name.constData()))
        , m_enabled(enabled)
    {
        if (m_enabled)
            qputenv(m_name.constData(), value);
    }

    ~ScopedEnvironmentOverride()
    {
        if (!m_enabled)
            return;
        if (m_wasSet)
            qputenv(m_name.constData(), m_previousValue);
        else
            qunsetenv(m_name.constData());
    }

private:
    QByteArray m_name;
    bool m_wasSet = false;
    QByteArray m_previousValue;
    bool m_enabled = false;
};

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

QString piSdlAudioDevice()
{
#ifdef Q_OS_LINUX
    // Caller-provided routing always wins. SDL2's ALSA backend reads AUDIODEV;
    // SDL_AUDIO_DEVICE_NAME is also treated as an explicit generic override.
    if (!qEnvironmentVariableIsEmpty("AUDIODEV")
            || !qEnvironmentVariableIsEmpty("SDL_AUDIO_DEVICE_NAME")) {
        return {};
    }
    const QByteArray requestedDriver = qgetenv("SDL_AUDIODRIVER").trimmed();
    if (!requestedDriver.isEmpty()
            && requestedDriver.compare("alsa", Qt::CaseInsensitive) != 0) {
        return {};
    }

    // Accept the existing launcher override, but do not publish it as a global
    // AUDIODEV value: child playback processes must not inherit menu routing.
    const QByteArray configuredDevice =
        qgetenv("SDL_AUDIO_ALSA_DEFAULT_DEVICE").trimmed();
    if (!configuredDevice.isEmpty())
        return QString::fromLocal8Bit(configuredDevice);

    return connectedPiAlsaDevice();
#else
    return {};
#endif
}
}

MenuSoundPlayer::MenuSoundPlayer(const QString &appRoot, AppCore *appCore,
                                 QObject *parent)
    : QObject(parent)
    , m_appRoot(appRoot)
    , m_piAlsaDevice(piSdlAudioDevice())
    , m_appCore(appCore)
{
    // Select ALSA only while SDL initializes. Restoring the process environment
    // immediately keeps mpv and every other child process isolated from the
    // menu-sound route.
    const bool selectAlsa = !m_piAlsaDevice.isEmpty()
        && qEnvironmentVariableIsEmpty("SDL_AUDIODRIVER");
    const ScopedEnvironmentOverride driverOverride(
        QByteArrayLiteral("SDL_AUDIODRIVER"), QByteArrayLiteral("alsa"), selectAlsa);
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) == 0) {
        m_audioSubsystemReady = true;
        if (!m_piAlsaDevice.isEmpty()) {
            qInfo("[menu-sounds] using Pi ALSA output: %s",
                  qPrintable(m_piAlsaDevice));
        }
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

    // Playback owns the Pi output exclusively. Release the menu handle before
    // mpv, RetroArch, or Moonlight can open it; context signals already block
    // all subsequent cues until the external experience has ended.
    if (active)
        closeAudioDevice();
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
    if (!m_enabled && m_audioDevice) {
        SDL_LockAudioDevice(m_audioDevice);
        m_activeCueSound.clear();
        m_activeCueOffset = 0;
        SDL_UnlockAudioDevice(m_audioDevice);
    }
    if (packSlug != m_packSlug || m_moveSound.isEmpty()) {
        m_packSlug = packSlug;
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

    const QByteArray sound = convertAudio(
        spec, buffer, length, QString::fromLocal8Bit(encodedPath));
    SDL_FreeWAV(buffer);
    return sound;
}

QByteArray MenuSoundPlayer::decodeWave(const QByteArray &wavData) const
{
    if (wavData.isEmpty())
        return {};

    SDL_RWops *source = SDL_RWFromConstMem(wavData.constData(), wavData.size());
    if (!source) {
        qWarning("[app-audio] could not open narration WAV: %s", SDL_GetError());
        return {};
    }

    SDL_AudioSpec spec{};
    Uint8 *buffer = nullptr;
    Uint32 length = 0;
    if (!SDL_LoadWAV_RW(source, 1, &spec, &buffer, &length)) {
        qWarning("[app-audio] could not decode narration WAV: %s", SDL_GetError());
        return {};
    }

    const QByteArray sound = convertAudio(
        spec, buffer, length, QStringLiteral("Tater narration"));
    SDL_FreeWAV(buffer);
    return sound;
}

QByteArray MenuSoundPlayer::convertAudio(const SDL_AudioSpec &spec,
                                         const Uint8 *buffer, Uint32 length,
                                         const QString &description) const
{
    QByteArray sound;
    SDL_AudioCVT converter{};
    const int conversion = SDL_BuildAudioCVT(
        &converter, spec.format, spec.channels, spec.freq,
        AUDIO_S16SYS, kOutputChannels, kSampleRate);
    if (conversion < 0) {
        qWarning("[app-audio] could not prepare %s: %s",
                 qPrintable(description), SDL_GetError());
    } else if (conversion == 0) {
        sound = QByteArray(reinterpret_cast<const char *>(buffer), int(length));
    } else {
        converter.len = int(length);
        converter.buf = static_cast<Uint8 *>(
            SDL_malloc(size_t(converter.len) * size_t(converter.len_mult)));
        if (!converter.buf) {
            qWarning("[app-audio] could not allocate converted audio for %s",
                     qPrintable(description));
        } else {
            SDL_memcpy(converter.buf, buffer, length);
            if (SDL_ConvertAudio(&converter) == 0) {
                sound = QByteArray(reinterpret_cast<const char *>(converter.buf),
                                   converter.len_cvt);
            } else {
                qWarning("[app-audio] could not convert %s: %s",
                         qPrintable(description), SDL_GetError());
            }
            SDL_free(converter.buf);
        }
    }
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
    desired.callback = &MenuSoundPlayer::audioCallback;
    desired.userdata = this;
    // SDL2 reads AUDIODEV inside SDL_OpenAudioDevice(). Limit the override to
    // this call so it can never leak into mpv's QProcess environment.
    const ScopedEnvironmentOverride deviceOverride(
        QByteArrayLiteral("AUDIODEV"), m_piAlsaDevice.toLocal8Bit(),
        !m_piAlsaDevice.isEmpty());
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
    const SDL_AudioDeviceID device = m_audioDevice;
    m_audioDevice = 0;
    SDL_PauseAudioDevice(device, 1);
    SDL_CloseAudioDevice(device);
    const quint64 generation = m_narrationGeneration;
    m_activeCueSound.clear();
    m_narrationSound.clear();
    m_activeCueOffset = 0;
    m_narrationOffset = 0;
    m_narrationGeneration = 0;
    if (generation)
        emit narrationFinished(generation);
}

void MenuSoundPlayer::play(Cue cue)
{
    const QByteArray &sound = soundForCue(cue);
    if (sound.isEmpty() || !openAudioDevice())
        return;

    SDL_LockAudioDevice(m_audioDevice);
    m_activeCueSound = sound;
    m_activeCueOffset = 0;
    SDL_UnlockAudioDevice(m_audioDevice);
}

void MenuSoundPlayer::playNarration(const QByteArray &wavData, quint64 generation)
{
    const QByteArray sound = decodeWave(wavData);
    if (sound.isEmpty() || !openAudioDevice()) {
        qWarning("[app-audio] Tater narration could not be played");
        emit narrationFinished(generation);
        return;
    }

    SDL_LockAudioDevice(m_audioDevice);
    m_narrationSound = sound;
    m_narrationOffset = 0;
    m_narrationGeneration = generation;
    SDL_UnlockAudioDevice(m_audioDevice);
    qInfo("[app-audio] Tater narration started in the shared mixer");
}

void MenuSoundPlayer::stopNarration()
{
    if (m_audioDevice)
        SDL_LockAudioDevice(m_audioDevice);
    m_narrationSound.clear();
    m_narrationOffset = 0;
    m_narrationGeneration = 0;
    if (m_audioDevice)
        SDL_UnlockAudioDevice(m_audioDevice);
}

void MenuSoundPlayer::setNarrationVolume(double volume)
{
    if (m_audioDevice)
        SDL_LockAudioDevice(m_audioDevice);
    m_narrationGain = qBound(0.0, volume, 200.0) / 100.0;
    if (m_audioDevice)
        SDL_UnlockAudioDevice(m_audioDevice);
}

void MenuSoundPlayer::setNarrationMuted(bool muted)
{
    if (m_audioDevice)
        SDL_LockAudioDevice(m_audioDevice);
    m_narrationMuted = muted;
    if (m_audioDevice)
        SDL_UnlockAudioDevice(m_audioDevice);
}

void MenuSoundPlayer::audioCallback(void *userdata, Uint8 *stream, int length)
{
    static_cast<MenuSoundPlayer *>(userdata)->mixAudio(stream, length);
}

void MenuSoundPlayer::mixAudio(Uint8 *stream, int length)
{
    SDL_memset(stream, 0, size_t(length));
    mixBuffer(m_narrationSound, m_narrationOffset, stream, length,
              m_narrationMuted ? 0.0 : m_narrationGain);
    mixBuffer(m_activeCueSound, m_activeCueOffset, stream, length, 1.0);

    if (!m_narrationSound.isEmpty()
            && m_narrationOffset >= m_narrationSound.size()) {
        const quint64 generation = m_narrationGeneration;
        m_narrationSound.clear();
        m_narrationOffset = 0;
        m_narrationGeneration = 0;
        if (generation) {
            QMetaObject::invokeMethod(this, [this, generation]() {
                emit narrationFinished(generation);
            }, Qt::QueuedConnection);
        }
    }
    if (!m_activeCueSound.isEmpty()
            && m_activeCueOffset >= m_activeCueSound.size()) {
        m_activeCueSound.clear();
        m_activeCueOffset = 0;
    }
}

void MenuSoundPlayer::mixBuffer(const QByteArray &source, qsizetype &offset,
                                Uint8 *stream, int length, double gain)
{
    if (source.isEmpty() || offset >= source.size())
        return;
    const qsizetype remaining = source.size() - offset;
    const int count = int(qMin<qsizetype>(remaining, length)) & ~1;
    if (count <= 0) {
        offset = source.size();
        return;
    }
    const auto *input = reinterpret_cast<const qint16 *>(source.constData() + offset);
    auto *output = reinterpret_cast<qint16 *>(stream);
    for (int i = 0; i < count / int(sizeof(qint16)); ++i) {
        const int mixed = int(output[i]) + int(double(input[i]) * gain);
        output[i] = qint16(qBound(-32768, mixed, 32767));
    }
    offset += count;
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
