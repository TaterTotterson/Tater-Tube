#include "RetroBackend.h"
#include "GamePortCatalog.h"

#include <QByteArrayView>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QScreen>
#include <QStandardPaths>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QtConcurrent/QtConcurrent>
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
constexpr const char *kPortRomHashCacheFile = "port-rom-hashes.json";
constexpr int kGameCacheVersion = 5;
constexpr const char *kPortsSystemId = "ports";

QSize activeCompositeDisplayMode()
{
#ifdef Q_OS_LINUX
    const QString override = qEnvironmentVariable("TATER_TUBE_COMPOSITE_MODE").trimmed();
    if (!override.isEmpty()) {
        const QString commandLine = override.contains(QStringLiteral("video="))
            ? override
            : QStringLiteral("video=Composite-1:") + override;
        return GamePortCatalog::compositeDisplayMode(commandLine);
    }

    QFile commandLineFile(QStringLiteral("/proc/cmdline"));
    if (commandLineFile.open(QIODevice::ReadOnly)) {
        return GamePortCatalog::compositeDisplayMode(
            QString::fromLatin1(commandLineFile.readAll()));
    }
#endif
    return {};
}

QSize activeWideDisplayMode()
{
    QScreen *screen = QGuiApplication::primaryScreen();
    if (!screen)
        return {};

    const QSize size = screen->size();
    if (size.width() < 640 || size.height() < 480
        || size.width() * 2 <= size.height() * 3) {
        return {};
    }
    return size;
}

QString managedPortConfigName(const QString &portId)
{
    if (portId == QLatin1String("2ship2harkinian"))
        return QStringLiteral("2ship2harkinian.json");
    if (portId == QLatin1String("shipwright"))
        return QStringLiteral("shipofharkinian.json");
    if (portId == QLatin1String("spaghettikart"))
        return QStringLiteral("spaghettify.cfg.json");
    if (portId == QLatin1String("starship"))
        return QStringLiteral("starship.cfg.json");
    return {};
}

void prepareManagedPortConfig(const QString &portId,
                              const QString &userRoot,
                              const QSize &wideDisplayMode)
{
    const QString configName = managedPortConfigName(portId);
    if (configName.isEmpty())
        return;

    const QString configPath = QDir(userRoot).absoluteFilePath(configName);
    QJsonObject root;
    QFile input(configPath);
    if (input.exists()) {
        if (!input.open(QIODevice::ReadOnly))
            return;
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(input.readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject())
            return;
        root = document.object();
    }

    QJsonObject window = root.value(QStringLiteral("Window")).toObject();
    bool changed = false;
    const QString audioBackend =
        window.value(QStringLiteral("AudioBackend")).toString().trimmed().toLower();
    if (audioBackend.isEmpty() || audioBackend == QLatin1String("null")) {
        window.insert(QStringLiteral("AudioBackend"), QStringLiteral("sdl"));
        changed = true;
    }

    if (wideDisplayMode.isValid()) {
        QJsonObject fullscreen =
            window.value(QStringLiteral("Fullscreen")).toObject();
        if (!fullscreen.contains(QStringLiteral("Enabled"))) {
            fullscreen.insert(QStringLiteral("Enabled"), true);
            changed = true;
        }
        if (!fullscreen.contains(QStringLiteral("Width"))) {
            fullscreen.insert(QStringLiteral("Width"), wideDisplayMode.width());
            changed = true;
        }
        if (!fullscreen.contains(QStringLiteral("Height"))) {
            fullscreen.insert(QStringLiteral("Height"), wideDisplayMode.height());
            changed = true;
        }
        window.insert(QStringLiteral("Fullscreen"), fullscreen);
    }

    if (!changed)
        return;

    root.insert(QStringLiteral("Window"), window);
    QDir().mkpath(userRoot);
    QSaveFile output(configPath);
    if (!output.open(QIODevice::WriteOnly))
        return;
    output.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    if (output.commit()) {
        qInfo("[RetroBackend] updated managed port defaults: %s",
              qPrintable(configPath));
    }
}

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

QString gamePortVirtualPath(const QString &portId, const QString &romPath)
{
    QUrl url;
    url.setScheme(QStringLiteral("tater-port"));
    url.setHost(portId);
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("rom"), romPath);
    url.setQuery(query);
    return url.toString(QUrl::FullyEncoded);
}

bool parseGamePortVirtualPath(const QString &path, QString *portId, QString *romPath)
{
    const QUrl url(path);
    if (url.scheme() != QLatin1String("tater-port") || url.host().isEmpty())
        return false;
    if (portId)
        *portId = url.host();
    if (romPath)
        *romPath = QUrlQuery(url).queryItemValue(QStringLiteral("rom"), QUrl::FullyDecoded);
    return true;
}

QString escapeRetroValue(QString value)
{
    value.replace('\\', "\\\\");
    value.replace('"', "\\\"");
    return value;
}

QString connectedPiHdmiAudioCard()
{
#ifdef Q_OS_LINUX
    QDir drmDir(QStringLiteral("/sys/class/drm"));
    const QStringList connectors = drmDir.entryList(
        QStringList{QStringLiteral("card*-HDMI-A-*")},
        QDir::Dirs | QDir::NoDotAndDotDot,
        QDir::Name);
    for (const QString &connector : connectors) {
        QFile statusFile(drmDir.absoluteFilePath(connector + QStringLiteral("/status")));
        if (!statusFile.open(QIODevice::ReadOnly))
            continue;
        const QString status = QString::fromLatin1(statusFile.readAll()).trimmed();
        if (status != QStringLiteral("connected"))
            continue;

        QString card;
        if (connector.endsWith(QStringLiteral("HDMI-A-1")))
            card = QStringLiteral("vc4hdmi0");
        else if (connector.endsWith(QStringLiteral("HDMI-A-2")))
            card = QStringLiteral("vc4hdmi1");

        if (!card.isEmpty() && QFile::exists(QStringLiteral("/proc/asound/") + card))
            return card;
    }
#endif
    return QString();
}

QString connectedPiAudioDevice()
{
#ifdef Q_OS_LINUX
    // Composite output on the Pi uses the analogue Headphones device.
    if (QFile::exists(QStringLiteral("/sys/class/drm/card1-Composite-1"))
            && QFile::exists(QStringLiteral("/proc/asound/Headphones"))) {
        return QStringLiteral("sysdefault:CARD=Headphones");
    }

    const QString hdmiCard = connectedPiHdmiAudioCard();
    if (!hdmiCard.isEmpty())
        return QStringLiteral("sysdefault:CARD=%1").arg(hdmiCard);
#endif
    return {};
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

void writeRetroBinding(QTextStream &out, int player, const QString &retroKey,
                       const QVariantMap &binding)
{
    const QString type = binding.value(QStringLiteral("retroType")).toString();
    const QString value = binding.value(QStringLiteral("retroValue")).toString();
    if (player < 1 || retroKey.isEmpty() || value.isEmpty())
        return;

    const QString prefix = QStringLiteral("input_player%1_%2").arg(player).arg(retroKey);
    if (type == QStringLiteral("axis")) {
        out << prefix << "_axis = \"" << escapeRetroValue(value) << "\"\n";
        out << prefix << "_btn = \"nul\"\n";
    } else {
        out << prefix << "_axis = \"nul\"\n";
        out << prefix << "_btn = \"" << escapeRetroValue(value) << "\"\n";
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
    if (m_gameCacheWatcher) {
        m_gameCacheWatcher->cancel();
        m_gameCacheWatcher->waitForFinished();
        delete m_gameCacheWatcher;
        m_gameCacheWatcher = nullptr;
    }
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

QString RetroBackend::configuredPortsPath() const
{
    return setting(QStringLiteral("ports_path"));
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

QVariantList RetroBackend::localPortGames() const
{
    QVariantList result;
    QHash<QString, QByteArray> hashCache = loadPortRomHashCache();
    QHash<QString, QStringList> candidatesBySearch;
    if (hashCache.size() > 8192)
        hashCache.clear();
    QStringList manifestErrors;
    const QList<GamePortDefinition> ports = GamePortCatalog::load(m_appRoot, &manifestErrors);
    for (const QString &error : manifestErrors)
        qWarning("[game-port] %s", qPrintable(error));

    for (const GamePortDefinition &port : ports) {
        if (GamePortCatalog::executableNames(port).isEmpty())
            continue;

        const QString engine = GamePortCatalog::findEngine(
            port, m_appRoot, m_dataRoot, configuredPortsPath());

        QString romPath;
        for (const GamePortRomRequirement &requirement : port.romRequirements) {
            const QString staged = GamePortCatalog::stagedRomPath(
                m_dataRoot, port, requirement.fileName);
            if (GamePortCatalog::romMatches(port, staged, nullptr, &hashCache)) {
                romPath = staged;
                break;
            }
        }

        QStringList folders = port.romFolders;
        QStringList extensions = port.romExtensions;
        for (QString &folder : folders)
            folder = folder.toLower();
        for (QString &extension : extensions)
            extension = extension.toLower();
        folders.removeDuplicates();
        extensions.removeDuplicates();
        folders.sort(Qt::CaseInsensitive);
        extensions.sort(Qt::CaseInsensitive);
        const QString searchKey = folders.join(QLatin1Char('\n'))
            + QLatin1Char('\0') + extensions.join(QLatin1Char('\n'));
        auto candidateIt = candidatesBySearch.constFind(searchKey);
        if (candidateIt == candidatesBySearch.constEnd()) {
            candidateIt = candidatesBySearch.insert(
                searchKey, GamePortCatalog::findRomCandidates(port, gamesRoot()));
        }
        const QStringList candidates = candidateIt.value();
        if (romPath.isEmpty())
            romPath = GamePortCatalog::findMatchingRom(
                port, candidates, nullptr, &hashCache, engine);

        QString status;
        if (!engine.isEmpty() && !romPath.isEmpty())
            status = QStringLiteral("READY");
        else if (engine.isEmpty() && romPath.isEmpty())
            status = candidates.isEmpty()
                ? QStringLiteral("ENGINE + ROM NEEDED")
                : QStringLiteral("ENGINE + SUPPORTED ROM NEEDED");
        else if (engine.isEmpty())
            status = QStringLiteral("ENGINE NEEDED");
        else
            status = candidates.isEmpty()
                ? QStringLiteral("ROM NEEDED")
                : QStringLiteral("SUPPORTED ROM NEEDED");

        QVariantMap item;
        item[QStringLiteral("systemId")] = QString::fromUtf8(kPortsSystemId);
        item[QStringLiteral("title")] = port.title;
        item[QStringLiteral("path")] = gamePortVirtualPath(port.id, romPath);
        item[QStringLiteral("folder")] = QString();
        item[QStringLiteral("portId")] = port.id;
        item[QStringLiteral("romPath")] = romPath;
        item[QStringLiteral("enginePath")] = engine;
        item[QStringLiteral("status")] = status;
        item[QStringLiteral("ready")] = !engine.isEmpty() && !romPath.isEmpty();
        item[QStringLiteral("sourceUrl")] = port.sourceUrl;
        item[QStringLiteral("distribution")] = port.distribution;
        result.append(item);
    }
    savePortRomHashCache(hashCache);
    return result;
}

void RetroBackend::appendPortsToCache(QVariantList *systems,
                                      QVariantMap *gamesBySystem,
                                      const QVariantList &portGames) const
{
    if (!systems || !gamesBySystem || portGames.isEmpty())
        return;

    QVariantMap system;
    system[QStringLiteral("id")] = QString::fromUtf8(kPortsSystemId);
    system[QStringLiteral("label")] = QStringLiteral("Ports");
    system[QStringLiteral("path")] = QString();
    system[QStringLiteral("core")] = QString();
    system[QStringLiteral("corePackage")] = QString();
    system[QStringLiteral("gameCount")] = portGames.size();
    systems->append(system);
    gamesBySystem->insert(QString::fromUtf8(kPortsSystemId), portGames);
}

QString RetroBackend::gameCachePath() const
{
    return QDir(m_dataRoot).absoluteFilePath(QString::fromUtf8(kGameCacheFile));
}

QString RetroBackend::portRomHashCachePath() const
{
    return QDir(m_dataRoot).absoluteFilePath(
        QString::fromUtf8(kPortRomHashCacheFile));
}

QString RetroBackend::gameCacheRootKey() const
{
    const QFileInfo info(gamesRoot());
    const QString canonical = info.exists() ? info.canonicalFilePath() : QString();
    return canonical.isEmpty() ? info.absoluteFilePath() : canonical;
}

QString RetroBackend::gamePortManifestKey() const
{
    static constexpr char separator[] = "\0";
    const QString root = QDir(m_appRoot).absoluteFilePath(
        QStringLiteral("modules/retro/ports"));
    const QDir directory(root);
    const QStringList files = directory.entryList(
        {QStringLiteral("*.json")}, QDir::Files | QDir::Readable, QDir::Name);
    QCryptographicHash hash(QCryptographicHash::Sha256);
    for (const QString &name : files) {
        QFile file(directory.absoluteFilePath(name));
        if (!file.open(QIODevice::ReadOnly))
            continue;
        hash.addData(name.toUtf8());
        hash.addData(QByteArrayView(separator, 1));
        hash.addData(file.readAll());
        hash.addData(QByteArrayView(separator, 1));
    }
    return QString::fromLatin1(hash.result().toHex());
}

QHash<QString, QByteArray> RetroBackend::loadPortRomHashCache() const
{
    QHash<QString, QByteArray> result;
    QFile file(portRomHashCachePath());
    if (!file.open(QIODevice::ReadOnly))
        return result;

    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject())
        return result;
    const QJsonObject object = document.object();
    if (object.size() > 8192)
        return result;
    for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
        const QByteArray value = it.value().toString().toLatin1().toLower();
        if (!value.isEmpty())
            result.insert(it.key(), value);
    }
    return result;
}

bool RetroBackend::savePortRomHashCache(
    const QHash<QString, QByteArray> &cache) const
{
    if (cache.size() > 8192)
        return false;
    QJsonObject object;
    for (auto it = cache.constBegin(); it != cache.constEnd(); ++it)
        object.insert(it.key(), QString::fromLatin1(it.value()));

    QDir().mkpath(m_dataRoot);
    QSaveFile file(portRomHashCachePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;
    file.write(QJsonDocument(object).toJson(QJsonDocument::Compact));
    return file.commit();
}

bool RetroBackend::gameCacheIsCurrent(const QVariantMap &cache) const
{
    return cache.value(QStringLiteral("version")).toInt() == kGameCacheVersion
        && cache.value(QStringLiteral("gamesRoot")).toString() == gameCacheRootKey()
        && cache.value(QStringLiteral("portManifestKey")).toString()
            == gamePortManifestKey();
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
    cache[QStringLiteral("portManifestKey")] = gamePortManifestKey();

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

    appendPortsToCache(&systems, &gamesBySystem, localPortGames());

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

void RetroBackend::startGameCacheBuild()
{
    if (m_gameCacheWatcher)
        return;

    auto *watcher = new QFutureWatcher<QVariantMap>(this);
    m_gameCacheWatcher = watcher;
    connect(watcher, &QFutureWatcher<QVariantMap>::finished, this,
            [this, watcher]() {
        const QVariantMap cache = watcher->result();
        if (m_gameCacheWatcher == watcher)
            m_gameCacheWatcher = nullptr;
        watcher->deleteLater();
        emit authStateChanged();
        emit systemsLoaded(cache.value(QStringLiteral("systems")).toList());
    });
    watcher->setFuture(QtConcurrent::run([this]() {
        return buildGameCache();
    }));
}

QString RetroBackend::get_auth_state()
{
    if (QDir(gamesRoot()).exists())
        return QStringLiteral("authed");
    if (!setting(QStringLiteral("local_path")).isEmpty()
        || !setting(QStringLiteral("retronas_host")).isEmpty())
        return QStringLiteral("authed");
    return QStringLiteral("none");
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
    const QVariantMap existingCache = loadGameCache();
    const QVariantList portGames = existingCache.value(QStringLiteral("games"))
        .toMap().value(QString::fromUtf8(kPortsSystemId)).toList();
    bool portsAvailable = !portGames.isEmpty();
    bool portsReady = std::any_of(
        portGames.cbegin(), portGames.cend(), [](const QVariant &value) {
            return value.toMap().value(QStringLiteral("ready")).toBool();
        });
    if (!portsAvailable || !portsReady) {
        for (const GamePortDefinition &port : GamePortCatalog::load(m_appRoot)) {
            if (GamePortCatalog::executableNames(port).isEmpty())
                continue;
            const QString engine = GamePortCatalog::findEngine(
                port, m_appRoot, m_dataRoot, configuredPortsPath());
            if (engine.isEmpty())
                continue;
            portsAvailable = true;
            for (const GamePortRomRequirement &requirement : port.romRequirements) {
                if (QFileInfo::exists(GamePortCatalog::stagedRomPath(
                        m_dataRoot, port, requirement.fileName))) {
                    portsReady = true;
                    break;
                }
            }
            if (portsReady)
                break;
        }
    }
    status["portsAvailable"] = portsAvailable;
    status["portsReady"] = portsReady;
    status["portsPath"] = configuredPortsPath();
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
        clearGameCache();
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
        clearGameCache();
    emit authStateChanged();
    emit mountFinished(ok, ok
        ? QStringLiteral("RETRONAS READY")
        : (output.isEmpty() ? QStringLiteral("RETRO MOUNT FAILED") : output.toUpper()));
#endif
}

void RetroBackend::load_systems()
{
    const QVariantMap cache = loadGameCache();
    if (!cache.isEmpty()) {
        emit systemsLoaded(cache.value(QStringLiteral("systems")).toList());
        return;
    }
    startGameCacheBuild();
}

void RetroBackend::load_games(const QString &systemId)
{
    emit gamesLoaded(cachedGamesForSystem(systemId));
}

void RetroBackend::refresh_game_cache()
{
    clearGameCache();
    startGameCacheBuild();
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
    for (int player = 1; player <= 4; ++player) {
        out << "input_libretro_device_p" << player << " = \"1\"\n";
        out << "input_device_p" << player << " = \"1\"\n";
    }
    out << "menu_show_start_screen = \"false\"\n";
    out << "savestate_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("states")) << "\"\n";
    out << "savefile_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("saves")) << "\"\n";
    out << "system_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("system")) << "\"\n";
    out << "assets_directory = \"" << escapeRetroValue(QDir(retroRoot).absoluteFilePath("assets")) << "\"\n";

    const QVariantMap controllerMapping = loadControllerMapping(m_dataRoot);
    const QVariantMap bindings = controllerMapping.value(QStringLiteral("bindings")).toMap();
    if (!bindings.isEmpty()) {
        out << "input_joypad_driver = \"udev\"\n";

        for (int player = 1; player <= 4; ++player) {
            out << "input_player" << player << "_joypad_index = \"" << (player - 1) << "\"\n";

            const auto writeMapped = [&](const QString &retroKey, const QString &bindingKey) {
                writeRetroBinding(out, player, retroKey, bindings.value(bindingKey).toMap());
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
    }

    if (detectHeadlessMode()) {
        out << "audio_driver = \"alsa\"\n";
        const QString hdmiCard = connectedPiHdmiAudioCard();
        if (!hdmiCard.isEmpty())
            out << "audio_device = \"sysdefault:CARD=" << hdmiCard << "\"\n";
        else if (hasPiHeadphonesAudioDevice())
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
    if (systemId == QLatin1String(kPortsSystemId)) {
        QString portId;
        QString romPath;
        if (!parseGamePortVirtualPath(path, &portId, &romPath)) {
            emit errorOccurred(QStringLiteral("INVALID GAME PORT ENTRY"));
            return;
        }
        launch_port(portId, romPath);
        return;
    }

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
    m_processLogName = QStringLiteral("retroarch");
    m_processFailureMessage = QStringLiteral("RETROARCH PLAYBACK FAILED");
    qInfo("[RetroBackend] selected game: system=%s title=%s path=%s",
          qPrintable(systemId),
          qPrintable(m_currentTitle),
          qPrintable(gameInfo.canonicalFilePath()));
    m_process = new QProcess(this);
    m_process->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_process, &QProcess::readyRead, this, [this]() {
        const QByteArray out = m_process ? m_process->readAll() : QByteArray();
        if (!out.isEmpty())
            qWarning("[%s] %s", qPrintable(m_processLogName), out.trimmed().constData());
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

void RetroBackend::launch_port(const QString &portId, const QString &romPath)
{
    launchLocalPort(portId, romPath);
}

void RetroBackend::launchLocalPort(const QString &portId, const QString &romPath)
{
    GamePortDefinition port;
    bool found = false;
    for (const GamePortDefinition &candidate : GamePortCatalog::load(m_appRoot)) {
        if (candidate.id == portId) {
            port = candidate;
            found = true;
            break;
        }
    }
    if (!found || GamePortCatalog::executableNames(port).isEmpty()) {
        emit errorOccurred(QStringLiteral("THIS GAME PORT IS NOT AVAILABLE ON THIS SYSTEM"));
        return;
    }

    const QString engine = GamePortCatalog::findEngine(
        port, m_appRoot, m_dataRoot, configuredPortsPath());
    if (engine.isEmpty()) {
        emit errorOccurred(QStringLiteral("PORT ENGINE NOT INSTALLED. SET PORT ENGINES PATH IN GAME CENTER SETTINGS"));
        return;
    }
    if (romPath.trimmed().isEmpty()) {
        emit errorOccurred(QStringLiteral("SUPPORTED ORIGINAL ROM NOT FOUND. REFRESH THE GAME LIST AFTER ADDING IT"));
        return;
    }

    if (!QFileInfo(romPath).isFile()) {
        const bool configuredRetroNas = setting(QStringLiteral("local_path")).isEmpty()
            && !setting(QStringLiteral("retronas_host")).isEmpty();
        emit errorOccurred(configuredRetroNas && !QDir(gamesRoot()).exists()
                               ? QStringLiteral("RETRONAS IS NOT CONNECTED. REOPEN GAME CENTER TO RECONNECT")
                               : QStringLiteral("PORT ROM FILE NOT FOUND. REFRESH THE GAME LIST"));
        return;
    }

    const QString userRoot = GamePortCatalog::portUserRoot(m_dataRoot, port);
    const bool allowedRom = pathIsInside(romPath, gamesRoot())
        || pathIsInside(romPath, userRoot);
    if (!allowedRom) {
        emit errorOccurred(QStringLiteral("PORT ROM PATH IS OUTSIDE THE GAME LIBRARY"));
        return;
    }

    QString stagedRom;
    QString stageError;
    if (!GamePortCatalog::stageRom(
            port, romPath, m_dataRoot, &stagedRom, &stageError, engine)) {
        emit errorOccurred(stageError.isEmpty()
                               ? QStringLiteral("PORT ROM VALIDATION FAILED")
                               : stageError);
        return;
    }

    stop_game();

    QDir().mkpath(userRoot);
    m_currentTitle = port.title;
    m_processLogName = QStringLiteral("game-port");
    m_processFailureMessage = QStringLiteral("GAME PORT CLOSED WITH AN ERROR");
    m_process = new QProcess(this);
    m_process->setWorkingDirectory(QFileInfo(engine).absolutePath());
    m_process->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_process, &QProcess::readyRead, this, [this]() {
        const QByteArray out = m_process ? m_process->readAll() : QByteArray();
        if (!out.isEmpty())
            qWarning("[%s] %s", qPrintable(m_processLogName), out.trimmed().constData());
    });
    connect(m_process, &QProcess::started, this, [this]() {
        emit runningChanged(true);
        emit gameStarted(m_currentTitle);
    });
    connect(m_process,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &RetroBackend::onProcessFinished);

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("APP_ROOT"), m_appRoot);
    env.insert(QStringLiteral("XDG_CONFIG_HOME"), QDir(userRoot).absoluteFilePath("config"));
    env.insert(QStringLiteral("XDG_DATA_HOME"), QDir(userRoot).absoluteFilePath("data"));
    env.insert(QStringLiteral("XDG_CACHE_HOME"), QDir(userRoot).absoluteFilePath("cache"));
    env.insert(QStringLiteral("TATER_TUBE_PORT_ID"), port.id);
    env.insert(QStringLiteral("TATER_TUBE_PORT_ENGINE_DIR"), QFileInfo(engine).absolutePath());
    env.insert(QStringLiteral("TATER_TUBE_PORT_USER_ROOT"), userRoot);
    env.insert(QStringLiteral("TATER_TUBE_PORT_ROM"), stagedRom);
    env.remove(QStringLiteral("TATER_TUBE_CRT_WIDTH"));
    env.remove(QStringLiteral("TATER_TUBE_CRT_HEIGHT"));
#ifdef Q_OS_LINUX
    // SDL's default ALSA device can point at a disconnected Pi HDMI port.
    // Route only the native game-port child to the connector Tater Tube is
    // displaying on, without changing mpv or the app-wide audio environment.
    const QString piAudioDevice = connectedPiAudioDevice();
    if (!piAudioDevice.isEmpty()) {
        env.insert(QStringLiteral("SDL_AUDIODRIVER"), QStringLiteral("alsa"));
        env.insert(QStringLiteral("AUDIODEV"), piAudioDevice);
        env.insert(QStringLiteral("SDL_AUDIO_ALSA_DEFAULT_DEVICE"), piAudioDevice);
    }
#endif
#ifdef Q_OS_LINUX
    // Native ports must not inherit the app's private library stack. Keeping
    // only sibling port libraries avoids mixing incompatible dependency sets.
    env.insert(QStringLiteral("LD_LIBRARY_PATH"), QFileInfo(engine).absolutePath());
#endif

    const QSize compositeMode = activeCompositeDisplayMode();
    const QSize wideDisplayMode =
        compositeMode.isValid() ? QSize() : activeWideDisplayMode();
    prepareManagedPortConfig(port.id, userRoot, wideDisplayMode);
    if (compositeMode.isValid()) {
        env.insert(QStringLiteral("TATER_TUBE_CRT_WIDTH"),
                   QString::number(compositeMode.width()));
        env.insert(QStringLiteral("TATER_TUBE_CRT_HEIGHT"),
                   QString::number(compositeMode.height()));
        qInfo("[RetroBackend] applying composite port mode: %dx%d",
              compositeMode.width(), compositeMode.height());
    }

    m_headlessMode = detectHeadlessMode();
    if (m_headlessMode) {
        env.remove(QStringLiteral("DISPLAY"));
        env.remove(QStringLiteral("WAYLAND_DISPLAY"));
        prepareHeadlessLaunch();
    } else {
        env.remove(QStringLiteral("WAYLAND_DISPLAY"));
    }
    m_process->setProcessEnvironment(env);

    const QStringList args = GamePortCatalog::launchArguments(
        port, engine, stagedRom, userRoot, compositeMode);
    qInfo("[RetroBackend] launching game port %s: %s %s",
          qPrintable(port.id), qPrintable(engine), qPrintable(args.join(' ')));
    m_process->start(engine, args);
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
        || key == QLatin1String("ports_path")
        || key == QLatin1String("retronas_host")
        || key == QLatin1String("retronas_share")
        || key == QLatin1String("retronas_path")) {
        clearGameCache();
        emit authStateChanged();
    }
}

void RetroBackend::onProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    const QString logName = m_processLogName;
    const QString failureMessage = m_processFailureMessage;
    QProcess *finished = m_process;
    if (finished) {
        const QByteArray remaining = finished->readAll();
        if (!remaining.isEmpty())
            qWarning("[%s] %s", qPrintable(logName), remaining.trimmed().constData());
        finished->deleteLater();
        m_process = nullptr;
    }

    restoreHeadlessDisplay();
    emit runningChanged(false);
    emit gameFinished();

    if (exitStatus != QProcess::NormalExit || exitCode != 0) {
        qWarning("[RetroBackend] %s exited with code %d", qPrintable(logName), exitCode);
        emit errorOccurred(failureMessage);
    }

    m_processLogName = QStringLiteral("retroarch");
    m_processFailureMessage = QStringLiteral("RETROARCH PLAYBACK FAILED");
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
