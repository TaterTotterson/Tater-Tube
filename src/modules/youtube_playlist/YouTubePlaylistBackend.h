#pragma once

#include <QObject>
#include <QVariantList>
#include <QString>

class YouTubePlaylistBackend : public QObject {
    Q_OBJECT

public:
    explicit YouTubePlaylistBackend(const QString &appRoot, const QString &dataRoot,
                                    QObject *parent = nullptr);

    Q_INVOKABLE QString get_auth_state();
    Q_INVOKABLE QString get_saved_playlist_input() const;
    Q_INVOKABLE QString normalize_playlist_input(const QString &input) const;
    Q_INVOKABLE QString ytdl_format_for_quality(const QString &quality) const;
    Q_INVOKABLE void load_playlist(const QString &input);
    Q_INVOKABLE void refresh_playlist_cache();

signals:
    void playlistLoaded(const QString &title, const QVariantList &items);
    void errorOccurred(const QString &message);
    void authStateChanged();

public slots:
    void onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);

private:
    QVariantMap moduleConfig() const;
    QString setting(const QString &key, const QString &fallback = QString()) const;
    QString ytDlpPath() const;
    QString playlistCachePath() const;
    QVariantMap loadPlaylistCache(const QString &playlistUrl) const;
    bool savePlaylistCache(const QString &playlistUrl, const QString &title,
                           const QVariantList &items) const;
    void clearPlaylistCache() const;
    void fetchPlaylist(const QString &input, bool forceRefresh);

    QString m_appRoot;
    QString m_dataRoot;
};
