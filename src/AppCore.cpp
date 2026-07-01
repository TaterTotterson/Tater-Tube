#include "AppCore.h"
#include <algorithm>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QJSValue>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QUrl>
#include <QVariantMap>
#include <QDebug>
#include <QRegularExpression>
#include <QQmlContext>
#include <QtConcurrent/QtConcurrent>

namespace {
constexpr const char *kDefaultUpdateManifestUrl =
    "https://raw.githubusercontent.com/TaterTotterson/Tater-Tube/main/update-manifest.json";
constexpr const char *kPiUpdateHelper = "/usr/local/sbin/240mp-update";
constexpr const char *kSshControlHelper = "/usr/local/sbin/240mp-ssh-control";
constexpr const char *kBluetoothControlHelper = "/usr/local/sbin/240mp-bluetooth-control";
constexpr const char *kArgonFanControlHelper = "/usr/local/sbin/240mp-argon-fan-control";

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

QVariant jsonFriendlyVariant(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QJSValue>())
        return jsonFriendlyVariant(value.value<QJSValue>().toVariant());

    if (value.metaType().id() == QMetaType::QVariantList) {
        QVariantList normalized;
        const QVariantList list = value.toList();
        normalized.reserve(list.size());
        for (const QVariant &item : list)
            normalized.append(jsonFriendlyVariant(item));
        return normalized;
    }

    if (value.metaType().id() == QMetaType::QVariantMap) {
        QVariantMap normalized;
        const QVariantMap map = value.toMap();
        for (auto it = map.constBegin(); it != map.constEnd(); ++it)
            normalized.insert(it.key(), jsonFriendlyVariant(it.value()));
        return normalized;
    }

    return value;
}

QJsonValue jsonValueFromVariant(const QVariant &value)
{
    return QJsonValue::fromVariant(jsonFriendlyVariant(value));
}

QString settingDebugValue(const QVariant &value)
{
    const QJsonValue jsonValue = jsonValueFromVariant(value);
    if (jsonValue.isArray())
        return QString::fromUtf8(QJsonDocument(jsonValue.toArray()).toJson(QJsonDocument::Compact));
    if (jsonValue.isObject())
        return QString::fromUtf8(QJsonDocument(jsonValue.toObject()).toJson(QJsonDocument::Compact));
    return jsonValue.toVariant().toString();
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

QVariantMap parseBluetoothControlOutput(const QString &output)
{
    QVariantMap result{
        {"available", false},
        {"enabled", false},
        {"active", false},
        {"powered", false},
        {"discovering", false}
    };
    QVariantList devices;

    const QStringList lines = output.split('\n', Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        if (line.startsWith(QStringLiteral("device\t"))) {
            const QStringList parts = line.split('\t');
            if (parts.size() < 7)
                continue;

            const bool bonded = truthyValue(parts.value(6));
            const bool paired = truthyValue(parts.value(3)) || bonded;
            const bool trusted = truthyValue(parts.value(4));
            const bool connected = truthyValue(parts.value(5));
            QString status = QStringLiteral("PAIR");
            if (connected)
                status = QStringLiteral("CONNECTED");
            else if (paired)
                status = QStringLiteral("CONNECT");
            else if (trusted)
                status = QStringLiteral("PAIR AGAIN");

            devices.append(QVariantMap{
                {"address", parts.value(1)},
                {"name", parts.value(2).isEmpty() ? parts.value(1) : parts.value(2)},
                {"paired", paired},
                {"bonded", bonded},
                {"trusted", trusted},
                {"connected", connected},
                {"status", status}
            });
            continue;
        }

        const int eq = line.indexOf('=');
        if (eq <= 0)
            continue;

        const QString key = line.left(eq).trimmed();
        const QString value = line.mid(eq + 1).trimmed();
        if (key == "available" || key == "enabled" || key == "active" ||
            key == "powered" || key == "discovering") {
            result[key] = truthyValue(value);
        } else if (key == "message") {
            result[key] = value;
        }
    }

    result["devices"] = devices;
    return result;
}

QString bluetoothControlMessage(const QVariantMap &info, const QString &action)
{
    if (!info.value("available").toBool())
        return QStringLiteral("BLUETOOTH IS NOT AVAILABLE.");

    if (action == QStringLiteral("scan")) {
        const int count = info.value("devices").toList().size();
        return count == 0
            ? QStringLiteral("NO CONTROLLERS FOUND.")
            : QStringLiteral("FOUND %1 CONTROLLER%2.").arg(count).arg(count == 1 ? QString() : QStringLiteral("S"));
    }

    if (action == QStringLiteral("pair-connect"))
        return QStringLiteral("CONTROLLER READY.");
    if (action == QStringLiteral("connect"))
        return QStringLiteral("CONTROLLER CONNECTED.");
    if (action == QStringLiteral("forget"))
        return QStringLiteral("CONTROLLER FORGOTTEN.");

    if (info.value("enabled").toBool() && info.value("active").toBool() &&
        info.value("powered").toBool()) {
        return QStringLiteral("BLUETOOTH IS ON.");
    }
    if (info.value("enabled").toBool() || info.value("active").toBool())
        return QStringLiteral("BLUETOOTH IS ENABLED.");
    return QStringLiteral("BLUETOOTH IS OFF.");
}

QVariantMap runBluetoothControl(const QStringList &helperArgs, int timeoutMs = 15000)
{
    const QString action = helperArgs.isEmpty() ? QStringLiteral("status") : helperArgs.first();
    QVariantMap result{
        {"ok", false},
        {"available", false},
        {"enabled", false},
        {"active", false},
        {"powered", false},
        {"discovering", false},
        {"devices", QVariantList{}},
        {"message", "BLUETOOTH CONTROL IS NOT AVAILABLE ON THIS SYSTEM."}
    };

#ifndef Q_OS_LINUX
    Q_UNUSED(helperArgs);
    Q_UNUSED(timeoutMs);
    return result;
#else
    const QFileInfo helperInfo(QString::fromUtf8(kBluetoothControlHelper));
    if (!helperInfo.exists() || !helperInfo.isExecutable())
        return result;

    const QFileInfo sudoInfo("/usr/bin/sudo");
    const QString sudoPath = sudoInfo.exists() ? QStringLiteral("/usr/bin/sudo")
                                               : QStringLiteral("sudo");
    QStringList args{
        QStringLiteral("-n"),
        QString::fromUtf8(kBluetoothControlHelper)
    };
    args.append(helperArgs);

    QProcess process;
    process.start(sudoPath, args);
    if (!process.waitForStarted(1000)) {
        result["message"] = "COULD NOT START BLUETOOTH CONTROL HELPER.";
        return result;
    }

    if (!process.waitForFinished(timeoutMs)) {
        process.kill();
        process.waitForFinished(1000);
        result["message"] = "BLUETOOTH CONTROL HELPER TIMED OUT.";
        return result;
    }

    const QString output = QString::fromUtf8(process.readAllStandardOutput());
    const QString errorOutput = QString::fromUtf8(process.readAllStandardError()).trimmed();
    const QVariantMap parsedStatus = parseBluetoothControlOutput(output);
    for (auto it = parsedStatus.constBegin(); it != parsedStatus.constEnd(); ++it)
        result.insert(it.key(), it.value());

    const bool ok = process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
    result["ok"] = ok;
    result["message"] = ok ? bluetoothControlMessage(result, action)
                           : (errorOutput.isEmpty()
                                  ? QStringLiteral("BLUETOOTH CONTROL HELPER FAILED.")
                                  : errorOutput.toUpper());
    return result;
#endif
}

int boundedFanSpeed(int speed)
{
    return std::clamp(speed, 0, 100);
}

QVariantMap parseArgonFanControlOutput(const QString &output)
{
    QVariantMap result{
        {"available", false},
        {"detected", false},
        {"active", false},
        {"mode", "auto"},
        {"speed", 0},
        {"fan", 0},
        {"temp", QVariant{}}
    };

    bool sawDetected = false;
    const QStringList lines = output.split('\n', Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        const int eq = line.indexOf('=');
        if (eq <= 0)
            continue;

        const QString key = line.left(eq).trimmed();
        const QString value = line.mid(eq + 1).trimmed();
        if (key == "available" || key == "active") {
            result[key] = truthyValue(value);
        } else if (key == "detected") {
            result[key] = truthyValue(value);
            sawDetected = true;
        } else if (key == "mode") {
            result[key] = value;
        } else if (key == "speed" || key == "fan") {
            result[key] = boundedFanSpeed(value.toInt());
        } else if (key == "temp") {
            bool ok = false;
            const double temp = value.toDouble(&ok);
            if (ok)
                result[key] = temp;
        } else if (key == "message") {
            result[key] = value;
        }
    }

    if (!sawDetected)
        result["detected"] = result.value("available").toBool();

    return result;
}

QString argonFanDisplayValue(const QVariantMap &info)
{
    if (!info.value("available").toBool())
        return QStringLiteral("N/A");

    const QString mode = info.value("mode", QStringLiteral("auto")).toString().toLower();
    if (mode == QStringLiteral("off"))
        return QStringLiteral("OFF");
    if (mode == QStringLiteral("fixed"))
        return QStringLiteral("%1%").arg(boundedFanSpeed(info.value("speed").toInt()));
    return QStringLiteral("AUTO");
}

QString normalizeArgonFanMode(const QString &raw)
{
    QString mode = raw.trimmed().toLower();
    mode.remove(QChar('%'));
    if (mode == QStringLiteral("automatic"))
        mode = QStringLiteral("auto");
    if (mode == QStringLiteral("0"))
        mode = QStringLiteral("off");
    if (mode == QStringLiteral("auto") || mode == QStringLiteral("off"))
        return mode;

    bool ok = false;
    const int speed = mode.toInt(&ok);
    if (ok)
        return QString::number(boundedFanSpeed(speed));

    return QStringLiteral("auto");
}

QString argonFanControlMessage(const QVariantMap &info)
{
    if (!info.value("available").toBool())
        return info.value("message", QStringLiteral("ARGON FAN CONTROL IS NOT AVAILABLE.")).toString();

    const QString display = argonFanDisplayValue(info);
    const QString hardwareMessage = info.value("message").toString().trimmed();
    if (!info.value("detected", true).toBool() && !hardwareMessage.isEmpty())
        return QStringLiteral("ARGON FAN %1. %2").arg(display, hardwareMessage);

    const double temp = info.value("temp").toDouble();
    if (info.contains("temp") && temp > 0.0)
        return QStringLiteral("ARGON FAN %1. CPU %2 C.").arg(display).arg(temp, 0, 'f', 1);
    return QStringLiteral("ARGON FAN %1.").arg(display);
}

QVariantMap runArgonFanControl(const QStringList &helperArgs)
{
    QVariantMap result{
        {"ok", false},
        {"available", false},
        {"detected", false},
        {"active", false},
        {"mode", "auto"},
        {"speed", 0},
        {"fan", 0},
        {"display", "N/A"},
        {"message", "ARGON FAN CONTROL IS NOT AVAILABLE ON THIS SYSTEM."}
    };

#ifndef Q_OS_LINUX
    Q_UNUSED(helperArgs);
    return result;
#else
    const QFileInfo helperInfo(QString::fromUtf8(kArgonFanControlHelper));
    if (!helperInfo.exists() || !helperInfo.isExecutable())
        return result;

    const QFileInfo sudoInfo("/usr/bin/sudo");
    const QString sudoPath = sudoInfo.exists() ? QStringLiteral("/usr/bin/sudo")
                                               : QStringLiteral("sudo");
    QStringList args{
        QStringLiteral("-n"),
        QString::fromUtf8(kArgonFanControlHelper)
    };
    args.append(helperArgs);

    QProcess process;
    process.start(sudoPath, args);
    if (!process.waitForStarted(1000)) {
        result["message"] = "COULD NOT START ARGON FAN HELPER.";
        return result;
    }

    if (!process.waitForFinished(10000)) {
        process.kill();
        process.waitForFinished(1000);
        result["message"] = "ARGON FAN HELPER TIMED OUT.";
        return result;
    }

    const QString output = QString::fromUtf8(process.readAllStandardOutput());
    const QString errorOutput = QString::fromUtf8(process.readAllStandardError()).trimmed();
    const QVariantMap parsedStatus = parseArgonFanControlOutput(output);
    for (auto it = parsedStatus.constBegin(); it != parsedStatus.constEnd(); ++it)
        result.insert(it.key(), it.value());

    const bool ok = process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
    const QString helperMessage = result.value("message").toString();
    const bool smbusMissing = helperMessage.contains(QStringLiteral("SMBUS"),
                                                     Qt::CaseInsensitive);
    if (ok)
        result["available"] = result.value("available").toBool() || !smbusMissing;

    result["ok"] = ok;
    result["display"] = argonFanDisplayValue(result);
    result["message"] = ok ? argonFanControlMessage(result)
                           : (errorOutput.isEmpty()
                                  ? QStringLiteral("ARGON FAN HELPER FAILED.")
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
        m.order    = manifest["order"].toInt(1000);
        m.settings = manifest["settings"].toArray().toVariantList();
        m_modules.append(m);
        qDebug("[AppCore] Loaded manifest: %s", qPrintable(id));
    }

    std::stable_sort(m_modules.begin(), m_modules.end(),
                     [](const ModuleEntry &left, const ModuleEntry &right) {
                         if (left.order != right.order)
                             return left.order < right.order;
                         return QString::compare(left.name, right.name, Qt::CaseInsensitive) < 0;
                     });
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
        {"app", QJsonObject{
            {"color_scheme", "Off Air"},
            {"off_air_highlight_color", "Orange"}
        }},
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
        sub[parts[1]] = jsonValueFromVariant(value);
        target[parts[0]] = sub;
    } else {
        target[key] = jsonValueFromVariant(value);
    }

    setTarget(target);
    saveConfig(config);

    qDebug("[AppCore] Setting saved: %s.%s = %s",
           qPrintable(moduleId.isEmpty() ? "app" : moduleId),
           qPrintable(key), qPrintable(settingDebugValue(value)));

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

    // errorOccurred(message) -> onBackendErrorOccurred (re-emit with moduleId)
    sig = bmo->indexOfSignal(QMetaObject::normalizedSignature("errorOccurred(QString)"));
    if (sig >= 0) {
        int slot = amo->indexOfSlot(
            QMetaObject::normalizedSignature("onBackendErrorOccurred(QString)"));
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

void AppCore::onBackendErrorOccurred(const QString &message) {
    QString moduleId = moduleIdForBackend(sender());
    if (!moduleId.isEmpty())
        emit moduleErrorOccurred(moduleId, message);
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
        {"repo", "https://github.com/TaterTotterson/Tater-Tube"},
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
    request.setRawHeader("User-Agent", QByteArray("Tater Tube/") + appVersion().toUtf8());

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
        const QString manifestVersion = manifest.value("version").toString();
        const QString latestVersion = manifest.value("app_version").toString(manifestVersion);
        const QString sourceArchive = manifest.value("source_archive").toString();
        const QString binaryArchive = manifest.value("binary_archive").toString();
        const QString repo = manifest.value("repo").toString(result.value("repo").toString());

        result["latestVersion"] = latestVersion;
        result["manifestVersion"] = manifestVersion;
        result["sourceArchive"] = sourceArchive;
        result["binaryArchive"] = binaryArchive;
        result["repo"] = repo;

        if (latestVersion.isEmpty() || manifestVersion.isEmpty() || (sourceArchive.isEmpty() && binaryArchive.isEmpty())) {
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
        ? "INSTALLING UPDATE. TATER TUBE WILL RESTART."
        : "COULD NOT START THE UPDATE HELPER.";
    emit updateInstallFinished(result);
}

QVariantMap AppCore::getSshInfo() const {
    return runSshControl(QStringLiteral("status"));
}

QVariantMap AppCore::setSshEnabled(bool enabled) {
    return runSshControl(enabled ? QStringLiteral("enable") : QStringLiteral("disable"));
}

QVariantMap AppCore::getBluetoothInfo() const {
    return runBluetoothControl({QStringLiteral("status")});
}

QVariantMap AppCore::setBluetoothEnabled(bool enabled) {
    return runBluetoothControl({enabled ? QStringLiteral("enable") : QStringLiteral("disable")});
}

QVariantMap AppCore::scanBluetoothDevices() {
    return runBluetoothControl({QStringLiteral("scan")}, 24000);
}

void AppCore::scanBluetoothDevicesAsync() {
    auto *watcher = new QFutureWatcher<QVariantMap>(this);
    connect(watcher, &QFutureWatcher<QVariantMap>::finished, this, [this, watcher]() {
        const QVariantMap result = watcher->result();
        watcher->deleteLater();
        emit bluetoothScanFinished(result);
    });
    watcher->setFuture(QtConcurrent::run([]() {
        return runBluetoothControl({QStringLiteral("scan")}, 24000);
    }));
}

QVariantMap AppCore::pairBluetoothDevice(const QString &address) {
    return runBluetoothControl({QStringLiteral("pair-connect"), address.trimmed()}, 95000);
}

void AppCore::pairBluetoothDeviceAsync(const QString &address) {
    const QString cleanAddress = address.trimmed();
    auto *watcher = new QFutureWatcher<QVariantMap>(this);
    connect(watcher, &QFutureWatcher<QVariantMap>::finished, this, [this, watcher]() {
        const QVariantMap result = watcher->result();
        watcher->deleteLater();
        emit bluetoothActionFinished(QStringLiteral("pair-connect"), result);
    });
    watcher->setFuture(QtConcurrent::run([cleanAddress]() {
        return runBluetoothControl({QStringLiteral("pair-connect"), cleanAddress}, 95000);
    }));
}

QVariantMap AppCore::connectBluetoothDevice(const QString &address) {
    return runBluetoothControl({QStringLiteral("connect"), address.trimmed()}, 30000);
}

void AppCore::connectBluetoothDeviceAsync(const QString &address) {
    const QString cleanAddress = address.trimmed();
    auto *watcher = new QFutureWatcher<QVariantMap>(this);
    connect(watcher, &QFutureWatcher<QVariantMap>::finished, this, [this, watcher]() {
        const QVariantMap result = watcher->result();
        watcher->deleteLater();
        emit bluetoothActionFinished(QStringLiteral("connect"), result);
    });
    watcher->setFuture(QtConcurrent::run([cleanAddress]() {
        return runBluetoothControl({QStringLiteral("connect"), cleanAddress}, 30000);
    }));
}

QVariantMap AppCore::forgetBluetoothDevice(const QString &address) {
    return runBluetoothControl({QStringLiteral("forget"), address.trimmed()}, 15000);
}

void AppCore::forgetBluetoothDeviceAsync(const QString &address) {
    const QString cleanAddress = address.trimmed();
    auto *watcher = new QFutureWatcher<QVariantMap>(this);
    connect(watcher, &QFutureWatcher<QVariantMap>::finished, this, [this, watcher]() {
        const QVariantMap result = watcher->result();
        watcher->deleteLater();
        emit bluetoothActionFinished(QStringLiteral("forget"), result);
    });
    watcher->setFuture(QtConcurrent::run([cleanAddress]() {
        return runBluetoothControl({QStringLiteral("forget"), cleanAddress}, 15000);
    }));
}

QVariantMap AppCore::getArgonFanInfo() const {
    return runArgonFanControl({QStringLiteral("status")});
}

QVariantMap AppCore::setArgonFanMode(const QString &mode) {
    return runArgonFanControl({QStringLiteral("set"), normalizeArgonFanMode(mode)});
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
