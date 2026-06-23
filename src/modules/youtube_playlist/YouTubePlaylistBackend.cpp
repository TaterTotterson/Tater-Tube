#include "YouTubePlaylistBackend.h"

#include <QDateTime>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantMap>

namespace {
constexpr const char *kModuleId = "com.240mp.youtube_playlist";
constexpr const char *kLegacyPlaylistCacheFile = "public-access-cache.json";
constexpr int kPlaylistCacheVersion = 1;
constexpr int kPlaylistLimit = 250;

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

bool runningOnRaspberryPi3()
{
#ifdef Q_OS_LINUX
    QFile f(QStringLiteral("/proc/device-tree/model"));
    if (!f.open(QIODevice::ReadOnly))
        return false;
    const QString model = QString::fromLatin1(f.readAll()).remove(QChar('\0')).trimmed();
    return model.startsWith(QStringLiteral("Raspberry Pi 3"));
#else
    return false;
#endif
}

QString cleanTitle(QString title, const QString &fallback)
{
    title = title.trimmed();
    title.replace(QRegularExpression("\\s+"), " ");
    return title.isEmpty() ? fallback : title;
}

QString fallbackPlaylistTitle(const QString &input, int index)
{
    const QString cleaned = input.trimmed();
    if (!cleaned.isEmpty()) {
        QString tail = cleaned;
        const int slash = tail.lastIndexOf('/');
        if (slash >= 0)
            tail = tail.mid(slash + 1);
        const int eq = tail.lastIndexOf('=');
        if (eq >= 0)
            tail = tail.mid(eq + 1);
        tail.remove(QRegularExpression("[^A-Za-z0-9_-]"));
        if (!tail.isEmpty())
            return QStringLiteral("PLAYLIST %1").arg(tail.left(8).toUpper());
    }
    return QStringLiteral("PLAYLIST %1").arg(index + 1);
}

QString decodeJsonString(const QString &value)
{
    const QByteArray json = QByteArray("[\"") + value.toUtf8() + QByteArray("\"]");
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error == QJsonParseError::NoError && doc.isArray() && !doc.array().isEmpty())
        return doc.array().first().toString();
    return value;
}

QVariantList playlistItemsFromHtml(const QString &playlistUrl, int limit)
{
    QVariantList items;
    const QString curlPath = QStandardPaths::findExecutable(QStringLiteral("curl"),
                                                            executableSearchPaths());
    if (curlPath.isEmpty())
        return items;

    QProcess process;
    process.setProcessChannelMode(QProcess::SeparateChannels);
    process.start(curlPath, {
        QStringLiteral("-L"),
        QStringLiteral("-sS"),
        QStringLiteral("--compressed"),
        QStringLiteral("--max-time"),
        QStringLiteral("20"),
        playlistUrl
    });
    if (!process.waitForStarted(2000))
        return items;
    if (!process.waitForFinished(25000)) {
        process.kill();
        process.waitForFinished(1000);
        return items;
    }
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0)
        return items;

    const QString html = QString::fromUtf8(process.readAllStandardOutput());
    const QRegularExpression videoRe(QStringLiteral("\"videoId\"\\s*:\\s*\"([A-Za-z0-9_-]{11})\""));
    const QRegularExpression titleRe(QStringLiteral(
        "\"title\"\\s*:\\s*\\{\\s*(?:\"runs\"\\s*:\\s*\\[\\s*\\{\\s*\"text\"\\s*:\\s*\"([^\"]+)\"|\"simpleText\"\\s*:\\s*\"([^\"]+)\")"));

    QSet<QString> seen;
    QRegularExpressionMatchIterator it = videoRe.globalMatch(html);
    while (it.hasNext() && items.size() < limit) {
        const QRegularExpressionMatch match = it.next();
        const QString id = match.captured(1);
        if (seen.contains(id))
            continue;
        seen.insert(id);

        QString title;
        const QString segment = html.mid(match.capturedStart(), 3000);
        const QRegularExpressionMatch titleMatch = titleRe.match(segment);
        if (titleMatch.hasMatch())
            title = decodeJsonString(titleMatch.captured(1).isEmpty()
                ? titleMatch.captured(2)
                : titleMatch.captured(1));

        QVariantMap item;
        item[QStringLiteral("id")] = id;
        item[QStringLiteral("url")] = QStringLiteral("https://www.youtube.com/watch?v=%1").arg(id);
        item[QStringLiteral("title")] = cleanTitle(title, QStringLiteral("VIDEO %1").arg(items.size() + 1));
        item[QStringLiteral("index")] = items.size();
        items.append(item);
    }

    return items;
}
}

YouTubePlaylistBackend::YouTubePlaylistBackend(const QString &appRoot,
                                               const QString &dataRoot,
                                               QObject *parent)
    : QObject(parent)
    , m_appRoot(appRoot)
    , m_dataRoot(dataRoot)
{
}

QVariantMap YouTubePlaylistBackend::moduleConfig() const
{
    const QJsonObject config = loadConfig();
    return config.value(QStringLiteral("modules")).toObject()[QString::fromUtf8(kModuleId)]
        .toObject().toVariantMap();
}

QJsonObject YouTubePlaylistBackend::loadConfig() const
{
    QFile file(m_dataRoot + "/config.json");
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    return doc.object();
}

bool YouTubePlaylistBackend::saveConfig(const QJsonObject &config) const
{
    QDir().mkpath(m_dataRoot);
    QSaveFile file(m_dataRoot + "/config.json");
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[YouTubePlaylistBackend] could not write config: %s",
                 qPrintable(file.errorString()));
        return false;
    }

    file.write(QJsonDocument(config).toJson(QJsonDocument::Indented));
    if (!file.commit()) {
        qWarning("[YouTubePlaylistBackend] could not save config: %s",
                 qPrintable(file.errorString()));
        return false;
    }
    return true;
}

QString YouTubePlaylistBackend::setting(const QString &key, const QString &fallback) const
{
    const QVariantMap cfg = moduleConfig();
    const QString value = cfg.value(key).toString().trimmed();
    return value.isEmpty() ? fallback : value;
}

QString YouTubePlaylistBackend::ytDlpPath() const
{
    QString path = QStandardPaths::findExecutable(QStringLiteral("yt-dlp"), executableSearchPaths());
    if (!path.isEmpty())
        return path;
    return QStandardPaths::findExecutable(QStringLiteral("youtube-dl"), executableSearchPaths());
}

QString YouTubePlaylistBackend::playlistCachePath(const QString &playlistUrl) const
{
    const QByteArray hash = QCryptographicHash::hash(playlistUrl.toUtf8(), QCryptographicHash::Sha1).toHex();
    return QDir(m_dataRoot).absoluteFilePath(QStringLiteral("public-access-cache-%1.json")
                                             .arg(QString::fromLatin1(hash)));
}

QVariantMap YouTubePlaylistBackend::loadPlaylistCache(const QString &playlistUrl) const
{
    QFile file(playlistCachePath(playlistUrl));
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};

    const QVariantMap cache = doc.object().toVariantMap();
    if (cache.value(QStringLiteral("version")).toInt() != kPlaylistCacheVersion)
        return {};
    if (cache.value(QStringLiteral("playlistUrl")).toString() != playlistUrl)
        return {};
    if (cache.value(QStringLiteral("items")).toList().isEmpty())
        return {};
    return cache;
}

bool YouTubePlaylistBackend::savePlaylistCache(const QString &playlistUrl,
                                               const QString &title,
                                               const QVariantList &items) const
{
    if (playlistUrl.isEmpty() || items.isEmpty())
        return false;

    QDir().mkpath(m_dataRoot);
    QSaveFile file(playlistCachePath(playlistUrl));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning("[YouTubePlaylistBackend] could not write playlist cache: %s",
                 qPrintable(file.errorString()));
        return false;
    }

    QVariantMap cache;
    cache[QStringLiteral("version")] = kPlaylistCacheVersion;
    cache[QStringLiteral("playlistUrl")] = playlistUrl;
    cache[QStringLiteral("title")] = title;
    cache[QStringLiteral("items")] = items;
    cache[QStringLiteral("cachedAt")] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);

    file.write(QJsonDocument(QJsonObject::fromVariantMap(cache)).toJson(QJsonDocument::Indented));
    if (!file.commit()) {
        qWarning("[YouTubePlaylistBackend] could not save playlist cache: %s",
                 qPrintable(file.errorString()));
        return false;
    }
    return true;
}

void YouTubePlaylistBackend::clearPlaylistCache() const
{
    QFile::remove(QDir(m_dataRoot).absoluteFilePath(QString::fromUtf8(kLegacyPlaylistCacheFile)));
    const QStringList names = QDir(m_dataRoot).entryList(
        {QStringLiteral("public-access-cache-*.json")}, QDir::Files);
    for (const QString &name : names)
        QFile::remove(QDir(m_dataRoot).absoluteFilePath(name));
}

void YouTubePlaylistBackend::clearPlaylistCache(const QString &playlistUrl) const
{
    if (playlistUrl.isEmpty())
        return;
    QFile::remove(playlistCachePath(playlistUrl));
}

QString YouTubePlaylistBackend::get_auth_state()
{
    return get_saved_playlists().isEmpty()
        ? QStringLiteral("none")
        : QStringLiteral("authed");
}

QString YouTubePlaylistBackend::get_saved_playlist_input() const
{
    return setting(QStringLiteral("playlist_input"));
}

QVariantList YouTubePlaylistBackend::get_saved_playlists() const
{
    QVariantList result;
    const QVariantMap cfg = moduleConfig();
    const QVariantList saved = cfg.value(QStringLiteral("playlists")).toList();
    QSet<QString> seen;

    int index = 0;
    for (const QVariant &value : saved) {
        QVariantMap playlist = value.toMap();
        const QString input = playlist.value(QStringLiteral("input")).toString().trimmed();
        const QString url = normalize_playlist_input(
            playlist.value(QStringLiteral("url")).toString().trimmed().isEmpty()
                ? input
                : playlist.value(QStringLiteral("url")).toString());
        if (url.isEmpty() || seen.contains(url))
            continue;

        playlist[QStringLiteral("input")] = input.isEmpty() ? url : input;
        playlist[QStringLiteral("url")] = url;
        playlist[QStringLiteral("title")] = cleanTitle(
            playlist.value(QStringLiteral("title")).toString(),
            fallbackPlaylistTitle(input.isEmpty() ? url : input, index));
        playlist[QStringLiteral("id")] = playlist.value(QStringLiteral("id")).toString().isEmpty()
            ? QString::fromLatin1(QCryptographicHash::hash(url.toUtf8(), QCryptographicHash::Sha1).toHex())
            : playlist.value(QStringLiteral("id")).toString();
        result.append(playlist);
        seen.insert(url);
        ++index;
    }

    const QString legacyInput = get_saved_playlist_input();
    const QString legacyUrl = normalize_playlist_input(legacyInput);
    if (!legacyUrl.isEmpty() && !seen.contains(legacyUrl)) {
        QVariantMap legacy;
        legacy[QStringLiteral("id")] = QString::fromLatin1(
            QCryptographicHash::hash(legacyUrl.toUtf8(), QCryptographicHash::Sha1).toHex());
        legacy[QStringLiteral("input")] = legacyInput;
        legacy[QStringLiteral("url")] = legacyUrl;
        legacy[QStringLiteral("title")] = fallbackPlaylistTitle(legacyInput, result.size());
        legacy[QStringLiteral("legacy")] = true;
        result.append(legacy);
    }

    return result;
}

QVariantList YouTubePlaylistBackend::playlistRemovalOptions() const
{
    QVariantList options;
    const QVariantList saved = get_saved_playlists();
    for (const QVariant &value : saved) {
        const QVariantMap playlist = value.toMap();
        const QString id = playlist.value(QStringLiteral("id")).toString();
        if (id.isEmpty())
            continue;
        options.append(QVariantMap{
            {QStringLiteral("id"), id},
            {QStringLiteral("label"), playlist.value(QStringLiteral("title")).toString()}
        });
    }
    return options;
}

QString YouTubePlaylistBackend::normalize_playlist_input(const QString &input) const
{
    QString raw = input.trimmed();
    if (raw.isEmpty())
        return QString();

    raw.remove(QRegularExpression("^['\"]|['\"]$"));

    const QRegularExpression listParamRe("(^|[?&])list=([A-Za-z0-9_-]+)");
    const QRegularExpressionMatch listMatch = listParamRe.match(raw);
    if (listMatch.hasMatch())
        raw = listMatch.captured(2);

    if (raw.startsWith(QStringLiteral("http://"), Qt::CaseInsensitive) ||
        raw.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
        const QUrl url(raw);
        const QString listId = QUrlQuery(url).queryItemValue(QStringLiteral("list"));
        if (!listId.isEmpty())
            raw = listId;
        else
            return raw;
    }

    raw.remove(QRegularExpression("[^A-Za-z0-9_-]"));
    if (raw.isEmpty())
        return QString();

    return QStringLiteral("https://www.youtube.com/playlist?list=%1").arg(raw);
}

QString YouTubePlaylistBackend::ytdl_format_for_quality(const QString &quality) const
{
    const QString q = quality.trimmed().toLower();
    if (runningOnRaspberryPi3() && q == QLatin1String("best"))
        return QStringLiteral("best[height<=480][ext=mp4]/bestvideo[height<=480][vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[height<=480]/best");
    if (q == QLatin1String("best"))
        return QStringLiteral("bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best");
    if (q == QLatin1String("480p"))
        return QStringLiteral("best[height<=480][ext=mp4]/bestvideo[height<=480][vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[height<=480]/best");
    return QStringLiteral("best[height<=360][ext=mp4]/bestvideo[height<=360][vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[height<=360]/best");
}

QVariantMap YouTubePlaylistBackend::inspectPlaylist(const QString &playlistUrl, int limit,
                                                    QString *errorOut) const
{
    QVariantMap result;
    const QString bin = ytDlpPath();
    if (bin.isEmpty()) {
        if (errorOut)
            *errorOut = QStringLiteral("YT-DLP IS NOT INSTALLED");
        return result;
    }

    QStringList args{
        QStringLiteral("--flat-playlist"),
        QStringLiteral("--dump-single-json"),
        QStringLiteral("--no-warnings"),
        QStringLiteral("--playlist-end"),
        QString::number(limit),
        playlistUrl
    };

    QProcess process;
    process.setProcessChannelMode(QProcess::SeparateChannels);
    process.start(bin, args);
    if (!process.waitForStarted(2000)) {
        if (errorOut)
            *errorOut = QStringLiteral("COULD NOT START YT-DLP");
        return result;
    }

    if (!process.waitForFinished(90000)) {
        process.kill();
        process.waitForFinished(1000);
        if (errorOut)
            *errorOut = QStringLiteral("YOUTUBE PLAYLIST TIMED OUT");
        return result;
    }

    const QByteArray stdoutData = process.readAllStandardOutput();
    const QString stderrText = QString::fromUtf8(process.readAllStandardError()).trimmed();
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        if (errorOut)
            *errorOut = stderrText.isEmpty()
                ? QStringLiteral("YOUTUBE PLAYLIST FAILED")
                : stderrText.toUpper().left(160);
        return result;
    }

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(stdoutData, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        if (errorOut)
            *errorOut = QStringLiteral("YOUTUBE PLAYLIST DATA IS INVALID");
        return result;
    }

    result = doc.object().toVariantMap();
    return result;
}

QVariantMap YouTubePlaylistBackend::resolve_playlist_info(const QString &input) const
{
    QVariantMap result;
    const QString playlistUrl = normalize_playlist_input(input);
    if (playlistUrl.isEmpty()) {
        result[QStringLiteral("ok")] = false;
        result[QStringLiteral("message")] = QStringLiteral("ENTER PLAYLIST CODE");
        return result;
    }

    QString error;
    const QVariantMap info = inspectPlaylist(playlistUrl, 1, &error);
    const QString title = cleanTitle(info.value(QStringLiteral("title")).toString(),
                                     fallbackPlaylistTitle(input, 0));

    result[QStringLiteral("ok")] = error.isEmpty();
    result[QStringLiteral("input")] = input.trimmed();
    result[QStringLiteral("url")] = playlistUrl;
    result[QStringLiteral("title")] = title;
    result[QStringLiteral("id")] = QString::fromLatin1(
        QCryptographicHash::hash(playlistUrl.toUtf8(), QCryptographicHash::Sha1).toHex());
    result[QStringLiteral("message")] = error;
    return result;
}

void YouTubePlaylistBackend::load_playlist(const QString &input)
{
    fetchPlaylist(input, false);
}

void YouTubePlaylistBackend::refresh_playlist_cache()
{
    clearPlaylistCache();
    emit authStateChanged();
}

void YouTubePlaylistBackend::refresh_playlist(const QString &input)
{
    fetchPlaylist(input, true);
}

void YouTubePlaylistBackend::load_playlist_remove_options()
{
    emit dynamicOptionsReady(QStringLiteral("remove_playlist_id"), playlistRemovalOptions());
}

void YouTubePlaylistBackend::remove_selected_playlist()
{
    const QVariantList saved = get_saved_playlists();
    if (saved.isEmpty()) {
        emit dynamicOptionsReady(QStringLiteral("remove_playlist_id"), QVariantList{});
        emit authStateChanged();
        return;
    }

    const QVariantMap cfg = moduleConfig();
    QString selectedId = cfg.value(QStringLiteral("remove_playlist_id")).toString();
    if (selectedId.isEmpty())
        selectedId = saved.first().toMap().value(QStringLiteral("id")).toString();

    QVariantList remaining;
    QString removedUrl;
    for (const QVariant &value : saved) {
        const QVariantMap playlist = value.toMap();
        if (playlist.value(QStringLiteral("id")).toString() == selectedId) {
            removedUrl = playlist.value(QStringLiteral("url")).toString();
            continue;
        }

        QVariantMap clean;
        clean[QStringLiteral("id")] = playlist.value(QStringLiteral("id")).toString();
        clean[QStringLiteral("input")] = playlist.value(QStringLiteral("input")).toString();
        clean[QStringLiteral("url")] = playlist.value(QStringLiteral("url")).toString();
        clean[QStringLiteral("title")] = playlist.value(QStringLiteral("title")).toString();
        remaining.append(clean);
    }

    if (remaining.size() == saved.size())
        return;

    QJsonObject config = loadConfig();
    QJsonObject modules = config.value(QStringLiteral("modules")).toObject();
    QJsonObject module = modules.value(QString::fromUtf8(kModuleId)).toObject();
    module[QStringLiteral("playlists")] = QJsonValue::fromVariant(remaining);
    module.remove(QStringLiteral("playlist_input"));
    if (remaining.isEmpty())
        module.remove(QStringLiteral("remove_playlist_id"));
    else
        module[QStringLiteral("remove_playlist_id")] =
            remaining.first().toMap().value(QStringLiteral("id")).toString();

    modules[QString::fromUtf8(kModuleId)] = module;
    config[QStringLiteral("modules")] = modules;
    if (!saveConfig(config)) {
        emit errorOccurred(QStringLiteral("COULD NOT REMOVE PLAYLIST"));
        return;
    }

    clearPlaylistCache(removedUrl);
    emit dynamicOptionsReady(QStringLiteral("remove_playlist_id"), playlistRemovalOptions());
    emit authStateChanged();
}

void YouTubePlaylistBackend::fetchPlaylist(const QString &input, bool forceRefresh)
{
    const QString playlistUrl = normalize_playlist_input(input);
    if (playlistUrl.isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER PLAYLIST CODE"));
        return;
    }

    if (!forceRefresh) {
        const QVariantMap cache = loadPlaylistCache(playlistUrl);
        if (!cache.isEmpty()) {
            emit playlistLoaded(cache.value(QStringLiteral("title")).toString(),
                                cache.value(QStringLiteral("items")).toList());
            return;
        }
    }

    if (forceRefresh)
        clearPlaylistCache(playlistUrl);

    QString error;
    const QVariantMap rootMap = inspectPlaylist(playlistUrl, kPlaylistLimit, &error);
    if (!error.isEmpty()) {
        emit errorOccurred(error);
        return;
    }

    const QJsonArray entries = QJsonArray::fromVariantList(rootMap.value(QStringLiteral("entries")).toList());
    QVariantList items;
    int position = 0;
    for (const QJsonValue &value : entries) {
        if (!value.isObject())
            continue;
        const QJsonObject entry = value.toObject();
        const QString id = entry.value(QStringLiteral("id")).toString().trimmed();
        QString url = entry.value(QStringLiteral("url")).toString().trimmed();
        if (url.isEmpty() && id.isEmpty())
            continue;
        if (!url.startsWith(QStringLiteral("http://"), Qt::CaseInsensitive) &&
            !url.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
            const QString videoId = id.isEmpty() ? url : id;
            url = QStringLiteral("https://www.youtube.com/watch?v=%1").arg(videoId);
        }

        QVariantMap item;
        item["id"] = id.isEmpty() ? url : id;
        item["url"] = url;
        item["title"] = cleanTitle(entry.value(QStringLiteral("title")).toString(),
                                   QStringLiteral("VIDEO %1").arg(position + 1));
        item["index"] = position;
        items.append(item);
        ++position;
    }

    if (items.isEmpty() && rootMap.value(QStringLiteral("playlist_count")).toInt() > 0)
        items = playlistItemsFromHtml(playlistUrl, kPlaylistLimit);

    if (items.isEmpty()) {
        emit errorOccurred(QStringLiteral("PLAYLIST HAS NO VIDEOS"));
        return;
    }

    const QString title = cleanTitle(rootMap.value(QStringLiteral("title")).toString(),
                                     QStringLiteral("YOUTUBE PLAYLIST"));
    savePlaylistCache(playlistUrl, title, items);
    emit playlistLoaded(title, items);
}

void YouTubePlaylistBackend::onSettingChanged(const QString &moduleId,
                                              const QString &key,
                                              const QVariant &value)
{
    Q_UNUSED(value)
    if (moduleId != QLatin1String(kModuleId))
        return;

    if (key == QLatin1String("playlist_input")) {
        clearPlaylistCache();
        emit authStateChanged();
        emit dynamicOptionsReady(QStringLiteral("remove_playlist_id"), playlistRemovalOptions());
    } else if (key == QLatin1String("playlists")) {
        emit authStateChanged();
        emit dynamicOptionsReady(QStringLiteral("remove_playlist_id"), playlistRemovalOptions());
    }
}
