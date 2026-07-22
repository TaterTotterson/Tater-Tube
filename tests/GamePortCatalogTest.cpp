#include "modules/retro/GamePortCatalog.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

class GamePortCatalogTest : public QObject {
    Q_OBJECT

private slots:
    void discoversValidatesAndStagesPort();
    void reusesHashesAcrossRequirementsAndPorts();
    void streamsEngineValidatedDiscWithoutCopying();
    void detectsCompositeDisplayModes();
};

void GamePortCatalogTest::discoversValidatesAndStagesPort()
{
    QTemporaryDir temporary;
    QVERIFY(temporary.isValid());

    const QString appRoot = temporary.filePath(QStringLiteral("app"));
    const QString dataRoot = temporary.filePath(QStringLiteral("data"));
    const QString gamesRoot = temporary.filePath(QStringLiteral("games"));
    const QString engineRoot = temporary.filePath(QStringLiteral("engines"));
    QVERIFY(QDir().mkpath(QDir(appRoot).filePath(QStringLiteral("modules/retro/ports"))));
    QVERIFY(QDir().mkpath(QDir(gamesRoot).filePath(QStringLiteral("N64"))));
    QVERIFY(QDir().mkpath(engineRoot));

    const QByteArray romContents("game-port-test-rom");
    const QByteArray romMd5 = QCryptographicHash::hash(
        romContents, QCryptographicHash::Md5).toHex();
    const QString romPath = QDir(gamesRoot).filePath(QStringLiteral("N64/Test.z64"));
    QFile rom(romPath);
    QVERIFY(rom.open(QIODevice::WriteOnly));
    QCOMPARE(rom.write(romContents), romContents.size());
    rom.close();

    const QString executableName = QStringLiteral("test-port-engine");
    const QString enginePath = QDir(engineRoot).filePath(executableName);
    QFile engine(enginePath);
    QVERIFY(engine.open(QIODevice::WriteOnly | QIODevice::Text));
    QVERIFY(engine.write("#!/bin/sh\nexit 0\n") > 0);
    engine.close();
    QVERIFY(QFile::setPermissions(enginePath,
                                  QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));

    QJsonObject requirement{
        {QStringLiteral("label"), QStringLiteral("Test ROM")},
        {QStringLiteral("fileName"), QStringLiteral("baserom.test.z64")},
        {QStringLiteral("hashAlgorithm"), QStringLiteral("md5")},
        {QStringLiteral("hash"), QString::fromLatin1(romMd5)},
        {QStringLiteral("size"), romContents.size()}
    };
    QJsonObject executableMap;
    executableMap.insert(GamePortCatalog::currentPlatformKey(),
                         QJsonArray{executableName});
    QJsonObject manifest{
        {QStringLiteral("schemaVersion"), 1},
        {QStringLiteral("id"), QStringLiteral("test-port")},
        {QStringLiteral("title"), QStringLiteral("Test Port")},
        {QStringLiteral("distribution"), QStringLiteral("user-supplied-engine")},
        {QStringLiteral("romFolders"), QJsonArray{QStringLiteral("N64")}},
        {QStringLiteral("romExtensions"), QJsonArray{QStringLiteral("z64")}},
        {QStringLiteral("romRequirements"), QJsonArray{requirement}},
        {QStringLiteral("executables"), executableMap},
        {QStringLiteral("launchArguments"), QJsonArray{
             QStringLiteral("--savepath"), QStringLiteral("{savePath}"),
             QStringLiteral("--rom"), QStringLiteral("{romPath}")}},
        {QStringLiteral("crtLaunchArguments"), QJsonArray{
             QStringLiteral("--width"), QStringLiteral("{displayWidth}"),
             QStringLiteral("--height"), QStringLiteral("{displayHeight}")}}
    };
    QFile manifestFile(QDir(appRoot).filePath(
        QStringLiteral("modules/retro/ports/test-port.json")));
    QVERIFY(manifestFile.open(QIODevice::WriteOnly | QIODevice::Text));
    QVERIFY(manifestFile.write(QJsonDocument(manifest).toJson()) > 0);
    manifestFile.close();

    QStringList errors;
    const QList<GamePortDefinition> ports = GamePortCatalog::load(appRoot, &errors);
    QVERIFY2(errors.isEmpty(), qPrintable(errors.join(QStringLiteral("; "))));
    QCOMPARE(ports.size(), 1);
    const GamePortDefinition port = ports.first();
    QCOMPARE(port.id, QStringLiteral("test-port"));
    QCOMPARE(GamePortCatalog::findEngine(port, appRoot, dataRoot, engineRoot),
             enginePath);

    const QStringList candidates = GamePortCatalog::findRomCandidates(port, gamesRoot);
    QCOMPARE(candidates, QStringList{romPath});
    QVERIFY(GamePortCatalog::remotePathCanProvideRom(
        port, QStringLiteral("N64/folder/Test.z64")));
    QVERIFY(!GamePortCatalog::remotePathCanProvideRom(
        port, QStringLiteral("SNES/Test.z64")));
    QVERIFY(GamePortCatalog::romMatches(port, romPath));

    QString stagedPath;
    QString stageError;
    QVERIFY2(GamePortCatalog::stageRom(
                 port, romPath, dataRoot, &stagedPath, &stageError),
             qPrintable(stageError));
    QVERIFY(GamePortCatalog::romMatches(port, stagedPath));
    QCOMPARE(stagedPath, QDir(dataRoot).filePath(
        QStringLiteral("ports/test-port/user/baserom.test.z64")));

    const QString savePath = QDir(dataRoot).filePath(QStringLiteral("save"));
    const QStringList arguments = GamePortCatalog::launchArguments(
        port, enginePath, stagedPath, savePath);
    QCOMPARE(arguments, QStringList({QStringLiteral("--savepath"), savePath,
                                     QStringLiteral("--rom"), stagedPath}));
    const QStringList crtArguments = GamePortCatalog::launchArguments(
        port, enginePath, stagedPath, savePath, QSize(720, 480));
    QCOMPARE(crtArguments, QStringList({QStringLiteral("--savepath"), savePath,
                                        QStringLiteral("--rom"), stagedPath,
                                        QStringLiteral("--width"), QStringLiteral("720"),
                                        QStringLiteral("--height"), QStringLiteral("480")}));
}

void GamePortCatalogTest::reusesHashesAcrossRequirementsAndPorts()
{
    QTemporaryDir temporary;
    QVERIFY(temporary.isValid());

    const QByteArray romContents("one-read-per-hash-algorithm");
    const QByteArray sha1 = QCryptographicHash::hash(
        romContents, QCryptographicHash::Sha1).toHex();
    const QString romPath = temporary.filePath(QStringLiteral("Test.z64"));
    QFile rom(romPath);
    QVERIFY(rom.open(QIODevice::WriteOnly));
    QCOMPARE(rom.write(romContents), romContents.size());
    rom.close();

    GamePortDefinition firstPort;
    firstPort.romExtensions = {QStringLiteral("z64")};
    firstPort.romRequirements = {
        {QStringLiteral("Wrong 1"), QStringLiteral("wrong-1.z64"),
         QStringLiteral("sha1"), QByteArray(40, '0'), romContents.size()},
        {QStringLiteral("Wrong 2"), QStringLiteral("wrong-2.z64"),
         QStringLiteral("sha1"), QByteArray(40, '1'), romContents.size()},
        {QStringLiteral("Match"), QStringLiteral("match.z64"),
         QStringLiteral("sha1"), sha1, romContents.size()}
    };

    QHash<QString, QByteArray> hashCache;
    QString stagedFileName;
    QVERIFY(GamePortCatalog::romMatches(
        firstPort, romPath, &stagedFileName, &hashCache));
    QCOMPARE(stagedFileName, QStringLiteral("match.z64"));
    QCOMPARE(hashCache.size(), 1);

    GamePortDefinition secondPort = firstPort;
    secondPort.romRequirements = {firstPort.romRequirements.constLast()};
    QVERIFY(GamePortCatalog::findMatchingRom(
        secondPort, {romPath}, nullptr, &hashCache) == romPath);
    QCOMPARE(hashCache.size(), 1);
}

void GamePortCatalogTest::streamsEngineValidatedDiscWithoutCopying()
{
    QTemporaryDir temporary;
    QVERIFY(temporary.isValid());

    const QString appRoot = temporary.filePath(QStringLiteral("app"));
    const QString dataRoot = temporary.filePath(QStringLiteral("data"));
    const QString gamesRoot = temporary.filePath(QStringLiteral("games"));
    QVERIFY(QDir().mkpath(QDir(appRoot).filePath(QStringLiteral("modules/retro/ports"))));
    QVERIFY(QDir().mkpath(QDir(gamesRoot).filePath(QStringLiteral("GameCube"))));

    const QString discPath = QDir(gamesRoot).filePath(
        QStringLiteral("GameCube/Twilight Princess.rvz"));
    QFile disc(discPath);
    QVERIFY(disc.open(QIODevice::WriteOnly));
    QCOMPARE(disc.write("engine-validated-disc"), qint64(21));
    disc.close();

    QJsonObject executableMap;
    executableMap.insert(GamePortCatalog::currentPlatformKey(),
                         QJsonArray{QStringLiteral("dusklight")});
    QJsonObject manifest{
        {QStringLiteral("schemaVersion"), 1},
        {QStringLiteral("id"), QStringLiteral("dusklight")},
        {QStringLiteral("title"), QStringLiteral("Dusklight")},
        {QStringLiteral("distribution"), QStringLiteral("bundled-patched-engine")},
        {QStringLiteral("romValidation"), QStringLiteral("engine")},
        {QStringLiteral("romAccess"), QStringLiteral("direct")},
        {QStringLiteral("romFolders"), QJsonArray{QStringLiteral("GameCube")}},
        {QStringLiteral("romExtensions"), QJsonArray{QStringLiteral("rvz")}},
        {QStringLiteral("executables"), executableMap},
        {QStringLiteral("validationArguments"), QJsonArray{
             QStringLiteral("--validate"), QStringLiteral("{romPath}")}},
        {QStringLiteral("launchArguments"), QJsonArray{
             QStringLiteral("--dvd"), QStringLiteral("{romPath}")}}
    };
    QFile manifestFile(QDir(appRoot).filePath(
        QStringLiteral("modules/retro/ports/dusklight.json")));
    QVERIFY(manifestFile.open(QIODevice::WriteOnly | QIODevice::Text));
    QVERIFY(manifestFile.write(QJsonDocument(manifest).toJson()) > 0);
    manifestFile.close();

    QStringList errors;
    const QList<GamePortDefinition> ports = GamePortCatalog::load(appRoot, &errors);
    QVERIFY2(errors.isEmpty(), qPrintable(errors.join(QStringLiteral("; "))));
    QCOMPARE(ports.size(), 1);
    const GamePortDefinition port = ports.first();
    QCOMPARE(port.romValidation, QStringLiteral("engine"));
    QCOMPARE(port.romAccess, QStringLiteral("direct"));

    const QStringList candidates = GamePortCatalog::findRomCandidates(port, gamesRoot);
    QCOMPARE(candidates, QStringList{discPath});
    const QString validatorPath = temporary.filePath(QStringLiteral("dusklight"));
    QFile validator(validatorPath);
    QVERIFY(validator.open(QIODevice::WriteOnly | QIODevice::Text));
    QVERIFY(validator.write("#!/bin/sh\n[ \"$1\" = --validate ] && [ -f \"$2\" ]\n") > 0);
    validator.close();
    QVERIFY(QFile::setPermissions(
        validatorPath, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
    QVERIFY(GamePortCatalog::romMatches(
        port, discPath, nullptr, nullptr, validatorPath));

    QString launchedPath;
    QString stageError;
    QVERIFY2(GamePortCatalog::stageRom(
                 port, discPath, dataRoot, &launchedPath, &stageError, validatorPath),
             qPrintable(stageError));
    QCOMPARE(launchedPath, QFileInfo(discPath).canonicalFilePath());
    QVERIFY(!QDir(GamePortCatalog::portUserRoot(dataRoot, port)).exists());

    const QStringList arguments = GamePortCatalog::launchArguments(
        port, QStringLiteral("/ports/dusklight"), launchedPath,
        GamePortCatalog::portUserRoot(dataRoot, port));
    QCOMPARE(arguments, QStringList({QStringLiteral("--dvd"), launchedPath}));
}

void GamePortCatalogTest::detectsCompositeDisplayModes()
{
    QCOMPARE(GamePortCatalog::compositeDisplayMode(
                 QStringLiteral("quiet video=Composite-1:720x480ie root=/dev/mmcblk0p2")),
             QSize(720, 480));
    QCOMPARE(GamePortCatalog::compositeDisplayMode(
                 QStringLiteral("video=Composite-1:720x576ie vc4.tv_norm=PAL")),
             QSize(720, 576));
    QVERIFY(!GamePortCatalog::compositeDisplayMode(
                 QStringLiteral("video=HDMI-A-1:1920x1080@60")).isValid());
    QVERIFY(!GamePortCatalog::compositeDisplayMode(
                 QStringLiteral("video=Composite-1:1920x1080e")).isValid());
}

QTEST_MAIN(GamePortCatalogTest)
#include "GamePortCatalogTest.moc"
