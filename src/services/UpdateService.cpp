#include "UpdateService.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QPointer>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QVersionNumber>
#include <functional>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winhttp.h>
#ifndef WINHTTP_OPTION_REDIRECT_POLICY
#define WINHTTP_OPTION_REDIRECT_POLICY 88
#endif
#ifndef WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS
#define WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS 2
#endif
#endif

#ifndef SEKAIDESK_VERSION
#define SEKAIDESK_VERSION "0.3.0"
#endif

namespace {

QString stripVersionPrefix(const QString& ver)
{
    QString s = ver.trimmed();
    if (s.startsWith(QLatin1Char('v'), Qt::CaseInsensitive))
        s = s.mid(1);
    const int dash = s.indexOf(QLatin1Char('-'));
    if (dash > 0)
        s = s.left(dash);
    return s;
}

bool isVersionNewer(const QString& latestRaw, const QString& currentRaw)
{
    const QString lClean = stripVersionPrefix(latestRaw);
    const QString cClean = stripVersionPrefix(currentRaw);
    if (lClean.isEmpty() || cClean.isEmpty())
        return false;
    const QVersionNumber latest = QVersionNumber::fromString(lClean);
    const QVersionNumber current = QVersionNumber::fromString(cClean);
    if (latest.isNull() || current.isNull())
        return false;
    return QVersionNumber::compare(latest, current) > 0;
}

QString parseSha256ForAsset(const QByteArray& sumsBytes, const QString& assetName)
{
    const QString text = QString::fromUtf8(sumsBytes);
    const QStringList lines = text.split(QRegularExpression(QStringLiteral("[\r\n]+")), Qt::SkipEmptyParts);
    const QRegularExpression hexRe(QStringLiteral("^[0-9a-fA-F]{64}$"));
    for (const QString& line : lines) {
        const QString trimmed = line.trimmed();
        const QStringList parts = trimmed.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
        if (parts.size() >= 2 && hexRe.match(parts.at(0)).hasMatch()) {
            QString fname = parts.at(1);
            if (fname.startsWith(QLatin1Char('*')))
                fname = fname.mid(1);
            fname = QFileInfo(fname).fileName();
            if (fname.compare(assetName, Qt::CaseInsensitive) == 0)
                return parts.at(0).toLower();
        }
    }
    return {};
}

#ifdef Q_OS_WIN
struct HttpRequestHandles {
    HINTERNET hSession = nullptr;
    HINTERNET hConnect = nullptr;
    HINTERNET hRequest = nullptr;

    ~HttpRequestHandles()
    {
        if (hRequest) WinHttpCloseHandle(hRequest);
        if (hConnect) WinHttpCloseHandle(hConnect);
        if (hSession) WinHttpCloseHandle(hSession);
    }
};

bool openWinHttpRequest(const QString& urlStr,
                        const QString& extraHeaders,
                        int timeoutMs,
                        HttpRequestHandles& out,
                        DWORD& outStatusCode,
                        qint64& outContentLength,
                        QString& outError)
{
    outStatusCode = 0;
    outContentLength = -1;

    const QUrl url(urlStr);
    if (!url.isValid() || url.host().isEmpty()) {
        outError = QStringLiteral("Invalid update URL");
        return false;
    }

    const bool isHttps = (url.scheme().compare(QStringLiteral("https"), Qt::CaseInsensitive) == 0);
    const INTERNET_PORT port = static_cast<INTERNET_PORT>(url.port(isHttps ? 443 : 80));
    QString path = url.path(QUrl::FullyEncoded);
    if (path.isEmpty())
        path = QStringLiteral("/");
    if (url.hasQuery())
        path += QLatin1Char('?') + url.query(QUrl::FullyEncoded);

    const QString ua = QStringLiteral("SekaiDesk-Updater/") + QStringLiteral(SEKAIDESK_VERSION);
    out.hSession = WinHttpOpen(
        reinterpret_cast<LPCWSTR>(ua.utf16()),
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);
    if (!out.hSession) {
        outError = QStringLiteral("WinHttpOpen failed (%1)").arg(GetLastError());
        return false;
    }

    WinHttpSetTimeouts(out.hSession, timeoutMs, timeoutMs, timeoutMs, timeoutMs);
    DWORD redirPolicy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(out.hSession, WINHTTP_OPTION_REDIRECT_POLICY, &redirPolicy, sizeof(redirPolicy));

    const std::wstring hostW = url.host().toStdWString();
    out.hConnect = WinHttpConnect(out.hSession, hostW.c_str(), port, 0);
    if (!out.hConnect) {
        outError = QStringLiteral("Connection failed (%1)").arg(GetLastError());
        return false;
    }

    const std::wstring pathW = path.toStdWString();
    out.hRequest = WinHttpOpenRequest(
        out.hConnect,
        L"GET",
        pathW.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        isHttps ? WINHTTP_FLAG_SECURE : 0);
    if (!out.hRequest) {
        outError = QStringLiteral("Request init failed (%1)").arg(GetLastError());
        return false;
    }

    WinHttpSetOption(out.hRequest, WINHTTP_OPTION_REDIRECT_POLICY, &redirPolicy, sizeof(redirPolicy));

    if (!extraHeaders.isEmpty()) {
        const std::wstring hdrW = extraHeaders.toStdWString();
        WinHttpAddRequestHeaders(out.hRequest, hdrW.c_str(), static_cast<DWORD>(hdrW.size()),
                                 WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    }

    if (!WinHttpSendRequest(out.hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
        outError = QStringLiteral("Network error (%1)").arg(GetLastError());
        return false;
    }

    if (!WinHttpReceiveResponse(out.hRequest, nullptr)) {
        outError = QStringLiteral("No server response (%1)").arg(GetLastError());
        return false;
    }

    DWORD statusSize = sizeof(outStatusCode);
    WinHttpQueryHeaders(out.hRequest,
                        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        &outStatusCode,
                        &statusSize,
                        WINHTTP_NO_HEADER_INDEX);

    wchar_t clBuf[64]{};
    DWORD clBytes = sizeof(clBuf);
    if (WinHttpQueryHeaders(out.hRequest,
                            WINHTTP_QUERY_CONTENT_LENGTH,
                            WINHTTP_HEADER_NAME_BY_INDEX,
                            clBuf,
                            &clBytes,
                            WINHTTP_NO_HEADER_INDEX)) {
        bool ok = false;
        const qint64 len = QString::fromWCharArray(clBuf).trimmed().toLongLong(&ok);
        if (ok && len > 0)
            outContentLength = len;
    }

    if (outStatusCode < 200 || outStatusCode >= 300) {
        outError = QStringLiteral("HTTP %1").arg(outStatusCode);
        return false;
    }
    return true;
}

bool winHttpGetBytes(const QString& urlStr,
                     const QString& extraHeaders,
                     QByteArray& outBytes,
                     QString& outError,
                     const std::atomic<bool>& cancelFlag)
{
    outBytes.clear();
    HttpRequestHandles http;
    DWORD status = 0;
    qint64 contentLen = -1;
    if (!openWinHttpRequest(urlStr, extraHeaders, 10000, http, status, contentLen, outError))
        return false;

    DWORD avail = 0;
    while (WinHttpQueryDataAvailable(http.hRequest, &avail) && avail > 0) {
        if (cancelFlag.load()) {
            outError = QStringLiteral("Cancelled");
            return false;
        }
        const DWORD toRead = qMin<DWORD>(avail, 65536);
        QByteArray chunk(static_cast<int>(toRead), Qt::Uninitialized);
        DWORD readBytes = 0;
        if (!WinHttpReadData(http.hRequest, chunk.data(), toRead, &readBytes) || readBytes == 0)
            break;
        chunk.truncate(static_cast<int>(readBytes));
        outBytes.append(chunk);
        if (outBytes.size() > 8 * 1024 * 1024) {
            outError = QStringLiteral("Metadata payload too large");
            return false;
        }
    }
    return true;
}

bool winHttpDownloadFileWithSha256(const QString& urlStr,
                                   const QString& destPath,
                                   const std::function<void(qint64, qint64)>& onProgress,
                                   QString& outSha256Hex,
                                   QString& outError,
                                   const std::atomic<bool>& cancelFlag)
{
    outSha256Hex.clear();
    HttpRequestHandles http;
    DWORD status = 0;
    qint64 contentLen = -1;
    if (!openWinHttpRequest(urlStr, QString(), 25000, http, status, contentLen, outError))
        return false;

    QFile outFile(destPath);
    if (!outFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        outError = QStringLiteral("Cannot write temporary update file");
        return false;
    }

    QCryptographicHash hasher(QCryptographicHash::Sha256);
    qint64 downloaded = 0;
    QElapsedTimer uiThrottle;
    uiThrottle.start();

    if (onProgress)
        onProgress(0, contentLen);

    DWORD avail = 0;
    while (WinHttpQueryDataAvailable(http.hRequest, &avail)) {
        if (avail == 0)
            break;
        if (cancelFlag.load()) {
            outFile.close();
            QFile::remove(destPath);
            outError = QStringLiteral("Cancelled");
            return false;
        }
        const DWORD toRead = qMin<DWORD>(avail, 65536);
        QByteArray buf(static_cast<int>(toRead), Qt::Uninitialized);
        DWORD readBytes = 0;
        if (!WinHttpReadData(http.hRequest, buf.data(), toRead, &readBytes)) {
            outError = QStringLiteral("Download stream interrupted (%1)").arg(GetLastError());
            outFile.close();
            QFile::remove(destPath);
            return false;
        }
        if (readBytes == 0)
            break;

        const qint64 written = outFile.write(buf.constData(), static_cast<qint64>(readBytes));
        if (written != static_cast<qint64>(readBytes)) {
            outError = QStringLiteral("Disk write error while downloading update");
            outFile.close();
            QFile::remove(destPath);
            return false;
        }
        hasher.addData(QByteArrayView(buf.constData(), static_cast<qsizetype>(readBytes)));
        downloaded += static_cast<qint64>(readBytes);

        if (onProgress && uiThrottle.elapsed() >= 80) {
            uiThrottle.restart();
            onProgress(downloaded, contentLen);
        }
    }

    outFile.flush();
    outFile.close();

    if (downloaded <= 0) {
        QFile::remove(destPath);
        outError = QStringLiteral("Downloaded update package is empty");
        return false;
    }

    if (onProgress)
        onProgress(downloaded, contentLen > 0 ? contentLen : downloaded);

    outSha256Hex = QString::fromLatin1(hasher.result().toHex()).toLower();
    return true;
}

bool spawnDetachedProcess(const QString& commandLine, const QString& workDir, QString& outError)
{
    std::wstring cmdW = commandLine.toStdWString();
    const std::wstring dirW = QDir::toNativeSeparators(workDir).toStdWString();

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr,
                        cmdW.data(),
                        nullptr,
                        nullptr,
                        FALSE,
                        CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                        nullptr,
                        dirW.empty() ? nullptr : dirW.c_str(),
                        &si,
                        &pi)) {
        const DWORD err = GetLastError();
        qWarning("UpdateService: CreateProcessW failed (err=%lu) cmd=%s", err, qPrintable(commandLine));
        outError = QStringLiteral("Failed to launch updater helper (%1)").arg(err);
        return false;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}
#endif

} // namespace

UpdateService::UpdateService(QObject* parent)
    : QObject(parent)
    , m_currentVersion(stripVersionPrefix(QStringLiteral(SEKAIDESK_VERSION)))
{
    if (m_currentVersion.isEmpty())
        m_currentVersion = QStringLiteral("0.3.0");

    const QString fakeVer = qEnvironmentVariable("SEKAIDESK_FAKE_VERSION").trimmed();
    if (!fakeVer.isEmpty())
        m_currentVersion = stripVersionPrefix(fakeVer);

    const QString appDir = QCoreApplication::applicationDirPath();
    m_isInstallerInstall = QFileInfo::exists(appDir + QStringLiteral("/Uninstall.exe"));

    // Clean up any hook DLL rotated aside during a previous portable self-update.
    const QString oldHook = appDir + QStringLiteral("/SekaiTrayHook.dll.old");
    if (QFileInfo::exists(oldHook))
        QFile::remove(oldHook);

    // Silent background check after boot settles so startup stays instant.
    QTimer::singleShot(12000, this, [this]() { checkForUpdates(true); });
}

UpdateService::~UpdateService()
{
    m_destroyed.store(true);
    if (m_worker.joinable())
        m_worker.join();
}

void UpdateService::joinWorkerIfFinished()
{
    if (!m_busy.load() && m_worker.joinable())
        m_worker.join();
}

void UpdateService::setState(const QString& status, const QString& statusText, const QString& errorMessage)
{
    m_status = status;
    m_statusText = statusText;
    m_errorMessage = errorMessage;
    emit stateChanged();
}

void UpdateService::dismissToast()
{
    if (!m_toastVisible)
        return;
    m_toastVisible = false;
    emit stateChanged();
}

void UpdateService::checkForUpdates(bool silent)
{
    if (m_busy.load() || m_destroyed.load())
        return;
    joinWorkerIfFinished();

    m_busy.store(true);
    if (!silent)
        setState(QStringLiteral("checking"), QStringLiteral("Checking GitHub Releases..."));

#ifdef Q_OS_WIN
    const QPointer<UpdateService> self(this);
    const QString currentVer = m_currentVersion;
    const bool isInstaller = m_isInstallerInstall;

    m_worker = std::thread([this, self, silent, currentVer, isInstaller]() {
        const QString apiUrl = QStringLiteral("https://api.github.com/repos/Yuukitake/SekaiDesk/releases/latest");
        const QString hdrs = QStringLiteral("Accept: application/vnd.github+json\r\n");

        QByteArray raw;
        QString err;
        const bool ok = winHttpGetBytes(apiUrl, hdrs, raw, err, m_destroyed);

        QString tag;
        QString notes;
        QString htmlUrl;
        QString setupUrl;
        QString zipUrl;
        QString sumsUrl;

        if (ok) {
            const QJsonDocument doc = QJsonDocument::fromJson(raw);
            if (!doc.isObject()) {
                err = QStringLiteral("Invalid release metadata");
            } else {
                const QJsonObject obj = doc.object();
                tag = stripVersionPrefix(obj.value(QStringLiteral("tag_name")).toString());
                notes = obj.value(QStringLiteral("body")).toString().trimmed();
                htmlUrl = obj.value(QStringLiteral("html_url")).toString();

                const QJsonArray assets = obj.value(QStringLiteral("assets")).toArray();
                for (const QJsonValue& v : assets) {
                    const QJsonObject a = v.toObject();
                    const QString name = a.value(QStringLiteral("name")).toString();
                    const QString dl = a.value(QStringLiteral("browser_download_url")).toString();
                    if (name.compare(QStringLiteral("SekaiDesk-Setup.exe"), Qt::CaseInsensitive) == 0)
                        setupUrl = dl;
                    else if (name.compare(QStringLiteral("SekaiDesk-win64.zip"), Qt::CaseInsensitive) == 0)
                        zipUrl = dl;
                    else if (name.compare(QStringLiteral("SHA256SUMS.txt"), Qt::CaseInsensitive) == 0)
                        sumsUrl = dl;
                }
            }
        }

        const QString assetName = isInstaller
            ? QStringLiteral("SekaiDesk-Setup.exe")
            : QStringLiteral("SekaiDesk-win64.zip");
        const QString assetUrl = isInstaller ? setupUrl : zipUrl;
        const bool newer = err.isEmpty() && !tag.isEmpty() && !assetUrl.isEmpty() && isVersionNewer(tag, currentVer);

        m_busy.store(false);
        if (m_destroyed.load())
            return;

        QMetaObject::invokeMethod(this, [self, silent, err, tag, notes, htmlUrl, assetName, assetUrl, sumsUrl, newer]() {
            if (!self || self->m_destroyed.load())
                return;

            if (!err.isEmpty()) {
                if (silent) {
                    if (self->m_status == QLatin1String("checking"))
                        self->setState(QStringLiteral("idle"), QStringLiteral("Ready to check for updates"));
                } else {
                    self->setState(QStringLiteral("error"), err, err);
                }
                return;
            }

            self->m_latestVersion = tag;
            self->m_releaseNotes = notes;
            self->m_releaseUrl = htmlUrl;
            self->m_targetAssetName = assetName;
            self->m_targetAssetUrl = assetUrl;
            self->m_sumsUrl = sumsUrl;

            if (newer) {
                self->m_updateAvailable = true;
                self->m_toastVisible = true;
                self->setState(QStringLiteral("available"),
                               QStringLiteral("v%1 is ready to install").arg(tag));
            } else {
                self->m_updateAvailable = false;
                if (!silent) {
                    self->setState(QStringLiteral("up_to_date"),
                                   QStringLiteral("You are on the latest version (v%1)").arg(self->m_currentVersion));
                } else {
                    self->setState(QStringLiteral("idle"),
                                   QStringLiteral("Up to date (v%1)").arg(self->m_currentVersion));
                }
            }
        }, Qt::QueuedConnection);
    });
#else
    m_busy.store(false);
    Q_UNUSED(silent)
#endif
}

void UpdateService::startUpdate()
{
    if (m_busy.load() || m_destroyed.load())
        return;
    if (!m_updateAvailable || m_targetAssetUrl.isEmpty() || m_targetAssetName.isEmpty())
        return;
    joinWorkerIfFinished();

    m_busy.store(true);
    m_downloadedBytes = 0;
    m_totalBytes = 0;
    m_downloadProgress = 0.0;
    m_toastVisible = true;
    emit progressChanged();
    setState(QStringLiteral("downloading"),
             QStringLiteral("Downloading %1...").arg(m_targetAssetName));

#ifdef Q_OS_WIN
    const QPointer<UpdateService> self(this);
    const QString latestVer = m_latestVersion;
    const QString assetName = m_targetAssetName;
    const QString assetUrl = m_targetAssetUrl;
    const QString sumsUrl = m_sumsUrl;
    const bool isInstaller = m_isInstallerInstall;
    const QString appDirNative = QDir::toNativeSeparators(QCoreApplication::applicationDirPath());
    const unsigned long selfPid = GetCurrentProcessId();

    m_worker = std::thread([this, self, latestVer, assetName, assetUrl, sumsUrl, isInstaller, appDirNative, selfPid]() {
        const QString tempRoot = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
        const QString workDir = QDir::cleanPath(tempRoot + QStringLiteral("/SekaiDeskUpdate/") + latestVer);
        QDir().mkpath(workDir);
        const QString workDirNative = QDir::toNativeSeparators(workDir);
        const QString destPathNative = QDir::toNativeSeparators(workDir + QLatin1Char('/') + assetName);

        QString expectedSha;
        if (!sumsUrl.isEmpty()) {
            QByteArray sumsRaw;
            QString sumsErr;
            if (winHttpGetBytes(sumsUrl, QString(), sumsRaw, sumsErr, m_destroyed))
                expectedSha = parseSha256ForAsset(sumsRaw, assetName);
        }

        QString actualSha;
        QString dlErr;
        const bool dlOk = winHttpDownloadFileWithSha256(
            assetUrl,
            destPathNative,
            [this, self](qint64 got, qint64 total) {
                if (m_destroyed.load())
                    return;
                QMetaObject::invokeMethod(this, [self, got, total]() {
                    if (!self || self->m_destroyed.load())
                        return;
                    self->m_downloadedBytes = got;
                    self->m_totalBytes = total > 0 ? total : got;
                    self->m_downloadProgress = (total > 0)
                        ? qBound(0.0, static_cast<double>(got) / static_cast<double>(total), 1.0)
                        : 0.0;
                    emit self->progressChanged();
                }, Qt::QueuedConnection);
            },
            actualSha,
            dlErr,
            m_destroyed);

        if (!dlOk) {
            m_busy.store(false);
            if (!m_destroyed.load()) {
                QMetaObject::invokeMethod(this, [self, dlErr]() {
                    if (!self || self->m_destroyed.load())
                        return;
                    self->setState(QStringLiteral("error"), dlErr, dlErr);
                }, Qt::QueuedConnection);
            }
            return;
        }

        if (!m_destroyed.load()) {
            QMetaObject::invokeMethod(this, [self]() {
                if (!self || self->m_destroyed.load())
                    return;
                self->m_downloadProgress = 1.0;
                emit self->progressChanged();
                self->setState(QStringLiteral("verifying"), QStringLiteral("Verifying SHA-256..."));
            }, Qt::QueuedConnection);
        }

        if (!expectedSha.isEmpty() && expectedSha.compare(actualSha, Qt::CaseInsensitive) != 0) {
            QFile::remove(destPathNative);
            m_busy.store(false);
            if (!m_destroyed.load()) {
                QMetaObject::invokeMethod(this, [self]() {
                    if (!self || self->m_destroyed.load())
                        return;
                    const QString msg = QStringLiteral("SHA-256 checksum mismatch");
                    self->setState(QStringLiteral("error"), msg, msg);
                }, Qt::QueuedConnection);
            }
            return;
        }

        if (!m_destroyed.load()) {
            QMetaObject::invokeMethod(this, [self]() {
                if (!self || self->m_destroyed.load())
                    return;
                self->setState(QStringLiteral("installing"), QStringLiteral("Closing & installing update..."));
            }, Qt::QueuedConnection);
        }

        QString launchCmd;
        QString helperErr;
        wchar_t sysDirBuf[MAX_PATH]{};
        const UINT sysLen = GetSystemDirectoryW(sysDirBuf, MAX_PATH);
        const QString sysDir = (sysLen > 0)
            ? QDir::toNativeSeparators(QString::fromWCharArray(sysDirBuf, static_cast<int>(sysLen)))
            : QStringLiteral("C:\\Windows\\System32");

        if (isInstaller) {
            const QString cmdPath = QDir::toNativeSeparators(workDir + QStringLiteral("/apply_installer.cmd"));
            QFile cmdFile(cmdPath);
            if (!cmdFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
                helperErr = QStringLiteral("Failed to write installer helper script");
            } else {
                const QByteArray bat =
                    "@echo off\r\n"
                    "setlocal\r\n"
                    "set \"APPPID=%~1\"\r\n"
                    "set \"SETUP=%~2\"\r\n"
                    "set \"APPDIR=%~3\"\r\n"
                    "set \"LOG=%~dp0..\\updater.log\"\r\n"
                    "echo [%DATE% %TIME%] Installer updater started (PID=%APPPID%, APPDIR=%APPDIR%) >> \"%LOG%\"\r\n"
                    "set /a tries=0\r\n"
                    ":waitloop\r\n"
                    "tasklist /FI \"PID eq %APPPID%\" 2>NUL | find /I \"%APPPID%\" >NUL\r\n"
                    "if not errorlevel 1 (\r\n"
                    "    set /a tries+=1\r\n"
                    "    if %tries% LSS 30 (\r\n"
                    "        timeout /t 1 /nobreak >NUL\r\n"
                    "        goto waitloop\r\n"
                    "    )\r\n"
                    ")\r\n"
                    "echo [%DATE% %TIME%] Running \"%SETUP%\" /S /D=%APPDIR% >> \"%LOG%\"\r\n"
                    "\"%SETUP%\" /S /D=%APPDIR%\r\n"
                    "set \"SEKAIDESK_FAKE_VERSION=\"\r\n"
                    "if exist \"%APPDIR%\\SekaiDesk.exe\" (\r\n"
                    "    echo [%DATE% %TIME%] Relaunching SekaiDesk.exe >> \"%LOG%\"\r\n"
                    "    start \"\" /D \"%APPDIR%\" \"%APPDIR%\\SekaiDesk.exe\"\r\n"
                    ")\r\n"
                    "exit /b 0\r\n";
                cmdFile.write(bat);
                cmdFile.close();
                const QString cmdExe = sysDir + QStringLiteral("\\cmd.exe");
                launchCmd = QStringLiteral("\"%1\" /c \"\"%2\" %3 \"%4\" \"%5\"\"")
                                .arg(cmdExe, cmdPath)
                                .arg(selfPid)
                                .arg(destPathNative, appDirNative);
            }
        } else {
            const QString psPath = QDir::toNativeSeparators(workDir + QStringLiteral("/apply_portable.ps1"));
            QFile psFile(psPath);
            if (!psFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                helperErr = QStringLiteral("Failed to write portable updater script");
            } else {
                const QByteArray ps1 =
                    "param([int]$AppPid, [string]$ZipPath, [string]$AppDir, [string]$WorkDir)\r\n"
                    "$log = Join-Path (Split-Path $WorkDir -Parent) \"updater.log\"\r\n"
                    "function Log($m) { Add-Content -Path $log -Value (\"[{0:HH:mm:ss}] {1}\" -f (Get-Date), $m) -ErrorAction SilentlyContinue }\r\n"
                    "try {\r\n"
                    "    Log \"Portable updater started (PID=$AppPid, AppDir=$AppDir)\"\r\n"
                    "    try { Wait-Process -Id $AppPid -Timeout 30 -ErrorAction SilentlyContinue } catch {}\r\n"
                    "    Start-Sleep -Milliseconds 500\r\n"
                    "    $extractDir = Join-Path $WorkDir \"extracted\"\r\n"
                    "    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }\r\n"
                    "    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null\r\n"
                    "    try {\r\n"
                    "        Add-Type -AssemblyName System.IO.Compression.FileSystem\r\n"
                    "        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extractDir)\r\n"
                    "    } catch {\r\n"
                    "        Expand-Archive -Path $ZipPath -DestinationPath $extractDir -Force\r\n"
                    "    }\r\n"
                    "    $srcRoot = Join-Path $extractDir \"SekaiDesk\"\r\n"
                    "    if (-not (Test-Path $srcRoot)) { $srcRoot = $extractDir }\r\n"
                    "    $dllPath = Join-Path $AppDir \"SekaiTrayHook.dll\"\r\n"
                    "    $dllOld = Join-Path $AppDir \"SekaiTrayHook.dll.old\"\r\n"
                    "    if (Test-Path $dllOld) { Remove-Item $dllOld -Force -ErrorAction SilentlyContinue }\r\n"
                    "    if (Test-Path $dllPath) {\r\n"
                    "        try { Rename-Item -Path $dllPath -NewName \"SekaiTrayHook.dll.old\" -Force -ErrorAction Stop } catch {}\r\n"
                    "    }\r\n"
                    "    for ($attempt = 1; $attempt -le 3; $attempt++) {\r\n"
                    "        try {\r\n"
                    "            Copy-Item -Path (Join-Path $srcRoot \"*\") -Destination $AppDir -Recurse -Force -ErrorAction Stop\r\n"
                    "            break\r\n"
                    "        } catch {\r\n"
                    "            Log \"Copy attempt $attempt failed: $($_.Exception.Message)\"\r\n"
                    "            if ($attempt -ge 3) { throw }\r\n"
                    "            Start-Sleep -Milliseconds 600\r\n"
                    "        }\r\n"
                    "    }\r\n"
                    "    Remove-Item Env:SEKAIDESK_FAKE_VERSION -ErrorAction SilentlyContinue\r\n"
                    "    $exe = Join-Path $AppDir \"SekaiDesk.exe\"\r\n"
                    "    if (Test-Path $exe) {\r\n"
                    "        Log \"Relaunching $exe\"\r\n"
                    "        Start-Process -FilePath $exe -WorkingDirectory $AppDir\r\n"
                    "    }\r\n"
                    "    Start-Sleep -Seconds 2\r\n"
                    "    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue\r\n"
                    "} catch {\r\n"
                    "    Log \"ERROR: $($_.Exception.Message)\"\r\n"
                    "}\r\n";
                psFile.write(ps1);
                psFile.close();
                const QString psExe = sysDir + QStringLiteral("\\WindowsPowerShell\\v1.0\\powershell.exe");
                launchCmd = QStringLiteral(
                    "\"%1\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
                    "-File \"%2\" -AppPid %3 -ZipPath \"%4\" -AppDir \"%5\" -WorkDir \"%6\"")
                    .arg(psExe, psPath)
                    .arg(selfPid)
                    .arg(destPathNative, appDirNative, workDirNative);
            }
        }

        if (helperErr.isEmpty())
            spawnDetachedProcess(launchCmd, workDirNative, helperErr);

        m_busy.store(false);
        if (m_destroyed.load())
            return;

        QMetaObject::invokeMethod(this, [self, helperErr]() {
            if (!self || self->m_destroyed.load())
                return;
            if (!helperErr.isEmpty()) {
                self->setState(QStringLiteral("error"), helperErr, helperErr);
                return;
            }
            emit self->quitForUpdateRequested();
        }, Qt::QueuedConnection);
    });
#else
    m_busy.store(false);
#endif
}
