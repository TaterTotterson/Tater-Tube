#pragma once
#include <QObject>
#include <QVariant>
#include <QVariantList>
#include <QJsonObject>
#include <QMap>
#include <QCoreApplication>

class QQmlContext;
class QNetworkAccessManager;
class QProcess;
class QTimer;

struct ModuleEntry {
    QString id;
    QString name;
    QString folder;      // subdirectory under modules/
    QString entryQml;    // relative to module folder, e.g. "views/Root.qml"
    QString iconRel;     // relative to module folder, e.g. "assets/images/logo.svg"
    int order = 1000;
    QVariantList settings;
};

class AppCore : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString appVersion READ appVersion CONSTANT)
    Q_PROPERTY(QVariantList taterRecommendations READ taterRecommendations NOTIFY taterRecommendationsChanged)
    Q_PROPERTY(QVariantMap taterRecommendationBatch READ taterRecommendationBatch NOTIFY taterRecommendationsChanged)
    Q_PROPERTY(bool taterNarrating READ taterNarrating NOTIFY taterNarratingChanged)
public:
    explicit AppCore(const QString &appRoot, const QString &dataRoot, QObject *parent = nullptr);

    QString appVersion() const { return QCoreApplication::applicationVersion(); }
    QString appRoot() const { return m_appRoot; }
    QString dataRoot() const { return m_dataRoot; }
    QVariantList taterRecommendations() const { return m_taterRecommendations; }
    QVariantMap taterRecommendationBatch() const { return m_taterRecommendationBatch; }
    bool taterNarrating() const { return m_taterNarrating; }

    // True when launched by the autostart systemd service (which injects MP240_AUTOSTART=1).
    // Gates the quit overlay's "Exit to Terminal" option, which only makes sense on a
    // headless RPi running under the service. See scripts/install.sh and 240mp-stop.
    Q_INVOKABLE bool isAutostartSession() const {
        return qEnvironmentVariableIsSet("MP240_AUTOSTART");
    }

    Q_INVOKABLE void scan_for_modules();
    Q_INVOKABLE QVariant get_settings();
    Q_INVOKABLE QVariant get_setting(const QString &moduleId, const QString &key);
    Q_INVOKABLE void save_setting(const QString &moduleId, const QString &key, const QVariant &value);
    Q_INVOKABLE QVariant get_module_info(const QString &moduleId);
    Q_INVOKABLE QVariant get_module_settings_schema(const QString &moduleId);
    Q_INVOKABLE void invoke_module_action(const QString &moduleId, const QString &slotName);
    Q_INVOKABLE QVariant get_installed_modules();
    Q_INVOKABLE QVariantMap getCustomColorScheme() const;
    Q_INVOKABLE QVariantList listDirectories(const QString &path);
    Q_INVOKABLE QString parentDirectory(const QString &path);
    Q_INVOKABLE QString homePath();
    Q_INVOKABLE QString get_module_auth_state(const QString &moduleId);
    Q_INVOKABLE QVariantMap getUpdateInfo() const;
    Q_INVOKABLE void checkForUpdates();
    Q_INVOKABLE void installUpdate();
    Q_INVOKABLE QVariantMap getSshInfo() const;
    Q_INVOKABLE QVariantMap setSshEnabled(bool enabled);
    Q_INVOKABLE QVariantMap getBluetoothInfo() const;
    Q_INVOKABLE QVariantMap setBluetoothEnabled(bool enabled);
    Q_INVOKABLE QVariantMap scanBluetoothDevices();
    Q_INVOKABLE void scanBluetoothDevicesAsync();
    Q_INVOKABLE QVariantMap pairBluetoothDevice(const QString &address);
    Q_INVOKABLE void pairBluetoothDeviceAsync(const QString &address);
    Q_INVOKABLE QVariantMap connectBluetoothDevice(const QString &address);
    Q_INVOKABLE void connectBluetoothDeviceAsync(const QString &address);
    Q_INVOKABLE QVariantMap forgetBluetoothDevice(const QString &address);
    Q_INVOKABLE void forgetBluetoothDeviceAsync(const QString &address);
    Q_INVOKABLE QVariantMap getArgonFanInfo() const;
    Q_INVOKABLE QVariantMap setArgonFanMode(const QString &mode);
    Q_INVOKABLE void refreshTaterRecommendations();
    Q_INVOKABLE void sendTaterRecommendationFeedback(const QString &recommendationId,
                                                     const QString &feedback);
    Q_INVOKABLE void speakTaterRecommendation(const QString &recommendationId);
    Q_INVOKABLE void speakTaterBriefing(const QString &batchId);
    Q_INVOKABLE void stopTaterNarration();

    // Registers a module backend: stores it for action routing, exposes it to QML under
    // contextProperty, and connects its optional signals/slots by introspection (only
    // those the backend actually declares). The module ID is stated once, here.
    void registerModule(const QString &moduleId, const QString &contextProperty,
                        QObject *backend, QQmlContext *ctx);

signals:
    void modulesLoaded(const QVariantList &modules);
    void appSettingChanged(const QString &key, const QString &value);
    void moduleSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);
    void dynamicOptionsReady(const QString &moduleId, const QString &key, const QVariant &options);
    void moduleErrorOccurred(const QString &moduleId, const QString &message);
    void moduleAuthStateChanged(const QString &moduleId);
    void updateCheckFinished(const QVariantMap &result);
    void updateInstallFinished(const QVariantMap &result);
    void bluetoothScanFinished(const QVariantMap &result);
    void bluetoothActionFinished(const QString &action, const QVariantMap &result);
    void taterRecommendationsChanged();
    void taterNarratingChanged();

private slots:
    // Receive a backend's signal and re-emit it with the module ID prepended, recovering
    // the module ID via sender() reverse-lookup. Lets registerModule connect any backend
    // generically, with no per-module forwarding lambdas.
    void onBackendDynamicOptions(const QString &key, const QVariant &options);
    void onBackendErrorOccurred(const QString &message);
    void onBackendAuthStateChanged();

private:
    QJsonObject loadConfig() const;
    void saveConfig(const QJsonObject &config) const;
    QString moduleIdForBackend(QObject *backend) const;
    QString updateManifestUrl() const;
    bool canInstallUpdates() const;
    QString taterServerApiUrl(const QString &path) const;
    QString taterServerToken() const;
    bool taterPicksNarrationEnabled() const;
    void requestTaterNarration(const QJsonObject &identity);
    void pollTaterNarrationRequest();
    void playTaterNarrationAudio(const QString &requestId, quint64 generation);
    void cancelTaterNarrationRequest(const QString &requestId);
    void setTaterNarrating(bool narrating);

    QString m_appRoot;
    QString m_dataRoot;
    QList<ModuleEntry> m_modules;
    QMap<QString, QObject*> m_backends;
    QNetworkAccessManager *m_updateNetwork = nullptr;
    QTimer *m_taterRecommendationsTimer = nullptr;
    QTimer *m_taterNarrationPollTimer = nullptr;
    QProcess *m_taterNarrationProcess = nullptr;
    QVariantList m_taterRecommendations;
    QVariantMap m_taterRecommendationBatch;
    QString m_taterNarrationRequestId;
    quint64 m_taterNarrationGeneration = 0;
    int m_taterNarrationPollAttempts = 0;
    bool m_taterNarrating = false;
};
