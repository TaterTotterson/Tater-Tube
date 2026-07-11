#pragma once

#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class QNetworkReply;

class UsenetBackend : public QObject {
    Q_OBJECT

public:
    explicit UsenetBackend(const QString &appRoot, const QString &dataRoot,
                           QObject *parent = nullptr);

    Q_INVOKABLE QString get_auth_state();
    Q_INVOKABLE QVariantMap get_setup_status();
    Q_INVOKABLE void pair_server(const QString &serverUrl, const QString &pin);
    Q_INVOKABLE void load_categories();
    Q_INVOKABLE void load_items(const QString &categoryId, const QString &categoryTitle);
    Q_INVOKABLE void load_local_items(const QString &categoryId, const QString &path,
                                      int sourceIndex, const QString &categoryTitle);
    Q_INVOKABLE void search_items(const QString &query);
    Q_INVOKABLE void load_discover(const QString &catalogId, const QString &title);
    Q_INVOKABLE void load_trending(const QString &category, const QString &timePeriod,
                                   const QString &title);
    Q_INVOKABLE void request_streams(const QString &requestId, const QVariantMap &item);

signals:
    void authStateChanged();
    void categoriesLoaded(const QVariantList &categories);
    void itemsLoaded(const QString &categoryTitle, const QVariantList &items);
    void streamsReady(const QString &requestId, const QString &title, const QVariantList &streams);
    void pairingSucceeded(const QString &serverUrl, const QString &token, const QString &playerName);
    void errorOccurred(const QString &message);

public slots:
    void onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);

private:
    QVariantMap moduleConfig() const;
    QString setting(const QString &key, const QString &fallback = QString()) const;
    QString newznabApiKey() const;
    QString omgUsername() const;
    QString newznabApiBase() const;
    QString serverApiBase() const;
    QString serverPlayerToken() const;
    QUrl newznabUrl(const QVariantMap &params) const;
    QUrl omgNzbUrl(const QString &id) const;
    QUrl omgTrendingUrl(const QString &category, const QString &timePeriod) const;
    QUrl taterApiUrlFromBase(const QString &baseUrl, const QString &path,
                             const QVariantMap &params = {}) const;
    QUrl taterApiUrl(const QString &path, const QVariantMap &params = {}) const;
    void addTaterAuthHeader(QNetworkRequest &request) const;
    QString ensureNewznabApiKey(const QString &url) const;
    int browseLimit() const;
    int streamTimeout() const;

    void handleCategoriesReply(QNetworkReply *reply);
    void handleItemsReply(QNetworkReply *reply, const QString &categoryTitle);
    void handleStreamsReply(QNetworkReply *reply, const QString &requestId,
                            const QString &fallbackTitle);
    void handlePairingReply(QNetworkReply *reply, const QString &serverUrl);
    QVariantList parseCategories(const QByteArray &data, QString *errorOut) const;
    QVariantList parseItems(const QByteArray &data, QString *errorOut) const;
    QVariantList parseStreams(const QByteArray &data, QString *errorOut) const;
    QVariantList parseJsonRows(const QByteArray &data, const QString &arrayKey,
                               QString *errorOut) const;

    QString m_appRoot;
    QString m_dataRoot;
    QNetworkAccessManager m_network;
};
