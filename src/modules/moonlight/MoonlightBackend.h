#pragma once

#include <QObject>
#include <QProcess>
#include <QVariantList>
#include <QVariantMap>

#ifdef Q_OS_LINUX
#include <xf86drm.h>
#include <xf86drmMode.h>

struct MoonlightDrmSavedState {
    uint32_t crtcId      = 0;
    uint32_t connectorId = 0;
    uint32_t fbId        = 0;
    int      x           = 0;
    int      y           = 0;
    drmModeModeInfo mode = {};
    bool     valid       = false;
};
#endif

class MoonlightBackend : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool running READ isRunning NOTIFY runningChanged)

public:
    explicit MoonlightBackend(const QString &appRoot, const QString &dataRoot,
                              QObject *parent = nullptr);
    ~MoonlightBackend() override;

    bool isRunning() const;

    Q_INVOKABLE QString get_auth_state();
    Q_INVOKABLE QVariantMap get_setup_status();
    Q_INVOKABLE void pair_host(const QString &host);
    Q_INVOKABLE void repair_host(const QString &host);
    Q_INVOKABLE void forget_pairing();
    Q_INVOKABLE void cancel_pairing();
    Q_INVOKABLE void load_apps();
    Q_INVOKABLE void refresh_app_cache();
    Q_INVOKABLE void launch_app(const QString &appName);
    Q_INVOKABLE void stop_stream();

signals:
    void authStateChanged();
    void pairCodeReady(const QString &code);
    void pairStatusChanged(const QString &message);
    void pairFinished(bool ok, const QString &message);
    void appsLoaded(const QVariantList &apps);
    void streamStarted(const QString &title);
    void streamFinished();
    void errorOccurred(const QString &message);
    void runningChanged(bool running);

public slots:
    void onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);

private slots:
    void onPairProcessFinished(int exitCode, QProcess::ExitStatus exitStatus);
    void onListProcessFinished(int exitCode, QProcess::ExitStatus exitStatus);
    void onStreamProcessFinished(int exitCode, QProcess::ExitStatus exitStatus);

private:
    QVariantMap moduleConfig() const;
    QString setting(const QString &key, const QString &fallback = QString()) const;
    QString moonlightPath() const;
    QString moonlightRoot() const;
    QString host() const;
    QString appCachePath() const;
    QVariantList loadAppCache() const;
    bool saveAppCache(const QVariantList &apps) const;
    void clearAppCache() const;
    void unpairMoonlightHost(const QString &hostValue) const;
    void removeMoonlightPairingState() const;
    void startAppList(bool forceRefresh);
    QVariantList parseAppList(const QString &output) const;
    QString bundledMoonlightPath() const;
    QString moonlightLaunchHelperPath() const;
    bool canUseMoonlightLaunchHelper() const;
    QStringList streamArguments(const QString &appName, bool forceSdl = false) const;
    void prepareMoonlightEnvironment(QProcess *process) const;
    QString processOutput(QProcess *process) const;
    QString processErrorMessage(QProcess *process, const QString &fallback) const;
    QStringList executableSearchPaths() const;
    bool detectHeadlessMode() const;
    bool hasPiHeadphonesAudioDevice() const;
    int getActiveVt() const;
    int findFreeVt() const;
    int findQtDrmFd() const;
    void switchToVt(int vt);
    void prepareHeadlessLaunch();
    void restoreHeadlessDisplay();
#ifdef Q_OS_LINUX
    void saveDrmCrtcState(int fd);
    void restoreDrmCrtcState(int fd);
#endif

    QString m_appRoot;
    QString m_dataRoot;
    QProcess *m_pairProcess = nullptr;
    QProcess *m_listProcess = nullptr;
    QProcess *m_streamProcess = nullptr;
    QString m_pairOutput;
    bool m_pairTimedOut = false;
    int m_pairSessionId = 0;
    QString m_listOutput;
    QString m_streamOutput;
    QString m_currentTitle;
    bool m_headlessMode = false;
    int m_previousVt = -1;
    int m_qtDrmFd = -1;
    bool m_qtDrmMasterDropped = false;
#ifdef Q_OS_LINUX
    MoonlightDrmSavedState m_savedDrm = {};
#endif
};
