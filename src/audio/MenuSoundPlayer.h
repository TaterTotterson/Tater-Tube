#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QVariant>
#include <SDL.h>

class AppCore;

class MenuSoundPlayer : public QObject {
    Q_OBJECT

public:
    explicit MenuSoundPlayer(const QString &appRoot, AppCore *appCore,
                             QObject *parent = nullptr);
    ~MenuSoundPlayer() override;

    void setPlaybackActive(bool active);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    enum class Cue { None, Move, Page, Back, Select };

    void reloadSettings();
    void loadPack(const QString &packSlug);
    QByteArray loadWave(const QString &path) const;
    bool openAudioDevice();
    void closeAudioDevice();
    void play(Cue cue);
    const QByteArray &soundForCue(Cue cue) const;
    static Cue cueForKey(int key);
    static QString packSlugForSetting(const QString &value);
    static bool settingEnabled(const QVariant &value, bool fallback);
    static bool isTextEditingFocus(QObject *focusObject);

    QString m_appRoot;
    AppCore *m_appCore = nullptr;
    QString m_packSlug = QStringLiteral("soft-touch");
    bool m_enabled = true;
    bool m_playbackActive = false;
    bool m_audioSubsystemReady = false;
    bool m_audioWarningShown = false;
    SDL_AudioDeviceID m_audioDevice = 0;
    QByteArray m_moveSound;
    QByteArray m_pageSound;
    QByteArray m_backSound;
    QByteArray m_selectSound;
    QElapsedTimer m_lastSoundTimer;
};
