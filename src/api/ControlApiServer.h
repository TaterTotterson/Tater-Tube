#pragma once

#include <QObject>
#include <QByteArray>
#include <QHash>
#include <QHostAddress>
#include <QJsonObject>
#include <QJsonValue>
#include <QVariantList>
#include <QVariantMap>

class AppCore;
class MpvController;
class EmbyJellyfinBackend;
class MoonlightBackend;
class RetroBackend;
class QTcpServer;
class QTcpSocket;
class QTimer;

class ControlApiServer : public QObject {
    Q_OBJECT

public:
    explicit ControlApiServer(MpvController *player,
                              AppCore *appCore = nullptr,
                              EmbyJellyfinBackend *mediaBackend = nullptr,
                              RetroBackend *retroBackend = nullptr,
                              MoonlightBackend *moonlightBackend = nullptr,
                              QObject *parent = nullptr);

    bool startFromEnvironment();
    bool start(const QHostAddress &address, quint16 port);

private:
    struct HttpRequest {
        QByteArray method;
        QString path;
        QHash<QByteArray, QByteArray> headers;
        QByteArray body;
    };

    void onNewConnection();
    void onReadyRead(QTcpSocket *socket);
    bool tryParseRequest(const QByteArray &buffer, HttpRequest &request) const;
    void handleRequest(QTcpSocket *socket, const HttpRequest &request);

    bool isAuthorized(const HttpRequest &request) const;
    bool handleSetupStaticRequest(QTcpSocket *socket, const HttpRequest &request);
    bool handleSetupApiRequest(QTcpSocket *socket, const HttpRequest &request);
    QJsonObject playbackStatus() const;
    QJsonObject setupStatus() const;
    QJsonObject setupData() const;
    QJsonObject parseBodyObject(const HttpRequest &request, bool &ok) const;
    QVariant jsonValueToSaveValue(const QString &moduleId, const QString &key,
                                  const QJsonValue &value) const;
    bool isSecretSettingKey(const QString &key) const;
    QVariantMap redactedSettingsMap(const QVariantMap &settings) const;
    QString moduleIconAssetPath(const QString &moduleName) const;
    void handleSetupSaveRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupActionRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupEmbyLoginRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupPlexStartRequest(QTcpSocket *socket);
    void handleSetupPlexPollRequest(QTcpSocket *socket);
    void handleSetupPlexSelectRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupRetroConnectRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupMoonlightPairRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupMoonlightStatusRequest(QTcpSocket *socket);
    void handleSetupTubePairRequest(QTcpSocket *socket, const HttpRequest &request);
    QString commercialsRootPath() const;
    QJsonObject commercialsLibrary() const;
    void notifyCommercialLibraryChanged();
    void handleSetupCommercialCategoryRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupCommercialUploadRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupCommercialDeleteFileRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupCommercialDeleteCategoryRequest(QTcpSocket *socket, const HttpRequest &request);
    QJsonArray vodCustomChannels() const;
    void saveVodCustomChannels(const QJsonArray &channels);
    void handleSetupVodCustomChannelsListRequest(QTcpSocket *socket);
    void handleSetupVodCustomChannelSaveRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupVodCustomChannelDeleteRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSetupVodSearchRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleSearchRequest(QTcpSocket *socket, const HttpRequest &request);
    void handleLaunchRequest(QTcpSocket *socket, const HttpRequest &request);
    QString normalizedKey(const QString &key) const;
    void pressKey(const QString &key, int repeat = 1);
    QStringList requestedTypes(const QJsonObject &body) const;
    bool wantsGames(const QStringList &types) const;
    bool wantsMedia(const QStringList &types) const;
    QString percentDecode(const QString &value) const;
    void launchMedia(QTcpSocket *socket, const QString &ratingKey, const QString &kind);
    void launchGame(QTcpSocket *socket, const QString &systemId, const QString &path);
    void startApiTimeline(const QVariantMap &launch);
    void stopApiTimeline(int finalPositionMs, int finalDurationMs);
    void sendApiTimeline(const QString &state, int positionMs = -1, int durationMs = -1);
    void writeBytes(QTcpSocket *socket, int statusCode, const QByteArray &payload,
                    const QByteArray &contentType) const;
    void writeJson(QTcpSocket *socket, int statusCode, const QJsonObject &body) const;
    void writeEmpty(QTcpSocket *socket, int statusCode) const;

    MpvController *m_player = nullptr;
    AppCore *m_appCore = nullptr;
    EmbyJellyfinBackend *m_mediaBackend = nullptr;
    RetroBackend *m_retroBackend = nullptr;
    MoonlightBackend *m_moonlightBackend = nullptr;
    QTcpServer *m_server = nullptr;
    QTimer *m_apiTimelineTimer = nullptr;
    QHash<QTcpSocket *, QByteArray> m_buffers;
    QByteArray m_token;
    QString m_apiTimelineRatingKey;
    QString m_apiTimelinePartKey;
    QString m_moonlightPairCode;
    QString m_moonlightPairMessage;
    bool m_moonlightPairing = false;
    bool m_moonlightPairOk = false;
};
