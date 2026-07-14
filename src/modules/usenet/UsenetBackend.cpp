#include "UsenetBackend.h"

#include "../../media/CommercialLibrary.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>
#include <QUrlQuery>
#include <QXmlStreamReader>
#include <QtGlobal>

namespace {
constexpr const char *kModuleId = "com.240mp.usenet";

QString cleanText(QString value)
{
    value.replace(QRegularExpression(QStringLiteral("\\s+")), QStringLiteral(" "));
    return value.trimmed();
}

QString trimmedBaseUrl(QString value)
{
    value = value.trimmed();
    while (value.endsWith(QLatin1Char('/')))
        value.chop(1);
    return value;
}

QString formatBytes(qint64 bytes)
{
    if (bytes <= 0)
        return QString();

    const QStringList units{QStringLiteral("B"), QStringLiteral("KB"), QStringLiteral("MB"),
                            QStringLiteral("GB"), QStringLiteral("TB")};
    double value = static_cast<double>(bytes);
    int unit = 0;
    while (value >= 1024.0 && unit < units.size() - 1) {
        value /= 1024.0;
        ++unit;
    }

    return QStringLiteral("%1 %2").arg(value, 0, unit >= 3 ? 'f' : 'f', unit >= 3 ? 1 : 0)
        .arg(units.at(unit));
}

qint64 attrSizeToInteger(const QString &value)
{
    bool ok = false;
    const qint64 size = value.trimmed().toLongLong(&ok);
    return ok ? size : 0;
}

QString attrValue(const QXmlStreamAttributes &attrs, const QString &name)
{
    return attrs.value(name).toString();
}

bool isOmgwtfHost(const QString &host)
{
    const QString normalized = host.trimmed().toLower();
    return normalized == QStringLiteral("omgwtfnzbs.org")
        || normalized == QStringLiteral("api.omgwtfnzbs.org");
}

bool isRedirectStatus(int status)
{
    return status >= 300 && status < 400;
}

QString omgItemIdFromUrl(const QString &value)
{
    const QUrl url(value.trimmed());
    if (!url.isValid())
        return QString();

    const QUrlQuery query(url);
    return query.queryItemValue(QStringLiteral("id")).trimmed();
}

bool isMediaCategoryGroup(const QString &id, const QString &name)
{
    const QString normalizedId = id.trimmed();
    const QString lowerName = name.trimmed().toLower();
    return normalizedId.startsWith(QStringLiteral("2000"))
        || normalizedId.startsWith(QStringLiteral("3000"))
        || normalizedId.startsWith(QStringLiteral("5000"))
        || lowerName.contains(QStringLiteral("movie"))
        || lowerName == QStringLiteral("tv")
        || lowerName.contains(QStringLiteral("television"))
        || lowerName.contains(QStringLiteral("audio"))
        || lowerName.contains(QStringLiteral("music"));
}
}

UsenetBackend::UsenetBackend(const QString &appRoot, const QString &dataRoot,
                             QObject *parent)
    : QObject(parent)
    , m_appRoot(appRoot)
    , m_dataRoot(dataRoot)
{
}

QVariantMap UsenetBackend::moduleConfig() const
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

QString UsenetBackend::setting(const QString &key, const QString &fallback) const
{
    const QString value = moduleConfig().value(key).toString().trimmed();
    return value.isEmpty() ? fallback : value;
}

QString UsenetBackend::newznabApiKey() const
{
    QString key = setting(QStringLiteral("newznab_api_key"));
    if (key.endsWith(QStringLiteral("Copy"), Qt::CaseSensitive))
        key.chop(4);
    return key.trimmed();
}

QString UsenetBackend::omgUsername() const
{
    return setting(QStringLiteral("omg_username")).trimmed();
}

QString UsenetBackend::newznabApiBase() const
{
    QString base = trimmedBaseUrl(setting(QStringLiteral("newznab_url")));
    if (base.isEmpty())
        return QString();

    QUrl url(base);
    if (!url.isValid() || url.scheme().isEmpty())
        url = QUrl(QStringLiteral("http://") + base);
    if (isOmgwtfHost(url.host()) && url.scheme().compare(QStringLiteral("https"), Qt::CaseInsensitive) != 0)
        url.setScheme(QStringLiteral("https"));

    QString path = url.path();
    while (path.endsWith(QLatin1Char('/')))
        path.chop(1);
    if (!path.endsWith(QStringLiteral("/api"), Qt::CaseInsensitive))
        path += QStringLiteral("/api");
    url.setPath(path);
    url.setQuery(QString());
    return url.toString(QUrl::StripTrailingSlash);
}

QString UsenetBackend::serverApiBase() const
{
    QString base = trimmedBaseUrl(setting(QStringLiteral("tater_server_url")));
    if (base.isEmpty())
        return QString();

    QUrl url(base);
    if (!url.isValid() || url.scheme().isEmpty())
        url = QUrl(QStringLiteral("http://") + base);

    url.setQuery(QString());
    return url.toString(QUrl::StripTrailingSlash);
}

QString UsenetBackend::serverPlayerToken() const
{
    return setting(QStringLiteral("tater_server_token")).trimmed();
}

QUrl UsenetBackend::newznabUrl(const QVariantMap &params) const
{
    QUrl url(newznabApiBase());
    QUrlQuery query;
    for (auto it = params.constBegin(); it != params.constEnd(); ++it)
        query.addQueryItem(it.key(), it.value().toString());

    const QString apiKey = newznabApiKey();
    if (!apiKey.isEmpty() && !query.hasQueryItem(QStringLiteral("apikey")))
        query.addQueryItem(QStringLiteral("apikey"), apiKey);

    url.setQuery(query);
    return url;
}

QUrl UsenetBackend::omgNzbUrl(const QString &id) const
{
    QUrl url(QStringLiteral("https://api.omgwtfnzbs.org/nzb/"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("id"), id.trimmed());
    query.addQueryItem(QStringLiteral("user"), omgUsername());
    query.addQueryItem(QStringLiteral("api"), newznabApiKey());
    url.setQuery(query);
    return url;
}

QUrl UsenetBackend::omgTrendingUrl(const QString &category, const QString &timePeriod) const
{
    QUrl url(QStringLiteral("https://rss.omgwtfnzbs.org/rss-trends.php"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("user"), omgUsername());
    query.addQueryItem(QStringLiteral("api"), newznabApiKey());
    query.addQueryItem(QStringLiteral("cat"), category.trimmed().toLower());
    query.addQueryItem(QStringLiteral("s"), QString());
    query.addQueryItem(QStringLiteral("time"), timePeriod.trimmed().toLower());
    query.addQueryItem(QStringLiteral("res"), QString());
    url.setQuery(query);
    return url;
}

QUrl UsenetBackend::taterApiUrlFromBase(const QString &baseUrl, const QString &path,
                                        const QVariantMap &params) const
{
    QString base = trimmedBaseUrl(baseUrl);
    QUrl url(base);
    if (!url.isValid() || url.scheme().isEmpty())
        url = QUrl(QStringLiteral("http://") + base);

    QString urlPath = url.path();
    while (urlPath.endsWith(QLatin1Char('/')))
        urlPath.chop(1);
    if (urlPath.endsWith(QStringLiteral("/api"), Qt::CaseInsensitive)
        && path.startsWith(QStringLiteral("/api/"), Qt::CaseInsensitive)) {
        urlPath.chop(4);
    }
    urlPath += path.startsWith(QLatin1Char('/')) ? path : QStringLiteral("/") + path;
    url.setPath(urlPath);

    QUrlQuery query;
    for (auto it = params.constBegin(); it != params.constEnd(); ++it)
        query.addQueryItem(it.key(), it.value().toString());
    url.setQuery(query);
    return url;
}

QUrl UsenetBackend::taterApiUrl(const QString &path, const QVariantMap &params) const
{
    return taterApiUrlFromBase(serverApiBase(), path, params);
}

void UsenetBackend::addTaterAuthHeader(QNetworkRequest &request) const
{
    const QString token = serverPlayerToken();
    if (!token.isEmpty())
        request.setRawHeader("Authorization", QStringLiteral("Bearer %1").arg(token).toUtf8());
}

QString UsenetBackend::ensureNewznabApiKey(const QString &rawUrl) const
{
    QUrl url(rawUrl.trimmed());
    const QString apiKey = newznabApiKey();
    if (!url.isValid() || apiKey.isEmpty())
        return rawUrl.trimmed();

    QUrlQuery query(url);
    if (!query.hasQueryItem(QStringLiteral("apikey")) && !query.hasQueryItem(QStringLiteral("api"))) {
        query.addQueryItem(QStringLiteral("apikey"), apiKey);
        url.setQuery(query);
    }
    return url.toString();
}

int UsenetBackend::browseLimit() const
{
    bool ok = false;
    int limit = setting(QStringLiteral("browse_limit"), QStringLiteral("100")).toInt(&ok);
    if (!ok)
        limit = 100;
    return qBound(10, limit, 500);
}

int UsenetBackend::streamTimeout() const
{
    bool ok = false;
    int timeout = setting(QStringLiteral("stream_timeout"), QStringLiteral("300")).toInt(&ok);
    if (!ok)
        timeout = 300;
    return qBound(60, timeout, 900);
}

QString UsenetBackend::playbackTranscodeProfile(int screenWidth, int screenHeight) const
{
    const QString quality = setting(QStringLiteral("tube_transcode_quality"),
                                    QStringLiteral("Auto")).trimmed().toLower();
    if (quality == QStringLiteral("crt 480p") || quality == QStringLiteral("crt_480p"))
        return QStringLiteral("crt_480p");
    if (quality == QStringLiteral("hdmi 1080p") || quality == QStringLiteral("hdmi_1080p"))
        return QStringLiteral("hdmi_1080p");
    if (quality == QStringLiteral("hdmi 4k") || quality == QStringLiteral("hdmi_4k"))
        return QStringLiteral("hdmi_4k");

    const int longEdge = qMax(screenWidth, screenHeight);
    const int shortEdge = qMin(screenWidth, screenHeight);
    if (longEdge >= 3000 || shortEdge >= 1800)
        return QStringLiteral("hdmi_4k");
    if (longEdge >= 1280 || shortEdge >= 720)
        return QStringLiteral("hdmi_1080p");
    return QStringLiteral("crt_480p");
}

QString UsenetBackend::playback_url(const QString &rawUrl, int screenWidth, int screenHeight) const
{
    QUrl url(rawUrl.trimmed());
    if (!url.isValid() || url.scheme().isEmpty())
        return rawUrl.trimmed();

    const QString mode = setting(QStringLiteral("tube_transcode_mode"),
                                 QStringLiteral("On")).trimmed().toLower();
    QUrlQuery query(url);
    query.removeAllQueryItems(QStringLiteral("direct"));
    query.removeAllQueryItems(QStringLiteral("transcode"));
    query.removeAllQueryItems(QStringLiteral("profile"));
    query.removeAllQueryItems(QStringLiteral("hwaccel"));

    if (mode == QStringLiteral("off")) {
        query.addQueryItem(QStringLiteral("transcode"), QStringLiteral("0"));
    } else {
        query.addQueryItem(QStringLiteral("profile"),
                           playbackTranscodeProfile(screenWidth, screenHeight));
        query.addQueryItem(QStringLiteral("transcode"), QStringLiteral("1"));
        query.addQueryItem(QStringLiteral("hwaccel"), QStringLiteral("auto"));
    }

    url.setQuery(query);
    return url.toString();
}

bool UsenetBackend::uses_server_seek() const
{
    const QString mode = setting(QStringLiteral("tube_transcode_mode"),
                                 QStringLiteral("On")).trimmed().toLower();
    return mode != QStringLiteral("off");
}

QVariantList UsenetBackend::get_commercial_videos_for_setting(const QString &settingKey) const
{
    return CommercialLibrary(m_dataRoot).videosForSetting(moduleConfig(), settingKey);
}

QVariantList UsenetBackend::get_commercial_videos_for_category(const QString &categoryId) const
{
    return CommercialLibrary(m_dataRoot).videosForCategory(categoryId);
}

void UsenetBackend::load_tube_commercial_category_options()
{
    emit dynamicOptionsReady(QStringLiteral("tube_commercial_categories"),
                             CommercialLibrary(m_dataRoot).categoryOptions());
}

QString UsenetBackend::get_auth_state()
{
    return serverApiBase().isEmpty()
        || serverPlayerToken().isEmpty()
        ? QStringLiteral("none")
        : QStringLiteral("authed");
}

QVariantMap UsenetBackend::get_setup_status()
{
    QVariantMap status;
    status[QStringLiteral("serverUrl")] = setting(QStringLiteral("tater_server_url"));
    status[QStringLiteral("paired")] = !serverPlayerToken().isEmpty();
    status[QStringLiteral("newznabUrl")] = setting(QStringLiteral("newznab_url"));
    status[QStringLiteral("newznabApiKey")] = setting(QStringLiteral("newznab_api_key"));
    status[QStringLiteral("omgUsername")] = omgUsername();
    status[QStringLiteral("configured")] = get_auth_state() == QStringLiteral("authed");
    return status;
}

void UsenetBackend::pair_server(const QString &serverUrl, const QString &pin)
{
    const QString base = trimmedBaseUrl(serverUrl);
    const QString cleanPin = pin.trimmed();
    if (base.isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER SERVER URL"));
        return;
    }
    if (cleanPin.isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER PAIRING PIN"));
        return;
    }

    QNetworkRequest request(taterApiUrlFromBase(base, QStringLiteral("/api/tater/players/pair")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));

    QJsonObject payload;
    payload[QStringLiteral("pin")] = cleanPin;
    payload[QStringLiteral("name")] = QStringLiteral("Tater Tube Player");

    QNetworkReply *reply = m_network.post(request, QJsonDocument(payload).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, base]() {
        handlePairingReply(reply, base);
    });
}

void UsenetBackend::load_categories()
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/catalog")));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCategoriesReply(reply);
    });
}

void UsenetBackend::load_items(const QString &categoryId, const QString &categoryTitle)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/items"), {
        {QStringLiteral("category_id"), categoryId},
        {QStringLiteral("title"), categoryTitle}
    }));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, categoryTitle]() {
        handleItemsReply(reply, categoryTitle);
    });
}

void UsenetBackend::load_local_items(const QString &categoryId, const QString &path,
                                     int sourceIndex, const QString &categoryTitle)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    QVariantMap params{
        {QStringLiteral("category_id"), categoryId},
        {QStringLiteral("title"), categoryTitle}
    };
    if (!path.trimmed().isEmpty())
        params[QStringLiteral("path")] = path.trimmed();
    if (sourceIndex >= 0)
        params[QStringLiteral("source")] = QString::number(sourceIndex);

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/items"), params));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, categoryTitle]() {
        handleItemsReply(reply, categoryTitle);
    });
}

void UsenetBackend::search_items(const QString &query)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    const QString cleanQuery = cleanText(query);
    if (cleanQuery.size() < 3) {
        emit errorOccurred(QStringLiteral("ENTER 3 OR MORE LETTERS"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/search"), {
        {QStringLiteral("q"), cleanQuery}
    }));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    const QString title = QStringLiteral("Search: %1").arg(cleanQuery);
    connect(reply, &QNetworkReply::finished, this, [this, reply, title]() {
        handleItemsReply(reply, title);
    });
}

void UsenetBackend::load_discover(const QString &catalogId, const QString &title)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    const QString cleanCatalog = catalogId.trimmed();
    if (cleanCatalog.isEmpty()) {
        emit errorOccurred(QStringLiteral("DISCOVER CATALOG INVALID"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/discover"), {
        {QStringLiteral("catalog"), cleanCatalog}
    }));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, title]() {
        handleItemsReply(reply, title);
    });
}

void UsenetBackend::load_trending(const QString &category, const QString &timePeriod,
                                  const QString &title)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    const QString cleanCategory = category.trimmed().toLower();
    if (cleanCategory != QStringLiteral("movie") && cleanCategory != QStringLiteral("tv")) {
        emit errorOccurred(QStringLiteral("TRENDING CATEGORY INVALID"));
        return;
    }

    const QString cleanTime = timePeriod.trimmed().toLower();
    if (cleanTime != QStringLiteral("today")
        && cleanTime != QStringLiteral("week")
        && cleanTime != QStringLiteral("month")
        && cleanTime != QStringLiteral("year")) {
        emit errorOccurred(QStringLiteral("TRENDING TIME INVALID"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/trending"), {
        {QStringLiteral("category"), cleanCategory},
        {QStringLiteral("period"), cleanTime}
    }));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, title]() {
        handleItemsReply(reply, title);
    });
}

void UsenetBackend::load_continue_watching()
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("PAIR TATER TUBE SERVER"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/playstate/continue")));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleItemsReply(reply, QStringLiteral("Continue Watching"));
    });
}

void UsenetBackend::load_music_libraries()
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("PAIR TATER TUBE SERVER"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/music/libraries")));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleMusicRowsReply(reply, QStringLiteral("libraries"),
                             QStringLiteral("LOAD MUSIC LIBRARIES FAILED"));
    });
}

void UsenetBackend::load_music_albums(const QString &categoryId)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("PAIR TATER TUBE SERVER"));
        return;
    }

    const QString cleanId = categoryId.trimmed();
    if (cleanId.isEmpty()) {
        emit errorOccurred(QStringLiteral("MUSIC LIBRARY INVALID"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/music/albums"), {
        {QStringLiteral("category_id"), cleanId}
    }));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleMusicRowsReply(reply, QStringLiteral("albums"),
                             QStringLiteral("LOAD MUSIC ALBUMS FAILED"));
    });
}

void UsenetBackend::load_music_tracks(const QString &albumId)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("PAIR TATER TUBE SERVER"));
        return;
    }

    const QString cleanId = albumId.trimmed();
    if (cleanId.isEmpty()) {
        emit errorOccurred(QStringLiteral("MUSIC ALBUM INVALID"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/music/tracks"), {
        {QStringLiteral("album_id"), cleanId}
    }));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleMusicRowsReply(reply, QStringLiteral("tracks"),
                             QStringLiteral("LOAD MUSIC TRACKS FAILED"));
    });
}

void UsenetBackend::load_active_streams()
{
    if (serverApiBase().isEmpty() || serverPlayerToken().isEmpty())
        return;

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/streams/active")));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleActiveStreamsReply(reply);
    });
}

void UsenetBackend::load_tube_tv_lineup()
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("PAIR TATER TUBE SERVER"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/tv/lineup")));
    addTaterAuthHeader(request);
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleTubeTvLineupReply(reply);
    });
}

void UsenetBackend::request_streams(const QString &requestId, const QVariantMap &item)
{
    const QString nzbUrl = item.value(QStringLiteral("nzbUrl")).toString().trimmed();
    const QString title = item.value(QStringLiteral("title")).toString().trimmed();
    if (nzbUrl.isEmpty()) {
        emit errorOccurred(QStringLiteral("NZB LINK MISSING"));
        return;
    }
    if (serverApiBase().isEmpty() || serverPlayerToken().isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER SERVER SETTINGS"));
        return;
    }

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/usenet/play")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    addTaterAuthHeader(request);

    QJsonObject payload;
    payload[QStringLiteral("nzb_url")] = nzbUrl;
    payload[QStringLiteral("title")] = title;
    payload[QStringLiteral("category")] = item.value(QStringLiteral("category")).toString().trimmed();
    payload[QStringLiteral("timeout")] = streamTimeout();

    QNetworkReply *reply = m_network.post(request, QJsonDocument(payload).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, requestId, title]() {
        handleStreamsReply(reply, requestId, title);
    });
}

void UsenetBackend::save_play_state(const QVariantMap &state)
{
    if (serverApiBase().isEmpty() || serverPlayerToken().isEmpty())
        return;

    const QString playStateId = state.value(QStringLiteral("playStateId")).toString().trimmed();
    const QString path = state.value(QStringLiteral("path")).toString().trimmed();
    if (playStateId.isEmpty() && path.isEmpty())
        return;

    QNetworkRequest request(taterApiUrl(QStringLiteral("/api/tater/playstate")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    addTaterAuthHeader(request);

    QNetworkReply *reply = m_network.post(request, QJsonDocument(QJsonObject::fromVariantMap(state)).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [reply]() {
        reply->deleteLater();
    });
}

void UsenetBackend::handlePairingReply(QNetworkReply *reply, const QString &serverUrl)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status)) {
        emit errorOccurred(QStringLiteral("SERVER URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        QString error;
        parseJsonRows(body, QStringLiteral("players"), &error);
        emit errorOccurred(error.isEmpty() ? QStringLiteral("PAIRING FAILED") : error);
        return;
    }

    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(body, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        emit errorOccurred(QStringLiteral("PAIRING RESPONSE INVALID"));
        return;
    }

    QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("success")).isBool() && !obj.value(QStringLiteral("success")).toBool()) {
        const QJsonObject err = obj.value(QStringLiteral("error")).toObject();
        QString message = err.value(QStringLiteral("message")).toString();
        if (message.isEmpty())
            message = obj.value(QStringLiteral("message")).toString();
        emit errorOccurred(message.isEmpty() ? QStringLiteral("PAIRING FAILED") : message.toUpper());
        return;
    }

    const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
    const QString token = data.value(QStringLiteral("token")).toString().trimmed();
    const QString playerName = cleanText(data.value(QStringLiteral("player_name")).toString());
    if (token.isEmpty()) {
        emit errorOccurred(QStringLiteral("PAIRING TOKEN MISSING"));
        return;
    }

    emit pairingSucceeded(serverUrl, token, playerName);
}

void UsenetBackend::handleCategoriesReply(QNetworkReply *reply)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status)) {
        emit errorOccurred(QStringLiteral("SERVER URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        QString error;
        parseJsonRows(body, QStringLiteral("categories"), &error);
        emit errorOccurred(error.isEmpty() ? QStringLiteral("CATEGORY LOAD FAILED") : error);
        return;
    }

    QString error;
    const QVariantList categories = parseCategories(body, &error);
    if (!error.isEmpty()) {
        emit errorOccurred(error);
        return;
    }
    emit categoriesLoaded(categories);
}

void UsenetBackend::handleItemsReply(QNetworkReply *reply, const QString &categoryTitle)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status)) {
        emit errorOccurred(QStringLiteral("SERVER URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        QString error;
        parseJsonRows(body, QStringLiteral("items"), &error);
        emit errorOccurred(error.isEmpty() ? QStringLiteral("BROWSE FAILED") : error);
        return;
    }

    QString error;
    const QVariantList items = parseItems(body, &error);
    if (!error.isEmpty()) {
        emit errorOccurred(error);
        return;
    }
    emit itemsLoaded(categoryTitle, items);
}

void UsenetBackend::handleMusicRowsReply(QNetworkReply *reply, const QString &arrayKey,
                                         const QString &failureMessage)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status)) {
        emit errorOccurred(QStringLiteral("SERVER URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        QString error;
        parseJsonRows(body, arrayKey, &error);
        emit errorOccurred(error.isEmpty() ? failureMessage : error);
        return;
    }

    QString error;
    const QVariantList rows = parseJsonRows(body, arrayKey, &error);
    if (!error.isEmpty()) {
        emit errorOccurred(error);
        return;
    }

    if (arrayKey == QStringLiteral("libraries"))
        emit musicLibrariesLoaded(rows);
    else if (arrayKey == QStringLiteral("albums"))
        emit musicAlbumsLoaded(rows);
    else if (arrayKey == QStringLiteral("tracks"))
        emit musicTracksLoaded(rows);
}

void UsenetBackend::handleActiveStreamsReply(QNetworkReply *reply)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status) || reply->error() != QNetworkReply::NoError || status >= 400)
        return;

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(body, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return;

    QJsonValue data = doc.object().value(QStringLiteral("data"));
    if (data.isObject())
        data = data.toObject().value(QStringLiteral("streams"));
    if (!data.isArray())
        return;

    QVariantList streams;
    const QJsonArray values = data.toArray();
    for (const QJsonValue &value : values) {
        if (value.isObject())
            streams.append(value.toObject().toVariantMap());
    }
    emit activeStreamsLoaded(streams);
}

void UsenetBackend::handleTubeTvLineupReply(QNetworkReply *reply)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status)) {
        emit errorOccurred(QStringLiteral("SERVER URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        QString error;
        parseJsonRows(body, QStringLiteral("channels"), &error);
        emit errorOccurred(error.isEmpty() ? QStringLiteral("TV LINEUP FAILED") : error);
        return;
    }

    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(body, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        emit errorOccurred(QStringLiteral("SERVER RESPONSE INVALID"));
        return;
    }

    QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("success")).isBool() && !obj.value(QStringLiteral("success")).toBool()) {
        const QJsonObject err = obj.value(QStringLiteral("error")).toObject();
        QString message = err.value(QStringLiteral("message")).toString();
        if (message.isEmpty())
            message = obj.value(QStringLiteral("message")).toString();
        emit errorOccurred(message.isEmpty() ? QStringLiteral("TV LINEUP FAILED") : message.toUpper());
        return;
    }

    if (obj.value(QStringLiteral("data")).isObject())
        obj = obj.value(QStringLiteral("data")).toObject();

    QVariantList channels;
    const QJsonArray values = obj.value(QStringLiteral("channels")).toArray();
    for (const QJsonValue &value : values) {
        if (value.isObject())
            channels.append(value.toObject().toVariantMap());
    }

    QVariantMap metadata = obj.toVariantMap();
    metadata.remove(QStringLiteral("channels"));
    emit tubeTvLineupLoaded(channels, metadata);
}

void UsenetBackend::handleStreamsReply(QNetworkReply *reply, const QString &requestId,
                                       const QString &fallbackTitle)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        QString error;
        parseStreams(body, &error);
        if (!error.isEmpty()) {
            emit errorOccurred(error);
            return;
        }
        if (status == 401) {
            emit errorOccurred(QStringLiteral("SERVER AUTH FAILED"));
            return;
        }
        if (status == 408) {
            emit errorOccurred(QStringLiteral("SERVER STILL DOWNLOADING"));
            return;
        }
        emit errorOccurred(QStringLiteral("SERVER STREAM FAILED"));
        return;
    }

    QString error;
    QVariantList streams = parseStreams(body, &error);
    if (!error.isEmpty()) {
        emit errorOccurred(error);
        return;
    }
    if (streams.isEmpty()) {
        emit errorOccurred(QStringLiteral("NO STREAMS FOUND"));
        return;
    }

    for (QVariant &streamValue : streams) {
        QVariantMap stream = streamValue.toMap();
        if (stream.value(QStringLiteral("title")).toString().trimmed().isEmpty())
            stream[QStringLiteral("title")] = fallbackTitle;
        streamValue = stream;
    }
    emit streamsReady(requestId, fallbackTitle, streams);
}

QVariantList UsenetBackend::parseCategories(const QByteArray &data, QString *errorOut) const
{
    if (data.trimmed().startsWith('{'))
        return parseJsonRows(data, QStringLiteral("categories"), errorOut);

    QVariantList rows;
    QXmlStreamReader xml(data);

    while (!xml.atEnd()) {
        xml.readNext();
        if (!xml.isStartElement() || xml.name() != QStringLiteral("category")) {
            if (xml.isStartElement() && xml.name() == QStringLiteral("error") && errorOut) {
                const QString code = attrValue(xml.attributes(), QStringLiteral("code"));
                const QString description = attrValue(xml.attributes(), QStringLiteral("description"));
                *errorOut = cleanText(QStringLiteral("NEWZNAB %1 %2").arg(code, description));
                return {};
            }
            continue;
        }

        const QXmlStreamAttributes attrs = xml.attributes();
        const QString id = attrValue(attrs, QStringLiteral("id"));
        const QString name = cleanText(attrValue(attrs, QStringLiteral("name")));
        if (id.isEmpty() || name.isEmpty())
            continue;

        QVariantList children;
        const bool includeGroup = isMediaCategoryGroup(id, name);
        if (includeGroup) {
            QVariantMap all;
            all[QStringLiteral("id")] = id;
            all[QStringLiteral("title")] = QStringLiteral("All %1").arg(name);
            all[QStringLiteral("fullTitle")] = name;
            all[QStringLiteral("group")] = name;
            all[QStringLiteral("isSubcat")] = false;
            children.append(all);
        }

        while (!(xml.isEndElement() && xml.name() == QStringLiteral("category")) && !xml.atEnd()) {
            xml.readNext();
            if (!xml.isStartElement() || xml.name() != QStringLiteral("subcat"))
                continue;
            const QXmlStreamAttributes subAttrs = xml.attributes();
            const QString subId = attrValue(subAttrs, QStringLiteral("id"));
            const QString subName = cleanText(attrValue(subAttrs, QStringLiteral("name")));
            if (subId.isEmpty() || subName.isEmpty())
                continue;
            if (!includeGroup)
                continue;
            QVariantMap sub;
            sub[QStringLiteral("id")] = subId;
            sub[QStringLiteral("title")] = subName;
            sub[QStringLiteral("fullTitle")] = QStringLiteral("%1 / %2").arg(name, subName);
            sub[QStringLiteral("group")] = name;
            sub[QStringLiteral("isSubcat")] = true;
            children.append(sub);
        }

        if (!includeGroup)
            continue;

        QVariantMap parent;
        parent[QStringLiteral("id")] = id;
        parent[QStringLiteral("title")] = name;
        parent[QStringLiteral("group")] = name;
        parent[QStringLiteral("isGroup")] = true;
        parent[QStringLiteral("children")] = children;
        parent[QStringLiteral("count")] = children.size();
        rows.append(parent);
    }

    if (xml.hasError() && errorOut)
        *errorOut = QStringLiteral("CATEGORY XML INVALID");
    else if (rows.isEmpty() && errorOut)
        *errorOut = QStringLiteral("NO CATEGORIES FOUND");
    return rows;
}

QVariantList UsenetBackend::parseItems(const QByteArray &data, QString *errorOut) const
{
    if (data.trimmed().startsWith('{'))
        return parseJsonRows(data, QStringLiteral("items"), errorOut);

    QVariantList rows;
    QXmlStreamReader xml(data);

    bool inItem = false;
    QVariantMap item;
    QString currentTextElement;
    qint64 size = 0;

    while (!xml.atEnd()) {
        xml.readNext();

        if (xml.isStartElement()) {
            const QString name = xml.name().toString();
            if (name == QStringLiteral("item")) {
                inItem = true;
                item = QVariantMap{};
                size = 0;
                currentTextElement.clear();
                continue;
            }

            if (name == QStringLiteral("error") && errorOut) {
                const QXmlStreamAttributes attrs = xml.attributes();
                const QString code = attrValue(attrs, QStringLiteral("code"));
                const QString description = attrValue(attrs, QStringLiteral("description"));
                *errorOut = cleanText(QStringLiteral("NEWZNAB %1 %2").arg(code, description));
                return {};
            }

            if (!inItem)
                continue;

            if (name == QStringLiteral("title")
                || name == QStringLiteral("link")
                || name == QStringLiteral("guid")
                || name == QStringLiteral("pubDate")
                || name == QStringLiteral("description")) {
                currentTextElement = name;
                continue;
            }

            if (name == QStringLiteral("enclosure")) {
                const QXmlStreamAttributes attrs = xml.attributes();
                const QString url = attrValue(attrs, QStringLiteral("url"));
                if (!url.isEmpty())
                    item[QStringLiteral("nzbUrl")] = url;
                size = qMax(size, attrSizeToInteger(attrValue(attrs, QStringLiteral("length"))));
                continue;
            }

            if (name == QStringLiteral("attr")) {
                const QXmlStreamAttributes attrs = xml.attributes();
                const QString attrName = attrValue(attrs, QStringLiteral("name")).toLower();
                const QString value = attrValue(attrs, QStringLiteral("value"));
                if (attrName == QStringLiteral("size")) {
                    size = qMax(size, attrSizeToInteger(value));
                } else if (attrName == QStringLiteral("category")) {
                    item[QStringLiteral("category")] = cleanText(value);
                } else if (attrName == QStringLiteral("guid")) {
                    item[QStringLiteral("guid")] = value.trimmed();
                } else if (attrName == QStringLiteral("files")) {
                    item[QStringLiteral("files")] = value;
                } else if (attrName == QStringLiteral("grabs")) {
                    item[QStringLiteral("grabs")] = value;
                }
                continue;
            }
        }

        if (xml.isCharacters() && inItem && !currentTextElement.isEmpty()) {
            const QString text = xml.text().toString().trimmed();
            if (text.isEmpty())
                continue;
            if (currentTextElement == QStringLiteral("title"))
                item[QStringLiteral("title")] = cleanText(item.value(QStringLiteral("title")).toString() + text);
            else if (currentTextElement == QStringLiteral("link") && item.value(QStringLiteral("nzbUrl")).toString().isEmpty())
                item[QStringLiteral("nzbUrl")] = text;
            else if (currentTextElement == QStringLiteral("guid"))
                item[QStringLiteral("guid")] = text;
            else if (currentTextElement == QStringLiteral("pubDate"))
                item[QStringLiteral("date")] = cleanText(text);
            else if (currentTextElement == QStringLiteral("description"))
                item[QStringLiteral("description")] = cleanText(text);
        }

        if (xml.isEndElement()) {
            const QString name = xml.name().toString();
            if (inItem && name == currentTextElement)
                currentTextElement.clear();
            if (name == QStringLiteral("item")) {
                inItem = false;
                const QString title = cleanText(item.value(QStringLiteral("title")).toString());
                QString nzbUrl = item.value(QStringLiteral("nzbUrl")).toString().trimmed();
                const QString guid = item.value(QStringLiteral("guid")).toString().trimmed();
                if (!nzbUrl.isEmpty()) {
                    const QUrl candidateUrl(nzbUrl);
                    const QString itemId = omgItemIdFromUrl(nzbUrl);
                    if (!itemId.isEmpty()
                        && isOmgwtfHost(candidateUrl.host())
                        && !candidateUrl.path().startsWith(QStringLiteral("/nzb"),
                                                           Qt::CaseInsensitive)) {
                        nzbUrl = omgNzbUrl(itemId).toString();
                    }
                }
                if (nzbUrl.isEmpty() && !guid.isEmpty()) {
                    const QString itemId = omgItemIdFromUrl(guid);
                    if (!itemId.isEmpty()) {
                        nzbUrl = omgNzbUrl(itemId).toString();
                    } else {
                        nzbUrl = newznabUrl({
                            {QStringLiteral("t"), QStringLiteral("get")},
                            {QStringLiteral("id"), guid}
                        }).toString();
                    }
                }
                if (!title.isEmpty() && !nzbUrl.isEmpty()) {
                    item[QStringLiteral("title")] = title;
                    item[QStringLiteral("nzbUrl")] = ensureNewznabApiKey(nzbUrl);
                    item[QStringLiteral("sizeBytes")] = size;
                    item[QStringLiteral("sizeText")] = formatBytes(size);
                    rows.append(item);
                }
            }
        }
    }

    if (xml.hasError() && errorOut)
        *errorOut = QStringLiteral("BROWSE XML INVALID");
    return rows;
}

QVariantList UsenetBackend::parseStreams(const QByteArray &data, QString *errorOut) const
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(data, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        if (errorOut)
            *errorOut = QStringLiteral("SERVER RESPONSE INVALID");
        return {};
    }

    QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("success")).isBool() && !obj.value(QStringLiteral("success")).toBool()) {
        const QJsonObject err = obj.value(QStringLiteral("error")).toObject();
        QString message = err.value(QStringLiteral("message")).toString();
        if (message.isEmpty())
            message = obj.value(QStringLiteral("message")).toString();
        if (errorOut)
            *errorOut = message.isEmpty() ? QStringLiteral("SERVER STREAM FAILED") : message.toUpper();
        return {};
    }

    if (obj.value(QStringLiteral("data")).isObject())
        obj = obj.value(QStringLiteral("data")).toObject();

    const QJsonArray streamsArray = obj.value(QStringLiteral("streams")).toArray();
    QVariantList streams;
    for (const QJsonValue &value : streamsArray) {
        const QJsonObject streamObj = value.toObject();
        const QString url = streamObj.value(QStringLiteral("url")).toString().trimmed();
        if (url.isEmpty())
            continue;
        QVariantMap stream;
        stream[QStringLiteral("url")] = url;
        stream[QStringLiteral("title")] = cleanText(streamObj.value(QStringLiteral("title")).toString());
        stream[QStringLiteral("name")] = cleanText(streamObj.value(QStringLiteral("name")).toString());
        streams.append(stream);
    }
    return streams;
}

QVariantList UsenetBackend::parseJsonRows(const QByteArray &data, const QString &arrayKey,
                                          QString *errorOut) const
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(data, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        if (errorOut)
            *errorOut = QStringLiteral("SERVER RESPONSE INVALID");
        return {};
    }

    QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("success")).isBool() && !obj.value(QStringLiteral("success")).toBool()) {
        const QJsonObject err = obj.value(QStringLiteral("error")).toObject();
        QString message = err.value(QStringLiteral("message")).toString();
        if (message.isEmpty())
            message = obj.value(QStringLiteral("message")).toString();
        if (errorOut)
            *errorOut = message.isEmpty() ? QStringLiteral("SERVER REQUEST FAILED") : message.toUpper();
        return {};
    }

    if (obj.value(QStringLiteral("data")).isObject())
        obj = obj.value(QStringLiteral("data")).toObject();

    const QJsonArray values = obj.value(arrayKey).toArray();
    QVariantList rows;
    for (const QJsonValue &value : values) {
        if (!value.isObject())
            continue;
        rows.append(value.toObject().toVariantMap());
    }
    return rows;
}

void UsenetBackend::onSettingChanged(const QString &moduleId, const QString &key,
                                     const QVariant &value)
{
    Q_UNUSED(value)
    if (moduleId != QString::fromUtf8(kModuleId))
        return;
    if (key == QStringLiteral("tater_server_url")
        || key == QStringLiteral("tater_server_token")
        || key == QStringLiteral("newznab_url")
        || key == QStringLiteral("newznab_api_key")
        || key == QStringLiteral("omg_username")) {
        emit authStateChanged();
    } else if (key == QStringLiteral("commercial_library_updated_ms")) {
        emit dynamicOptionsReady(QStringLiteral("tube_commercial_categories"),
                                 CommercialLibrary(m_dataRoot).categoryOptions());
    }
}
