#include "DeskExtrasService.h"
#include "MediaService.h"
#include "core/SettingsStore.h"

#include <QClipboard>
#include <QDate>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QMimeData>
#include <QPointer>
#include <QProcess>
#include <QRegularExpression>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantMap>
#include <QVector>
#include <QWindow>

#include <algorithm>
#include <cmath>
#include <functional>
#include <thread>
#include <vector>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <commdlg.h>
#include <objbase.h>
#include <shellapi.h>
#include <winhttp.h>
#endif

namespace {

struct HttpResult {
    int statusCode = 0;
    QByteArray body;
    QString error;
};

HttpResult curlGetSync(const QString& urlStr)
{
    HttpResult res;
#ifdef Q_OS_WIN
    const QUrl url(urlStr);
    if (!url.isValid() || url.host().isEmpty()) {
        res.error = QStringLiteral("Invalid URL");
        return res;
    }

    QString encodedUrl = QString::fromLatin1(url.toEncoded());
    encodedUrl.remove(QLatin1Char('"'));

    wchar_t sysDir[MAX_PATH]{};
    std::wstring curlExe = L"curl.exe";
    if (GetSystemDirectoryW(sysDir, MAX_PATH) > 0) {
        std::wstring candidate = std::wstring(sysDir) + L"\\curl.exe";
        if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES)
            curlExe = std::move(candidate);
    }

    const std::wstring cmdLine =
        L"\"" + curlExe + L"\" -4 -sS -L --connect-timeout 5 --max-time 8 "
        L"-A \"SekaiDesk/0.2\" -w \"\\n%{http_code}\" \"" + encodedUrl.toStdWString() + L"\"";
    std::vector<wchar_t> cmdBuf(cmdLine.begin(), cmdLine.end());
    cmdBuf.push_back(L'\0');

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE hRead = nullptr;
    HANDLE hWrite = nullptr;
    if (!CreatePipe(&hRead, &hWrite, &sa, 0)) {
        res.error = QStringLiteral("CreatePipe failed");
        return res;
    }
    SetHandleInformation(hRead, HANDLE_FLAG_INHERIT, 0);

    HANDLE hNulOut = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    HANDLE hNulIn = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = hWrite;
    si.hStdError = (hNulOut != INVALID_HANDLE_VALUE) ? hNulOut : hWrite;
    si.hStdInput = (hNulIn != INVALID_HANDLE_VALUE) ? hNulIn : nullptr;

    PROCESS_INFORMATION pi{};
    const BOOL ok = CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, TRUE,
                                   CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(hWrite);
    if (hNulOut != INVALID_HANDLE_VALUE)
        CloseHandle(hNulOut);
    if (hNulIn != INVALID_HANDLE_VALUE)
        CloseHandle(hNulIn);

    if (!ok) {
        CloseHandle(hRead);
        res.error = QStringLiteral("curl CreateProcessW failed (%1)").arg(GetLastError());
        return res;
    }

    QByteArray out;
    char buf[16384];
    DWORD bytesRead = 0;
    while (ReadFile(hRead, buf, sizeof(buf), &bytesRead, nullptr) && bytesRead > 0) {
        out.append(buf, static_cast<int>(bytesRead));
        if (out.size() > 4 * 1024 * 1024 + 64)
            break;
    }
    CloseHandle(hRead);
    WaitForSingleObject(pi.hProcess, 1500);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    const int nl = out.lastIndexOf('\n');
    if (nl >= 0) {
        const QByteArray codeBytes = out.mid(nl + 1).trimmed();
        bool codeOk = false;
        const int code = codeBytes.toInt(&codeOk);
        if (codeOk && codeBytes.size() == 3) {
            res.statusCode = code;
            res.body = out.left(nl);
            if (res.statusCode == 0)
                res.error = QStringLiteral("curl HTTP 000");
            return res;
        }
    } else {
        const QByteArray codeBytes = out.trimmed();
        bool codeOk = false;
        const int code = codeBytes.toInt(&codeOk);
        if (codeOk && codeBytes.size() == 3) {
            res.statusCode = code;
            if (res.statusCode == 0)
                res.error = QStringLiteral("curl HTTP 000");
            return res;
        }
    }
    res.error = QStringLiteral("curl parse failed");
#else
    Q_UNUSED(urlStr);
    res.error = QStringLiteral("Unsupported platform");
#endif
    return res;
}

HttpResult winHttpGetSync(const QString& urlStr)
{
    HttpResult res;
#ifdef Q_OS_WIN
    const QUrl url(urlStr);
    if (!url.isValid() || url.host().isEmpty()) {
        res.error = QStringLiteral("Invalid URL");
        return res;
    }

    const bool isHttps = (url.scheme().compare(QStringLiteral("https"), Qt::CaseInsensitive) == 0);
    const std::wstring hostW = url.host().toStdWString();
    QString pathAndQuery = url.path(QUrl::FullyEncoded);
    if (pathAndQuery.isEmpty())
        pathAndQuery = QStringLiteral("/");
    if (url.hasQuery())
        pathAndQuery += QStringLiteral("?") + url.query(QUrl::FullyEncoded);
    const std::wstring pathW = pathAndQuery.toStdWString();
    const INTERNET_PORT port = url.port(isHttps ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT);

    HINTERNET hSession = WinHttpOpen(
        L"SekaiDesk/0.2",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);
    if (!hSession) {
        res.error = QStringLiteral("WinHttpOpen failed (%1)").arg(GetLastError());
        return res;
    }

    WinHttpSetTimeouts(hSession, 6000, 6000, 6000, 6000);
    DWORD redirPolicy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(hSession, WINHTTP_OPTION_REDIRECT_POLICY, &redirPolicy, sizeof(redirPolicy));

    HINTERNET hConnect = WinHttpConnect(hSession, hostW.c_str(), port, 0);
    if (!hConnect) {
        res.error = QStringLiteral("WinHttpConnect failed (%1)").arg(GetLastError());
        WinHttpCloseHandle(hSession);
        return res;
    }

    HINTERNET hRequest = WinHttpOpenRequest(
        hConnect,
        L"GET",
        pathW.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        isHttps ? WINHTTP_FLAG_SECURE : 0);
    if (!hRequest) {
        res.error = QStringLiteral("WinHttpOpenRequest failed (%1)").arg(GetLastError());
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return res;
    }

    const wchar_t* headers = L"Accept: application/json\r\nUser-Agent: SekaiDesk/0.2 (Windows NT)\r\n";
    if (!WinHttpSendRequest(hRequest, headers, static_cast<DWORD>(-1L), WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(hRequest, nullptr)) {
        res.error = QStringLiteral("HTTP request failed (%1)").arg(GetLastError());
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return res;
    }

    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    if (WinHttpQueryHeaders(hRequest,
                            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX,
                            &statusCode,
                            &statusSize,
                            WINHTTP_NO_HEADER_INDEX)) {
        res.statusCode = static_cast<int>(statusCode);
    }

    DWORD avail = 0;
    while (WinHttpQueryDataAvailable(hRequest, &avail) && avail > 0) {
        const DWORD toRead = qMin<DWORD>(avail, 65536);
        QByteArray chunk(static_cast<int>(toRead), Qt::Uninitialized);
        DWORD readBytes = 0;
        if (!WinHttpReadData(hRequest, chunk.data(), toRead, &readBytes) || readBytes == 0)
            break;
        chunk.truncate(static_cast<int>(readBytes));
        res.body.append(chunk);
        if (res.body.size() > 4 * 1024 * 1024)
            break;
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
#else
    res.error = QStringLiteral("Unsupported platform");
#endif
    return res;
}

void runHttpAsync(QObject* receiver, const QString& url, std::function<void(HttpResult)> onDone)
{
    QPointer<QObject> guard(receiver);
    std::thread([guard, url, cb = std::move(onDone)]() mutable {
        HttpResult result = curlGetSync(url);
        if (result.statusCode <= 0) {
            HttpResult fallback = winHttpGetSync(url);
            if (fallback.statusCode > 0 || result.error.isEmpty())
                result = std::move(fallback);
        }
        if (!guard)
            return;
        QMetaObject::invokeMethod(
            guard.data(),
            [guard, result = std::move(result), cb = std::move(cb)]() mutable {
                if (guard)
                    cb(result);
            },
            Qt::QueuedConnection);
    }).detach();
}

QString sanitizeArtist(QString raw)
{
    static const QRegularExpression kTopicRe(
        QStringLiteral("\\s*-\\s*Topic\\s*$"), QRegularExpression::CaseInsensitiveOption);
    raw.remove(kTopicRe);
    static const QRegularExpression kOfficialRe(
        QStringLiteral("\\s*(?:-\\s*)?(?:Official(?:\\s+Channel)?|VEVO)\\s*$"),
        QRegularExpression::CaseInsensitiveOption);
    raw.remove(kOfficialRe);
    return raw.simplified().trimmed();
}

QString sanitizeTrackText(QString raw)
{
    static const QRegularExpression kJpBracketRe(QStringLiteral("【[^】]*】"));
    raw.remove(kJpBracketRe);
    static const QRegularExpression kParenRe(
        QStringLiteral("\\s*[\\[(](?:official|lyrics|audio|mv|music video|hd|4k|remix|feat\\.|ft\\.|explicit|ver\\.|version|visualizer|cover(?:ed)?(?:\\s+by)?|arrange|公式|歌詞|歌ってみた)[^\\])]*[\\])]"),
        QRegularExpression::CaseInsensitiveOption);
    raw.remove(kParenRe);
    static const QRegularExpression kCoverByRe(
        QStringLiteral("(?:\\s+[-/|·•])?\\s*(?:Arrange\\s+)?(?:covered|cover|sung|vocal)\\s+by\\s+.*$"),
        QRegularExpression::CaseInsensitiveOption);
    raw.remove(kCoverByRe);
    static const QRegularExpression kCoverTagRe(
        QStringLiteral("\\b(?:Arrange|Covered|Cover|歌ってみた|Full\\s+Ver\\.?|Short\\s+Ver\\.?)\\b"),
        QRegularExpression::CaseInsensitiveOption);
    raw.remove(kCoverTagRe);
    static const QRegularExpression kFeatRe(
        QStringLiteral("\\s+(?:feat\\.|ft\\.)\\s+.*$"),
        QRegularExpression::CaseInsensitiveOption);
    raw.remove(kFeatRe);
    static const QRegularExpression kTrailingSepRe(QStringLiteral("\\s*[-/|·•]\\s*$"));
    raw.remove(kTrailingSepRe);
    return raw.simplified().trimmed();
}

bool needsTranslationFor(const QString& targetLang, const QVariantList& lines)
{
    if (targetLang == QStringLiteral("off") || lines.isEmpty())
        return false;
    QString sample;
    const int n = qMin(lines.size(), 12);
    for (int i = 0; i < n; ++i)
        sample += lines.at(i).toMap().value(QStringLiteral("text")).toString();

    if (targetLang == QStringLiteral("en")) {
        for (const QChar ch : sample) {
            if (ch.unicode() > 0x024F)
                return true;
        }
        return false;
    }
    if (targetLang == QStringLiteral("vi")) {
        static const QString viChars = QStringLiteral("ăâđêôơưĂÂĐÊÔƠƯ");
        for (const QChar ch : sample) {
            const ushort u = ch.unicode();
            if ((u >= 0x1EA0 && u <= 0x1EF9) || viChars.contains(ch))
                return false;
        }
        return true;
    }
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// LyricsService
// ---------------------------------------------------------------------------

LyricsService::LyricsService(MediaService* media, QObject* parent)
    : QObject(parent)
    , m_media(media)
{
    m_tickTimer.setInterval(120);
    m_tickTimer.setTimerType(Qt::CoarseTimer);
    connect(&m_tickTimer, &QTimer::timeout, this, &LyricsService::updateActiveLine);

    if (m_media) {
        connect(m_media, &MediaService::mediaChanged, this, &LyricsService::onMediaUpdated);
        connect(m_media, &MediaService::timelineChanged, this, &LyricsService::onTimelineUpdated);
    }
    onMediaUpdated();
}

void LyricsService::setPaused(bool paused)
{
    if (m_paused == paused)
        return;
    m_paused = paused;
    if (m_paused) {
        m_tickTimer.stop();
    } else if (m_media && m_media->isPlaying() && !m_lines.isEmpty()) {
        m_anchorMs = QDateTime::currentMSecsSinceEpoch();
        updateActiveLine();
        m_tickTimer.start();
    }
}

void LyricsService::setTranslateLang(const QString& lang)
{
    const QString l = lang.trimmed().toLower();
    const QString norm = (l == QStringLiteral("vi") || l == QStringLiteral("off")) ? l : QStringLiteral("en");
    if (m_translateLang == norm)
        return;
    m_translateLang = norm;
    m_translatedLines.clear();
    emit translateLangChanged();
    emit lyricsChanged();
    if (!m_lines.isEmpty() && m_translateLang != QStringLiteral("off"))
        startTranslationIfNeeded(m_requestGen);
}

void LyricsService::refresh()
{
    if (!m_media || m_media->title().trimmed().isEmpty()) {
        m_loading = false;
        m_synced = false;
        m_lines.clear();
        m_translatedLines.clear();
        m_plainText.clear();
        m_activeIndex = -1;
        m_trackKey.clear();
        m_statusText = QStringLiteral("No track playing");
        m_tickTimer.stop();
        emit lyricsChanged();
        emit activeIndexChanged();
        return;
    }
    m_pendingKey.clear();
    fetchLyrics(m_media->title().trimmed(), m_media->artist().trimmed(), m_media->durationSec(), true);
}

void LyricsService::searchManual(const QString& query)
{
    const QString cleaned = query.trimmed();
    if (cleaned.isEmpty())
        return;

    ++m_requestGen;
    const uint64_t gen = m_requestGen;
    m_loading = true;
    m_synced = false;
    m_lines.clear();
    m_translatedLines.clear();
    m_plainText.clear();
    m_activeIndex = -1;
    m_trackKey = cleaned;
    m_pendingKey = cleaned;
    m_lastReportedPosSec = -1.0;
    m_anchorPosSec = m_media ? m_media->positionSec() : 0.0;
    m_anchorMs = QDateTime::currentMSecsSinceEpoch();
    m_wasPlaying = m_media ? m_media->isPlaying() : false;
    m_statusText = QStringLiteral("Searching \"%1\"...").arg(cleaned);
    m_tickTimer.stop();
    emit lyricsChanged();
    emit activeIndexChanged();

    const double targetDuration = (m_media && m_media->hasSession()) ? m_media->durationSec() : 0.0;
    fetchSearchFallback(cleaned, targetDuration, gen);
}

void LyricsService::onMediaUpdated()
{
    if (!m_media || !m_media->hasSession() || m_media->title().trimmed().isEmpty()) {
        ++m_requestGen;
        const bool wasEmpty = m_lines.isEmpty() && m_plainText.isEmpty() && !m_loading;
        m_loading = false;
        m_synced = false;
        m_lines.clear();
        m_translatedLines.clear();
        m_plainText.clear();
        m_activeIndex = -1;
        m_trackKey.clear();
        m_pendingKey.clear();
        m_lastReportedPosSec = -1.0;
        m_wasPlaying = false;
        m_statusText = QStringLiteral("Play music or search manually");
        m_tickTimer.stop();
        if (!wasEmpty) {
            emit lyricsChanged();
            emit activeIndexChanged();
        }
        return;
    }

    onTimelineUpdated();

    const QString key = m_media->title().trimmed() + QStringLiteral("|") + m_media->artist().trimmed();
    if (key != m_pendingKey)
        fetchLyrics(m_media->title().trimmed(), m_media->artist().trimmed(), m_media->durationSec());
}

void LyricsService::onTimelineUpdated()
{
    if (!m_media)
        return;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const double reported = m_media->positionSec();
    const bool playing = m_media->isPlaying();

    double curInterp = m_anchorPosSec;
    if (m_wasPlaying && m_anchorMs > 0) {
        const qint64 elapsed = now - m_anchorMs;
        if (elapsed > 0 && elapsed < 300000)
            curInterp += elapsed / 1000.0;
    }

    if (m_lastReportedPosSec < 0.0 || qAbs(reported - m_lastReportedPosSec) > 0.25) {
        m_anchorPosSec = reported;
        m_anchorMs = now;
    } else if (playing != m_wasPlaying) {
        if (!playing)
            m_anchorPosSec = curInterp;
        m_anchorMs = now;
    }

    m_lastReportedPosSec = reported;
    m_wasPlaying = playing;

    if (m_synced && !m_lines.isEmpty()) {
        if (!m_paused && playing && !m_tickTimer.isActive())
            m_tickTimer.start();
        else if ((!playing || m_paused) && m_tickTimer.isActive())
            m_tickTimer.stop();
    }
    updateActiveLine();
}

void LyricsService::fetchLyrics(const QString& title, const QString& artist, double durationSec, bool force)
{
    const QString key = title + QStringLiteral("|") + artist;
    if (!force && key == m_pendingKey)
        return;

    ++m_requestGen;
    const uint64_t gen = m_requestGen;

    m_pendingKey = key;
    m_trackKey = key;
    m_loading = true;
    m_synced = false;
    m_lines.clear();
    m_translatedLines.clear();
    m_plainText.clear();
    m_activeIndex = -1;
    m_lastReportedPosSec = -1.0;
    m_anchorPosSec = m_media ? m_media->positionSec() : 0.0;
    m_anchorMs = QDateTime::currentMSecsSinceEpoch();
    m_wasPlaying = m_media ? m_media->isPlaying() : false;
    m_statusText = QStringLiteral("Fetching lyrics...");
    m_tickTimer.stop();
    emit lyricsChanged();
    emit activeIndexChanged();

    const QString cleanTitle = sanitizeTrackText(title);
    const QString queryTitle = cleanTitle.isEmpty() ? title : cleanTitle;
    const QString cleanArtist = sanitizeArtist(artist);

    QUrl url(QStringLiteral("https://lrclib.net/api/get"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("track_name"), queryTitle);
    if (!cleanArtist.isEmpty())
        q.addQueryItem(QStringLiteral("artist_name"), cleanArtist);
    if (durationSec > 10.0)
        q.addQueryItem(QStringLiteral("duration"), QString::number(qRound(durationSec)));
    url.setQuery(q);

    runHttpAsync(this, url.toString(QUrl::FullyEncoded), [this, gen, queryTitle, cleanArtist, durationSec](const HttpResult& res) {
        if (gen != m_requestGen)
            return;

        if (res.statusCode == 200 && applyTrackJson(res.body, false, durationSec)) {
            m_loading = false;
            emit lyricsChanged();
            updateActiveLine();
            startTranslationIfNeeded(gen);
            return;
        }

        // Clean up YouTube / Spotify suffixes for search fallback
        QString searchQ = queryTitle;
        if (!cleanArtist.isEmpty() && !searchQ.contains(cleanArtist, Qt::CaseInsensitive))
            searchQ = searchQ + QStringLiteral(" ") + cleanArtist;
        const QString secondaryQ = (searchQ != queryTitle) ? queryTitle : QString();

        fetchSearchFallback(searchQ, durationSec, gen, secondaryQ);
    });
}

void LyricsService::fetchSearchFallback(const QString& query, double targetDuration, uint64_t gen, const QString& secondaryQuery)
{
    QUrl url(QStringLiteral("https://lrclib.net/api/search"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("q"), query);
    url.setQuery(q);

    runHttpAsync(this, url.toString(QUrl::FullyEncoded), [this, gen, targetDuration, secondaryQuery](const HttpResult& res) {
        if (gen != m_requestGen)
            return;

        if (res.statusCode == 200 && !res.body.isEmpty()) {
            const QJsonDocument doc = QJsonDocument::fromJson(res.body);
            if (doc.isArray()) {
                const QJsonArray arr = doc.array();
                int bestIdx = -1;
                double bestScore = -1e9;
                for (int i = 0; i < arr.size(); ++i) {
                    const QJsonObject obj = arr.at(i).toObject();
                    const bool hasSync = !obj.value(QStringLiteral("syncedLyrics")).toString().trimmed().isEmpty();
                    const bool hasPlain = !obj.value(QStringLiteral("plainLyrics")).toString().trimmed().isEmpty();
                    if (!hasSync && !hasPlain)
                        continue;
                    double score = hasSync ? 100.0 : 20.0;
                    const double d = obj.value(QStringLiteral("duration")).toDouble();
                    if (targetDuration > 10.0 && d > 10.0)
                        score -= std::abs(d - targetDuration) * 0.5;
                    if (score > bestScore) {
                        bestScore = score;
                        bestIdx = i;
                    }
                }
                if (bestIdx >= 0) {
                    m_loading = false;
                    const QJsonObject chosen = arr.at(bestIdx).toObject();
                    const QString syncedLrc = chosen.value(QStringLiteral("syncedLyrics")).toString().trimmed();
                    const QString plainLrc = chosen.value(QStringLiteral("plainLyrics")).toString().trimmed();
                    const double recDur = chosen.value(QStringLiteral("duration")).toDouble();
                    const double effDur = targetDuration > 10.0 ? targetDuration : recDur;
                    if (!syncedLrc.isEmpty()) {
                        parseLrc(syncedLrc);
                        m_synced = !m_lines.isEmpty();
                        m_statusText = m_synced ? QStringLiteral("Synced") : QStringLiteral("Plain");
                    } else if (!plainLrc.isEmpty()) {
                        applyPlainLyrics(plainLrc, effDur);
                    }
                    emit lyricsChanged();
                    updateActiveLine();
                    startTranslationIfNeeded(gen);
                    return;
                }
            }
        }

        if (!secondaryQuery.isEmpty()) {
            fetchSearchFallback(secondaryQuery, targetDuration, gen, QString());
            return;
        }

        m_loading = false;
        m_synced = false;
        m_lines.clear();
        m_translatedLines.clear();
        m_plainText.clear();
        m_statusText = res.error.isEmpty()
            ? QStringLiteral("No lyrics found on LRCLIB")
            : QStringLiteral("Lyrics offline (%1)").arg(res.error);
        emit lyricsChanged();
        emit activeIndexChanged();
    });
}

bool LyricsService::applyTrackJson(const QByteArray& body, bool allowArray, double targetDuration)
{
    const QJsonDocument doc = QJsonDocument::fromJson(body);
    QJsonObject obj;
    if (doc.isObject()) {
        obj = doc.object();
    } else if (allowArray && doc.isArray() && !doc.array().isEmpty()) {
        obj = doc.array().first().toObject();
    } else {
        return false;
    }

    const QString syncedLrc = obj.value(QStringLiteral("syncedLyrics")).toString().trimmed();
    const QString plainLrc = obj.value(QStringLiteral("plainLyrics")).toString().trimmed();
    const double recDur = obj.value(QStringLiteral("duration")).toDouble();
    const double effDur = targetDuration > 10.0 ? targetDuration : recDur;

    if (!syncedLrc.isEmpty()) {
        parseLrc(syncedLrc);
        if (!m_lines.isEmpty()) {
            m_synced = true;
            m_statusText = QStringLiteral("Synced");
            return true;
        }
    }
    if (!plainLrc.isEmpty()) {
        applyPlainLyrics(plainLrc, effDur);
        return !m_lines.isEmpty();
    }
    return false;
}

void LyricsService::applyPlainLyrics(const QString& plainLrc, double targetDuration)
{
    m_plainText = plainLrc;
    m_lines.clear();
    QStringList nonEmpty;
    const QStringList splitLines = plainLrc.split(QLatin1Char('\n'));
    for (const QString& ln : splitLines) {
        const QString t = ln.trimmed();
        if (!t.isEmpty())
            nonEmpty.append(t);
    }
    const double dur = (targetDuration > 10.0) ? targetDuration : 180.0;
    const int total = nonEmpty.size();
    for (int i = 0; i < total; ++i) {
        QVariantMap row;
        row[QStringLiteral("time")] = (dur * i) / qMax(1, total);
        row[QStringLiteral("text")] = nonEmpty.at(i);
        m_lines.append(row);
    }
    m_synced = !m_lines.isEmpty();
    m_statusText = QStringLiteral("Auto-scroll");
    if (!m_paused && m_media && m_media->isPlaying() && !m_lines.isEmpty())
        m_tickTimer.start();
}

void LyricsService::startTranslationIfNeeded(uint64_t gen)
{
    if (gen != m_requestGen || m_lines.isEmpty() || m_translateLang == QStringLiteral("off"))
        return;
    if (!needsTranslationFor(m_translateLang, m_lines))
        return;

    m_translatedLines.clear();
    m_translatedLines.reserve(m_lines.size());
    for (int i = 0; i < m_lines.size(); ++i)
        m_translatedLines.append(QString());

    QList<QPair<int, int>> ranges;
    int chunkStart = 0;
    int chunkBytes = 0;
    for (int i = 0; i < m_lines.size(); ++i) {
        const int lineBytes = m_lines.at(i).toMap().value(QStringLiteral("text")).toString().toUtf8().size() + 1;
        if (i > chunkStart && chunkBytes + lineBytes > 1100) {
            ranges.append(qMakePair(chunkStart, i));
            chunkStart = i;
            chunkBytes = 0;
            if (ranges.size() >= 4)
                break;
        }
        chunkBytes += lineBytes;
    }
    if (ranges.size() < 4 && chunkStart < m_lines.size())
        ranges.append(qMakePair(chunkStart, m_lines.size()));

    if (!ranges.isEmpty())
        translateChunk(0, ranges, m_translateLang, gen);
}

void LyricsService::translateChunk(int chunkIdx, const QList<QPair<int, int>>& ranges, const QString& targetLang, uint64_t gen)
{
    if (gen != m_requestGen || chunkIdx >= ranges.size() || m_translateLang != targetLang)
        return;

    const int start = ranges.at(chunkIdx).first;
    const int end = qMin(ranges.at(chunkIdx).second, m_lines.size());
    if (start >= end)
        return;

    QStringList batch;
    batch.reserve(end - start);
    for (int i = start; i < end; ++i)
        batch.append(m_lines.at(i).toMap().value(QStringLiteral("text")).toString());

    QUrl url(QStringLiteral("https://translate.googleapis.com/translate_a/single"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("client"), QStringLiteral("gtx"));
    q.addQueryItem(QStringLiteral("sl"), QStringLiteral("auto"));
    q.addQueryItem(QStringLiteral("tl"), targetLang);
    q.addQueryItem(QStringLiteral("dt"), QStringLiteral("t"));
    q.addQueryItem(QStringLiteral("q"), batch.join(QLatin1Char('\n')));
    url.setQuery(q);

    runHttpAsync(this, url.toString(QUrl::FullyEncoded), [this, chunkIdx, ranges, targetLang, gen, start, end](const HttpResult& res) {
        if (gen != m_requestGen || m_translateLang != targetLang)
            return;
        if (res.statusCode == 200 && !res.body.isEmpty()) {
            const QJsonDocument doc = QJsonDocument::fromJson(res.body);
            if (doc.isArray() && !doc.array().isEmpty()) {
                const QJsonArray segs = doc.array().at(0).toArray();
                QString full;
                for (const QJsonValue& v : segs) {
                    if (v.isArray() && !v.toArray().isEmpty())
                        full += v.toArray().at(0).toString();
                }
                const QStringList trans = full.split(QLatin1Char('\n'));
                for (int k = 0; k < (end - start) && k < trans.size(); ++k) {
                    if (start + k < m_translatedLines.size())
                        m_translatedLines[start + k] = trans.at(k).trimmed();
                }
                emit lyricsChanged();
            }
        }
        translateChunk(chunkIdx + 1, ranges, targetLang, gen);
    });
}

void LyricsService::parseLrc(const QString& lrcText)
{
    m_lines.clear();
    static const QRegularExpression kTimeTag(QStringLiteral("\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]"));

    const QStringList rawLines = lrcText.split(QLatin1Char('\n'));
    QList<QPair<double, QString>> entries;

    for (const QString& raw : rawLines) {
        QList<double> times;
        int lastEnd = 0;
        QRegularExpressionMatchIterator it = kTimeTag.globalMatch(raw);
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            const int mins = m.captured(1).toInt();
            const int secs = m.captured(2).toInt();
            const QString fracStr = m.captured(3);
            double frac = 0.0;
            if (fracStr.length() == 1)
                frac = fracStr.toInt() / 10.0;
            else if (fracStr.length() == 2)
                frac = fracStr.toInt() / 100.0;
            else if (fracStr.length() >= 3)
                frac = fracStr.left(3).toInt() / 1000.0;
            times.append(mins * 60.0 + secs + frac);
            lastEnd = m.capturedEnd();
        }
        if (times.isEmpty())
            continue;
        QString text = raw.mid(lastEnd).trimmed();
        if (text.isEmpty())
            text = QStringLiteral("♪");
        for (double t : times)
            entries.append(qMakePair(t, text));
    }

    std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
        return a.first < b.first;
    });

    for (const auto& entry : entries) {
        QVariantMap row;
        row[QStringLiteral("time")] = entry.first;
        row[QStringLiteral("text")] = entry.second;
        m_lines.append(row);
    }

    if (!m_paused && m_media && m_media->isPlaying() && !m_lines.isEmpty())
        m_tickTimer.start();
}

void LyricsService::updateActiveLine()
{
    if (!m_synced || m_lines.isEmpty()) {
        if (m_activeIndex != -1) {
            m_activeIndex = -1;
            emit activeIndexChanged();
        }
        return;
    }

    double currentPos = m_anchorPosSec;
    if (m_media && m_media->isPlaying() && m_anchorMs > 0) {
        const qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - m_anchorMs;
        if (elapsed > 0 && elapsed < 300000)
            currentPos += elapsed / 1000.0;
    }

    int idx = -1;
    for (int i = 0; i < m_lines.size(); ++i) {
        const double t = m_lines.at(i).toMap().value(QStringLiteral("time")).toDouble();
        if (t <= currentPos + 0.15)
            idx = i;
        else
            break;
    }

    if (idx != m_activeIndex) {
        m_activeIndex = idx;
        emit activeIndexChanged();
    }
}

// ---------------------------------------------------------------------------
// WeatherService
// ---------------------------------------------------------------------------

WeatherService::WeatherService(SettingsStore* settings, QObject* parent)
    : QObject(parent)
    , m_settings(settings)
{
    if (m_settings) {
        const QString savedCity = m_settings->get(QStringLiteral("weather.city"), QStringLiteral("Ho Chi Minh")).toString().trimmed();
        if (!savedCity.isEmpty())
            m_city = savedCity;
        m_lat = m_settings->get(QStringLiteral("weather.lat"), 10.8231).toDouble();
        m_lon = m_settings->get(QStringLiteral("weather.lon"), 106.6297).toDouble();
    }

    m_refreshTimer.setInterval(20 * 60 * 1000);
    connect(&m_refreshTimer, &QTimer::timeout, this, &WeatherService::refresh);
    m_refreshTimer.start();

    QTimer::singleShot(900, this, &WeatherService::refresh);
}

void WeatherService::refresh()
{
    if (m_city.trimmed().isEmpty()) {
        locateAndFetch();
    } else {
        fetchForecast(m_lat, m_lon, m_city);
    }
}

void WeatherService::setCity(const QString& cityName)
{
    const QString cleaned = cityName.trimmed();
    if (cleaned.isEmpty()) {
        if (m_settings)
            m_settings->set(QStringLiteral("weather.city"), QString());
        locateAndFetch();
        return;
    }

    ++m_requestGen;
    const uint64_t gen = m_requestGen;
    m_loading = true;
    emit weatherChanged();

    QUrl url(QStringLiteral("https://geocoding-api.open-meteo.com/v1/search"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("name"), cleaned);
    q.addQueryItem(QStringLiteral("count"), QStringLiteral("1"));
    q.addQueryItem(QStringLiteral("language"), QStringLiteral("en"));
    url.setQuery(q);

    runHttpAsync(this, url.toString(QUrl::FullyEncoded), [this, gen, cleaned](const HttpResult& res) {
        if (gen != m_requestGen)
            return;

        if (res.statusCode == 200) {
            const QJsonDocument doc = QJsonDocument::fromJson(res.body);
            const QJsonArray results = doc.object().value(QStringLiteral("results")).toArray();
            if (!results.isEmpty()) {
                const QJsonObject first = results.first().toObject();
                const double lat = first.value(QStringLiteral("latitude")).toDouble(m_lat);
                const double lon = first.value(QStringLiteral("longitude")).toDouble(m_lon);
                const QString name = first.value(QStringLiteral("name")).toString(cleaned);
                m_city = name;
                m_lat = lat;
                m_lon = lon;
                if (m_settings) {
                    m_settings->set(QStringLiteral("weather.city"), name);
                    m_settings->set(QStringLiteral("weather.lat"), lat);
                    m_settings->set(QStringLiteral("weather.lon"), lon);
                }
                fetchForecast(lat, lon, name);
                return;
            }
        }
        m_loading = false;
        emit weatherChanged();
    });
}

void WeatherService::locateAndFetch()
{
    ++m_requestGen;
    const uint64_t gen = m_requestGen;
    m_loading = true;
    emit weatherChanged();

    runHttpAsync(this, QStringLiteral("https://ipwho.is/"), [this, gen](const HttpResult& res) {
        if (gen != m_requestGen)
            return;

        double lat = m_lat;
        double lon = m_lon;
        QString city = m_city;

        if (res.statusCode == 200) {
            const QJsonObject obj = QJsonDocument::fromJson(res.body).object();
            if (obj.value(QStringLiteral("success")).toBool(true)) {
                lat = obj.value(QStringLiteral("latitude")).toDouble(lat);
                lon = obj.value(QStringLiteral("longitude")).toDouble(lon);
                const QString detected = obj.value(QStringLiteral("city")).toString().trimmed();
                if (!detected.isEmpty())
                    city = detected;
            }
        }

        m_lat = lat;
        m_lon = lon;
        m_city = city;
        if (m_settings) {
            m_settings->set(QStringLiteral("weather.city"), city);
            m_settings->set(QStringLiteral("weather.lat"), lat);
            m_settings->set(QStringLiteral("weather.lon"), lon);
        }
        fetchForecast(lat, lon, city);
    });
}

void WeatherService::fetchForecast(double lat, double lon, const QString& cityLabel)
{
    ++m_requestGen;
    const uint64_t gen = m_requestGen;
    m_loading = true;
    emit weatherChanged();

    const QString urlStr = QStringLiteral(
        "https://api.open-meteo.com/v1/forecast?latitude=%1&longitude=%2"
        "&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,wind_direction_10m,pressure_msl,precipitation"
        "&hourly=temperature_2m,apparent_temperature,precipitation_probability,weather_code,uv_index,is_day,visibility"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max,sunrise,sunset&timezone=auto&forecast_days=3")
        .arg(lat, 0, 'f', 4)
        .arg(lon, 0, 'f', 4);

    runHttpAsync(this, urlStr, [this, gen, cityLabel](const HttpResult& res) {
        if (gen != m_requestGen)
            return;

        m_loading = false;
        if (res.statusCode == 200) {
            const QJsonObject root = QJsonDocument::fromJson(res.body).object();
            const QJsonObject cur = root.value(QStringLiteral("current")).toObject();
            if (!cur.isEmpty()) {
                static const char* kCompass16[] = {
                    "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
                };

                m_city = cityLabel;
                m_temperature = qRound(cur.value(QStringLiteral("temperature_2m")).toDouble(28.0));
                m_feelsLike = qRound(cur.value(QStringLiteral("apparent_temperature")).toDouble(m_temperature));
                m_humidity = qRound(cur.value(QStringLiteral("relative_humidity_2m")).toDouble(70.0));
                m_windSpeed = qRound(cur.value(QStringLiteral("wind_speed_10m")).toDouble(8.0));
                int deg = qRound(cur.value(QStringLiteral("wind_direction_10m")).toDouble(0.0)) % 360;
                if (deg < 0)
                    deg += 360;
                m_windDeg = deg;
                m_windDirection = QString::fromLatin1(kCompass16[qRound(deg / 22.5) % 16]);
                m_pressure = qRound(cur.value(QStringLiteral("pressure_msl")).toDouble(1013.0));
                m_isDay = (cur.value(QStringLiteral("is_day")).toInt(1) != 0);
                m_weatherCode = cur.value(QStringLiteral("weather_code")).toInt(2);
                m_conditionText = describeWmo(m_weatherCode);

                const QJsonObject daily = root.value(QStringLiteral("daily")).toObject();
                const QJsonArray dTimes = daily.value(QStringLiteral("time")).toArray();
                const QJsonArray dCodes = daily.value(QStringLiteral("weather_code")).toArray();
                const QJsonArray maxArr = daily.value(QStringLiteral("temperature_2m_max")).toArray();
                const QJsonArray minArr = daily.value(QStringLiteral("temperature_2m_min")).toArray();
                const QJsonArray rainMaxArr = daily.value(QStringLiteral("precipitation_probability_max")).toArray();
                const QJsonArray uvDailyArr = daily.value(QStringLiteral("uv_index_max")).toArray();
                const QJsonArray sunriseArr = daily.value(QStringLiteral("sunrise")).toArray();
                const QJsonArray sunsetArr = daily.value(QStringLiteral("sunset")).toArray();

                if (!maxArr.isEmpty())
                    m_tempMax = qRound(maxArr.first().toDouble(m_temperature + 3));
                if (!minArr.isEmpty())
                    m_tempMin = qRound(minArr.first().toDouble(m_temperature - 4));
                if (!uvDailyArr.isEmpty())
                    m_uvIndex = qRound(uvDailyArr.first().toDouble(4.0));
                if (!sunriseArr.isEmpty()) {
                    const QString sr = sunriseArr.first().toString().mid(11, 5);
                    if (!sr.isEmpty())
                        m_sunrise = sr;
                }
                if (!sunsetArr.isEmpty()) {
                    const QString ss = sunsetArr.first().toString().mid(11, 5);
                    if (!ss.isEmpty())
                        m_sunset = ss;
                }

                m_dailyForecast.clear();
                const int dayCount = qMin<int>(3, dTimes.size());
                for (int i = 0; i < dayCount; ++i) {
                    const QString dateStr = dTimes.at(i).toString();
                    QString dayLabel;
                    if (i == 0) {
                        dayLabel = QStringLiteral("Today");
                    } else if (i == 1) {
                        dayLabel = QStringLiteral("Tomorrow");
                    } else {
                        const QDate dt = QDate::fromString(dateStr, Qt::ISODate);
                        dayLabel = dt.isValid() ? dt.toString(QStringLiteral("ddd")) : dateStr.mid(5);
                    }
                    const int dCode = (i < dCodes.size()) ? dCodes.at(i).toInt(m_weatherCode) : m_weatherCode;
                    QVariantMap dSlot;
                    dSlot[QStringLiteral("label")] = dayLabel;
                    dSlot[QStringLiteral("date")] = dateStr;
                    dSlot[QStringLiteral("code")] = dCode;
                    dSlot[QStringLiteral("isDay")] = true;
                    dSlot[QStringLiteral("condition")] = describeWmo(dCode);
                    dSlot[QStringLiteral("high")] = (i < maxArr.size()) ? qRound(maxArr.at(i).toDouble(m_tempMax)) : m_tempMax;
                    dSlot[QStringLiteral("low")] = (i < minArr.size()) ? qRound(minArr.at(i).toDouble(m_tempMin)) : m_tempMin;
                    dSlot[QStringLiteral("rain")] = (i < rainMaxArr.size()) ? qRound(rainMaxArr.at(i).toDouble(0.0)) : 0;
                    m_dailyForecast.append(dSlot);
                }

                // Build next 8 3-hour slots starting from current local hour
                m_hourlyForecast.clear();
                const QJsonObject hourly = root.value(QStringLiteral("hourly")).toObject();
                const QJsonArray hTimes = hourly.value(QStringLiteral("time")).toArray();
                const QJsonArray hTemps = hourly.value(QStringLiteral("temperature_2m")).toArray();
                const QJsonArray hFeels = hourly.value(QStringLiteral("apparent_temperature")).toArray();
                const QJsonArray hRain = hourly.value(QStringLiteral("precipitation_probability")).toArray();
                const QJsonArray hCodes = hourly.value(QStringLiteral("weather_code")).toArray();
                const QJsonArray hUvs = hourly.value(QStringLiteral("uv_index")).toArray();
                const QJsonArray hIsDay = hourly.value(QStringLiteral("is_day")).toArray();

                const QString curTimeIso = cur.value(QStringLiteral("time")).toString();
                const QString curHourPrefix = curTimeIso.left(13);
                int startIdx = 0;
                for (int i = 0; i < hTimes.size(); ++i) {
                    if (hTimes.at(i).toString().left(13) >= curHourPrefix) {
                        startIdx = i;
                        break;
                    }
                }
                if (startIdx < hUvs.size())
                    m_uvIndex = qRound(hUvs.at(startIdx).toDouble(m_uvIndex));
                if (startIdx < hRain.size())
                    m_precipProb = qRound(hRain.at(startIdx).toDouble(0.0));

                for (int k = 0; k < 8 && (startIdx + k * 3) < hTimes.size(); ++k) {
                    const int idx = startIdx + k * 3;
                    const QString tStr = hTimes.at(idx).toString();
                    QString hh = tStr.mid(11, 5);
                    if (hh.isEmpty())
                        hh = QStringLiteral("--:--");
                    const int hCode = idx < hCodes.size() ? hCodes.at(idx).toInt() : m_weatherCode;
                    const int hTemp = idx < hTemps.size() ? qRound(hTemps.at(idx).toDouble()) : m_temperature;
                    const int hFeel = idx < hFeels.size() ? qRound(hFeels.at(idx).toDouble()) : hTemp;
                    const int hProb = idx < hRain.size() ? qRound(hRain.at(idx).toDouble()) : 0;
                    const bool hDay = idx < hIsDay.size() ? (hIsDay.at(idx).toInt(1) != 0) : m_isDay;
                    QVariantMap slot;
                    slot[QStringLiteral("time")] = (k == 0) ? QStringLiteral("Now") : hh.left(2) + QStringLiteral("h");
                    slot[QStringLiteral("label")] = (k == 0) ? QStringLiteral("Now") : hh;
                    slot[QStringLiteral("temp")] = hTemp;
                    slot[QStringLiteral("feels")] = hFeel;
                    slot[QStringLiteral("code")] = hCode;
                    slot[QStringLiteral("isDay")] = hDay;
                    slot[QStringLiteral("condition")] = describeWmo(hCode);
                    slot[QStringLiteral("rain")] = hProb;
                    m_hourlyForecast.append(slot);
                }

                m_ready = true;
            }
        }
        emit weatherChanged();
    });
}

QString WeatherService::describeWmo(int code)
{
    if (code == 0) return QStringLiteral("Clear Sky");
    if (code == 1) return QStringLiteral("Mainly Clear");
    if (code == 2) return QStringLiteral("Partly Cloudy");
    if (code == 3) return QStringLiteral("Overcast");
    if (code == 45 || code == 48) return QStringLiteral("Foggy");
    if (code >= 51 && code <= 57) return QStringLiteral("Drizzle");
    if (code >= 61 && code <= 67) return QStringLiteral("Rain");
    if (code >= 71 && code <= 77) return QStringLiteral("Snow");
    if (code >= 80 && code <= 82) return QStringLiteral("Rain Showers");
    if (code >= 85 && code <= 86) return QStringLiteral("Snow Showers");
    if (code >= 95) return QStringLiteral("Thunderstorm");
    return QStringLiteral("Cloudy");
}

// ---------------------------------------------------------------------------
// DropShelfService
// ---------------------------------------------------------------------------

DropShelfService::DropShelfService(QObject* parent)
    : QObject(parent)
{
}

void DropShelfService::appendSinglePath(const QString& rawPath)
{
    if (rawPath.trimmed().isEmpty())
        return;

    const QString path = QDir::toNativeSeparators(rawPath.trimmed());
    for (const QVariant& existing : m_items) {
        const QVariantMap m = existing.toMap();
        if (m.value(QStringLiteral("kind"), QStringLiteral("file")).toString() == QLatin1String("file") &&
            m.value(QStringLiteral("path")).toString().compare(path, Qt::CaseInsensitive) == 0) {
            return;
        }
    }

    const QFileInfo fi(path);
    QVariantMap entry;
    entry[QStringLiteral("id")] = QStringLiteral("f_%1").arg(++m_nextId);
    entry[QStringLiteral("kind")] = QStringLiteral("file");
    entry[QStringLiteral("path")] = path;
    entry[QStringLiteral("value")] = path;
    entry[QStringLiteral("name")] = fi.fileName().isEmpty() ? path : fi.fileName();
    entry[QStringLiteral("isDir")] = fi.isDir();
    entry[QStringLiteral("dir")] = fi.isDir();

    if (fi.exists() && !fi.isDir()) {
        const qint64 sz = fi.size();
        if (sz < 1024)
            entry[QStringLiteral("sizeText")] = QStringLiteral("%1 B").arg(sz);
        else if (sz < 1024 * 1024)
            entry[QStringLiteral("sizeText")] = QStringLiteral("%1 KB").arg(sz / 1024);
        else
            entry[QStringLiteral("sizeText")] = QStringLiteral("%1 MB").arg(sz / (1024.0 * 1024.0), 0, 'f', 1);
    } else {
        entry[QStringLiteral("sizeText")] = fi.isDir() ? QStringLiteral("Folder") : QStringLiteral("File");
    }

    m_items.prepend(entry);
}

void DropShelfService::addUrls(const QVariantList& urls)
{
    bool changed = false;
    for (const QVariant& v : urls) {
        QString path;
        if (v.canConvert<QUrl>()) {
            const QUrl u = v.toUrl();
            path = u.isLocalFile() ? u.toLocalFile() : u.toString();
        } else {
            const QString s = v.toString();
            const QUrl u(s);
            path = u.isLocalFile() ? u.toLocalFile() : s;
        }
        const int before = m_items.size();
        appendSinglePath(path);
        if (m_items.size() != before)
            changed = true;
    }
    if (changed)
        emit itemsChanged();
}

void DropShelfService::addPaths(const QStringList& paths)
{
    const int before = m_items.size();
    for (const QString& p : paths)
        appendSinglePath(p);
    if (m_items.size() != before)
        emit itemsChanged();
}

void DropShelfService::addText(const QString& text)
{
    const QString trimmed = text.trimmed();
    if (trimmed.isEmpty())
        return;

    for (const QVariant& existing : m_items) {
        const QVariantMap m = existing.toMap();
        if (m.value(QStringLiteral("kind")).toString() == QLatin1String("text") &&
            m.value(QStringLiteral("value")).toString() == trimmed) {
            return;
        }
    }

    QString firstLine = trimmed.section(QLatin1Char('\n'), 0, 0).simplified();
    if (firstLine.size() > 60)
        firstLine = firstLine.left(57) + QStringLiteral("...");

    QVariantMap entry;
    entry[QStringLiteral("id")] = QStringLiteral("t_%1").arg(++m_nextId);
    entry[QStringLiteral("kind")] = QStringLiteral("text");
    entry[QStringLiteral("path")] = trimmed;
    entry[QStringLiteral("value")] = trimmed;
    entry[QStringLiteral("name")] = firstLine;
    entry[QStringLiteral("isDir")] = false;
    entry[QStringLiteral("dir")] = false;
    entry[QStringLiteral("sizeText")] = QStringLiteral("Note");

    m_items.prepend(entry);
    emit itemsChanged();
}

void DropShelfService::pickFiles()
{
#ifdef Q_OS_WIN
    HWND initialOwner = nullptr;
    if (QWindow* fw = QGuiApplication::focusWindow()) {
        HWND h = reinterpret_cast<HWND>(fw->winId());
        if (h && IsWindow(h))
            initialOwner = h;
    }
    if (!initialOwner) {
        for (QWindow* w : QGuiApplication::topLevelWindows()) {
            if (!w || !w->isVisible())
                continue;
            HWND h = reinterpret_cast<HWND>(w->winId());
            if (h && IsWindow(h)) {
                initialOwner = h;
                break;
            }
        }
    }

    QPointer<DropShelfService> guard(this);
    std::thread([guard, initialOwner]() {
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        const bool didCoInit = SUCCEEDED(hr);

        using FnGetOpenFileNameW = BOOL(WINAPI*)(LPOPENFILENAMEW);
        HMODULE comdlg = LoadLibraryW(L"comdlg32.dll");
        auto pGetOpen = comdlg
            ? reinterpret_cast<FnGetOpenFileNameW>(GetProcAddress(comdlg, "GetOpenFileNameW"))
            : nullptr;

        QStringList picked;
        if (pGetOpen) {
            HWND ownerHwnd = (initialOwner && IsWindow(initialOwner)) ? initialOwner : nullptr;
            HWND tempOwner = nullptr;
            if (!ownerHwnd) {
                tempOwner = CreateWindowExW(0, L"STATIC", L"SekaiDesk", WS_POPUP,
                                            0, 0, 0, 0, nullptr, nullptr,
                                            GetModuleHandleW(nullptr), nullptr);
                ownerHwnd = tempOwner;
            }

            QVector<wchar_t> buf(65536, 0);
            OPENFILENAMEW ofn{};
            ofn.lStructSize = sizeof(ofn);
            ofn.hwndOwner = ownerHwnd;
            ofn.lpstrFilter = L"All Files (*.*)\0*.*\0\0";
            ofn.lpstrFile = buf.data();
            ofn.nMaxFile = static_cast<DWORD>(buf.size());
            ofn.lpstrTitle = L"Add Files to Drop Shelf";
            ofn.Flags = OFN_ALLOWMULTISELECT | OFN_EXPLORER | OFN_FILEMUSTEXIST
                      | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
            const BOOL ok = pGetOpen(&ofn);
            if (tempOwner)
                DestroyWindow(tempOwner);
            if (ok) {
                const wchar_t* p = buf.data();
                const QString first = QString::fromWCharArray(p);
                p += first.size() + 1;
                if (*p == L'\0') {
                    if (!first.isEmpty())
                        picked << first;
                } else {
                    const QDir dir(first);
                    while (*p != L'\0') {
                        const QString name = QString::fromWCharArray(p);
                        p += name.size() + 1;
                        picked << dir.filePath(name);
                    }
                }
            }
        }

        if (didCoInit)
            CoUninitialize();

        if (!guard || picked.isEmpty())
            return;
        QMetaObject::invokeMethod(
            guard.data(),
            [guard, picked = std::move(picked)]() {
                if (guard)
                    guard->addPaths(picked);
            },
            Qt::QueuedConnection);
    }).detach();
#endif
}

int DropShelfService::pasteFromClipboard()
{
    QStringList paths;
#ifdef Q_OS_WIN
    if (IsClipboardFormatAvailable(CF_HDROP) && OpenClipboard(nullptr)) {
        if (HANDLE hData = GetClipboardData(CF_HDROP)) {
            if (HDROP hDrop = static_cast<HDROP>(GlobalLock(hData))) {
                const UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
                for (UINT i = 0; i < count; ++i) {
                    const UINT len = DragQueryFileW(hDrop, i, nullptr, 0);
                    if (len == 0)
                        continue;
                    QVector<wchar_t> buf(static_cast<int>(len) + 1, 0);
                    DragQueryFileW(hDrop, i, buf.data(), len + 1);
                    paths << QString::fromWCharArray(buf.data(), static_cast<int>(len));
                }
                GlobalUnlock(hData);
            }
        }
        CloseClipboard();
    }
#endif
    if (paths.isEmpty()) {
        if (const auto* cb = QGuiApplication::clipboard()) {
            if (const QMimeData* mime = cb->mimeData()) {
                if (mime->hasUrls()) {
                    for (const QUrl& u : mime->urls()) {
                        if (u.isLocalFile())
                            paths << u.toLocalFile();
                    }
                }
                if (paths.isEmpty() && mime->hasText()) {
                    const QStringList lines = mime->text().split(QRegularExpression(QStringLiteral("[\r\n]+")),
                                                                 Qt::SkipEmptyParts);
                    for (QString line : lines) {
                        line = line.trimmed();
                        if (line.size() >= 2 && line.startsWith(QLatin1Char('"')) && line.endsWith(QLatin1Char('"')))
                            line = line.mid(1, line.size() - 2);
                        if (!line.isEmpty() && QFileInfo::exists(line))
                            paths << line;
                    }
                }
            }
        }
    }

    if (paths.isEmpty()) {
        if (const auto* cb = QGuiApplication::clipboard()) {
            const QString txt = cb->text().trimmed();
            if (!txt.isEmpty()) {
                const int before = m_items.size();
                addText(txt);
                return m_items.size() - before;
            }
        }
        return 0;
    }
    const int before = m_items.size();
    addPaths(paths);
    return m_items.size() - before;
}

void DropShelfService::copyItem(int index)
{
    if (index < 0 || index >= m_items.size())
        return;
    QClipboard* cb = QGuiApplication::clipboard();
    if (!cb)
        return;
    const QVariantMap item = m_items.at(index).toMap();
    const QString val = item.value(QStringLiteral("value"), item.value(QStringLiteral("path"))).toString();
    if (val.isEmpty())
        return;
    if (item.value(QStringLiteral("kind")).toString() == QLatin1String("text")) {
        cb->setText(val);
        return;
    }
    auto* md = new QMimeData();
    md->setUrls({ QUrl::fromLocalFile(val) });
    md->setText(val);
    cb->setMimeData(md);
}

void DropShelfService::openItem(int index)
{
    if (index < 0 || index >= m_items.size())
        return;
    const QVariantMap item = m_items.at(index).toMap();
    const QString kind = item.value(QStringLiteral("kind"), QStringLiteral("file")).toString();
    const QString val = item.value(QStringLiteral("value"), item.value(QStringLiteral("path"))).toString();
    if (val.isEmpty())
        return;
    if (kind == QLatin1String("text")) {
        if (val.startsWith(QStringLiteral("http://"), Qt::CaseInsensitive) ||
            val.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
            QDesktopServices::openUrl(QUrl(val));
        } else if (auto* cb = QGuiApplication::clipboard()) {
            cb->setText(val);
        }
        return;
    }
    QDesktopServices::openUrl(QUrl::fromLocalFile(val));
}

void DropShelfService::revealItem(int index)
{
    if (index < 0 || index >= m_items.size())
        return;
    const QVariantMap item = m_items.at(index).toMap();
    if (item.value(QStringLiteral("kind"), QStringLiteral("file")).toString() == QLatin1String("text"))
        return;
    const QString path = item.value(QStringLiteral("path")).toString();
    if (path.isEmpty())
        return;
    QProcess::startDetached(QStringLiteral("explorer.exe"), { QStringLiteral("/select,"), QDir::toNativeSeparators(path) });
}

void DropShelfService::copyAllPaths()
{
    QList<QUrl> fileUrls;
    QStringList list;
    for (const QVariant& itemVar : m_items) {
        const QVariantMap item = itemVar.toMap();
        const QString val = item.value(QStringLiteral("value"), item.value(QStringLiteral("path"))).toString();
        if (val.isEmpty())
            continue;
        list.append(val);
        if (item.value(QStringLiteral("kind"), QStringLiteral("file")).toString() == QLatin1String("file"))
            fileUrls.append(QUrl::fromLocalFile(val));
    }
    if (auto* cb = QGuiApplication::clipboard()) {
        if (!fileUrls.isEmpty()) {
            auto* md = new QMimeData();
            md->setUrls(fileUrls);
            md->setText(list.join(QLatin1Char('\n')));
            cb->setMimeData(md);
        } else if (!list.isEmpty()) {
            cb->setText(list.join(QLatin1Char('\n')));
        }
    }
}

void DropShelfService::removeIndex(int index)
{
    if (index < 0 || index >= m_items.size())
        return;
    m_items.removeAt(index);
    emit itemsChanged();
}

void DropShelfService::clear()
{
    if (m_items.isEmpty())
        return;
    m_items.clear();
    emit itemsChanged();
}
