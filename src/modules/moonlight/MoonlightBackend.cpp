#include "MoonlightBackend.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTimer>
#include <algorithm>

#ifdef Q_OS_LINUX
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/vt.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#ifndef DRM_IOCTL_SET_MASTER
#define DRM_IOCTL_SET_MASTER   _IO('d', 0x1e)
#define DRM_IOCTL_DROP_MASTER  _IO('d', 0x1f)
#endif
#endif

namespace {
constexpr const char *kModuleId = "com.240mp.moonlight";
constexpr const char *kAppCacheFile = "moonlight-app-cache.json";
constexpr int kAppCacheVersion = 1;
constexpr const char *kMoonlightLaunchHelper = "/usr/local/sbin/240mp-moonlight-control";

QString stripAnsi(QString value)
{
    value.remove(QRegularExpression(QStringLiteral("\\x1B\\[[0-?]*[ -/]*[@-~]")));
    return value.trimmed();
}

QString cleanMoonlightAppLine(QString line)
{
    line = stripAnsi(line);
    line.remove(QRegularExpression(QStringLiteral("^\\s*\\d+\\s*[\\).:-]\\s*")));
    line.remove(QRegularExpression(QStringLiteral("^[-*]\\s+")));
    return line.trimmed();
}

bool isLikelyMoonlightStatusLine(const QString &line)
{
    const QString lower = line.toLower();
    return lower.isEmpty()
        || lower.startsWith(QStringLiteral("moonlight"))
        || lower.startsWith(QStringLiteral("usage:"))
        || lower.startsWith(QStringLiteral("searching"))
        || lower.startsWith(QStringLiteral("connect"))
        || lower.startsWith(QStringLiteral("connecting"))
        || lower.startsWith(QStringLiteral("requesting"))
        || lower.startsWith(QStringLiteral("found"))
        || lower.startsWith(QStringLiteral("make sure"))
        || lower.startsWith(QStringLiteral("please"))
        || lower.startsWith(QStringLiteral("error"))
        || lower.startsWith(QStringLiteral("warning"))
        || lower.contains(QStringLiteral("available games"))
        || lower.contains(QStringLiteral("applications:"))
        || lower.contains(QStringLiteral("games:"));
}

QString optionValue(QString value, const QString &fallback)
{
    value = value.trimmed();
    return value.isEmpty() ? fallback : value;
}
}

MoonlightBackend::MoonlightBackend(const QString &appRoot, const QString &dataRoot,
                                   QObject *parent)
    : QObject(parent)
    , m_appRoot(appRoot)
    , m_dataRoot(dataRoot)
{
    QDir().mkpath(moonlightRoot());
}

MoonlightBackend::~MoonlightBackend()
{
    cancel_pairing();
    stop_stream();
    if (m_listProcess && m_listProcess->state() != QProcess::NotRunning)
        m_listProcess->kill();
}

bool MoonlightBackend::isRunning() const
{
    return m_streamProcess && m_streamProcess->state() != QProcess::NotRunning;
}

QStringList MoonlightBackend::executableSearchPaths() const
{
    QStringList paths = qEnvironmentVariable("PATH").split(':', Qt::SkipEmptyParts);
    const QStringList extra{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"};
    for (const QString &path : extra) {
        if (!paths.contains(path))
            paths.append(path);
    }
    return paths;
}

QString MoonlightBackend::moonlightPath() const
{
    const QString bundled = bundledMoonlightPath();
    if (!bundled.isEmpty())
        return bundled;

    QString path = QStandardPaths::findExecutable(QStringLiteral("moonlight"), executableSearchPaths());
    if (!path.isEmpty())
        return path;
    return QStandardPaths::findExecutable(QStringLiteral("moonlight-embedded"), executableSearchPaths());
}

QString MoonlightBackend::bundledMoonlightPath() const
{
    const QString path = QDir(m_appRoot).absoluteFilePath(
        QStringLiteral("vendor/moonlight-sdl/bin/moonlight"));
    const QFileInfo info(path);
    if (!info.isExecutable())
        return QString();
#ifdef Q_OS_LINUX
    QProcess ldd;
    ldd.start(QStringLiteral("ldd"), QStringList{path});
    if (!ldd.waitForFinished(1500))
        return QString();
    const QString output = QString::fromUtf8(ldd.readAllStandardOutput())
        + QString::fromUtf8(ldd.readAllStandardError());
    if (output.contains(QStringLiteral("not found")))
        return QString();
#endif
    return path;
}

QString MoonlightBackend::moonlightLaunchHelperPath() const
{
#ifdef Q_OS_LINUX
    return QFileInfo(QString::fromUtf8(kMoonlightLaunchHelper)).isExecutable()
        ? QString::fromUtf8(kMoonlightLaunchHelper)
        : QString();
#else
    return QString();
#endif
}

bool MoonlightBackend::canUseMoonlightLaunchHelper() const
{
#ifdef Q_OS_LINUX
    return detectHeadlessMode()
        && !moonlightLaunchHelperPath().isEmpty()
        && !QStandardPaths::findExecutable(QStringLiteral("sudo"), executableSearchPaths()).isEmpty();
#else
    return false;
#endif
}

QString MoonlightBackend::moonlightRoot() const
{
    return QDir(m_dataRoot).absoluteFilePath(QStringLiteral("moonlight"));
}

QVariantMap MoonlightBackend::moduleConfig() const
{
    QFile file(m_dataRoot + "/config.json");
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    return doc.object()["modules"].toObject()[QString::fromUtf8(kModuleId)]
        .toObject().toVariantMap();
}

QString MoonlightBackend::setting(const QString &key, const QString &fallback) const
{
    const QVariantMap cfg = moduleConfig();
    const QString value = cfg.value(key).toString().trimmed();
    return value.isEmpty() ? fallback : value;
}

QString MoonlightBackend::host() const
{
    return setting(QStringLiteral("sunshine_host"));
}

QString MoonlightBackend::appCachePath() const
{
    return QDir(moonlightRoot()).absoluteFilePath(QString::fromUtf8(kAppCacheFile));
}

QVariantList MoonlightBackend::loadAppCache() const
{
    QFile file(appCachePath());
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    const QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("version")).toInt() != kAppCacheVersion)
        return {};
    if (obj.value(QStringLiteral("host")).toString() != host())
        return {};
    return obj.value(QStringLiteral("apps")).toArray().toVariantList();
}

bool MoonlightBackend::saveAppCache(const QVariantList &apps) const
{
    QDir().mkpath(moonlightRoot());
    QSaveFile file(appCachePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[MoonlightBackend] could not write app cache: %s",
                 qPrintable(file.errorString()));
        return false;
    }

    QJsonObject obj;
    obj[QStringLiteral("version")] = kAppCacheVersion;
    obj[QStringLiteral("host")] = host();
    obj[QStringLiteral("createdAt")] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    obj[QStringLiteral("apps")] = QJsonArray::fromVariantList(apps);
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
    if (!file.commit()) {
        qWarning("[MoonlightBackend] could not save app cache: %s",
                 qPrintable(file.errorString()));
        return false;
    }
    return true;
}

void MoonlightBackend::clearAppCache() const
{
    QFile::remove(appCachePath());
}

void MoonlightBackend::removeMoonlightPairingState() const
{
    clearAppCache();

    const QString root = QFileInfo(moonlightRoot()).absoluteFilePath();
    const QString dataRoot = QFileInfo(m_dataRoot).absoluteFilePath();
    if (root.isEmpty() || dataRoot.isEmpty())
        return;

    const QStringList paths{
        QDir(root).absoluteFilePath(QStringLiteral("config")),
        QDir(root).absoluteFilePath(QStringLiteral("data")),
        QDir(root).absoluteFilePath(QStringLiteral("cache")),
        QDir(dataRoot).absoluteFilePath(QStringLiteral(".config/moonlight")),
        QDir(dataRoot).absoluteFilePath(QStringLiteral(".cache/moonlight")),
        QDir(dataRoot).absoluteFilePath(QStringLiteral(".local/share/moonlight")),
        QDir(dataRoot).absoluteFilePath(QStringLiteral(".config/Moonlight Game Streaming Project")),
        QDir(dataRoot).absoluteFilePath(QStringLiteral(".cache/Moonlight Game Streaming Project")),
        QDir(dataRoot).absoluteFilePath(QStringLiteral(".local/share/Moonlight Game Streaming Project")),
    };

    for (const QString &path : paths) {
        QFileInfo info(path);
        if (!info.exists())
            continue;

        QString absolute = info.canonicalFilePath();
        if (absolute.isEmpty())
            absolute = info.absoluteFilePath();

        const bool insideMoonlightRoot = absolute == root
            || absolute.startsWith(root + QLatin1Char('/'));
        const bool insideDataRoot = absolute.startsWith(dataRoot + QLatin1Char('/'));
        if (!insideMoonlightRoot && !insideDataRoot) {
            qWarning("[MoonlightBackend] refusing to remove unexpected Moonlight state path: %s",
                     qPrintable(absolute));
            continue;
        }

        if (info.isDir()) {
            QDir dir(absolute);
            if (!dir.removeRecursively()) {
                qWarning("[MoonlightBackend] could not remove Moonlight state directory: %s",
                         qPrintable(absolute));
            }
        } else if (!QFile::remove(absolute)) {
            qWarning("[MoonlightBackend] could not remove Moonlight state file: %s",
                     qPrintable(absolute));
        }
    }

    QDir().mkpath(root);
}

QString MoonlightBackend::get_auth_state()
{
    return host().isEmpty() ? QStringLiteral("none") : QStringLiteral("authed");
}

QVariantMap MoonlightBackend::get_setup_status()
{
    QVariantMap status;
    status[QStringLiteral("host")] = host();
    status[QStringLiteral("moonlightAvailable")] = !moonlightPath().isEmpty();
    status[QStringLiteral("running")] = isRunning();
    status[QStringLiteral("appCount")] = loadAppCache().size();
    return status;
}

void MoonlightBackend::prepareMoonlightEnvironment(QProcess *process) const
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("HOME"), m_dataRoot);
    env.insert(QStringLiteral("XDG_CONFIG_HOME"), QDir(moonlightRoot()).absoluteFilePath("config"));
    env.insert(QStringLiteral("XDG_DATA_HOME"), QDir(moonlightRoot()).absoluteFilePath("data"));
    env.insert(QStringLiteral("XDG_CACHE_HOME"), QDir(moonlightRoot()).absoluteFilePath("cache"));
    env.insert(QStringLiteral("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD"), QStringLiteral("1"));
    process->setProcessEnvironment(env);
}

QString MoonlightBackend::processOutput(QProcess *process) const
{
    if (!process)
        return QString();
    return QString::fromUtf8(process->readAll()).trimmed();
}

QString MoonlightBackend::processErrorMessage(QProcess *process, const QString &fallback) const
{
    const QString output = processOutput(process);
    if (output.isEmpty())
        return fallback;
    return output.split('\n', Qt::SkipEmptyParts).last().trimmed().toUpper();
}

void MoonlightBackend::pair_host(const QString &hostValue)
{
    const QString cleanHost = hostValue.trimmed();
    if (cleanHost.isEmpty()) {
        emit pairFinished(false, QStringLiteral("ENTER SUNSHINE HOST"));
        return;
    }

    const QString bin = moonlightPath();
    if (bin.isEmpty()) {
        emit pairFinished(false, QStringLiteral("MOONLIGHT IS NOT INSTALLED"));
        return;
    }

    cancel_pairing();
    const int sessionId = ++m_pairSessionId;
    m_pairTimedOut = false;
    m_pairOutput.clear();
    m_pairProcess = new QProcess(this);
    m_pairProcess->setProcessChannelMode(QProcess::MergedChannels);
    prepareMoonlightEnvironment(m_pairProcess);

    emit pairStatusChanged(QStringLiteral("CONNECTING TO SUNSHINE"));

    connect(m_pairProcess, &QProcess::readyRead, this, [this]() {
        if (!m_pairProcess)
            return;
        const QString chunk = QString::fromUtf8(m_pairProcess->readAll());
        m_pairOutput.append(chunk);
        const QString lower = stripAnsi(chunk).toLower();
        if (lower.contains(QStringLiteral("connecting to")))
            emit pairStatusChanged(QStringLiteral("CONNECTING TO SUNSHINE"));
        if (lower.contains(QStringLiteral("enter the following pin"))
            || lower.contains(QStringLiteral("please enter"))) {
            emit pairStatusChanged(QStringLiteral("ENTER PIN IN SUNSHINE"));
        }
        const QRegularExpression pinRegex(QStringLiteral("\\b(\\d{4})\\b"));
        const QRegularExpressionMatch match = pinRegex.match(m_pairOutput);
        if (match.hasMatch()) {
            emit pairCodeReady(match.captured(1));
            emit pairStatusChanged(QStringLiteral("ENTER PIN IN SUNSHINE"));
        }
        if (lower.contains(QStringLiteral("successfully paired"))
            || lower.contains(QStringLiteral("succesfully paired"))) {
            emit pairStatusChanged(QStringLiteral("SUNSHINE PAIRED"));
        }
    });
    connect(m_pairProcess,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &MoonlightBackend::onPairProcessFinished);

    qInfo("[MoonlightBackend] pairing Moonlight host: %s", qPrintable(cleanHost));
    m_pairProcess->start(bin, {QStringLiteral("pair"), cleanHost});
    QTimer::singleShot(180000, this, [this, sessionId]() {
        if (sessionId != m_pairSessionId || !m_pairProcess)
            return;
        if (m_pairProcess->state() == QProcess::NotRunning)
            return;
        m_pairTimedOut = true;
        m_pairOutput.append(QStringLiteral("\nSUNSHINE PAIRING TIMED OUT\n"));
        emit pairStatusChanged(QStringLiteral("PAIRING TIMED OUT"));
        m_pairProcess->kill();
    });
}

void MoonlightBackend::repair_host(const QString &hostValue)
{
    forget_pairing();
    pair_host(hostValue);
}

void MoonlightBackend::forget_pairing()
{
    cancel_pairing();
    stop_stream();
    removeMoonlightPairingState();
    emit authStateChanged();
}

void MoonlightBackend::cancel_pairing()
{
    if (!m_pairProcess)
        return;
    ++m_pairSessionId;
    if (m_pairProcess->state() != QProcess::NotRunning) {
        m_pairProcess->terminate();
        if (!m_pairProcess->waitForFinished(1200))
            m_pairProcess->kill();
    }
}

void MoonlightBackend::onPairProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    QProcess *finished = m_pairProcess;
    if (finished) {
        m_pairOutput.append(QString::fromUtf8(finished->readAll()));
        finished->deleteLater();
        m_pairProcess = nullptr;
    }

    const bool ok = exitStatus == QProcess::NormalExit && exitCode == 0;
    if (ok) {
        m_pairTimedOut = false;
        clearAppCache();
        emit authStateChanged();
        emit pairFinished(true, QStringLiteral("SUNSHINE PAIRED"));
        return;
    }

    const QString output = m_pairOutput.trimmed();
    const QString message = m_pairTimedOut
        ? QStringLiteral("PAIRING TIMED OUT")
        : (output.isEmpty()
               ? QStringLiteral("SUNSHINE PAIRING FAILED")
               : output.split('\n', Qt::SkipEmptyParts).last().toUpper());
    m_pairTimedOut = false;
    emit pairFinished(false, message);
}

QVariantList MoonlightBackend::parseAppList(const QString &output) const
{
    QVariantList result;
    QSet<QString> seen;
    const QStringList lines = output.split('\n', Qt::SkipEmptyParts);
    for (const QString &rawLine : lines) {
        const QString name = cleanMoonlightAppLine(rawLine);
        if (isLikelyMoonlightStatusLine(name))
            continue;
        if (name.length() < 2 || seen.contains(name.toLower()))
            continue;

        QVariantMap app;
        app[QStringLiteral("name")] = name;
        app[QStringLiteral("title")] = name.toUpper();
        result.append(app);
        seen.insert(name.toLower());
    }

    std::sort(result.begin(), result.end(), [](const QVariant &left, const QVariant &right) {
        return QString::compare(left.toMap().value(QStringLiteral("title")).toString(),
                                right.toMap().value(QStringLiteral("title")).toString(),
                                Qt::CaseInsensitive) < 0;
    });
    return result;
}

void MoonlightBackend::load_apps()
{
    const QVariantList cached = loadAppCache();
    if (!cached.isEmpty()) {
        emit appsLoaded(cached);
        return;
    }
    startAppList(false);
}

void MoonlightBackend::refresh_app_cache()
{
    clearAppCache();
    startAppList(true);
}

void MoonlightBackend::startAppList(bool forceRefresh)
{
    Q_UNUSED(forceRefresh)
    const QString cleanHost = host();
    if (cleanHost.isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER SUNSHINE HOST"));
        return;
    }

    const QString bin = moonlightPath();
    if (bin.isEmpty()) {
        emit errorOccurred(QStringLiteral("MOONLIGHT IS NOT INSTALLED"));
        return;
    }

    if (m_listProcess && m_listProcess->state() != QProcess::NotRunning)
        m_listProcess->kill();

    m_listOutput.clear();
    m_listProcess = new QProcess(this);
    m_listProcess->setProcessChannelMode(QProcess::MergedChannels);
    prepareMoonlightEnvironment(m_listProcess);
    connect(m_listProcess, &QProcess::readyRead, this, [this]() {
        if (m_listProcess)
            m_listOutput.append(QString::fromUtf8(m_listProcess->readAll()));
    });
    connect(m_listProcess,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &MoonlightBackend::onListProcessFinished);

    qInfo("[MoonlightBackend] listing Moonlight apps from host: %s", qPrintable(cleanHost));
    m_listProcess->start(bin, {QStringLiteral("list"), cleanHost});
}

void MoonlightBackend::onListProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    QProcess *finished = m_listProcess;
    if (finished) {
        m_listOutput.append(QString::fromUtf8(finished->readAll()));
        finished->deleteLater();
        m_listProcess = nullptr;
    }

    const bool ok = exitStatus == QProcess::NormalExit && exitCode == 0;
    if (!ok) {
        const QString message = m_listOutput.trimmed().isEmpty()
            ? QStringLiteral("COULD NOT LOAD SUNSHINE APPS")
            : m_listOutput.trimmed().split('\n', Qt::SkipEmptyParts).last().toUpper();
        emit errorOccurred(message);
        return;
    }

    const QVariantList apps = parseAppList(m_listOutput);
    saveAppCache(apps);
    emit appsLoaded(apps);
}

QStringList MoonlightBackend::streamArguments(const QString &appName, bool forceSdl) const
{
    QString width = QStringLiteral("640");
    QString height = QStringLiteral("480");
    const QString resolution = setting(QStringLiteral("resolution"), QStringLiteral("640x480"));
    const QRegularExpressionMatch resolutionMatch =
        QRegularExpression(QStringLiteral("^(\\d{3,5})x(\\d{3,5})$")).match(resolution);
    if (resolutionMatch.hasMatch()) {
        width = resolutionMatch.captured(1);
        height = resolutionMatch.captured(2);
    }

    QString bitrate = setting(QStringLiteral("bitrate"), QStringLiteral("1000 Kbps"));
    bitrate.remove(QStringLiteral("Kbps"), Qt::CaseInsensitive);
    bitrate.remove(QStringLiteral(" "));
    if (bitrate.isEmpty())
        bitrate = QStringLiteral("1000");

    QStringList args{
        QStringLiteral("stream"),
        QStringLiteral("-width"), width,
        QStringLiteral("-height"), height,
        QStringLiteral("-fps"), optionValue(setting(QStringLiteral("fps")), QStringLiteral("15")),
        QStringLiteral("-bitrate"), bitrate,
        QStringLiteral("-codec"), setting(QStringLiteral("codec"), QStringLiteral("h264")).toLower(),
        QStringLiteral("-remote"), QStringLiteral("no"),
        QStringLiteral("-quitappafter"),
        QStringLiteral("-app"), appName
    };

    const QString renderer = setting(QStringLiteral("renderer"), QStringLiteral("Auto"));
    if (forceSdl)
        args << QStringLiteral("-platform") << QStringLiteral("sdl");
    else if (renderer == QStringLiteral("Pi"))
        args << QStringLiteral("-platform") << QStringLiteral("pi");
    else if (renderer == QStringLiteral("SDL"))
        args << QStringLiteral("-platform") << QStringLiteral("sdl");

    QString mappingFile = QDir(moonlightRoot()).absoluteFilePath(QStringLiteral("gamepad.map"));
    if (!QFileInfo(mappingFile).exists()) {
        const QString bundledMapping = QDir(m_appRoot).absoluteFilePath(
            QStringLiteral("vendor/moonlight-sdl/share/moonlight/gamecontrollerdb.txt"));
        if (QFileInfo(bundledMapping).exists())
            mappingFile = bundledMapping;
    }
    if (QFileInfo(mappingFile).exists())
        args << QStringLiteral("-mapping") << mappingFile;

    if (!forceSdl && detectHeadlessMode() && hasPiHeadphonesAudioDevice())
        args << QStringLiteral("-audio") << QStringLiteral("sysdefault:CARD=Headphones");

    args << host();
    return args;
}

void MoonlightBackend::launch_app(const QString &appName)
{
    const QString cleanApp = appName.trimmed();
    if (cleanApp.isEmpty()) {
        emit errorOccurred(QStringLiteral("SELECT A PC APP"));
        return;
    }

    const QString bin = moonlightPath();
    if (bin.isEmpty()) {
        emit errorOccurred(QStringLiteral("MOONLIGHT IS NOT INSTALLED"));
        return;
    }
    if (host().isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER SUNSHINE HOST"));
        return;
    }

    stop_stream();
    m_streamOutput.clear();
    m_currentTitle = cleanApp;
    m_streamProcess = new QProcess(this);
    m_streamProcess->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_streamProcess, &QProcess::readyRead, this, [this]() {
        if (!m_streamProcess)
            return;
        const QByteArray out = m_streamProcess->readAll();
        if (!out.isEmpty()) {
            m_streamOutput.append(QString::fromUtf8(out));
            qWarning("[moonlight] %s", out.trimmed().constData());
        }
    });
    connect(m_streamProcess, &QProcess::started, this, [this]() {
        emit runningChanged(true);
        emit streamStarted(m_currentTitle);
    });
    connect(m_streamProcess,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &MoonlightBackend::onStreamProcessFinished);

    m_headlessMode = detectHeadlessMode();

    const bool useLaunchHelper = canUseMoonlightLaunchHelper();
    if (useLaunchHelper) {
        const QString helper = moonlightLaunchHelperPath();
        QStringList args{QStringLiteral("-n"), helper, QStringLiteral("launch")};
        args << streamArguments(cleanApp, true);
        if (!bundledMoonlightPath().isEmpty())
            args << QStringLiteral("--moonlight-bin") << bundledMoonlightPath();

        qInfo("[MoonlightBackend] launching Moonlight through helper: sudo %s",
              qPrintable(args.join(' ')));
        m_streamProcess->start(QStringLiteral("sudo"), args);
    } else {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("HOME"), m_dataRoot);
        env.insert(QStringLiteral("XDG_CONFIG_HOME"), QDir(moonlightRoot()).absoluteFilePath("config"));
        env.insert(QStringLiteral("XDG_DATA_HOME"), QDir(moonlightRoot()).absoluteFilePath("data"));
        env.insert(QStringLiteral("XDG_CACHE_HOME"), QDir(moonlightRoot()).absoluteFilePath("cache"));
        env.insert(QStringLiteral("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD"), QStringLiteral("1"));

        if (m_headlessMode) {
            env.remove(QStringLiteral("DISPLAY"));
            env.remove(QStringLiteral("WAYLAND_DISPLAY"));
            prepareHeadlessLaunch();
        } else {
            env.remove(QStringLiteral("WAYLAND_DISPLAY"));
        }
        m_streamProcess->setProcessEnvironment(env);

        const QStringList args = streamArguments(cleanApp);
        qInfo("[MoonlightBackend] launching Moonlight: %s %s",
              qPrintable(bin), qPrintable(args.join(' ')));
        m_streamProcess->start(bin, args);
    }
}

void MoonlightBackend::stop_stream()
{
    if (!m_streamProcess)
        return;

    if (m_streamProcess->state() != QProcess::NotRunning) {
        m_streamProcess->terminate();
        if (!m_streamProcess->waitForFinished(2500)) {
            m_streamProcess->kill();
            m_streamProcess->waitForFinished(1000);
        }
    }
}

void MoonlightBackend::onStreamProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    QProcess *finished = m_streamProcess;
    if (finished) {
        const QByteArray remaining = finished->readAll();
        if (!remaining.isEmpty()) {
            m_streamOutput.append(QString::fromUtf8(remaining));
            qWarning("[moonlight] %s", remaining.trimmed().constData());
        }
        finished->deleteLater();
        m_streamProcess = nullptr;
    }

    restoreHeadlessDisplay();
    emit runningChanged(false);
    emit streamFinished();

    if (exitStatus != QProcess::NormalExit || exitCode != 0) {
        qWarning("[MoonlightBackend] Moonlight exited with code %d", exitCode);
        emit errorOccurred(QStringLiteral("PC LINK STREAM FAILED"));
    }
}

void MoonlightBackend::onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value)
{
    Q_UNUSED(value)
    if (moduleId != QString::fromUtf8(kModuleId))
        return;
    if (key == QLatin1String("sunshine_host")) {
        clearAppCache();
        emit authStateChanged();
    }
}

bool MoonlightBackend::detectHeadlessMode() const
{
#ifdef Q_OS_LINUX
    return qEnvironmentVariableIsEmpty("DISPLAY") && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY");
#else
    return false;
#endif
}

bool MoonlightBackend::hasPiHeadphonesAudioDevice() const
{
#ifdef Q_OS_LINUX
    QFile cards(QStringLiteral("/proc/asound/cards"));
    if (!cards.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;
    return QString::fromUtf8(cards.readAll()).contains(QStringLiteral("Headphones"),
                                                       Qt::CaseInsensitive);
#else
    return false;
#endif
}

int MoonlightBackend::getActiveVt() const
{
#ifdef Q_OS_LINUX
    QFile f("/sys/class/tty/tty0/active");
    if (!f.open(QIODevice::ReadOnly))
        return -1;
    const QString name = QString::fromLatin1(f.readAll()).trimmed();
    bool ok = false;
    const int n = name.mid(3).toInt(&ok);
    return ok ? n : -1;
#else
    return -1;
#endif
}

int MoonlightBackend::findFreeVt() const
{
#ifdef Q_OS_LINUX
    bool envOk = false;
    int configuredVt = qEnvironmentVariableIntValue("MP240_MOONLIGHT_VT", &envOk);
    if (!envOk)
        configuredVt = qEnvironmentVariableIntValue("MP240_MPV_VT", &envOk);
    const int preferredVt = envOk ? configuredVt : 12;
    const int activeVt = getActiveVt();
    if (preferredVt > 0 && preferredVt <= 63 && preferredVt != activeVt)
        return preferredVt;

    int fd = ::open("/dev/tty0", O_WRONLY);
    if (fd < 0)
        return 7;
    int n = -1;
    ::ioctl(fd, VT_OPENQRY, &n);
    ::close(fd);
    return (n > 0) ? n : 7;
#else
    return -1;
#endif
}

void MoonlightBackend::switchToVt(int vt)
{
#ifdef Q_OS_LINUX
    int fd = ::open("/dev/tty0", O_WRONLY);
    if (fd < 0) {
        qWarning("[MoonlightBackend] switchToVt %d: open /dev/tty0 failed: %s",
                 vt, strerror(errno));
        return;
    }
    if (::ioctl(fd, VT_ACTIVATE, vt) < 0)
        qWarning("[MoonlightBackend] VT_ACTIVATE %d failed: %s", vt, strerror(errno));
    if (::ioctl(fd, VT_WAITACTIVE, vt) < 0)
        qWarning("[MoonlightBackend] VT_WAITACTIVE %d failed: %s", vt, strerror(errno));
    ::close(fd);
#else
    Q_UNUSED(vt)
#endif
}

int MoonlightBackend::findQtDrmFd() const
{
#ifdef Q_OS_LINUX
    QDir fdDir("/proc/self/fd");
    const QStringList entries = fdDir.entryList(QDir::Files | QDir::System);
    for (const QString &entry : entries) {
        bool ok = false;
        const int fd = entry.toInt(&ok);
        if (!ok)
            continue;
        struct stat st {};
        if (::fstat(fd, &st) < 0)
            continue;
        if (!S_ISCHR(st.st_mode))
            continue;
        if (major(st.st_rdev) != 226)
            continue;
        if (minor(st.st_rdev) >= 64)
            continue;
        if (::ioctl(fd, DRM_IOCTL_DROP_MASTER, 0) == 0)
            return fd;
    }
    return -1;
#else
    return -1;
#endif
}

void MoonlightBackend::prepareHeadlessLaunch()
{
#ifdef Q_OS_LINUX
    if (m_previousVt > 0)
        return;

    m_previousVt = getActiveVt();
    m_qtDrmFd = -1;
    m_qtDrmMasterDropped = false;

    switchToVt(findFreeVt());
    m_qtDrmFd = findQtDrmFd();
    if (m_qtDrmFd < 0) {
        qWarning("[MoonlightBackend] could not find Qt DRM fd");
        return;
    }

    m_qtDrmMasterDropped = true;
    saveDrmCrtcState(m_qtDrmFd);
#endif
}

void MoonlightBackend::restoreHeadlessDisplay()
{
#ifdef Q_OS_LINUX
    if (m_qtDrmFd >= 0) {
        if (m_qtDrmMasterDropped && ::ioctl(m_qtDrmFd, DRM_IOCTL_SET_MASTER, 0) < 0)
            qWarning("[MoonlightBackend] drmSetMaster failed: %s", strerror(errno));
        restoreDrmCrtcState(m_qtDrmFd);
    }

    const int previous = m_previousVt;
    m_previousVt = -1;
    m_qtDrmFd = -1;
    m_qtDrmMasterDropped = false;
    if (previous > 0)
        switchToVt(previous);
#endif
}

#ifdef Q_OS_LINUX
void MoonlightBackend::saveDrmCrtcState(int fd)
{
    m_savedDrm = {};
    drmModeResPtr res = drmModeGetResources(fd);
    if (!res) {
        qWarning("[MoonlightBackend] saveDrmCrtcState: drmModeGetResources failed");
        return;
    }

    for (int i = 0; i < res->count_crtcs && !m_savedDrm.valid; ++i) {
        drmModeCrtcPtr crtc = drmModeGetCrtc(fd, res->crtcs[i]);
        if (!crtc)
            continue;

        if (crtc->mode_valid) {
            m_savedDrm.crtcId = crtc->crtc_id;
            m_savedDrm.fbId = crtc->buffer_id;
            m_savedDrm.x = crtc->x;
            m_savedDrm.y = crtc->y;
            m_savedDrm.mode = crtc->mode;

            for (int j = 0; j < res->count_connectors; ++j) {
                drmModeConnectorPtr conn = drmModeGetConnector(fd, res->connectors[j]);
                if (!conn)
                    continue;
                if (conn->encoder_id) {
                    drmModeEncoderPtr enc = drmModeGetEncoder(fd, conn->encoder_id);
                    if (enc) {
                        if (enc->crtc_id == m_savedDrm.crtcId) {
                            m_savedDrm.connectorId = conn->connector_id;
                            m_savedDrm.valid = true;
                        }
                        drmModeFreeEncoder(enc);
                    }
                }
                drmModeFreeConnector(conn);
                if (m_savedDrm.valid)
                    break;
            }
        }
        drmModeFreeCrtc(crtc);
    }
    drmModeFreeResources(res);
}

void MoonlightBackend::restoreDrmCrtcState(int fd)
{
    if (!m_savedDrm.valid)
        return;

    const int ret = drmModeSetCrtc(fd,
                                   m_savedDrm.crtcId,
                                   m_savedDrm.fbId,
                                   m_savedDrm.x,
                                   m_savedDrm.y,
                                   &m_savedDrm.connectorId,
                                   1,
                                   &m_savedDrm.mode);
    if (ret < 0)
        qWarning("[MoonlightBackend] drmModeSetCrtc restore failed: %s", strerror(errno));

    m_savedDrm.valid = false;
}
#endif
