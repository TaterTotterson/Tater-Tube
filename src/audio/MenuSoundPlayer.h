#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QObject>
#include <QSet>
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
    Q_INVOKABLE void setContextActive(const QString &context, bool active);

public slots:
    void playNarration(const QByteArray &wavData, quint64 generation);
    void stopNarration();
    void setNarrationVolume(double volume);
    void setNarrationMuted(bool muted);

signals:
    void narrationFinished(quint64 generation);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    enum class Cue { None, Move, Page, Back, Select };

    void reloadSettings();
    void loadPack(const QString &packSlug);
    QByteArray loadWave(const QString &path) const;
    QByteArray decodeWave(const QByteArray &wavData) const;
    QByteArray convertAudio(const SDL_AudioSpec &spec, const Uint8 *buffer,
                            Uint32 length, const QString &description) const;
    bool openAudioDevice();
    void closeAudioDevice();
    void play(Cue cue);
    static void audioCallback(void *userdata, Uint8 *stream, int length);
    void mixAudio(Uint8 *stream, int length);
    static void mixBuffer(const QByteArray &source, qsizetype &offset,
                          Uint8 *stream, int length, double gain);
    const QByteArray &soundForCue(Cue cue) const;
    static Cue cueForKey(int key);
    static QString packSlugForSetting(const QString &value);
    static bool settingEnabled(const QVariant &value, bool fallback);
    static bool isTextEditingFocus(QObject *focusObject);

    QString m_appRoot;
    QString m_piAlsaDevice;
    AppCore *m_appCore = nullptr;
    QString m_packSlug = QStringLiteral("soft-touch");
    bool m_enabled = true;
    QSet<QString> m_activeContexts;
    bool m_audioSubsystemReady = false;
    bool m_audioWarningShown = false;
    SDL_AudioDeviceID m_audioDevice = 0;
    QByteArray m_moveSound;
    QByteArray m_pageSound;
    QByteArray m_backSound;
    QByteArray m_selectSound;
    QByteArray m_activeCueSound;
    QByteArray m_narrationSound;
    qsizetype m_activeCueOffset = 0;
    qsizetype m_narrationOffset = 0;
    quint64 m_narrationGeneration = 0;
    double m_narrationGain = 1.0;
    bool m_narrationMuted = false;
    QElapsedTimer m_lastSoundTimer;
};
