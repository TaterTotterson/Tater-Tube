#pragma once

#include <QObject>
#include <QVariant>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonValue>
#include <QUrl>
#include <QXmlStreamReader>
#include <functional>

class EmbyJellyfinBackend : public QObject {
    Q_OBJECT

public:
    explicit EmbyJellyfinBackend(const QString &appRoot, const QString &dataRoot,
                                 QObject *parent = nullptr);

    Q_INVOKABLE QString get_auth_state();
    Q_INVOKABLE QString get_active_user_name();
    Q_INVOKABLE QString get_active_server_name();
    Q_INVOKABLE QString get_saved_server_url();
    Q_INVOKABLE QString get_media_provider();

    Q_INVOKABLE void login(const QString &serverUrl, const QString &username,
                           const QString &password);
    Q_INVOKABLE void start_plex_pin_login();
    Q_INVOKABLE void poll_plex_pin_login();
    Q_INVOKABLE void select_plex_server(const QString &machineIdentifier);
    Q_INVOKABLE void logout();

    Q_INVOKABLE void load_libraries();
    Q_INVOKABLE void load_music_libraries();
    Q_INVOKABLE void load_music_albums(const QString &sectionId);
    Q_INVOKABLE void load_music_tracks(const QString &sectionId);
    Q_INVOKABLE void load_continue_watching();
    Q_INVOKABLE void load_section_hubs(const QString &sectionId);
    Q_INVOKABLE void load_items_for_hub(const QString &hubKey);
    Q_INVOKABLE void load_library_all(const QString &sectionId);
    Q_INVOKABLE void load_collections(const QString &sectionId);
    Q_INVOKABLE void load_collection_items(const QString &ratingKey);
    Q_INVOKABLE void load_playlists(const QString &sectionId);
    Q_INVOKABLE void load_playlist_items(const QString &ratingKey);
    Q_INVOKABLE void load_categories(const QString &sectionId);
    Q_INVOKABLE void load_category_items(const QString &sectionId, const QString &filterKey);
    Q_INVOKABLE void check_section_capabilities(const QString &sectionId);
    Q_INVOKABLE void load_children(const QString &ratingKey);
    Q_INVOKABLE void load_on_deck_for(const QString &ratingKey);
    Q_INVOKABLE void load_next_episode(const QString &currentRatingKey);
    Q_INVOKABLE void load_live_tv_channels();
    Q_INVOKABLE void request_live_tv_stream(const QString &channelId,
                                            const QString &sessionId,
                                            bool forceTranscode);
    Q_INVOKABLE void stop_live_tv_stream(bool failed = false);

    Q_INVOKABLE void load_item_detail(const QString &ratingKey);
    Q_INVOKABLE void build_stream_url(const QString &ratingKey, const QString &partKey,
                                      const QString &sessionId);
    Q_INVOKABLE void build_audio_stream_url(const QString &ratingKey,
                                            const QString &mediaSourceId);
    Q_INVOKABLE void request_transcode(const QString &ratingKey, const QString &partKey,
                                       const QString &sessionId,
                                       const QString &audioId, const QString &subtitleId,
                                       int offsetMs);
    Q_INVOKABLE void update_timeline(const QString &ratingKey, const QString &partKey,
                                     const QString &state, int timeMs, int durationMs);
    Q_INVOKABLE void set_audio_stream(const QString &streamId, const QString &partId);
    Q_INVOKABLE void set_subtitle_stream(const QString &streamId, const QString &partId);

    Q_INVOKABLE void getLibraries();
    Q_INVOKABLE void getVideoQualities();
    Q_INVOKABLE void get_resume_playback_options();
    Q_INVOKABLE void api_search_media(const QString &requestId,
                                      const QString &query,
                                      const QStringList &types,
                                      int limit);
    Q_INVOKABLE void api_prepare_media_launch(const QString &requestId,
                                              const QString &ratingKey,
                                              const QString &kind);

public slots:
    void onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);

signals:
    void authSuccess();
    void plexPinReady(const QString &code, const QString &linkUrl);
    void plexServersLoaded(const QVariant &servers);
    void logoutComplete();
    void authStateChanged();

    void librariesLoaded(const QVariant &libraries);
    void musicLibrariesLoaded(const QVariant &libraries);
    void musicAlbumsLoaded(const QVariant &albums);
    void musicTracksLoaded(const QVariant &items);
    void continueWatchingLoaded(const QVariant &items);
    void hubsLoaded(const QVariant &hubs);
    void itemsLoaded(const QVariant &items);
    void collectionsLoaded(const QVariant &collections);
    void playlistsLoaded(const QVariant &playlists);
    void categoriesLoaded(const QVariant &categories);
    void capabilitiesLoaded(const QVariant &capabilities);

    void itemLoaded(const QVariant &detail);
    void streamUrlReady(const QString &url, const QString &httpHeaderFields);
    void audioStreamUrlReady(const QString &itemId,
                             const QString &url,
                             const QString &httpHeaderFields);
    void childrenLoaded(const QVariant &items);
    void inProgressEpisodeLoaded(const QVariant &item);
    void nextEpisodeReady(const QVariant &detail);
    void liveTvChannelsLoaded(const QVariant &channels);
    void liveTvStreamReady(const QString &channelId,
                           const QString &url,
                           const QString &httpHeaderFields);

    void dynamicOptionsReady(const QString &key, const QVariant &options);
    void errorOccurred(const QString &message);
    void apiSearchResultsReady(const QString &requestId, const QVariantList &results);
    void apiLaunchStreamReady(const QString &requestId,
                              const QVariantMap &launch,
                              const QString &url,
                              const QString &httpHeaderFields);
    void apiRequestFailed(const QString &requestId, const QString &message);

private:
    QJsonObject loadAuth() const;
    void saveAuth(const QJsonObject &auth) const;
    QJsonObject loadPlexAuth() const;
    void savePlexAuth(const QJsonObject &auth) const;
    QJsonObject loadConfig() const;

    QString clientId() const;
    QString plexClientId() const;
    QString mediaProvider() const;
    QString serverUrl() const;
    QString accessToken() const;
    QString userId() const;
    QString videoQuality() const;

    static QString normalizeServerUrl(const QString &raw);
    static QString itemType(const QJsonObject &item);
    static bool codecNeedsTranscode(const QString &codec);
    static QString msToDisplay(int ms);
    static qint64 ticksToMs(const QJsonValue &ticks);
    static qint64 msToTicks(int ms);
    static QString plexAttr(const QXmlStreamAttributes &attrs, const QString &name);
    static int plexIntAttr(const QXmlStreamAttributes &attrs, const QString &name,
                           int fallback = 0);

    QNetworkRequest apiRequest(const QUrl &url, const QString &token = {}) const;
    QNetworkReply *apiGet(const QUrl &url, const QString &token = {});
    QNetworkReply *apiPostJson(const QUrl &url, const QString &token,
                               const QByteArray &body);
    QNetworkReply *apiPostJson(const QUrl &url, const QByteArray &body);

    QUrl apiUrl(const QString &path) const;
    QUrl itemListUrl(const QString &parentId, const QString &includeTypes,
                     bool recursive = true) const;
    QNetworkRequest plexTvRequest(const QUrl &url, const QString &token = {}) const;
    QNetworkReply *plexTvGet(const QUrl &url, const QString &token = {});
    QNetworkReply *plexTvPostForm(const QUrl &url, const QByteArray &body,
                                  const QString &token = {});
    QNetworkRequest plexServerRequest(const QUrl &url) const;
    QNetworkReply *plexServerGet(const QUrl &url);
    QUrl plexApiUrl(const QString &path) const;
    QUrl plexUrlWithToken(QUrl url) const;
    QString plexAbsoluteUrl(const QString &pathOrUrl) const;
    QString plexServerUrl() const;
    QString plexToken() const;
    void finishPlexLogin(const QString &token);
    void fetchPlexServers(const QString &token);
    void saveSelectedPlexServer(const QVariantMap &server);
    QVariantList parsePlexLibraries(const QByteArray &body, bool musicOnly = false) const;
    QVariantList parsePlexItems(const QByteArray &body) const;
    QVariantMap parsePlexDetail(const QByteArray &body) const;
    QVariantMap formatPlexItem(const QXmlStreamAttributes &attrs) const;
    QVariantMap formatPlexMusicAlbum(const QXmlStreamAttributes &attrs) const;
    void plexLoadLibraries();
    void plexLoadMusicLibraries();
    void plexLoadMusicAlbums(const QString &sectionId);
    void plexLoadMusicTracks(const QString &albumId);
    void plexLoadLibraryAll(const QString &sectionId);
    void plexLoadChildren(const QString &ratingKey);
    void plexLoadItemDetail(const QString &ratingKey);
    void plexBuildStreamUrl(const QString &ratingKey, const QString &partKey);
    void plexBuildAudioStreamUrl(const QString &ratingKey, const QString &partKey);
    void plexRequestTranscodeUrl(const QString &ratingKey,
                                 const QString &partKey,
                                 const QString &sessionId,
                                 const QString &audioId,
                                 const QString &subtitleId,
                                 int offsetMs,
                                 std::function<void(const QString &url,
                                                    const QString &httpHeaderFields)> onReady,
                                 std::function<void(const QString &message)> onError);
    QString plexTranscodeQuality() const;
    QString plexHttpHeaderFields() const;
    void plexLoadNextEpisode(const QString &currentRatingKey);
    void requestPlaybackInfo(const QString &ratingKey, const QString &partKey,
                             const QString &sessionId, const QString &audioId,
                             const QString &subtitleId, int offsetMs,
                             bool forceTranscode);
    QJsonObject playbackDeviceProfile(bool forceTranscode,
                                      const QString &quality = {}) const;
    QJsonObject playbackInfoPayload(const QString &partKey,
                                    const QString &audioId,
                                    const QString &subtitleId,
                                    int offsetMs,
                                    bool forceTranscode,
                                    const QString &quality = {}) const;
    QString playbackUrlFromInfo(const QJsonObject &info,
                                const QString &ratingKey,
                                const QString &partKey,
                                const QString &sessionId,
                                const QString &audioId,
                                const QString &subtitleId,
                                bool forceTranscode,
                                QJsonObject *selectedSource,
                                const QString &quality = {}) const;
    QString absoluteMediaUrl(const QString &pathOrUrl) const;
    QString withAccessToken(const QString &url) const;
    QString httpHeaderFieldsFor(const QJsonObject &mediaSource) const;
    QString streamUrlFor(const QString &itemId, const QString &mediaSourceId,
                         const QString &playSessionId,
                         const QString &audioIndex = {},
                         const QString &subtitleIndex = {},
                         bool transcode = false,
                         const QString &quality = {}) const;
    QString subtitleUrlFor(const QString &itemId, const QString &mediaSourceId,
                           int streamIndex, const QString &codec) const;

    QVariantMap formatItem(const QJsonObject &item) const;
    QVariantMap formatMusicAlbum(const QJsonObject &item) const;
    QVariantMap formatMusicTrack(const QJsonObject &item) const;
    QVariantMap formatApiMediaResult(const QVariantMap &item) const;
    QVariantMap buildItemDetail(const QJsonObject &item) const;
    QVariantList formatItems(const QJsonArray &items) const;
    QVariantList apiFilterMediaResults(const QVariantList &items,
                                       const QStringList &types,
                                       int limit) const;
    void apiPrepareDetailPlayback(const QString &requestId,
                                  const QVariantMap &detail);
    void apiPrepareShowPlayback(const QString &requestId,
                                const QString &ratingKey);
    void apiPreparePlexShowPlayback(const QString &requestId,
                                    const QString &ratingKey);
    void fetchServerInfoThenFinishLogin(QJsonObject auth);
    void fetchEpisodesForSeries(const QString &seriesId,
                                std::function<void(QJsonArray)> callback);
    void closeLiveTvStream(const QString &itemId, const QString &mediaSourceId,
                           const QString &liveStreamId, const QString &playSessionId,
                           bool failed);
    void closeActiveLiveTvStream(bool failed);

    QString m_appRoot;
    QString m_dataRoot;
    QNetworkAccessManager *m_nam = nullptr;
    mutable QString m_clientId;
    mutable QString m_plexClientId;
    int m_plexPinId = 0;
    QString m_plexPinCode;
    QString m_pendingPlexToken;
    QVariantList m_pendingPlexServers;
    int m_liveTvRequestSerial = 0;
    QString m_liveTvItemId;
    QString m_liveTvMediaSourceId;
    QString m_liveTvLiveStreamId;
    QString m_liveTvPlaySessionId;
};
