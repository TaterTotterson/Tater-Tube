#include "YouTubePlaylistBackend.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
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
constexpr const char *kPlaylistCacheFile = "public-access-cache.json";
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

QString cleanTitle(QString title, const QString &fallback)
{
    title = title.trimmed();
    title.replace(QRegularExpression("\\s+"), " ");
    return title.isEmpty() ? fallback : title;
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

QString YouTubePlaylistBackend::playlistCachePath() const
{
    return QDir(m_dataRoot).absoluteFilePath(QString::fromUtf8(kPlaylistCacheFile));
}

QVariantMap YouTubePlaylistBackend::loadPlaylistCache(const QString &playlistUrl) const
{
    QFile file(playlistCachePath());
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
    QSaveFile file(playlistCachePath());
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
    QFile::remove(playlistCachePath());
}

QString YouTubePlaylistBackend::get_auth_state()
{
    return normalize_playlist_input(get_saved_playlist_input()).isEmpty()
        ? QStringLiteral("none")
        : QStringLiteral("authed");
}

QString YouTubePlaylistBackend::get_saved_playlist_input() const
{
    return setting(QStringLiteral("playlist_input"));
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
    if (q == QLatin1String("best"))
        return QStringLiteral("bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best");
    if (q == QLatin1String("480p"))
        return QStringLiteral("best[height<=480][ext=mp4]/bestvideo[height<=480][vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[height<=480]/best");
    return QStringLiteral("best[height<=360][ext=mp4]/bestvideo[height<=360][vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[height<=360]/best");
}

void YouTubePlaylistBackend::load_playlist(const QString &input)
{
    fetchPlaylist(input, false);
}

void YouTubePlaylistBackend::refresh_playlist_cache()
{
    fetchPlaylist(get_saved_playlist_input(), true);
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

    const QString bin = ytDlpPath();
    if (bin.isEmpty()) {
        emit errorOccurred(QStringLiteral("YT-DLP IS NOT INSTALLED"));
        return;
    }

    QStringList args{
        QStringLiteral("--flat-playlist"),
        QStringLiteral("--dump-single-json"),
        QStringLiteral("--no-warnings"),
        QStringLiteral("--playlist-end"),
        QString::number(kPlaylistLimit),
        playlistUrl
    };

    QProcess process;
    process.setProcessChannelMode(QProcess::SeparateChannels);
    process.start(bin, args);
    if (!process.waitForStarted(2000)) {
        emit errorOccurred(QStringLiteral("COULD NOT START YT-DLP"));
        return;
    }

    if (!process.waitForFinished(90000)) {
        process.kill();
        process.waitForFinished(1000);
        emit errorOccurred(QStringLiteral("YOUTUBE PLAYLIST TIMED OUT"));
        return;
    }

    const QByteArray stdoutData = process.readAllStandardOutput();
    const QString stderrText = QString::fromUtf8(process.readAllStandardError()).trimmed();
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        emit errorOccurred(stderrText.isEmpty()
            ? QStringLiteral("YOUTUBE PLAYLIST FAILED")
            : stderrText.toUpper().left(160));
        return;
    }

    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(stdoutData, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        emit errorOccurred(QStringLiteral("YOUTUBE PLAYLIST DATA IS INVALID"));
        return;
    }

    const QJsonObject root = doc.object();
    const QJsonArray entries = root.value(QStringLiteral("entries")).toArray();
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

    if (items.isEmpty() && root.value(QStringLiteral("playlist_count")).toInt() > 0)
        items = playlistItemsFromHtml(playlistUrl, kPlaylistLimit);

    if (items.isEmpty()) {
        emit errorOccurred(QStringLiteral("PLAYLIST HAS NO VIDEOS"));
        return;
    }

    const QString title = cleanTitle(root.value(QStringLiteral("title")).toString(),
                                     QStringLiteral("YOUTUBE PLAYLIST"));
    savePlaylistCache(playlistUrl, title, items);
    emit playlistLoaded(title, items);
}

void YouTubePlaylistBackend::onSettingChanged(const QString &moduleId,
                                              const QString &key,
                                              const QVariant &value)
{
    Q_UNUSED(value)
    if (moduleId == QLatin1String(kModuleId) && key == QLatin1String("playlist_input")) {
        clearPlaylistCache();
        emit authStateChanged();
    }
}
