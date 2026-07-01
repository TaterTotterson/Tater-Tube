#pragma once

#include <QNetworkAccessManager>
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
    Q_INVOKABLE void load_categories();
    Q_INVOKABLE void load_items(const QString &categoryId, const QString &categoryTitle);
    Q_INVOKABLE void request_streams(const QString &requestId, const QVariantMap &item);

signals:
    void authStateChanged();
    void categoriesLoaded(const QVariantList &categories);
    void itemsLoaded(const QString &categoryTitle, const QVariantList &items);
    void streamsReady(const QString &requestId, const QString &title, const QVariantList &streams);
    void errorOccurred(const QString &message);

public slots:
    void onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);

private:
    QVariantMap moduleConfig() const;
    QString setting(const QString &key, const QString &fallback = QString()) const;
    QString newznabApiBase() const;
    QString altMountApiBase() const;
    QUrl newznabUrl(const QVariantMap &params) const;
    QUrl altMountStreamsUrl() const;
    QString ensureNewznabApiKey(const QString &url) const;
    int browseLimit() const;
    int streamTimeout() const;

    void handleCategoriesReply(QNetworkReply *reply);
    void handleItemsReply(QNetworkReply *reply, const QString &categoryTitle);
    void handleStreamsReply(QNetworkReply *reply, const QString &requestId,
                            const QString &fallbackTitle);
    QVariantList parseCategories(const QByteArray &data, QString *errorOut) const;
    QVariantList parseItems(const QByteArray &data, QString *errorOut) const;
    QVariantList parseStreams(const QByteArray &data, QString *errorOut) const;

    QString m_appRoot;
    QString m_dataRoot;
    QNetworkAccessManager m_network;
};
