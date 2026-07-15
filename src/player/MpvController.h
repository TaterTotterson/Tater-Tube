#pragma once
#include <QObject>
#include <QProcess>
#include <QLocalSocket>
#include <QTimer>
#include <QJsonArray>
#include <QList>
#include <QPointer>
#include <QStringList>

class AppCore;
class QWindow;

#ifdef Q_OS_LINUX
#include <xf86drm.h>
#include <xf86drmMode.h>

struct DrmSavedState {
    uint32_t crtcId      = 0;
    uint32_t connectorId = 0;
    uint32_t fbId        = 0;
    int      x           = 0;
    int      y           = 0;
    drmModeModeInfo mode = {};
    bool     valid       = false;
};
#endif

class MpvController : public QObject {
    Q_OBJECT
    Q_PROPERTY(int position    READ position    NOTIFY positionChanged)
    Q_PROPERTY(int duration    READ duration    NOTIFY durationChanged)
    Q_PROPERTY(int playlistPos READ playlistPos NOTIFY playlistPosChanged)
    Q_PROPERTY(bool running    READ isRunning   NOTIFY runningChanged)
    Q_PROPERTY(bool paused     READ paused      NOTIFY pausedChanged)
    Q_PROPERTY(double audioLevel READ audioLevel NOTIFY audioLevelChanged)
    Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(double volumeMax READ volumeMax CONSTANT)
    Q_PROPERTY(bool muted READ muted NOTIFY mutedChanged)

public:
    explicit MpvController(const QString &appRoot, AppCore *appCore = nullptr,
                           QObject *parent = nullptr);
    ~MpvController() override;

    int position()    const { return m_position;    }
    int duration()    const { return m_duration;    }
    int playlistPos() const { return m_playlistPos; }
    bool isRunning() const;
    bool paused() const { return m_paused; }
    double audioLevel() const { return m_audioLevel; }
    double volume() const { return m_volume; }
    double volumeMax() const { return 200.0; }
    bool muted() const { return m_muted; }

    Q_INVOKABLE void loadAndPlay(const QString &url, float startSeconds,
                                  int audioTrack, int subTrack,
                                  const QStringList &subFiles = {},
                                  bool loop = false,
                                  int playlistStart = -1,
                                  float transcodeOffsetSec = 0.0f,
                                  const QString &httpHeaderFields = {},
                                  bool muteAudio = false,
                                  const QString &oscMode = {},
                                  bool shuffle = false,
                                  const QString &displayTitle = {},
                                  bool audioOnly = false,
                                  bool allowYtdl = false,
                                  const QString &ytdlFormat = {});
    Q_INVOKABLE void loadAudioAndPlay(const QString &url,
                                      float startSeconds = 0.0f,
                                      const QString &httpHeaderFields = {},
                                      const QString &displayTitle = {});
    Q_INVOKABLE bool replaceCurrentFile(const QString &url,
                                        float startSeconds = 0.0f,
                                        const QString &httpHeaderFields = {},
                                        const QString &displayTitle = {});
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seekTo(int positionMs);
    Q_INVOKABLE void sendKey(const QString &key);
    Q_INVOKABLE void sendScriptMessage(const QString &message, const QString &arg = {});
    Q_INVOKABLE void setPaused(bool paused);
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void adjustVolume(double delta);
    Q_INVOKABLE void toggleMute();
    Q_INVOKABLE void setPlaybackSpeed(double speed);
    Q_INVOKABLE void setAudioPitchCorrection(bool enabled);

signals:
    void positionChanged(int ms);
    void durationChanged(int ms);
    void playlistPosChanged(int pos);
    void runningChanged(bool running);
    void pausedChanged(bool paused);
    void audioLevelChanged(double level);
    void volumeChanged(double volume);
    void mutedChanged(bool muted);
    void volumeOverlayRequested();
    // Emitted when mpv exits because the user quit/stopped playback before the end.
    void playbackFinished(int finalPositionMs, int finalDurationMs);
    // Emitted when mpv exits because the file played to its natural end (mpv's
    // end-file event reported reason "eof"). Used to trigger autoplay-next.
    void playbackFinishedNaturally(int finalPositionMs, int finalDurationMs);
    // Emitted when mpv reports a playback error or exits unexpectedly.
    // Player.qml uses this to retry with transcoding.
    void playbackFailed();
    // Emitted when an mpv Lua script sends a script-message back over IPC.
    void scriptMessageReceived(const QString &message, const QString &arg);

private slots:
    void onProcessFinished();
    void tryConnectIpc();
    void onIpcReadyRead();

private:
    // Hardware video-decode profile, detected once from /proc/device-tree/model.
    enum class VideoProfile { Pi3, Pi4, PiFullKms, Generic };

    struct PlaybackRequest {
        QString url;
        float startSeconds = 0.0f;
        int audioTrack = 0;
        int subTrack = -1;
        QStringList subFiles;
        bool loop = false;
        int playlistStart = -1;
        float transcodeOffsetSec = 0.0f;
        QString httpHeaderFields;
        bool muteAudio = false;
        QString oscMode;
        bool shuffle = false;
        QString displayTitle;
        bool audioOnly = false;
        bool allowYtdl = false;
        QString ytdlFormat;
    };

    void sendCommand(const QJsonArray &args);
    void doHeadlessRestore(int pos, int dur, bool naturalEof, bool playbackError);
    bool shouldRetryPi3SoftwareFallback(bool playbackError) const;
    bool detectHeadlessMode() const;
    VideoProfile detectVideoProfile() const;
    bool hasCompositeDrmConnector() const;
    bool hasPiHeadphonesAudioDevice() const;
    // Appends the profile-specific --vo/--gpu-context/--hwdec flags (honouring the
    // app-level "mpv_video_args" override) to a forming mpv argument list.
    void appendVideoArgs(QStringList &args) const;
    void appendAudioArgs(QStringList &args) const;
    void setAudioLevel(double level);
    void setVolumeLevel(double volume, bool persist, bool showOverlay);
    void setMutedState(bool muted, bool showOverlay);
    void showMpvVolumeOverlay();
    int  getActiveVt() const;
    int  findFreeVt() const;
    int  findQtDrmFd() const;
    void switchToVt(int vt);
    void suspendQtWindows();
    void resumeQtWindows();
#ifdef Q_OS_LINUX
    void saveDrmCrtcState(int fd);
    void restoreDrmCrtcState(int fd);
#endif

    AppCore      *m_appCore        = nullptr;
    VideoProfile  m_videoProfile  = VideoProfile::Generic;
    QProcess     *m_process        = nullptr;
    QLocalSocket *m_ipc            = nullptr;
    QTimer       *m_connectTimer   = nullptr;
    QTimer       *m_watchdogTimer  = nullptr;
    qint64        m_lastIpcEventMs = 0;
    QString       m_appRoot;
    QString       m_socketPath;
    QString       m_inputConfPath;
    QString       m_logFilePath;
    QString       m_lastEndFileReason;  // mpv end-file "reason" for the current session
    PlaybackRequest m_lastPlaybackRequest;
    int           m_position     = 0;
    int           m_duration     = 0;
    int           m_playlistPos  = -1;
    double        m_audioLevel   = 0.0;
    double        m_volume       = 100.0;
    bool          m_muted        = false;
    bool          m_paused       = false;
    bool          m_headlessMode = false;
    int           m_previousVt   = -1;
    int           m_qtDrmFd      = -1;
    bool          m_qtDrmMasterDropped = false;
    bool          m_hasLastPlaybackRequest = false;
    bool          m_replayingPi3Fallback = false;
    bool          m_pi3FallbackAttempted = false;
    bool          m_pi3SoftwareFallback = false;
    bool          m_currentAudioOnly = false;
    bool          m_currentStayIdle = false;
    QList<QPointer<QWindow>> m_suspendedQtWindows;
#ifdef Q_OS_LINUX
    DrmSavedState m_savedDrm     = {};
#endif
};
