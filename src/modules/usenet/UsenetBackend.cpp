#include "UsenetBackend.h"

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

bool isSha256Hex(const QString &value)
{
    static const QRegularExpression re(QStringLiteral("^[0-9a-fA-F]{64}$"));
    return re.match(value.trimmed()).hasMatch();
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

QString UsenetBackend::newznabApiBase() const
{
    QString base = trimmedBaseUrl(setting(QStringLiteral("newznab_url")));
    if (base.isEmpty())
        return QString();

    QUrl url(base);
    if (!url.isValid() || url.scheme().isEmpty())
        url = QUrl(QStringLiteral("http://") + base);

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

QUrl UsenetBackend::newznabUrl(const QVariantMap &params) const
{
    QUrl url(newznabApiBase());
    QUrlQuery query;
    for (auto it = params.constBegin(); it != params.constEnd(); ++it)
        query.addQueryItem(it.key(), it.value().toString());

    const QString apiKey = setting(QStringLiteral("newznab_api_key"));
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
    const QString apiKey = setting(QStringLiteral("newznab_api_key"));
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
        || setting(QStringLiteral("newznab_api_key")).isEmpty()
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
        {QStringLiteral("t"), QStringLiteral("browse")},
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

    QNetworkRequest request(altMountStreamsUrl());
    const QString altKey = setting(QStringLiteral("altmount_api_key"));

    auto *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);

    auto addTextPart = [multi](const QString &name, const QString &value) {
        QHttpPart part;
        part.setHeader(QNetworkRequest::ContentDispositionHeader,
                       QStringLiteral("form-data; name=\"%1\"").arg(name));
        part.setBody(value.toUtf8());
        multi->append(part);
    };

    addTextPart(QStringLiteral("nzb_url"), ensureNewznabApiKey(nzbUrl));
    addTextPart(QStringLiteral("category"), QStringLiteral("tater-tube"));
    addTextPart(QStringLiteral("timeout"), QString::number(streamTimeout()));
    if (isSha256Hex(altKey)) {
        addTextPart(QStringLiteral("download_key"), altKey);
    } else {
        request.setRawHeader("X-Api-Key", altKey.toUtf8());
    }

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
        if (!xml.isStartElement() || xml.name() != QStringLiteral("category"))
            continue;

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
                const QString nzbUrl = item.value(QStringLiteral("nzbUrl")).toString().trimmed();
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
