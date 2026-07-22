#include "GamePortCatalog.h"

#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QSysInfo>

namespace {
constexpr qint64 kMaximumManifestBytes = 256 * 1024;

QStringList jsonStringList(const QJsonValue &value)
{
    QStringList result;
    for (const QJsonValue &item : value.toArray()) {
        const QString text = item.toString().trimmed();
        if (!text.isEmpty() && !result.contains(text))
            result.append(text);
    }
    return result;
}

bool safePortId(const QString &id)
{
    static const QRegularExpression expression(QStringLiteral("^[a-z0-9][a-z0-9._-]{0,63}$"));
    return expression.match(id).hasMatch();
}

bool safeExecutableName(const QString &name)
{
    return !name.isEmpty()
        && QFileInfo(name).fileName() == name
        && name != QLatin1String(".")
        && name != QLatin1String("..");
}

QString normalizedRelativePath(QString path)
{
    path.replace(QLatin1Char('\\'), QLatin1Char('/'));
    while (path.startsWith(QLatin1Char('/')))
        path.remove(0, 1);
    return QDir::cleanPath(path);
}

bool folderMatches(const GamePortDefinition &port, const QString &folder)
{
    for (const QString &candidate : port.romFolders) {
        if (folder.compare(candidate, Qt::CaseInsensitive) == 0)
            return true;
    }
    return false;
}

bool extensionMatches(const GamePortDefinition &port, const QString &path)
{
    return port.romExtensions.contains(QFileInfo(path).suffix(), Qt::CaseInsensitive);
}

QCryptographicHash::Algorithm hashAlgorithm(const QString &name, bool *ok)
{
    const QString normalized = name.trimmed().toLower();
    if (normalized == QLatin1String("md5")) {
        *ok = true;
        return QCryptographicHash::Md5;
    }
    if (normalized == QLatin1String("sha1")) {
        *ok = true;
        return QCryptographicHash::Sha1;
    }
    if (normalized == QLatin1String("sha256")) {
        *ok = true;
        return QCryptographicHash::Sha256;
    }
    *ok = false;
    return QCryptographicHash::Sha256;
}

QByteArray fileHash(const QString &path, QCryptographicHash::Algorithm algorithm)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};

    QCryptographicHash hash(algorithm);
    while (!file.atEnd()) {
        const QByteArray block = file.read(1024 * 1024);
        if (block.isEmpty() && file.error() != QFile::NoError)
            return {};
        hash.addData(block);
    }
    return hash.result().toHex().toLower();
}

QString fileHashCacheKey(const QFileInfo &info, const QString &algorithm)
{
    return QStringLiteral("%1\n%2\n%3\n%4")
        .arg(info.absoluteFilePath(), algorithm)
        .arg(info.size())
        .arg(info.lastModified().toMSecsSinceEpoch());
}

bool engineValidatesRom(const GamePortDefinition &port, const QString &enginePath,
                        const QFileInfo &romInfo)
{
    const QFileInfo engineInfo(enginePath);
    if (!engineInfo.isFile() || !engineInfo.isExecutable()
        || port.validationArguments.isEmpty()) {
        return false;
    }

    QStringList arguments;
    for (QString argument : port.validationArguments) {
        argument.replace(QStringLiteral("{romPath}"), romInfo.absoluteFilePath());
        arguments.append(argument);
    }

    QProcess validator;
    validator.setProgram(engineInfo.absoluteFilePath());
    validator.setArguments(arguments);
    validator.setWorkingDirectory(engineInfo.absolutePath());
    validator.setProcessChannelMode(QProcess::MergedChannels);
    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
#ifdef Q_OS_LINUX
    environment.insert(QStringLiteral("LD_LIBRARY_PATH"), engineInfo.absolutePath());
#endif
    validator.setProcessEnvironment(environment);
    validator.start();
    if (!validator.waitForStarted(5000))
        return false;
    if (!validator.waitForFinished(15000)) {
        validator.kill();
        validator.waitForFinished(1000);
        return false;
    }
    return validator.exitStatus() == QProcess::NormalExit && validator.exitCode() == 0;
}

QString executableIn(const QString &path, const QStringList &names,
                     const QString &portId)
{
    if (path.trimmed().isEmpty())
        return {};

    const QFileInfo supplied(path);
    if (supplied.isFile() && supplied.isExecutable()
        && names.contains(supplied.fileName())) {
        return supplied.absoluteFilePath();
    }

    const QString root = supplied.absoluteFilePath();
    const QStringList roots{root, QDir(root).absoluteFilePath(portId)};
    for (const QString &candidateRoot : roots) {
        for (const QString &name : names) {
            const QFileInfo candidate(QDir(candidateRoot).absoluteFilePath(name));
            if (candidate.isFile() && candidate.isExecutable())
                return candidate.absoluteFilePath();
        }
    }
    return {};
}
}

QList<GamePortDefinition> GamePortCatalog::load(const QString &appRoot,
                                                QStringList *errors)
{
    QList<GamePortDefinition> result;
    const QString root = QDir(appRoot).absoluteFilePath(QStringLiteral("modules/retro/ports"));
    QDir directory(root);
    const QStringList files = directory.entryList({QStringLiteral("*.json")},
                                                   QDir::Files | QDir::Readable,
                                                   QDir::Name);
    for (const QString &name : files) {
        QFile file(directory.absoluteFilePath(name));
        if (!file.open(QIODevice::ReadOnly) || file.size() > kMaximumManifestBytes) {
            if (errors)
                errors->append(QStringLiteral("%1: could not read manifest").arg(name));
            continue;
        }

        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            if (errors)
                errors->append(QStringLiteral("%1: invalid JSON").arg(name));
            continue;
        }

        const QJsonObject object = document.object();
        if (object.value(QStringLiteral("schemaVersion")).toInt() != 1) {
            if (errors)
                errors->append(QStringLiteral("%1: unsupported schema").arg(name));
            continue;
        }

        GamePortDefinition port;
        port.id = object.value(QStringLiteral("id")).toString().trimmed();
        port.title = object.value(QStringLiteral("title")).toString().trimmed();
        port.sourceUrl = object.value(QStringLiteral("sourceUrl")).toString().trimmed();
        port.engineEnvironment = object.value(QStringLiteral("engineEnvironment")).toString().trimmed();
        port.distribution = object.value(QStringLiteral("distribution")).toString().trimmed();
        port.romValidation = object.value(QStringLiteral("romValidation"))
                                 .toString(QStringLiteral("hash")).trimmed().toLower();
        port.romAccess = object.value(QStringLiteral("romAccess"))
                             .toString(QStringLiteral("copy")).trimmed().toLower();
        port.romFolders = jsonStringList(object.value(QStringLiteral("romFolders")));
        port.romExtensions = jsonStringList(object.value(QStringLiteral("romExtensions")));
        port.validationArguments = jsonStringList(
            object.value(QStringLiteral("validationArguments")));
        port.launchArguments = jsonStringList(object.value(QStringLiteral("launchArguments")));
        port.crtLaunchArguments = jsonStringList(
            object.value(QStringLiteral("crtLaunchArguments")));

        const QJsonObject executables = object.value(QStringLiteral("executables")).toObject();
        for (auto it = executables.constBegin(); it != executables.constEnd(); ++it) {
            QStringList names;
            for (const QString &candidate : jsonStringList(it.value())) {
                if (safeExecutableName(candidate))
                    names.append(candidate);
            }
            if (!names.isEmpty())
                port.executables.insert(it.key(), names);
        }

        for (const QJsonValue &value : object.value(QStringLiteral("romRequirements")).toArray()) {
            const QJsonObject requirementObject = value.toObject();
            GamePortRomRequirement requirement;
            requirement.label = requirementObject.value(QStringLiteral("label")).toString().trimmed();
            requirement.fileName = requirementObject.value(QStringLiteral("fileName")).toString().trimmed();
            requirement.hashAlgorithm = requirementObject.value(QStringLiteral("hashAlgorithm")).toString().trimmed().toLower();
            requirement.hashHex = requirementObject.value(QStringLiteral("hash")).toString().trimmed().toLatin1().toLower();
            requirement.size = qint64(requirementObject.value(QStringLiteral("size")).toDouble(-1));

            bool algorithmOk = false;
            hashAlgorithm(requirement.hashAlgorithm, &algorithmOk);
            if (safeExecutableName(requirement.fileName) && algorithmOk
                && !requirement.hashHex.isEmpty()) {
                port.romRequirements.append(requirement);
            }
        }

        const bool validValidation = port.romValidation == QLatin1String("hash")
            || port.romValidation == QLatin1String("engine");
        const bool validAccess = port.romAccess == QLatin1String("copy")
            || port.romAccess == QLatin1String("direct");
        const bool requirementsComplete = port.romValidation == QLatin1String("engine")
            || !port.romRequirements.isEmpty();
        const bool validationCommandComplete = port.romValidation != QLatin1String("engine")
            || !port.validationArguments.isEmpty();
        if (!safePortId(port.id) || port.title.isEmpty()
            || port.romFolders.isEmpty() || port.romExtensions.isEmpty()
            || !validValidation || !validAccess || !requirementsComplete
            || !validationCommandComplete
            || port.executables.isEmpty()) {
            if (errors)
                errors->append(QStringLiteral("%1: incomplete manifest").arg(name));
            continue;
        }
        result.append(port);
    }
    return result;
}

QString GamePortCatalog::currentPlatformKey()
{
    QString architecture = QSysInfo::currentCpuArchitecture().toLower();
    if (architecture == QLatin1String("aarch64"))
        architecture = QStringLiteral("arm64");
    else if (architecture == QLatin1String("amd64"))
        architecture = QStringLiteral("x86_64");
    else if (architecture.startsWith(QLatin1String("armv")))
        architecture = QStringLiteral("arm");

#if defined(Q_OS_LINUX)
    return QStringLiteral("linux-") + architecture;
#elif defined(Q_OS_MACOS)
    return QStringLiteral("macos-") + architecture;
#elif defined(Q_OS_WIN)
    return QStringLiteral("windows-") + architecture;
#else
    return QStringLiteral("unknown-") + architecture;
#endif
}

QStringList GamePortCatalog::executableNames(const GamePortDefinition &port)
{
    return port.executables.value(currentPlatformKey());
}

QString GamePortCatalog::findEngine(const GamePortDefinition &port,
                                    const QString &appRoot,
                                    const QString &dataRoot,
                                    const QString &configuredPath)
{
    const QStringList names = executableNames(port);
    if (names.isEmpty())
        return {};

    if (!port.engineEnvironment.isEmpty()) {
        const QByteArray environmentName = port.engineEnvironment.toUtf8();
        const QString fromEnvironment = executableIn(
            qEnvironmentVariable(environmentName.constData()), names, port.id);
        if (!fromEnvironment.isEmpty())
            return fromEnvironment;
    }

    const QString configured = executableIn(configuredPath, names, port.id);
    if (!configured.isEmpty())
        return configured;

    const QStringList roots{
        QDir(dataRoot).absoluteFilePath(QStringLiteral("ports/engines/")),
        QDir(appRoot).absoluteFilePath(QStringLiteral("vendor/ports/"))
    };
    for (const QString &root : roots) {
        const QString found = executableIn(root, names, port.id);
        if (!found.isEmpty())
            return found;
    }

    for (const QString &name : names) {
        const QString found = QStandardPaths::findExecutable(name);
        if (!found.isEmpty())
            return found;
    }
    return {};
}

QStringList GamePortCatalog::findRomCandidates(const GamePortDefinition &port,
                                               const QString &gamesRoot)
{
    QStringList result;
    QDir root(gamesRoot);
    if (!root.exists())
        return result;

    QStringList matchingRoots;
    const QFileInfoList directories = root.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot,
                                                         QDir::Name);
    for (const QFileInfo &directory : directories) {
        if (folderMatches(port, directory.fileName()))
            matchingRoots.append(directory.absoluteFilePath());
    }

    for (const QString &matchingRoot : matchingRoots) {
        QDirIterator iterator(matchingRoot, QDir::Files | QDir::NoSymLinks,
                              QDirIterator::Subdirectories);
        while (iterator.hasNext()) {
            const QString path = iterator.next();
            if (extensionMatches(port, path))
                result.append(QFileInfo(path).absoluteFilePath());
        }
    }
    result.removeDuplicates();
    result.sort(Qt::CaseInsensitive);
    return result;
}

bool GamePortCatalog::remotePathCanProvideRom(const GamePortDefinition &port,
                                              const QString &relativePath)
{
    const QString normalized = normalizedRelativePath(relativePath);
    if (normalized.isEmpty() || normalized == QLatin1String("."))
        return false;
    const QString topFolder = normalized.section(QLatin1Char('/'), 0, 0);
    return folderMatches(port, topFolder) && extensionMatches(port, normalized);
}

bool GamePortCatalog::romMatches(const GamePortDefinition &port,
                                 const QString &path,
                                 QString *stagedFileName,
                                 QHash<QString, QByteArray> *hashCache,
                                 const QString &enginePath)
{
    const QFileInfo info(path);
    if (!info.isFile() || !info.isReadable() || info.size() <= 0
        || !extensionMatches(port, path))
        return false;

    QHash<QString, QByteArray> localHashCache;
    QHash<QString, QByteArray> *cache = hashCache ? hashCache : &localHashCache;

    // Compressed disc containers do not have stable whole-file hashes. An
    // explicitly allowlisted engine validator performs a lightweight game and
    // supported-region check without opening a graphics window. Its result is
    // cached using the same path/size/mtime key as ordinary ROM hashes.
    if (port.romValidation == QLatin1String("engine")) {
        const QFileInfo engineInfo(enginePath);
        if (!engineInfo.isFile() || !engineInfo.isExecutable())
            return false;
        const QString validatorIdentity = QStringLiteral("engine:%1:%2:%3:%4")
            .arg(port.id, engineInfo.canonicalFilePath())
            .arg(engineInfo.size())
            .arg(engineInfo.lastModified().toMSecsSinceEpoch());
        const QString cacheKey = fileHashCacheKey(
            info, validatorIdentity);
        auto cachedResult = cache->constFind(cacheKey);
        if (cachedResult == cache->constEnd()) {
            const QByteArray result = engineValidatesRom(port, enginePath, info)
                ? QByteArrayLiteral("match") : QByteArrayLiteral("miss");
            cachedResult = cache->insert(cacheKey, result);
        }
        if (cachedResult.value() != QByteArrayLiteral("match"))
            return false;
        if (stagedFileName)
            *stagedFileName = info.fileName();
        return true;
    }

    for (const GamePortRomRequirement &requirement : port.romRequirements) {
        if (requirement.size >= 0 && info.size() != requirement.size)
            continue;
        bool algorithmOk = false;
        const QCryptographicHash::Algorithm algorithm = hashAlgorithm(
            requirement.hashAlgorithm, &algorithmOk);
        if (!algorithmOk)
            continue;
        const QString cacheKey = fileHashCacheKey(info, requirement.hashAlgorithm);
        auto cachedHash = cache->constFind(cacheKey);
        if (cachedHash == cache->constEnd()) {
            cachedHash = cache->insert(cacheKey, fileHash(path, algorithm));
        }
        if (cachedHash.value() == requirement.hashHex) {
            if (stagedFileName)
                *stagedFileName = requirement.fileName;
            return true;
        }
    }
    return false;
}

QString GamePortCatalog::findMatchingRom(const GamePortDefinition &port,
                                         const QStringList &candidates,
                                         QString *stagedFileName,
                                         QHash<QString, QByteArray> *hashCache,
                                         const QString &enginePath)
{
    for (const QString &candidate : candidates) {
        QString fileName;
        if (romMatches(port, candidate, &fileName, hashCache, enginePath)) {
            if (stagedFileName)
                *stagedFileName = fileName;
            return QFileInfo(candidate).absoluteFilePath();
        }
    }
    return {};
}

QString GamePortCatalog::portUserRoot(const QString &dataRoot,
                                      const GamePortDefinition &port)
{
    return QDir(dataRoot).absoluteFilePath(
        QStringLiteral("ports/%1/user").arg(port.id));
}

QString GamePortCatalog::stagedRomPath(const QString &dataRoot,
                                       const GamePortDefinition &port,
                                       const QString &fileName)
{
    if (!safeExecutableName(fileName))
        return {};
    return QDir(portUserRoot(dataRoot, port)).absoluteFilePath(fileName);
}

bool GamePortCatalog::stageRom(const GamePortDefinition &port,
                               const QString &sourcePath,
                               const QString &dataRoot,
                               QString *stagedPath,
                               QString *error,
                               const QString &enginePath)
{
    QString fileName;
    if (!romMatches(port, sourcePath, &fileName, nullptr, enginePath)) {
        if (error)
            *error = QStringLiteral("THE SELECTED ROM IS NOT A SUPPORTED ORIGINAL DUMP");
        return false;
    }

    if (port.romAccess == QLatin1String("direct")) {
        const QString canonicalSource = QFileInfo(sourcePath).canonicalFilePath();
        if (canonicalSource.isEmpty()) {
            if (error)
                *error = QStringLiteral("THE PORT DISC IMAGE COULD NOT BE OPENED");
            return false;
        }
        if (stagedPath)
            *stagedPath = canonicalSource;
        return true;
    }

    const QString destination = GamePortCatalog::stagedRomPath(dataRoot, port, fileName);
    if (destination.isEmpty()) {
        if (error)
            *error = QStringLiteral("THE PORT ROM DESTINATION IS INVALID");
        return false;
    }

    QDir().mkpath(QFileInfo(destination).absolutePath());
    if (QFileInfo(sourcePath).canonicalFilePath() == QFileInfo(destination).canonicalFilePath()
        || (QFileInfo(destination).isFile() && romMatches(port, destination))) {
        if (stagedPath)
            *stagedPath = destination;
        return true;
    }

    QFile source(sourcePath);
    QSaveFile output(destination);
    if (!source.open(QIODevice::ReadOnly) || !output.open(QIODevice::WriteOnly)) {
        if (error)
            *error = QStringLiteral("COULD NOT OPEN THE PORT ROM CACHE");
        return false;
    }
    while (!source.atEnd()) {
        const QByteArray block = source.read(1024 * 1024);
        if (block.isEmpty() && source.error() != QFile::NoError) {
            output.cancelWriting();
            if (error)
                *error = QStringLiteral("COULD NOT READ THE PORT ROM");
            return false;
        }
        if (output.write(block) != block.size()) {
            output.cancelWriting();
            if (error)
                *error = QStringLiteral("COULD NOT CACHE THE PORT ROM");
            return false;
        }
    }
    if (!output.commit() || !romMatches(port, destination)) {
        QFile::remove(destination);
        if (error)
            *error = QStringLiteral("PORT ROM VALIDATION FAILED AFTER COPYING");
        return false;
    }
    QFile::setPermissions(destination, QFile::ReadOwner | QFile::WriteOwner);
    if (stagedPath)
        *stagedPath = destination;
    return true;
}

QStringList GamePortCatalog::launchArguments(const GamePortDefinition &port,
                                             const QString &enginePath,
                                             const QString &romPath,
                                             const QString &savePath,
                                             const QSize &displaySize)
{
    QStringList result;
    const QString engineDirectory = QFileInfo(enginePath).absolutePath();
    QStringList arguments = port.launchArguments;
    if (displaySize.isValid())
        arguments.append(port.crtLaunchArguments);
    for (QString argument : arguments) {
        argument.replace(QStringLiteral("{enginePath}"), enginePath);
        argument.replace(QStringLiteral("{engineDir}"), engineDirectory);
        argument.replace(QStringLiteral("{romPath}"), romPath);
        argument.replace(QStringLiteral("{savePath}"), savePath);
        argument.replace(QStringLiteral("{displayWidth}"),
                         QString::number(displaySize.width()));
        argument.replace(QStringLiteral("{displayHeight}"),
                         QString::number(displaySize.height()));
        result.append(argument);
    }
    return result;
}

QSize GamePortCatalog::compositeDisplayMode(const QString &kernelCommandLine)
{
    static const QRegularExpression expression(
        QStringLiteral("(?:^|\\s)video=Composite-1:(\\d+)x(\\d+)[^\\s]*"),
        QRegularExpression::CaseInsensitiveOption);
    const QRegularExpressionMatch match = expression.match(kernelCommandLine);
    if (!match.hasMatch())
        return {};

    const int width = match.captured(1).toInt();
    const int height = match.captured(2).toInt();
    if (width != 720 || (height != 480 && height != 576))
        return {};
    return QSize(width, height);
}
