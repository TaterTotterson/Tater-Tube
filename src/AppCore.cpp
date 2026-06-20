#include "AppCore.h"
#include <algorithm>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QUrl>
#include <QVariantMap>
#include <QDebug>
#include <QRegularExpression>
#include <QQmlContext>

namespace {
constexpr const char *kDefaultUpdateManifestUrl =
    "https://raw.githubusercontent.com/TaterTotterson/240-MP-Emby-Jelly/main/update-manifest.json";
constexpr const char *kPiUpdateHelper = "/usr/local/sbin/240mp-update";
constexpr const char *kSshControlHelper = "/usr/local/sbin/240mp-ssh-control";

int compareVersions(const QString &left, const QString &right)
{
    const QStringList leftParts = left.split(QRegularExpression("[^0-9]+"), Qt::SkipEmptyParts);
    const QStringList rightParts = right.split(QRegularExpression("[^0-9]+"), Qt::SkipEmptyParts);
    const int count = std::max(leftParts.size(), rightParts.size());

    for (int i = 0; i < count; ++i) {
        const int l = i < leftParts.size() ? leftParts[i].toInt() : 0;
        const int r = i < rightParts.size() ? rightParts[i].toInt() : 0;
        if (l < r) return -1;
        if (l > r) return 1;
    }

    return QString::compare(left, right, Qt::CaseInsensitive);
}

bool truthyValue(const QString &value)
{
    const QString normalized = value.trimmed().toLower();
    return normalized == "1" || normalized == "true" || normalized == "yes" ||
           normalized == "on";
}

QVariantMap parseSshControlOutput(const QString &output)
{
    QVariantMap result{
        {"available", false},
        {"enabled", false},
        {"active", false}
    };

    const QStringList lines = output.split('\n', Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        const int eq = line.indexOf('=');
        if (eq <= 0)
            continue;

        const QString key = line.left(eq).trimmed();
        const QString value = line.mid(eq + 1).trimmed();
        if (key == "available" || key == "enabled" || key == "active")
            result[key] = truthyValue(value);
    }

    return result;
}

QString sshControlMessage(const QVariantMap &info)
{
    if (!info.value("available").toBool())
        return QStringLiteral("SSH SERVICE IS NOT AVAILABLE.");
    if (info.value("enabled").toBool() && info.value("active").toBool())
        return QStringLiteral("SSH IS ON.");
    if (info.value("enabled").toBool())
        return QStringLiteral("SSH IS ENABLED BUT NOT RUNNING.");
    return QStringLiteral("SSH IS OFF.");
}

QVariantMap runSshControl(const QString &action)
{
    QVariantMap result{
        {"ok", false},
        {"available", false},
        {"enabled", false},
        {"active", false},
        {"message", "SSH CONTROL IS NOT AVAILABLE ON THIS SYSTEM."}
    };

#ifndef Q_OS_LINUX
    Q_UNUSED(action);
    return result;
#else
    const QFileInfo helperInfo(QString::fromUtf8(kSshControlHelper));
    if (!helperInfo.exists() || !helperInfo.isExecutable())
        return result;

    const QFileInfo sudoInfo("/usr/bin/sudo");
    const QString sudoPath = sudoInfo.exists() ? QStringLiteral("/usr/bin/sudo")
                                               : QStringLiteral("sudo");
    const QStringList args{
        QStringLiteral("-n"),
        QString::fromUtf8(kSshControlHelper),
        action
    };

    QProcess process;
    process.start(sudoPath, args);
    if (!process.waitForStarted(1000)) {
        result["message"] = "COULD NOT START SSH CONTROL HELPER.";
        return result;
    }

    if (!process.waitForFinished(10000)) {
        process.kill();
        process.waitForFinished(1000);
        result["message"] = "SSH CONTROL HELPER TIMED OUT.";
        return result;
    }

    const QString output = QString::fromUtf8(process.readAllStandardOutput());
    const QString errorOutput = QString::fromUtf8(process.readAllStandardError()).trimmed();
    const QVariantMap parsedStatus = parseSshControlOutput(output);
    for (auto it = parsedStatus.constBegin(); it != parsedStatus.constEnd(); ++it)
        result.insert(it.key(), it.value());

    const bool ok = process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
    result["ok"] = ok;
    result["message"] = ok ? sshControlMessage(result)
                           : (errorOutput.isEmpty()
                                  ? QStringLiteral("SSH CONTROL HELPER FAILED.")
                                  : errorOutput.toUpper());
    return result;
#endif
}
}

AppCore::AppCore(const QString &appRoot, const QString &dataRoot, QObject *parent)
    : QObject(parent), m_appRoot(appRoot), m_dataRoot(dataRoot)
{
    m_updateNetwork = new QNetworkAccessManager(this);

    QDir modulesDir(appRoot + "/modules");
    const QStringList dirs = modulesDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &folder : dirs) {
        QString manifestPath = modulesDir.absoluteFilePath(folder + "/manifest.json");
        QFile f(manifestPath);
        if (!f.open(QIODevice::ReadOnly)) continue;
        QJsonParseError err;
        QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
        if (err.error != QJsonParseError::NoError || !doc.isObject()) {
            qWarning("[AppCore] Bad manifest.json in %s: %s",
                     qPrintable(folder), qPrintable(err.errorString()));
            continue;
        }
        QJsonObject manifest = doc.object();
        QString id       = manifest["id"].toString();
        QString entryQml = manifest["entry_point_qml"].toString();
        if (id.isEmpty() || entryQml.isEmpty()) {
            qWarning("[AppCore] Skipping %s: manifest missing 'id' or 'entry_point_qml'",
                     qPrintable(folder));
            continue;
        }
        ModuleEntry m;
        m.id       = id;
        m.name     = manifest["name"].toString();
        m.folder   = folder;
        m.entryQml = entryQml;
        m.iconRel  = manifest["icon"].toString();
        m.settings = manifest["settings"].toArray().toVariantList();
        m_modules.append(m);
        qDebug("[AppCore] Loaded manifest: %s", qPrintable(id));
    }
}

// ---------------------------------------------------------------------------
// Config helpers
// ---------------------------------------------------------------------------

QJsonObject AppCore::loadConfig() const {
    QFile f(m_dataRoot + "/config.json");
    if (f.open(QIODevice::ReadOnly)) {
        QJsonParseError err;
        QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
        if (err.error == QJsonParseError::NoError && doc.isObject())
            return doc.object();
    }
    // Return a sensible default if the file is missing or corrupt
    return QJsonObject{
        {"app", QJsonObject{{"color_scheme","Off Air"}}},
        {"modules", QJsonObject{}}
    };
}

void AppCore::saveConfig(const QJsonObject &config) const {
    QFile f(m_dataRoot + "/config.json");
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning("[AppCore] Could not write config.json: %s", qPrintable(f.errorString()));
        return;
    }
    f.write(QJsonDocument(config).toJson(QJsonDocument::Indented));
}

// ---------------------------------------------------------------------------
// Q_INVOKABLE slots
// ---------------------------------------------------------------------------

void AppCore::scan_for_modules() {
    QJsonObject config = loadConfig();
    QJsonObject modulesConfig = config["modules"].toObject();

    QVariantList displayData;
    for (const auto &m : m_modules) {
        // Respect "enabled" setting; fall back to manifest default, then true
        QJsonObject mCfg = modulesConfig[m.id].toObject();
        bool manifestDefault = true;
        for (const auto &sv : m.settings) {
            QVariantMap s = sv.toMap();
            if (s["key"].toString() == "enabled") {
                manifestDefault = s["default"].toString().toUpper() != "OFF";
                break;
            }
        }
        bool enabled = mCfg.contains("enabled") ? mCfg["enabled"].toBool(true) : manifestDefault;
        if (!enabled) {
            qDebug("[AppCore] Module disabled: %s", qPrintable(m.name));
            continue;
        }
        // entry_point is a path relative to APP_ROOT
        QString entryPoint = QStringLiteral("modules/%1/%2").arg(m.folder, m.entryQml);
        QVariantMap entry;
        entry["name"]        = m.name;
        entry["entry_point"] = entryPoint;
        displayData.append(entry);
        qDebug("[AppCore] Module: %s -> %s", qPrintable(m.name), qPrintable(entryPoint));
    }
    emit modulesLoaded(displayData);
}

QVariant AppCore::get_settings() {
    return loadConfig().toVariantMap();
}

QVariant AppCore::get_setting(const QString &moduleId, const QString &key) {
    QJsonObject config = loadConfig();
    QJsonObject target;
    if (moduleId.isEmpty())
        target = config["app"].toObject();
    else
        target = config["modules"].toObject()[moduleId].toObject();
    return target[key].toVariant();
}

void AppCore::save_setting(const QString &moduleId, const QString &key, const QVariant &value) {
    QJsonObject config = loadConfig();

    // Navigate to the target section
    auto getTarget = [&]() -> QJsonObject {
        if (moduleId.isEmpty())
            return config["app"].toObject();
        return config["modules"].toObject()[moduleId].toObject();
    };
    auto setTarget = [&](const QJsonObject &target) {
        if (moduleId.isEmpty()) {
            config["app"] = target;
        } else {
            QJsonObject modules = config["modules"].toObject();
            modules[moduleId] = target;
            config["modules"] = modules;
        }
    };

    QJsonObject target = getTarget();

    // Handle dot-notation: "libraries.somekey" -> target["libraries"]["somekey"]
    QStringList parts = key.split('.', Qt::KeepEmptyParts);
    if (parts.size() == 2) {
        QJsonObject sub = target[parts[0]].toObject();
        sub[parts[1]] = QJsonValue::fromVariant(value);
        target[parts[0]] = sub;
    } else {
        target[key] = QJsonValue::fromVariant(value);
    }

    setTarget(target);
    saveConfig(config);

    qDebug("[AppCore] Setting saved: %s.%s = %s",
           qPrintable(moduleId.isEmpty() ? "app" : moduleId),
           qPrintable(key), qPrintable(value.toString()));

    if (moduleId.isEmpty())
        emit appSettingChanged(key, value.toString());
    else
        emit moduleSettingChanged(moduleId, key, value);
}

QVariant AppCore::get_module_info(const QString &moduleId) {
    for (const auto &m : m_modules) {
        if (m.id == moduleId) {
            QString iconPath = QStringLiteral("%1/modules/%2/%3")
                                   .arg(m_appRoot, m.folder, m.iconRel);
            QString iconUrl = QUrl::fromLocalFile(iconPath).toString();
            return QVariantMap{{"name", m.name}, {"icon", iconUrl}};
        }
    }
    return QVariantMap{};
}

QVariant AppCore::get_module_settings_schema(const QString &moduleId) {
    for (const auto &m : m_modules) {
        if (m.id == moduleId)
            return m.settings;
    }
    return QVariantList{};
}

void AppCore::invoke_module_action(const QString &moduleId, const QString &slotName) {
    auto it = m_backends.find(moduleId);
    if (it == m_backends.end()) {
        qWarning("[AppCore] invoke_module_action: no backend for '%s'", qPrintable(moduleId));
        return;
    }
    bool ok = QMetaObject::invokeMethod(it.value(), slotName.toLatin1().constData(),
                                        Qt::QueuedConnection);
    if (!ok)
        qWarning("[AppCore] invoke_module_action: slot '%s' not found on backend '%s'",
                 qPrintable(slotName), qPrintable(moduleId));
}

void AppCore::registerModule(const QString &moduleId, const QString &contextProperty,
                             QObject *backend, QQmlContext *ctx) {
    m_backends[moduleId] = backend;
    if (ctx)
        ctx->setContextProperty(contextProperty, backend);
    if (!backend) return;

    const QMetaObject *bmo = backend->metaObject();
    const QMetaObject *amo = this->metaObject();

    // dynamicOptionsReady(key, options) -> onBackendDynamicOptions (re-emit with moduleId)
    int sig = bmo->indexOfSignal(
        QMetaObject::normalizedSignature("dynamicOptionsReady(QString,QVariant)"));
    if (sig >= 0) {
        int slot = amo->indexOfSlot(
            QMetaObject::normalizedSignature("onBackendDynamicOptions(QString,QVariant)"));
        QMetaObject::connect(backend, sig, this, slot);
    }

    // authStateChanged() -> onBackendAuthStateChanged (re-emit with moduleId)
    sig = bmo->indexOfSignal(QMetaObject::normalizedSignature("authStateChanged()"));
    if (sig >= 0) {
        int slot = amo->indexOfSlot(
            QMetaObject::normalizedSignature("onBackendAuthStateChanged()"));
        QMetaObject::connect(backend, sig, this, slot);
    }

    // moduleSettingChanged(moduleId, key, value) -> backend.onSettingChanged(...)
    int slot = bmo->indexOfSlot(
        QMetaObject::normalizedSignature("onSettingChanged(QString,QString,QVariant)"));
    if (slot >= 0) {
        int s = amo->indexOfSignal(
            QMetaObject::normalizedSignature("moduleSettingChanged(QString,QString,QVariant)"));
        QMetaObject::connect(this, s, backend, slot);
    }
}

QString AppCore::moduleIdForBackend(QObject *backend) const {
    for (auto it = m_backends.constBegin(); it != m_backends.constEnd(); ++it) {
        if (it.value() == backend) return it.key();
    }
    return QString{};
}

void AppCore::onBackendDynamicOptions(const QString &key, const QVariant &options) {
    QString moduleId = moduleIdForBackend(sender());
    if (!moduleId.isEmpty())
        emit dynamicOptionsReady(moduleId, key, options);
}

void AppCore::onBackendAuthStateChanged() {
    QString moduleId = moduleIdForBackend(sender());
    if (!moduleId.isEmpty())
        emit moduleAuthStateChanged(moduleId);
}

QString AppCore::get_module_auth_state(const QString &moduleId) {
    auto it = m_backends.find(moduleId);
    if (it == m_backends.end()) return QString{};
    QString result;
    bool ok = QMetaObject::invokeMethod(
        it.value(), "get_auth_state",
        Qt::DirectConnection,
        Q_RETURN_ARG(QString, result)
    );
    if (!ok) return QString{};
    return result;
}

QString AppCore::updateManifestUrl() const {
    const QByteArray envUrl = qgetenv("MP240_UPDATE_MANIFEST_URL");
    if (!envUrl.isEmpty())
        return QString::fromUtf8(envUrl);
    return QString::fromUtf8(kDefaultUpdateManifestUrl);
}

bool AppCore::canInstallUpdates() const {
    if (!isAutostartSession() && qEnvironmentVariableIntValue("MP240_ALLOW_UPDATE_INSTALL") != 1)
        return false;

    const QFileInfo helperInfo(QString::fromUtf8(kPiUpdateHelper));
    return helperInfo.exists() && helperInfo.isExecutable();
}

QVariantMap AppCore::getUpdateInfo() const {
    return QVariantMap{
        {"currentVersion", appVersion()},
        {"manifestUrl", updateManifestUrl()},
        {"repo", "https://github.com/TaterTotterson/240-MP-Emby-Jelly"},
        {"canInstall", canInstallUpdates()}
    };
}

void AppCore::checkForUpdates() {
    QUrl url(updateManifestUrl());
    QVariantMap result = getUpdateInfo();

    if (!url.isValid() || url.scheme().isEmpty()) {
        result["ok"] = false;
        result["status"] = "error";
        result["message"] = "UPDATE MANIFEST URL IS INVALID.";
        emit updateCheckFinished(result);
        return;
    }

    QNetworkRequest request(url);
    request.setRawHeader("User-Agent", QByteArray("240-MP/") + appVersion().toUtf8());

    QNetworkReply *reply = m_updateNetwork->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        QVariantMap result = getUpdateInfo();
        result["ok"] = false;
        result["status"] = "error";

        const QVariant statusAttr = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute);
        const int httpStatus = statusAttr.isValid() ? statusAttr.toInt() : 0;
        if (reply->error() != QNetworkReply::NoError || httpStatus >= 400) {
            const QString detail = reply->errorString().isEmpty()
                ? QStringLiteral("HTTP %1").arg(httpStatus)
                : reply->errorString().toUpper();
            result["message"] = QStringLiteral("UPDATE CHECK FAILED: %1").arg(detail);
            reply->deleteLater();
            emit updateCheckFinished(result);
            return;
        }

        QJsonParseError parseError;
        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll(), &parseError);
        reply->deleteLater();

        if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
            result["message"] = "UPDATE MANIFEST IS NOT VALID JSON.";
            emit updateCheckFinished(result);
            return;
        }

        const QJsonObject manifest = doc.object();
        const QString latestVersion = manifest.value("version").toString();
        const QString sourceArchive = manifest.value("source_archive").toString();
        const QString binaryArchive = manifest.value("binary_archive").toString();
        const QString repo = manifest.value("repo").toString(result.value("repo").toString());

        result["latestVersion"] = latestVersion;
        result["sourceArchive"] = sourceArchive;
        result["binaryArchive"] = binaryArchive;
        result["repo"] = repo;

        if (latestVersion.isEmpty() || (sourceArchive.isEmpty() && binaryArchive.isEmpty())) {
            result["message"] = "UPDATE MANIFEST IS MISSING VERSION OR ARCHIVE.";
            emit updateCheckFinished(result);
            return;
        }

        result["ok"] = true;
        if (compareVersions(latestVersion, appVersion()) > 0) {
            result["status"] = "available";
            result["message"] = QStringLiteral("VERSION %1 IS READY.").arg(latestVersion);
        } else {
            result["status"] = "current";
            result["message"] = QStringLiteral("VERSION %1 IS CURRENT.").arg(appVersion());
        }

        emit updateCheckFinished(result);
    });
}

void AppCore::installUpdate() {
    QVariantMap result = getUpdateInfo();
    result["ok"] = false;
    result["status"] = "error";

    if (!canInstallUpdates()) {
        result["message"] = "UPDATES INSTALL FROM THE RASPBERRY PI IMAGE ONLY.";
        emit updateInstallFinished(result);
        return;
    }

    const QFileInfo sudoInfo("/usr/bin/sudo");
    const QString sudoPath = sudoInfo.exists() ? QStringLiteral("/usr/bin/sudo") : QStringLiteral("sudo");
    const QStringList args{QString::fromUtf8(kPiUpdateHelper), updateManifestUrl()};
    const bool started = QProcess::startDetached(sudoPath, args);

    result["ok"] = started;
    result["status"] = started ? "started" : "error";
    result["message"] = started
        ? "INSTALLING UPDATE. 240-MP WILL RESTART."
        : "COULD NOT START THE UPDATE HELPER.";
    emit updateInstallFinished(result);
}

QVariantMap AppCore::getSshInfo() const {
    return runSshControl(QStringLiteral("status"));
}

QVariantMap AppCore::setSshEnabled(bool enabled) {
    return runSshControl(enabled ? QStringLiteral("enable") : QStringLiteral("disable"));
}

QVariant AppCore::get_installed_modules() {
    QVariantList result;
    for (const auto &m : m_modules) {
        result.append(QVariantMap{
            {"id",           m.id},
            {"name",         m.name},
            {"has_settings", !m.settings.isEmpty()}
        });
    }
    return result;
}

QVariantMap AppCore::getCustomColorScheme() const {
    static const QStringList kRequiredKeys = {"primary","secondary","tertiary","surface","accent"};
    static const QRegularExpression kHexColor("^#[0-9A-Fa-f]{6}$");

    QFile f(m_dataRoot + "/custom_color_scheme.json");
    if (!f.exists()) return {};
    if (!f.open(QIODevice::ReadOnly)) return {};

    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning("[AppCore] custom_color_scheme.json: invalid JSON");
        return {};
    }

    QJsonObject obj = doc.object();
    QVariantMap result;
    for (const QString &key : kRequiredKeys) {
        if (!obj.contains(key) || !obj[key].isString()) {
            qWarning("[AppCore] custom_color_scheme.json: missing or non-string key '%s'", qPrintable(key));
            return {};
        }
        QString value = obj[key].toString();
        if (!kHexColor.match(value).hasMatch()) {
            qWarning("[AppCore] custom_color_scheme.json: invalid hex color for '%s': %s",
                     qPrintable(key), qPrintable(value));
            return {};
        }
        result[key] = value;
    }
    return result;
}

QVariantList AppCore::listDirectories(const QString &path) {
    QVariantList result;
    QDir dir(path);
    if (!dir.exists()) return result;
    const QStringList names = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden, QDir::Name);
    for (const QString &name : names) {
        QVariantMap item;
        item["name"] = name;
        item["path"] = dir.absoluteFilePath(name);
        result.append(item);
    }
    return result;
}

QString AppCore::parentDirectory(const QString &path) {
    QDir dir(path);
    if (!dir.cdUp()) return path;
    return dir.absolutePath();
}

QString AppCore::homePath() {
    return QDir::homePath();
}
