#pragma once

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QMap>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QtGlobal>

struct GamePortRomRequirement {
    QString label;
    QString fileName;
    QString hashAlgorithm;
    QByteArray hashHex;
    qint64 size = -1;
};

struct GamePortDefinition {
    QString id;
    QString title;
    QString sourceUrl;
    QString engineEnvironment;
    QString distribution;
    QString romValidation = QStringLiteral("hash");
    QString romAccess = QStringLiteral("copy");
    QStringList romFolders;
    QStringList romExtensions;
    QList<GamePortRomRequirement> romRequirements;
    QMap<QString, QStringList> executables;
    QStringList validationArguments;
    QStringList launchArguments;
    QStringList crtLaunchArguments;
};

class GamePortCatalog {
public:
    static QList<GamePortDefinition> load(const QString &appRoot,
                                          QStringList *errors = nullptr);
    static QString currentPlatformKey();
    static QStringList executableNames(const GamePortDefinition &port);
    static QString findEngine(const GamePortDefinition &port,
                              const QString &appRoot,
                              const QString &dataRoot,
                              const QString &configuredPath = QString());
    static QStringList findRomCandidates(const GamePortDefinition &port,
                                         const QString &gamesRoot);
    static bool remotePathCanProvideRom(const GamePortDefinition &port,
                                        const QString &relativePath);
    static bool romMatches(const GamePortDefinition &port,
                           const QString &path,
                           QString *stagedFileName = nullptr,
                           QHash<QString, QByteArray> *hashCache = nullptr,
                           const QString &enginePath = QString());
    static QString findMatchingRom(const GamePortDefinition &port,
                                   const QStringList &candidates,
                                   QString *stagedFileName = nullptr,
                                   QHash<QString, QByteArray> *hashCache = nullptr,
                                   const QString &enginePath = QString());
    static QString portUserRoot(const QString &dataRoot,
                                const GamePortDefinition &port);
    static QString stagedRomPath(const QString &dataRoot,
                                 const GamePortDefinition &port,
                                 const QString &fileName);
    static bool stageRom(const GamePortDefinition &port,
                         const QString &sourcePath,
                         const QString &dataRoot,
                         QString *stagedPath,
                         QString *error,
                         const QString &enginePath = QString());
    static QStringList launchArguments(const GamePortDefinition &port,
                                       const QString &enginePath,
                                       const QString &romPath,
                                       const QString &savePath,
                                       const QSize &displaySize = QSize());
    static QSize compositeDisplayMode(const QString &kernelCommandLine);
};
