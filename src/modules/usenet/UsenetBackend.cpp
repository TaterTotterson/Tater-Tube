#include "UsenetBackend.h"

#include <QCryptographicHash>
#include <QFile>
#include <QHttpMultiPart>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>
#include <QUrlQuery>
#include <QXmlStreamReader>

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

QString extractSha256Hex(const QString &value)
{
    static const QRegularExpression re(QStringLiteral("([0-9a-fA-F]{64})"));
    const QRegularExpressionMatch match = re.match(value);
    return match.hasMatch() ? match.captured(1).toLower() : QString();
}

QString hashApiKey(const QString &value)
{
    return QString::fromLatin1(QCryptographicHash::hash(value.toUtf8(), QCryptographicHash::Sha256).toHex());
}

QString stableNzbFilename(QString title, const QString &sourceUrl)
{
    title = cleanText(title);
    title.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]+")), QStringLiteral("_"));
    title.replace(QRegularExpression(QStringLiteral("_+")), QStringLiteral("_"));
    title = title.trimmed();
    while (title.startsWith(QLatin1Char('_')) || title.startsWith(QLatin1Char('.')))
        title.remove(0, 1);
    while (title.endsWith(QLatin1Char('_')) || title.endsWith(QLatin1Char('.')))
        title.chop(1);
    if (title.isEmpty())
        title = QStringLiteral("tater-tube");
    if (title.size() > 80)
        title = title.left(80);

    const QString digest = QString::fromLatin1(
        QCryptographicHash::hash(sourceUrl.toUtf8(), QCryptographicHash::Sha1).toHex().left(12));
    return QStringLiteral("%1-%2.nzb").arg(title, digest);
}

QString newznabErrorMessage(const QByteArray &data)
{
    QXmlStreamReader xml(data);
    while (!xml.atEnd()) {
        xml.readNext();
        if (!xml.isStartElement() || xml.name() != QStringLiteral("error"))
            continue;
        const QString code = attrValue(xml.attributes(), QStringLiteral("code"));
        const QString description = attrValue(xml.attributes(), QStringLiteral("description"));
        return cleanText(QStringLiteral("NEWZNAB %1 %2").arg(code, description));
    }
    return QString();
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

QString UsenetBackend::altMountApiBase() const
{
    QString base = trimmedBaseUrl(setting(QStringLiteral("altmount_url")));
    if (base.isEmpty())
        return QString();

    QUrl url(base);
    if (!url.isValid() || url.scheme().isEmpty())
        url = QUrl(QStringLiteral("http://") + base);

    url.setQuery(QString());
    return url.toString(QUrl::StripTrailingSlash);
}

QString UsenetBackend::altMountDownloadKey() const
{
    const QString value = setting(QStringLiteral("altmount_api_key")).trimmed();
    if (value.isEmpty())
        return QString();

    const QString extracted = extractSha256Hex(value);
    if (!extracted.isEmpty())
        return extracted;

    return hashApiKey(value);
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

QUrl UsenetBackend::altMountStreamsUrl() const
{
    QUrl url(altMountApiBase());
    QString path = url.path();
    while (path.endsWith(QLatin1Char('/')))
        path.chop(1);
    path += QStringLiteral("/api/nzb/streams");
    url.setPath(path);
    url.setQuery(QString());
    return url;
}

QString UsenetBackend::ensureNewznabApiKey(const QString &rawUrl) const
{
    QUrl url(rawUrl.trimmed());
    const QString apiKey = newznabApiKey();
    if (!url.isValid() || apiKey.isEmpty())
        return rawUrl.trimmed();

    QUrlQuery query(url);
    if (!query.hasQueryItem(QStringLiteral("apikey"))) {
        query.addQueryItem(QStringLiteral("apikey"), apiKey);
        url.setQuery(query);
    }
    return url.toString();
}

int UsenetBackend::browseLimit() const
{
    bool ok = false;
    int limit = setting(QStringLiteral("browse_limit"), QStringLiteral("50")).toInt(&ok);
    if (!ok)
        limit = 50;
    return qBound(10, limit, 100);
}

int UsenetBackend::streamTimeout() const
{
    bool ok = false;
    int timeout = setting(QStringLiteral("stream_timeout"), QStringLiteral("300")).toInt(&ok);
    if (!ok)
        timeout = 300;
    return qBound(60, timeout, 900);
}

QString UsenetBackend::get_auth_state()
{
    return newznabApiBase().isEmpty()
        || newznabApiKey().isEmpty()
        || altMountApiBase().isEmpty()
        || setting(QStringLiteral("altmount_api_key")).isEmpty()
        ? QStringLiteral("none")
        : QStringLiteral("authed");
}

QVariantMap UsenetBackend::get_setup_status()
{
    QVariantMap status;
    status[QStringLiteral("newznabUrl")] = setting(QStringLiteral("newznab_url"));
    status[QStringLiteral("newznabApiKey")] = setting(QStringLiteral("newznab_api_key"));
    status[QStringLiteral("altmountUrl")] = setting(QStringLiteral("altmount_url"));
    status[QStringLiteral("altmountApiKey")] = setting(QStringLiteral("altmount_api_key"));
    status[QStringLiteral("configured")] = get_auth_state() == QStringLiteral("authed");
    return status;
}

void UsenetBackend::load_categories()
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER USENET SETTINGS"));
        return;
    }

    QNetworkRequest request(newznabUrl({
        {QStringLiteral("t"), QStringLiteral("caps")}
    }));
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCategoriesReply(reply);
    });
}

void UsenetBackend::load_items(const QString &categoryId, const QString &categoryTitle)
{
    if (get_auth_state() != QStringLiteral("authed")) {
        emit errorOccurred(QStringLiteral("ENTER USENET SETTINGS"));
        return;
    }

    QNetworkRequest request(newznabUrl({
        {QStringLiteral("t"), QStringLiteral("search")},
        {QStringLiteral("cat"), categoryId},
        {QStringLiteral("extended"), QStringLiteral("1")},
        {QStringLiteral("limit"), QString::number(browseLimit())}
    }));
    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, categoryTitle]() {
        handleItemsReply(reply, categoryTitle);
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
    if (altMountApiBase().isEmpty() || setting(QStringLiteral("altmount_api_key")).isEmpty()) {
        emit errorOccurred(QStringLiteral("ENTER ALTMOUNT SETTINGS"));
        return;
    }

    const QString downloadUrl = ensureNewznabApiKey(nzbUrl);
    QNetworkRequest nzbRequest{QUrl(downloadUrl)};
    QNetworkReply *nzbReply = m_network.get(nzbRequest);
    connect(nzbReply, &QNetworkReply::finished, this,
            [this, nzbReply, requestId, title, downloadUrl]() {
        nzbReply->deleteLater();
        const QByteArray body = nzbReply->readAll();
        const int status = nzbReply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (nzbReply->error() != QNetworkReply::NoError || status >= 400) {
            emit errorOccurred(QStringLiteral("NZB DOWNLOAD FAILED"));
            return;
        }
        if (body.trimmed().isEmpty()) {
            emit errorOccurred(QStringLiteral("NZB DOWNLOAD EMPTY"));
            return;
        }

        const QString newznabError = newznabErrorMessage(body);
        if (!newznabError.isEmpty()) {
            emit errorOccurred(newznabError);
            return;
        }

        postNzbToAltMount(requestId, title, downloadUrl, body);
    });
}

void UsenetBackend::postNzbToAltMount(const QString &requestId, const QString &title,
                                      const QString &sourceUrl, const QByteArray &nzbData)
{
    QNetworkRequest request(altMountStreamsUrl());
    const QString downloadKey = altMountDownloadKey();

    auto *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);

    auto addTextPart = [multi](const QString &name, const QString &value) {
        QHttpPart part;
        part.setHeader(QNetworkRequest::ContentDispositionHeader,
                       QStringLiteral("form-data; name=\"%1\"").arg(name));
        part.setBody(value.toUtf8());
        multi->append(part);
    };

    QHttpPart filePart;
    filePart.setHeader(QNetworkRequest::ContentDispositionHeader,
                       QStringLiteral("form-data; name=\"file\"; filename=\"%1\"")
                           .arg(stableNzbFilename(title, sourceUrl)));
    filePart.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/x-nzb"));
    filePart.setBody(nzbData);
    multi->append(filePart);

    addTextPart(QStringLiteral("category"), QStringLiteral("tater-tube"));
    addTextPart(QStringLiteral("timeout"), QString::number(streamTimeout()));
    addTextPart(QStringLiteral("download_key"), downloadKey);

    QNetworkReply *reply = m_network.post(request, multi);
    multi->setParent(reply);
    connect(reply, &QNetworkReply::finished, this, [this, reply, requestId, title]() {
        handleStreamsReply(reply, requestId, title);
    });
}

void UsenetBackend::handleCategoriesReply(QNetworkReply *reply)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (isRedirectStatus(status)) {
        emit errorOccurred(QStringLiteral("NEWZNAB URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        emit errorOccurred(QStringLiteral("CATEGORY LOAD FAILED"));
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
        emit errorOccurred(QStringLiteral("NEWZNAB URL NEEDS HTTPS"));
        return;
    }
    if (reply->error() != QNetworkReply::NoError || status >= 400) {
        emit errorOccurred(QStringLiteral("BROWSE FAILED"));
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
            emit errorOccurred(QStringLiteral("ALTMOUNT AUTH FAILED"));
            return;
        }
        if (status == 408) {
            emit errorOccurred(QStringLiteral("ALTMOUNT STILL DOWNLOADING"));
            return;
        }
        emit errorOccurred(QStringLiteral("ALTMOUNT STREAM FAILED"));
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

        QVariantMap parent;
        parent[QStringLiteral("id")] = id;
        parent[QStringLiteral("title")] = name;
        parent[QStringLiteral("group")] = name;
        parent[QStringLiteral("isSubcat")] = false;
        rows.append(parent);

        while (!(xml.isEndElement() && xml.name() == QStringLiteral("category")) && !xml.atEnd()) {
            xml.readNext();
            if (!xml.isStartElement() || xml.name() != QStringLiteral("subcat"))
                continue;
            const QXmlStreamAttributes subAttrs = xml.attributes();
            const QString subId = attrValue(subAttrs, QStringLiteral("id"));
            const QString subName = cleanText(attrValue(subAttrs, QStringLiteral("name")));
            if (subId.isEmpty() || subName.isEmpty())
                continue;
            QVariantMap sub;
            sub[QStringLiteral("id")] = subId;
            sub[QStringLiteral("title")] = QStringLiteral("%1 / %2").arg(name, subName);
            sub[QStringLiteral("group")] = name;
            sub[QStringLiteral("isSubcat")] = true;
            rows.append(sub);
        }
    }

    if (xml.hasError() && errorOut)
        *errorOut = QStringLiteral("CATEGORY XML INVALID");
    else if (rows.isEmpty() && errorOut)
        *errorOut = QStringLiteral("NO CATEGORIES FOUND");
    return rows;
}

QVariantList UsenetBackend::parseItems(const QByteArray &data, QString *errorOut) const
{
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
                if (nzbUrl.isEmpty() && !guid.isEmpty()) {
                    nzbUrl = newznabUrl({
                        {QStringLiteral("t"), QStringLiteral("get")},
                        {QStringLiteral("id"), guid}
                    }).toString();
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
            *errorOut = QStringLiteral("ALTMOUNT RESPONSE INVALID");
        return {};
    }

    QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("success")).isBool() && !obj.value(QStringLiteral("success")).toBool()) {
        const QJsonObject err = obj.value(QStringLiteral("error")).toObject();
        QString message = err.value(QStringLiteral("message")).toString();
        if (message.isEmpty())
            message = obj.value(QStringLiteral("message")).toString();
        if (errorOut)
            *errorOut = message.isEmpty() ? QStringLiteral("ALTMOUNT STREAM FAILED") : message.toUpper();
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

void UsenetBackend::onSettingChanged(const QString &moduleId, const QString &key,
                                     const QVariant &value)
{
    Q_UNUSED(value)
    if (moduleId != QString::fromUtf8(kModuleId))
        return;
    if (key == QStringLiteral("newznab_url")
        || key == QStringLiteral("newznab_api_key")
        || key == QStringLiteral("altmount_url")
        || key == QStringLiteral("altmount_api_key")) {
        emit authStateChanged();
    }
}
