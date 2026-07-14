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
    Q_INVOKABLE void load_continue_watching();
    Q_INVOKABLE void load_music_libraries();
    Q_INVOKABLE void load_music_albums(const QString &categoryId);
    Q_INVOKABLE void load_music_tracks(const QString &albumId);
    Q_INVOKABLE void load_active_streams();
    Q_INVOKABLE void load_tube_tv_lineup();
    Q_INVOKABLE void request_streams(const QString &requestId, const QVariantMap &item);
    Q_INVOKABLE void save_play_state(const QVariantMap &state);
    Q_INVOKABLE QString playback_url(const QString &url, int screenWidth, int screenHeight) const;
    Q_INVOKABLE bool uses_server_seek() const;
    Q_INVOKABLE QVariantList get_commercial_videos_for_setting(const QString &settingKey) const;
    Q_INVOKABLE QVariantList get_commercial_videos_for_category(const QString &categoryId) const;
    Q_INVOKABLE void load_tube_commercial_category_options();

signals:
    void authStateChanged();
    void categoriesLoaded(const QVariantList &categories);
    void itemsLoaded(const QString &categoryTitle, const QVariantList &items);
    void musicLibrariesLoaded(const QVariant &libraries);
    void musicAlbumsLoaded(const QVariant &albums);
    void musicTracksLoaded(const QVariant &tracks);
    void activeStreamsLoaded(const QVariantList &streams);
    void tubeTvLineupLoaded(const QVariantList &channels, const QVariantMap &metadata);
    void streamsReady(const QString &requestId, const QString &title, const QVariantList &streams);
    void pairingSucceeded(const QString &serverUrl, const QString &token, const QString &playerName);
    void errorOccurred(const QString &message);
    void dynamicOptionsReady(const QString &key, const QVariant &options);

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
    QString playbackTranscodeProfile(int screenWidth, int screenHeight) const;

    void handleCategoriesReply(QNetworkReply *reply);
    void handleItemsReply(QNetworkReply *reply, const QString &categoryTitle);
    void handleMusicRowsReply(QNetworkReply *reply, const QString &arrayKey,
                              const QString &failureMessage);
    void handleActiveStreamsReply(QNetworkReply *reply);
    void handleTubeTvLineupReply(QNetworkReply *reply);
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
