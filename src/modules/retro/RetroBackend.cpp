#include "RetroBackend.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
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
constexpr const char *kModuleId = "com.240mp.retro";
constexpr const char *kRetroMountHelper = "/usr/local/sbin/240mp-retro-mount";
constexpr const char *kRetroCoreHelper = "/usr/local/sbin/240mp-retro-core-control";
constexpr const char *kGameCacheFile = "game-cache.json";
constexpr int kGameCacheVersion = 2;

QString normalizedRemotePath(QString path)
{
    path = path.trimmed();
    while (path.startsWith('/'))
        path.remove(0, 1);
    while (path.endsWith('/'))
        path.chop(1);
    return path;
}

QString cleanGameTitle(const QString &fileName)
{
    QString title = QFileInfo(fileName).completeBaseName();
    title.replace('_', ' ');
    title.replace(QRegularExpression("\\s+"), " ");
    return title.trimmed();
}

QString escapeRetroValue(QString value)
{
    value.replace('\\', "\\\\");
    value.replace('"', "\\\"");
    return value;
}

QVariantMap loadControllerMapping(const QString &dataRoot)
{
    QFile file(QDir(dataRoot).absoluteFilePath(QStringLiteral("controller-map.json")));
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    return doc.object().toVariantMap();
}

void writeRetroBinding(QTextStream &out, const QString &retroKey, const QVariantMap &binding)
{
    const QString type = binding.value(QStringLiteral("retroType")).toString();
    const QString value = binding.value(QStringLiteral("retroValue")).toString();
    if (retroKey.isEmpty() || value.isEmpty())
        return;

    if (type == QStringLiteral("axis")) {
        out << "input_player1_" << retroKey << "_axis = \"" << escapeRetroValue(value) << "\"\n";
        out << "input_player1_" << retroKey << "_btn = \"nul\"\n";
    } else {
        out << "input_player1_" << retroKey << "_axis = \"nul\"\n";
        out << "input_player1_" << retroKey << "_btn = \"" << escapeRetroValue(value) << "\"\n";
    }
}

void writeRetroCommandBinding(QTextStream &out, const QString &commandKey,
                              const QVariantMap &binding)
{
    const QString type = binding.value(QStringLiteral("retroType")).toString();
    const QString value = binding.value(QStringLiteral("retroValue")).toString();
    if (commandKey.isEmpty() || value.isEmpty())
        return;

    if (type == QStringLiteral("axis")) {
        out << commandKey << "_axis = \"" << escapeRetroValue(value) << "\"\n";
    } else {
        out << commandKey << "_btn = \"" << escapeRetroValue(value) << "\"\n";
    }
}

bool pathIsInside(const QString &child, const QString &parent)
{
    const QString c = QFileInfo(child).canonicalFilePath();
    const QString p = QFileInfo(parent).canonicalFilePath();
    if (c.isEmpty() || p.isEmpty())
        return false;
    return c == p || c.startsWith(p + QDir::separator());
}

QStringList executableSearchPaths()
{
    QStringList paths = qEnvironmentVariable("PATH").split(':', Qt::SkipEmptyParts);
    const QStringList extra{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"};
    for (const QString &path : extra) {
        if (!paths.contains(path))
            paths.append(path);
    }
    return paths;
}
}

RetroBackend::RetroBackend(const QString &appRoot, const QString &dataRoot, QObject *parent)
    : QObject(parent)
    , m_appRoot(appRoot)
    , m_dataRoot(dataRoot)
{
    QDir().mkpath(m_dataRoot + "/retroarch");
    QDir().mkpath(mountPoint());
}

RetroBackend::~RetroBackend()
{
    stop_game();
    if (m_coreInstallProcess) {
        m_coreInstallProcess->disconnect(this);
        m_coreInstallProcess->deleteLater();
        m_coreInstallProcess = nullptr;
    }
}

bool RetroBackend::isRunning() const
{
    return m_process && m_process->state() != QProcess::NotRunning;
}

QVariantMap RetroBackend::moduleConfig() const
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

QString RetroBackend::setting(const QString &key, const QString &fallback) const
{
    const QVariantMap cfg = moduleConfig();
    const QString value = cfg.value(key).toString().trimmed();
    return value.isEmpty() ? fallback : value;
}

QString RetroBackend::mountPoint() const
{
    return QDir(m_dataRoot).absoluteFilePath("retronas");
}

QString RetroBackend::gamesRoot() const
{
    const QString localPath = setting(QStringLiteral("local_path"));
    if (!localPath.isEmpty())
        return localPath;

    const QString remotePath = normalizedRemotePath(setting(QStringLiteral("retronas_path"),
                                                           QStringLiteral("games")));
    if (remotePath.isEmpty())
        return mountPoint();
    return QDir(mountPoint()).absoluteFilePath(remotePath);
}

QString RetroBackend::retroarchPath() const
{
    return QStandardPaths::findExecutable(QStringLiteral("retroarch"), executableSearchPaths());
}

QVariantList RetroBackend::coreInstallStatusOptions() const
{
    QString label = m_coreInstallStatus;
    if (m_coreInstallProcess && m_coreInstallProcess->state() != QProcess::NotRunning) {
        label = QStringLiteral("INSTALLING...");
    } else if (label.isEmpty()) {
#ifdef Q_OS_LINUX
        const QFileInfo helperInfo(QString::fromUtf8(kRetroCoreHelper));
        label = helperInfo.exists() && helperInfo.isExecutable()
            ? QStringLiteral("READY")
            : QStringLiteral("N/A");
#else
        label = QStringLiteral("PI ONLY");
#endif
    }

    QString id = label.toLower();
    id.replace(QRegularExpression("[^a-z0-9]+"), QStringLiteral("-"));

    return QVariantList{
        QVariantMap{
            {QStringLiteral("id"), id},
            {QStringLiteral("label"), label}
        }
    };
}

void RetroBackend::emitCoreInstallStatus()
{
    emit dynamicOptionsReady(QStringLiteral("core_install_status"), coreInstallStatusOptions());
}

QString RetroBackend::credentialsFilePath() const
{
    return QDir(m_dataRoot).absoluteFilePath("retronas.credentials");
}

bool RetroBackend::writeCredentialsFile(const QString &username, const QString &password,
                                        QString *pathOut, QString *errorOut) const
{
    const QString user = username.trimmed();
    const QString path = credentialsFilePath();

    if (user.isEmpty()) {
        QFile::remove(path);
        if (pathOut)
            pathOut->clear();
        return true;
    }

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        if (errorOut)
            *errorOut = file.errorString();
        return false;
    }

    QTextStream out(&file);
    out << "username=" << user << "\n";
    out << "password=" << password << "\n";
    out.flush();

    if (!file.commit()) {
        if (errorOut)
            *errorOut = file.errorString();
        return false;
    }

    QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner);
    if (pathOut)
        *pathOut = path;
    return true;
}

QList<RetroBackend::SystemDef> RetroBackend::systemDefinitions() const
{
    return {
        {"atari2600", "Atari 2600",
         {"Atari2600", "Atari 2600", "A2600", "2600"},
         {"a26", "bin", "rom", "zip", "7z"},
         {"stella_libretro.so", "stella2014_libretro.so"},
         "stella"},
        {"atari5200", "Atari 5200",
         {"Atari5200", "Atari 5200", "A5200", "5200"},
         {"a52", "bin", "rom", "zip", "7z"},
         {"atari800_libretro.so"},
         "atari800"},
        {"atari7800", "Atari 7800",
         {"Atari7800", "Atari 7800", "A7800", "7800"},
         {"a78", "bin", "rom", "zip", "7z"},
         {"prosystem_libretro.so"},
         "prosystem"},
        {"lynx", "Atari Lynx",
         {"AtariLynx", "Atari Lynx", "Lynx"},
         {"lnx", "zip", "7z"},
         {"handy_libretro.so"},
         "handy"},
        {"coleco", "ColecoVision",
         {"ColecoVision", "Coleco", "CV"},
         {"col", "rom", "bin", "zip", "7z"},
         {"bluemsx_libretro.so", "gearcoleco_libretro.so"},
         "bluemsx"},
        {"intellivision", "Intellivision",
         {"Intellivision", "INTV"},
         {"int", "bin", "rom", "zip", "7z"},
         {"freeintv_libretro.so"},
         "freeintv"},
        {"odyssey2", "Odyssey2",
         {"Odyssey2", "Odyssey 2", "Videopac"},
         {"o2", "bin", "rom", "zip", "7z"},
         {"o2em_libretro.so"},
         "o2em"},
        {"vectrex", "Vectrex",
         {"Vectrex", "VEC"},
         {"vec", "bin", "rom", "zip", "7z"},
         {"vecx_libretro.so"},
         "vecx"},
        {"msx", "MSX",
         {"MSX", "MSX1", "MSX2"},
         {"rom", "mx1", "mx2", "dsk", "cas", "zip", "7z"},
         {"bluemsx_libretro.so", "fmsx_libretro.so"},
         "bluemsx"},
        {"nes", "NES",
         {"NES", "Famicom", "FC"},
         {"nes", "fds", "zip", "7z"},
         {"nestopia_libretro.so", "fceumm_libretro.so", "quicknes_libretro.so"},
         "nestopia"},
        {"sg1000", "SG-1000",
         {"SG1000", "SG-1000", "Sega SG-1000"},
         {"sg", "zip", "7z"},
         {"genesis_plus_gx_libretro.so", "gearsystem_libretro.so"},
         "genesis-plus-gx"},
        {"sms", "Master System",
         {"SMS", "Master System", "Sega Master System"},
         {"sms", "zip", "7z"},
         {"genesis_plus_gx_libretro.so", "gearsystem_libretro.so"},
         "genesis-plus-gx"},
        {"gamegear", "Game Gear",
         {"GameGear", "Game Gear", "GG"},
         {"gg", "zip", "7z"},
         {"genesis_plus_gx_libretro.so", "gearsystem_libretro.so"},
         "genesis-plus-gx"},
        {"genesis", "Genesis",
         {"Genesis", "MegaDrive", "Mega Drive", "MD"},
         {"md", "gen", "smd", "bin", "zip", "7z"},
         {"genesis_plus_gx_libretro.so", "picodrive_libretro.so"},
         "genesis-plus-gx"},
        {"segacd", "Sega CD",
         {"SegaCD", "Sega CD", "MegaCD", "Mega-CD"},
         {"cue", "chd", "iso", "bin", "zip", "7z"},
         {"genesis_plus_gx_libretro.so", "picodrive_libretro.so"},
         "genesis-plus-gx"},
        {"sega32x", "Sega 32X",
         {"32X", "Sega32X", "Sega 32X"},
         {"32x", "bin", "zip", "7z"},
         {"picodrive_libretro.so"},
         "picodrive"},
        {"gb", "Game Boy",
         {"Gameboy", "Game Boy", "GB"},
         {"gb", "zip", "7z"},
         {"gambatte_libretro.so"},
         "gambatte"},
        {"gbc", "Game Boy Color",
         {"Gameboy Color", "Game Boy Color", "GBC"},
         {"gbc", "zip", "7z"},
         {"gambatte_libretro.so"},
         "gambatte"},
        {"gba", "Game Boy Advance",
         {"GBA", "Game Boy Advance"},
         {"gba", "zip", "7z"},
         {"mgba_libretro.so"},
         "mgba"},
        {"pokemonmini", "Pokemon Mini",
         {"PokemonMini", "Pokemon Mini", "PokeMini"},
         {"min", "zip", "7z"},
         {"pokemini_libretro.so"},
         "pokemini"},
        {"snes", "SNES",
         {"SNES", "Super Nintendo", "SFC"},
         {"sfc", "smc", "bs", "fig", "zip", "7z"},
         {"snes9x_libretro.so", "bsnes_libretro.so", "bsnes_mercury_balanced_libretro.so"},
         "snes9x"},
        {"satellaview", "Satellaview",
         {"Satellaview", "BS-X", "BSX"},
         {"bs", "sfc", "smc", "zip", "7z"},
         {"snes9x_libretro.so", "bsnes_libretro.so", "bsnes_mercury_balanced_libretro.so"},
         "snes9x"},
        {"pce", "TurboGrafx-16",
         {"TGFX16", "TurboGrafx16", "TurboGrafx-16", "PC Engine", "PCEngine", "PCE"},
         {"pce", "sgx", "cue", "chd", "zip", "7z"},
         {"mednafen_pce_fast_libretro.so", "mednafen_supergrafx_libretro.so"},
         "beetle-pce-fast"},
        {"supergrafx", "SuperGrafx",
         {"SuperGrafx", "Super Grafx"},
         {"sgx", "pce", "zip", "7z"},
         {"mednafen_supergrafx_libretro.so", "mednafen_pce_fast_libretro.so"},
         "beetle-supergrafx"},
        {"virtualboy", "Virtual Boy",
         {"VirtualBoy", "Virtual Boy", "VB"},
         {"vb", "vboy", "bin", "zip", "7z"},
         {"mednafen_vb_libretro.so"},
         "beetle-vb"},
        {"wonderswan", "WonderSwan",
         {"WonderSwan", "Wonder Swan", "WS"},
         {"ws", "wsc", "zip", "7z"},
         {"mednafen_wswan_libretro.so"},
         "beetle-wswan"},
        {"ngp", "Neo Geo Pocket",
         {"NGP", "NGPC", "NeoGeo Pocket", "Neo Geo Pocket", "NeoGeo Pocket Color", "Neo Geo Pocket Color"},
         {"ngp", "ngc", "zip", "7z"},
         {"race_libretro.so", "mednafen_ngp_libretro.so"},
         "race"},
        {"neogeo", "Neo Geo",
         {"NeoGeo", "Neo Geo", "NEOGEO"},
         {"zip", "7z"},
         {"fbneo_libretro.so", "fbalpha2012_neogeo_libretro.so"},
         "fbneo"},
        {"fbneo", "Arcade FBNeo",
         {"FBNeo", "FBN", "FinalBurnNeo", "Final Burn Neo", "Arcade"},
         {"zip", "7z"},
         {"fbneo_libretro.so"},
         "fbneo"},
        {"mame2003", "Arcade MAME 2003",
         {"MAME2003", "MAME 2003", "MAME", "Arcade MAME"},
         {"zip", "7z"},
         {"mame2003_plus_libretro.so", "mame2003_libretro.so", "mame2000_libretro.so"},
         "mame2003-plus"},
        {"psx", "PlayStation",
         {"PSX", "PS1", "PlayStation", "Playstation"},
         {"cue", "chd", "pbp", "m3u"},
         {"pcsx_rearmed_libretro.so", "mednafen_psx_hw_libretro.so",
          "mednafen_psx_libretro.so", "beetle_psx_hw_libretro.so",
          "beetle_psx_libretro.so", "swanstation_libretro.so"},
         "pcsx-rearmed"},
        {"doom", "Doom",
         {"Doom", "DOOM", "PrBoom"},
         {"wad", "iwad", "zip", "7z"},
         {"prboom_libretro.so"},
         "prboom"},
        {"quake", "Quake",
         {"Quake", "TyrQuake"},
         {"pak", "zip", "7z"},
         {"tyrquake_libretro.so"},
         "tyrquake"}
    };
}

const RetroBackend::SystemDef *RetroBackend::systemById(const QString &systemId) const
{
    static const QList<SystemDef> defs = systemDefinitions();
    for (const SystemDef &def : defs) {
        if (def.id == systemId)
            return &def;
    }
    return nullptr;
}

QString RetroBackend::corePath(const SystemDef &def) const
{
    const QStringList roots{
        "/usr/lib/aarch64-linux-gnu/libretro",
        "/usr/lib/arm-linux-gnueabihf/libretro",
        "/usr/lib/x86_64-linux-gnu/libretro",
        "/usr/lib/libretro",
        "/usr/local/lib/libretro",
        "/opt/homebrew/lib/libretro"
    };

    for (const QString &root : roots) {
        for (const QString &name : def.coreNames) {
            const QString candidate = QDir(root).absoluteFilePath(name);
            if (QFileInfo::exists(candidate))
                return candidate;
        }
    }

    return QString();
}

QString RetroBackend::systemDirectory(const SystemDef &def) const
{
    const QDir rootDir(gamesRoot());
    for (const QString &folder : def.folders) {
        const QString candidate = rootDir.absoluteFilePath(folder);
        if (QFileInfo(candidate).isDir())
            return candidate;
    }
    return QString();
}

int RetroBackend::gameCount(const SystemDef &def, const QString &dirPath, int limit) const
{
    int count = 0;
    const QSet<QString> extensions(def.extensions.constBegin(), def.extensions.constEnd());
    QDirIterator it(dirPath, QDir::Files | QDir::NoSymLinks, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        const QFileInfo info = it.fileInfo();
        if (info.fileName().startsWith('.'))
            continue;
        if (extensions.contains(info.suffix().toLower())) {
            ++count;
            if (count >= limit)
                return count;
        }
    }
    return count;
}

QVariantList RetroBackend::availableSystems() const
{
    QVariantList result;
    if (!QDir(gamesRoot()).exists())
        return result;

    for (const SystemDef &def : systemDefinitions()) {
        const QString core = corePath(def);
        if (core.isEmpty())
            continue;

        const QString dir = systemDirectory(def);
        if (dir.isEmpty())
            continue;

        const int count = gameCount(def, dir);
        if (count == 0)
            continue;

        QVariantMap item;
        item["id"] = def.id;
        item["label"] = def.label;
        item["path"] = dir;
        item["core"] = core;
        item["corePackage"] = def.corePackage;
        item["gameCount"] = count;
        result.append(item);
    }

    return result;
}

QVariantList RetroBackend::gamesForSystem(const SystemDef &def) const
{
    QVariantList result;
    const QString dirPath = systemDirectory(def);
    if (dirPath.isEmpty())
        return result;

    const QSet<QString> extensions(def.extensions.constBegin(), def.extensions.constEnd());
    QList<QVariantMap> games;

    QDirIterator it(dirPath, QDir::Files | QDir::NoSymLinks, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        const QFileInfo info = it.fileInfo();
        if (info.fileName().startsWith('.'))
            continue;

        const QString suffix = info.suffix().toLower();
        if (!extensions.contains(suffix))
            continue;

        QVariantMap item;
        item["systemId"] = def.id;
        item["title"] = cleanGameTitle(info.fileName());
        item["path"] = info.absoluteFilePath();
        item["folder"] = QDir(dirPath).relativeFilePath(info.absolutePath());
        games.append(item);
    }

    std::sort(games.begin(), games.end(), [](const QVariantMap &left, const QVariantMap &right) {
        return QString::compare(left.value("title").toString(),
                                right.value("title").toString(),
                                Qt::CaseInsensitive) < 0;
    });

    for (const QVariantMap &game : games)
        result.append(game);
    return result;
}

QString RetroBackend::gameCachePath() const
{
    return QDir(m_dataRoot).absoluteFilePath(QString::fromUtf8(kGameCacheFile));
}

QString RetroBackend::gameCacheRootKey() const
{
    const QFileInfo info(gamesRoot());
    const QString canonical = info.exists() ? info.canonicalFilePath() : QString();
    return canonical.isEmpty() ? info.absoluteFilePath() : canonical;
}

bool RetroBackend::gameCacheIsCurrent(const QVariantMap &cache) const
{
    return cache.value(QStringLiteral("version")).toInt() == kGameCacheVersion
        && cache.value(QStringLiteral("gamesRoot")).toString() == gameCacheRootKey();
}

QVariantMap RetroBackend::loadGameCache() const
{
    QFile file(gameCachePath());
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    const QVariantMap cache = doc.object().toVariantMap();
    return gameCacheIsCurrent(cache) ? cache : QVariantMap{};
}

bool RetroBackend::saveGameCache(const QVariantMap &cache) const
{
    QDir().mkpath(m_dataRoot);
    QSaveFile file(gameCachePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[RetroBackend] could not write game cache: %s",
                 qPrintable(file.errorString()));
        return false;
    }

    file.write(QJsonDocument(QJsonObject::fromVariantMap(cache)).toJson(QJsonDocument::Indented));
    if (!file.commit()) {
        qWarning("[RetroBackend] could not save game cache: %s",
                 qPrintable(file.errorString()));
        return false;
    }
    return true;
}

QVariantMap RetroBackend::buildGameCache() const
{
    QVariantMap cache;
    cache[QStringLiteral("version")] = kGameCacheVersion;
    cache[QStringLiteral("createdAt")] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    cache[QStringLiteral("gamesRoot")] = gameCacheRootKey();

    QVariantList systems;
    QVariantMap gamesBySystem;

    if (QDir(gamesRoot()).exists()) {
        for (const SystemDef &def : systemDefinitions()) {
            const QString core = corePath(def);
            if (core.isEmpty())
                continue;

            const QString dir = systemDirectory(def);
            if (dir.isEmpty())
                continue;

            const QVariantList games = gamesForSystem(def);
            if (games.isEmpty())
                continue;

            QVariantMap item;
            item[QStringLiteral("id")] = def.id;
            item[QStringLiteral("label")] = def.label;
            item[QStringLiteral("path")] = dir;
            item[QStringLiteral("core")] = core;
            item[QStringLiteral("corePackage")] = def.corePackage;
            item[QStringLiteral("gameCount")] = games.size();
            systems.append(item);
            gamesBySystem.insert(def.id, games);
        }
    }

    cache[QStringLiteral("systems")] = systems;
    cache[QStringLiteral("games")] = gamesBySystem;
    saveGameCache(cache);
    qInfo("[RetroBackend] cached %d game system(s)", int(systems.size()));
    return cache;
}

QVariantMap RetroBackend::ensureGameCache() const
{
    const QVariantMap cache = loadGameCache();
    if (!cache.isEmpty())
        return cache;
    return buildGameCache();
}

QVariantList RetroBackend::cachedSystems() const
{
    return ensureGameCache().value(QStringLiteral("systems")).toList();
}

QVariantList RetroBackend::cachedGamesForSystem(const QString &systemId) const
{
    const QVariantMap gamesBySystem = ensureGameCache().value(QStringLiteral("games")).toMap();
    return gamesBySystem.value(systemId).toList();
}

void RetroBackend::clearGameCache() const
{
    QFile::remove(gameCachePath());
}

QString RetroBackend::get_auth_state()
{
    return QDir(gamesRoot()).exists() ? QStringLiteral("authed") : QStringLiteral("none");
}

QVariantMap RetroBackend::get_setup_status()
{
    QVariantMap status;
    status["host"] = setting(QStringLiteral("retronas_host"));
    status["share"] = setting(QStringLiteral("retronas_share"), QStringLiteral("mister"));
    status["remotePath"] = setting(QStringLiteral("retronas_path"), QStringLiteral("games"));
    status["username"] = setting(QStringLiteral("retronas_username"));
    status["localPath"] = setting(QStringLiteral("local_path"));
    status["mountPoint"] = mountPoint();
    status["gamesRoot"] = gamesRoot();
    status["gamesRootExists"] = QDir(gamesRoot()).exists();
    status["retroarchAvailable"] = !retroarchPath().isEmpty();
    status["running"] = isRunning();
    return status;
}

void RetroBackend::mount_retronas(const QString &host,
                                  const QString &share,
                                  const QString &remotePath,
                                  const QString &username,
                                  const QString &password)
{
    Q_UNUSED(remotePath)

    const QString cleanHost = host.trimmed();
    const QString cleanShare = share.trimmed().isEmpty() ? QStringLiteral("mister") : share.trimmed();
    if (cleanHost.isEmpty()) {
        emit mountFinished(false, QStringLiteral("ENTER RETRONAS ADDRESS"));
        return;
    }

    QString credPath;
    QString credError;
    if (!writeCredentialsFile(username, password, &credPath, &credError)) {
        emit mountFinished(false, QStringLiteral("COULD NOT SAVE RETRONAS LOGIN: %1").arg(credError));
        return;
    }

#ifndef Q_OS_LINUX
    const bool ready = QDir(gamesRoot()).exists();
    if (ready)
        buildGameCache();
    emit mountFinished(ready,
                       ready
                           ? QStringLiteral("LOCAL ROM PATH READY")
                           : QStringLiteral("RETRO MOUNT IS PI-ONLY"));
    emit authStateChanged();
    return;
#else
    const QFileInfo helperInfo(QString::fromUtf8(kRetroMountHelper));
    if (!helperInfo.exists() || !helperInfo.isExecutable()) {
        emit mountFinished(false, QStringLiteral("RETRO MOUNT HELPER IS NOT INSTALLED"));
        return;
    }

    QDir().mkpath(mountPoint());

    const QFileInfo sudoInfo("/usr/bin/sudo");
    const QString sudoPath = sudoInfo.exists() ? QStringLiteral("/usr/bin/sudo")
                                               : QStringLiteral("sudo");
    QStringList args{
        QStringLiteral("-n"),
        QString::fromUtf8(kRetroMountHelper),
        QStringLiteral("mount"),
        cleanHost,
        cleanShare,
        mountPoint(),
        credPath.isEmpty() ? QStringLiteral("-") : credPath
    };

    QProcess process;
    process.setProcessChannelMode(QProcess::MergedChannels);
    process.start(sudoPath, args);
    if (!process.waitForStarted(2000)) {
        emit mountFinished(false, QStringLiteral("COULD NOT START RETRO MOUNT HELPER"));
        return;
    }

    if (!process.waitForFinished(60000)) {
        process.kill();
        process.waitForFinished(1000);
        emit mountFinished(false, QStringLiteral("RETRO MOUNT TIMED OUT"));
        return;
    }

    const QString output = QString::fromUtf8(process.readAll()).trimmed();
    const bool ok = process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
    if (ok)
        buildGameCache();
    emit authStateChanged();
    emit mountFinished(ok, ok
        ? QStringLiteral("RETRONAS READY")
        : (output.isEmpty() ? QStringLiteral("RETRO MOUNT FAILED") : output.toUpper()));
#endif
}

void RetroBackend::load_systems()
{
    emit systemsLoaded(cachedSystems());
}

void RetroBackend::load_games(const QString &systemId)
{
    emit gamesLoaded(cachedGamesForSystem(systemId));
}

void RetroBackend::refresh_game_cache()
{
    const QVariantMap cache = buildGameCache();
    emit authStateChanged();
    emit systemsLoaded(cache.value(QStringLiteral("systems")).toList());
}

QVariantList RetroBackend::api_search_games(const QString &query, int limit)
{
    QVariantList result;
    const QString needle = query.trimmed();
    if (needle.isEmpty())
        return result;

    const int maxResults = std::max(1, std::min(limit <= 0 ? 10 : limit, 50));
    for (const QVariant &systemValue : cachedSystems()) {
        const QVariantMap system = systemValue.toMap();
        const QString systemId = system.value(QStringLiteral("id")).toString();
        const QString systemLabel = system.value(QStringLiteral("label")).toString();

        for (const QVariant &gameValue : cachedGamesForSystem(systemId)) {
            QVariantMap game = gameValue.toMap();
            const QString title = game.value(QStringLiteral("title")).toString();
            if (!title.contains(needle, Qt::CaseInsensitive))
                continue;

            const QString path = game.value(QStringLiteral("path")).toString();
            QVariantMap item;
            item[QStringLiteral("id")] = QStringLiteral("game:%1:%2").arg(
                systemId,
                QString::fromLatin1(QUrl::toPercentEncoding(path)));
            item[QStringLiteral("module")] = QStringLiteral("game_center");
            item[QStringLiteral("kind")] = QStringLiteral("game");
            item[QStringLiteral("title")] = title.toUpper();
            item[QStringLiteral("system_id")] = systemId;
            item[QStringLiteral("system")] = systemLabel;
            item[QStringLiteral("path")] = path;
            item[QStringLiteral("folder")] = game.value(QStringLiteral("folder")).toString();
            result.append(item);

            if (result.size() >= maxResults)
                return result;
        }
    }

    return result;
}

QString RetroBackend::writeRetroarchConfig()
{
    const QString retroRoot = QDir(m_dataRoot).absoluteFilePath("retroarch");
    QDir().mkpath(retroRoot);
    QDir().mkpath(QDir(retroRoot).absoluteFilePath("saves"));
    QDir().mkpath(QDir(retroRoot).absoluteFilePath("states"));
    QDir().mkpath(QDir(retroRoot).absoluteFilePath("system"));

    const QString cfgPath = QDir(retroRoot).absoluteFilePath("retroarch-240mp.cfg");
    QSaveFile file(cfgPath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[RetroBackend] could not write RetroArch config: %s",
                 qPrintable(file.errorString()));
        return QString();
    }

    QTextStream out(&file);
    out << "video_fullscreen = \"true\"\n";
    out << "pause_nonactive = \"false\"\n";
    out << "quit_press_twice = \"false\"\n";
    out << "input_exit_emulator = \"escape\"\n";
    out << "input_exit_emulator_axis = \"nul\"\n";
    out << "input_exit_emulator_btn = \"nul\"\n";
    out << "input_driver = \"udev\"\n";
    out << "input_autodetect_enable = \"false\"\n";
    out << "input_libretro_device_p1 = \"1\"\n";
    out << "input_device_p1 = \"1\"\n";
    out << "menu_show_start_screen = \"false\"\n";
    out << "savestate_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("states")) << "\"\n";
    out << "savefile_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("saves")) << "\"\n";
    out << "system_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("system")) << "\"\n";
    out << "assets_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("assets")) << "\"\n";

    const QVariantMap controllerMapping = loadControllerMapping(m_dataRoot);
    const QVariantMap bindings = controllerMapping.value(QStringLiteral("bindings")).toMap();
    if (!bindings.isEmpty()) {
        out << "input_joypad_driver = \"udev\"\n";
        out << "input_player1_joypad_index = \"0\"\n";

        const auto writeMapped = [&](const QString &retroKey, const QString &bindingKey) {
            writeRetroBinding(out, retroKey, bindings.value(bindingKey).toMap());
        };

        writeMapped(QStringLiteral("up"), QStringLiteral("up"));
        writeMapped(QStringLiteral("down"), QStringLiteral("down"));
        writeMapped(QStringLiteral("left"), QStringLiteral("left"));
        writeMapped(QStringLiteral("right"), QStringLiteral("right"));
        writeMapped(QStringLiteral("b"), QStringLiteral("a"));
        writeMapped(QStringLiteral("a"), QStringLiteral("b"));
        writeMapped(QStringLiteral("y"), QStringLiteral("x"));
        writeMapped(QStringLiteral("x"), QStringLiteral("y"));
        writeMapped(QStringLiteral("select"), QStringLiteral("select"));
        writeMapped(QStringLiteral("start"), QStringLiteral("start"));
        writeMapped(QStringLiteral("l"), QStringLiteral("l"));
        writeMapped(QStringLiteral("r"), QStringLiteral("r"));
        writeMapped(QStringLiteral("l2"), QStringLiteral("l2"));
        writeMapped(QStringLiteral("r2"), QStringLiteral("r2"));
        writeMapped(QStringLiteral("l3"), QStringLiteral("l3"));
        writeMapped(QStringLiteral("r3"), QStringLiteral("r3"));

    }

    if (detectHeadlessMode() && hasPiHeadphonesAudioDevice()) {
        out << "audio_driver = \"alsa\"\n";
        out << "audio_device = \"sysdefault:CARD=Headphones\"\n";
    }

    out.flush();
    if (!file.commit()) {
        qWarning("[RetroBackend] could not commit RetroArch config: %s",
                 qPrintable(file.errorString()));
        return QString();
    }
    return cfgPath;
}

void RetroBackend::launch_game(const QString &systemId, const QString &path)
{
    const SystemDef *def = systemById(systemId);
    if (!def) {
        emit errorOccurred(QStringLiteral("UNKNOWN RETRO SYSTEM"));
        return;
    }

    const QString bin = retroarchPath();
    if (bin.isEmpty()) {
        emit errorOccurred(QStringLiteral("RETROARCH IS NOT INSTALLED"));
        return;
    }

    const QString core = corePath(*def);
    if (core.isEmpty()) {
        emit errorOccurred(QStringLiteral("MISSING RETRO CORE: %1").arg(def->corePackage));
        return;
    }

    const QString sysDir = systemDirectory(*def);
    if (sysDir.isEmpty() || !pathIsInside(path, sysDir)) {
        emit errorOccurred(QStringLiteral("ROM PATH IS NOT IN THE SYSTEM FOLDER"));
        return;
    }

    const QFileInfo gameInfo(path);
    if (!gameInfo.exists() || !gameInfo.isFile()) {
        emit errorOccurred(QStringLiteral("ROM FILE NOT FOUND"));
        return;
    }

    stop_game();

    const QString cfgPath = writeRetroarchConfig();
    if (cfgPath.isEmpty()) {
        emit errorOccurred(QStringLiteral("COULD NOT WRITE RETROARCH CONFIG"));
        return;
    }

    m_currentTitle = cleanGameTitle(gameInfo.fileName());
    qInfo("[RetroBackend] selected game: system=%s title=%s path=%s",
          qPrintable(systemId),
          qPrintable(m_currentTitle),
          qPrintable(gameInfo.canonicalFilePath()));
    m_process = new QProcess(this);
    m_process->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_process, &QProcess::readyRead, this, [this]() {
        const QByteArray out = m_process ? m_process->readAll() : QByteArray();
        if (!out.isEmpty())
            qWarning("[retroarch] %s", out.trimmed().constData());
    });
    connect(m_process, &QProcess::started, this, [this]() {
        emit runningChanged(true);
        emit gameStarted(m_currentTitle);
    });
    connect(m_process,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &RetroBackend::onProcessFinished);

    QStringList args{
        QStringLiteral("--config"), cfgPath,
        QStringLiteral("--verbose"),
        QStringLiteral("-L"), core,
        gameInfo.canonicalFilePath()
    };

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("APP_ROOT"), m_appRoot);
    env.insert(QStringLiteral("XDG_CONFIG_HOME"), QDir(m_dataRoot).absoluteFilePath("retroarch/config"));
    env.insert(QStringLiteral("XDG_DATA_HOME"), QDir(m_dataRoot).absoluteFilePath("retroarch/data"));
    env.insert(QStringLiteral("XDG_CACHE_HOME"), QDir(m_dataRoot).absoluteFilePath("retroarch/cache"));

    m_headlessMode = detectHeadlessMode();
    if (m_headlessMode) {
        env.remove(QStringLiteral("DISPLAY"));
        env.remove(QStringLiteral("WAYLAND_DISPLAY"));
        prepareHeadlessLaunch();
    } else {
        env.remove(QStringLiteral("WAYLAND_DISPLAY"));
    }
    m_process->setProcessEnvironment(env);

    qInfo("[RetroBackend] launching RetroArch: %s %s",
          qPrintable(bin), qPrintable(args.join(' ')));
    m_process->start(bin, args);
}

void RetroBackend::stop_game()
{
    if (!m_process)
        return;

    if (m_process->state() != QProcess::NotRunning) {
        m_process->terminate();
        if (!m_process->waitForFinished(2500)) {
            m_process->kill();
            m_process->waitForFinished(1000);
        }
    }
}

void RetroBackend::get_retro_system_options()
{
    QVariantList options;
    for (const QVariant &item : cachedSystems()) {
        const QVariantMap system = item.toMap();
        QVariantMap option;
        option["id"] = system.value("id");
        option["label"] = system.value("label");
        options.append(option);
    }
    emit dynamicOptionsReady(QStringLiteral("systems"), options);
}

void RetroBackend::load_core_install_status_options()
{
    emitCoreInstallStatus();
}

void RetroBackend::install_game_cores()
{
#ifndef Q_OS_LINUX
    m_coreInstallStatus = QStringLiteral("PI ONLY");
    emitCoreInstallStatus();
    return;
#else
    if (m_coreInstallProcess && m_coreInstallProcess->state() != QProcess::NotRunning) {
        m_coreInstallStatus = QStringLiteral("INSTALLING...");
        emitCoreInstallStatus();
        return;
    }

    const QFileInfo helperInfo(QString::fromUtf8(kRetroCoreHelper));
    if (!helperInfo.exists() || !helperInfo.isExecutable()) {
        m_coreInstallStatus = QStringLiteral("HELPER N/A");
        emitCoreInstallStatus();
        return;
    }

    const QFileInfo sudoInfo(QStringLiteral("/usr/bin/sudo"));
    const QString sudoPath = sudoInfo.exists() ? QStringLiteral("/usr/bin/sudo")
                                               : QStringLiteral("sudo");

    if (m_coreInstallProcess) {
        m_coreInstallProcess->deleteLater();
        m_coreInstallProcess = nullptr;
    }

    m_coreInstallProcess = new QProcess(this);
    m_coreInstallProcess->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_coreInstallProcess,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &RetroBackend::onCoreInstallFinished);
    m_coreInstallProcess->start(sudoPath, {
        QStringLiteral("-n"),
        QString::fromUtf8(kRetroCoreHelper),
        QStringLiteral("install")
    });

    if (!m_coreInstallProcess->waitForStarted(2000)) {
        m_coreInstallStatus = QStringLiteral("START FAILED");
        m_coreInstallProcess->deleteLater();
        m_coreInstallProcess = nullptr;
        emitCoreInstallStatus();
        return;
    }

    m_coreInstallStatus = QStringLiteral("INSTALLING...");
    emitCoreInstallStatus();
#endif
}

void RetroBackend::onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value)
{
    Q_UNUSED(value)
    if (moduleId != QString::fromUtf8(kModuleId))
        return;
    if (key == QLatin1String("local_path")
        || key == QLatin1String("retronas_host")
        || key == QLatin1String("retronas_share")
        || key == QLatin1String("retronas_path")) {
        clearGameCache();
        emit authStateChanged();
    }
}

void RetroBackend::onProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    QProcess *finished = m_process;
    if (finished) {
        const QByteArray remaining = finished->readAll();
        if (!remaining.isEmpty())
            qWarning("[retroarch] %s", remaining.trimmed().constData());
        finished->deleteLater();
        m_process = nullptr;
    }

    restoreHeadlessDisplay();
    emit runningChanged(false);
    emit gameFinished();

    if (exitStatus != QProcess::NormalExit || exitCode != 0) {
        qWarning("[RetroBackend] RetroArch exited with code %d", exitCode);
        emit errorOccurred(QStringLiteral("RETROARCH PLAYBACK FAILED"));
    }
}

void RetroBackend::onCoreInstallFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    QProcess *finished = m_coreInstallProcess;
    if (finished) {
        const QByteArray remaining = finished->readAll();
        if (!remaining.isEmpty())
            qInfo("[retro-core] %s", remaining.trimmed().constData());
        finished->deleteLater();
        m_coreInstallProcess = nullptr;
    }

    const bool ok = exitStatus == QProcess::NormalExit && exitCode == 0;
    m_coreInstallStatus = ok ? QStringLiteral("DONE") : QStringLiteral("FAILED");
    if (ok) {
        clearGameCache();
        emit authStateChanged();
    }
    emitCoreInstallStatus();
}

bool RetroBackend::detectHeadlessMode() const
{
#ifdef Q_OS_LINUX
    return qEnvironmentVariableIsEmpty("DISPLAY") && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY");
#else
    return false;
#endif
}

bool RetroBackend::hasPiHeadphonesAudioDevice() const
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

int RetroBackend::getActiveVt() const
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

int RetroBackend::findFreeVt() const
{
#ifdef Q_OS_LINUX
    bool envOk = false;
    int configuredVt = qEnvironmentVariableIntValue("MP240_RETRO_VT", &envOk);
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

void RetroBackend::switchToVt(int vt)
{
#ifdef Q_OS_LINUX
    int fd = ::open("/dev/tty0", O_WRONLY);
    if (fd < 0) {
        qWarning("[RetroBackend] switchToVt %d: open /dev/tty0 failed: %s",
                 vt, strerror(errno));
        return;
    }
    if (::ioctl(fd, VT_ACTIVATE, vt) < 0)
        qWarning("[RetroBackend] VT_ACTIVATE %d failed: %s", vt, strerror(errno));
    if (::ioctl(fd, VT_WAITACTIVE, vt) < 0)
        qWarning("[RetroBackend] VT_WAITACTIVE %d failed: %s", vt, strerror(errno));
    ::close(fd);
#else
    Q_UNUSED(vt)
#endif
}

int RetroBackend::findQtDrmFd() const
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

void RetroBackend::prepareHeadlessLaunch()
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
        qWarning("[RetroBackend] could not find Qt DRM fd");
        return;
    }

    m_qtDrmMasterDropped = true;
    saveDrmCrtcState(m_qtDrmFd);
#endif
}

void RetroBackend::restoreHeadlessDisplay()
{
#ifdef Q_OS_LINUX
    if (m_qtDrmFd >= 0) {
        if (m_qtDrmMasterDropped && ::ioctl(m_qtDrmFd, DRM_IOCTL_SET_MASTER, 0) < 0)
            qWarning("[RetroBackend] drmSetMaster failed: %s", strerror(errno));
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
void RetroBackend::saveDrmCrtcState(int fd)
{
    m_savedDrm = {};
    drmModeResPtr res = drmModeGetResources(fd);
    if (!res) {
        qWarning("[RetroBackend] saveDrmCrtcState: drmModeGetResources failed");
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

void RetroBackend::restoreDrmCrtcState(int fd)
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
        qWarning("[RetroBackend] drmModeSetCrtc restore failed: %s", strerror(errno));

    m_savedDrm.valid = false;
}
#endif
