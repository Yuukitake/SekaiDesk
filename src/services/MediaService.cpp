#include "MediaService.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrl>
#include <QVariantMap>
#include <QtMath>

#ifdef Q_OS_WIN
#include <windows.h>

namespace {
void attachToKillOnCloseJob(qint64 pid)
{
    if (pid <= 0)
        return;
    static HANDLE s_job = []() -> HANDLE {
        HANDLE h = CreateJobObjectW(nullptr, nullptr);
        if (h) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli{};
            jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(h, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
        }
        return h;
    }();
    if (!s_job)
        return;
    HANDLE hProc = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, static_cast<DWORD>(pid));
    if (hProc) {
        AssignProcessToJobObject(s_job, hProc);
        CloseHandle(hProc);
    }
}
} // namespace
#endif

MediaService::MediaService(QObject* parent)
    : QObject(parent)
{
#ifdef Q_OS_WIN
    const qint64 pid = QCoreApplication::applicationPid();
    m_cmdFile = QDir::tempPath() + QStringLiteral("/sekaidesk_media_cmd_%1.txt").arg(pid);
    m_artDir = QDir::tempPath() + QStringLiteral("/sekaidesk_art_%1").arg(pid);
    QDir().mkpath(m_artDir);
    QTimer::singleShot(400, this, &MediaService::startWorker);
#endif
}

MediaService::~MediaService()
{
    if (m_proc) {
        m_proc->kill();
        m_proc->waitForFinished(300);
    }
    if (!m_cmdFile.isEmpty())
        QFile::remove(m_cmdFile);
    if (!m_artDir.isEmpty())
        QDir(m_artDir).removeRecursively();
}

void MediaService::sendCommand(const QString& cmd)
{
#ifdef Q_OS_WIN
    if (m_cmdFile.isEmpty())
        return;
    QFile f(m_cmdFile);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(cmd.toUtf8());
        f.close();
    }
#else
    Q_UNUSED(cmd);
#endif
}

void MediaService::playPause()
{
    sendCommand(QStringLiteral("playpause"));
}

void MediaService::next()
{
    sendCommand(QStringLiteral("next"));
}

void MediaService::previous()
{
    sendCommand(QStringLiteral("prev"));
}

void MediaService::seek(double seconds)
{
    sendCommand(QStringLiteral("seek:%1").arg(seconds, 0, 'f', 3));
}

void MediaService::selectSession(const QString& appId)
{
    sendCommand(QStringLiteral("select:%1").arg(appId));
}

void MediaService::setPaused(bool paused)
{
    sendCommand(paused ? QStringLiteral("pause") : QStringLiteral("resume"));
}

void MediaService::startWorker()
{
#ifdef Q_OS_WIN
    if (m_proc)
        return;

    m_proc = new QProcess(this);
    m_proc->setCreateProcessArgumentsModifier([](QProcess::CreateProcessArguments* args) {
        args->flags |= CREATE_NO_WINDOW;
    });
    connect(m_proc, &QProcess::started, this, [this]() {
        if (m_proc)
            attachToKillOnCloseJob(m_proc->processId());
    });
    connect(m_proc, &QProcess::readyReadStandardOutput,
            this, &MediaService::onStdoutReady);

    QString escapedCmdPath = m_cmdFile;
    escapedCmdPath.replace(QLatin1Char('\''), QStringLiteral("''"));
    QString escapedArtDir = m_artDir;
    escapedArtDir.replace(QLatin1Char('\''), QStringLiteral("''"));

    const QString script = QStringLiteral(
        "$ErrorActionPreference = 'SilentlyContinue'\n"
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n"
        "Add-Type -AssemblyName System.Runtime.WindowsRuntime\n"
        "$thCode = @'\n"
        "using System;\n"
        "using System.IO;\n"
        "using System.Runtime.InteropServices;\n"
        "using System.Runtime.InteropServices.ComTypes;\n"
        "public static class WinRtStreamHelper {\n"
        "    [DllImport(\"shcore.dll\")]\n"
        "    private static extern int CreateStreamOverRandomAccessStream([MarshalAs(UnmanagedType.IUnknown)] object ras, ref Guid riid, out IStream ppv);\n"
        "    public static byte[] ReadAll(object ras) {\n"
        "        if (ras == null) return null;\n"
        "        Guid iid = typeof(IStream).GUID;\n"
        "        IStream istream;\n"
        "        int hr = CreateStreamOverRandomAccessStream(ras, ref iid, out istream);\n"
        "        if (hr != 0 || istream == null) return null;\n"
        "        try {\n"
        "            using (var ms = new MemoryStream()) {\n"
        "                byte[] buf = new byte[16384];\n"
        "                IntPtr readPtr = Marshal.AllocHGlobal(4);\n"
        "                try {\n"
        "                    while (true) {\n"
        "                        istream.Read(buf, buf.Length, readPtr);\n"
        "                        int n = Marshal.ReadInt32(readPtr);\n"
        "                        if (n <= 0) break;\n"
        "                        ms.Write(buf, 0, n);\n"
        "                        if (ms.Length > 8388608) break;\n"
        "                    }\n"
        "                } finally { Marshal.FreeHGlobal(readPtr); }\n"
        "                return ms.ToArray();\n"
        "            }\n"
        "        } finally { Marshal.ReleaseComObject(istream); }\n"
        "    }\n"
        "}\n"
        "'@\n"
        "Add-Type -TypeDefinition $thCode\n"
        "[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null\n"
        "[Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null\n"
        "$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]\n"
        "function Await($op, $t) {\n"
        "  if ($null -eq $op) { return $null }\n"
        "  $m = $asTask.MakeGenericMethod($t)\n"
        "  $tsk = $m.Invoke($null, @($op))\n"
        "  $tsk.Wait(1500) | Out-Null\n"
        "  return $tsk.Result\n"
        "}\n"
        "function AppLabel($raw) {\n"
        "  if ([string]::IsNullOrEmpty($raw)) { return 'Media' }\n"
        "  $low = $raw.ToLower()\n"
        "  if ($low -match 'firefox' -or $low -match '308046b0af4a39cb') { return 'Firefox' }\n"
        "  if ($low -match 'chrome') { return 'Chrome' }\n"
        "  if ($low -match 'msedge' -or $low -match 'edge') { return 'Edge' }\n"
        "  if ($low -match 'spotify') { return 'Spotify' }\n"
        "  if ($low -match 'vlc') { return 'VLC' }\n"
        "  if ($low -match 'foobar') { return 'foobar2000' }\n"
        "  if ($low -match 'mpv') { return 'mpv' }\n"
        "  $base = ($raw -split '!')[-1] -replace '\\.exe$',''\n"
        "  if ($base -match '^([A-Za-z0-9]+)') { return $matches[1] }\n"
        "  return $raw\n"
        "}\n"
        "$cmdFile = '%1'\n"
        "$artDir = '%2'\n"
        "$parentPid = %3\n"
        "$mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])\n"
        "$last = ''\n"
        "$lastTrackKey = ''\n"
        "$cachedArt = ''\n"
        "$artSeq = 0\n"
        "$lastDur = 0.0\n"
        "$lastPos = 0.0\n"
        "$lastPlaying = $false\n"
        "$seekBasePos = -1.0\n"
        "$seekBaseTime = [DateTimeOffset]::MinValue\n"
        "$seekBaseTlUpdated = [DateTimeOffset]::MinValue\n"
        "$selectedApp = ''\n"
        "$tick = 0\n"
        "$paused = $false\n"
        "function PickSession() {\n"
        "  if (-not $mgr) { return $null }\n"
        "  $all = $mgr.GetSessions()\n"
        "  if ($all -and $all.Count -gt 0) {\n"
        "    if ($selectedApp -ne '') {\n"
        "      foreach ($cand in $all) { if ([string]$cand.SourceAppUserModelId -eq $selectedApp) { return $cand } }\n"
        "      $selectedApp = ''\n"
        "    }\n"
        "    foreach ($cand in $all) {\n"
        "      $cpb = $cand.GetPlaybackInfo()\n"
        "      if ($cpb -and $cpb.PlaybackStatus -eq 'Playing') { return $cand }\n"
        "    }\n"
        "  }\n"
        "  $s = $mgr.GetCurrentSession()\n"
        "  if ($s) { return $s }\n"
        "  if ($all -and $all.Count -gt 0) { return $all[0] }\n"
        "  return $null\n"
        "}\n"
        "while ($true) {\n"
        "  if (($tick % 12) -eq 0 -and -not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }\n"
        "  if ([System.IO.File]::Exists($cmdFile)) {\n"
        "    $cmd = ([System.IO.File]::ReadAllText($cmdFile)).Trim()\n"
        "    [System.IO.File]::Delete($cmdFile)\n"
        "    if ($cmd -eq 'pause') {\n"
        "      $paused = $true\n"
        "    } elseif ($cmd -eq 'resume') {\n"
        "      $paused = $false\n"
        "      $tick = 4\n"
        "    } elseif ($cmd.StartsWith('select:')) {\n"
        "      $selectedApp = $cmd.Substring(7)\n"
        "      $tick = 4\n"
        "    } else {\n"
        "      $cs = PickSession\n"
        "      if ($cs) {\n"
        "        if ($cmd -eq 'playpause') { $null = Await ($cs.TryTogglePlayPauseAsync()) ([bool]) }\n"
        "        elseif ($cmd -eq 'next') { $null = Await ($cs.TrySkipNextAsync()) ([bool]) }\n"
        "        elseif ($cmd -eq 'prev') { $null = Await ($cs.TrySkipPreviousAsync()) ([bool]) }\n"
        "        elseif ($cmd.StartsWith('seek:')) {\n"
        "          $sec = [double]$cmd.Substring(5)\n"
        "          $tl = $cs.GetTimelineProperties()\n"
        "          if ($tl) {\n"
        "            $seekBaseTlUpdated = $tl.LastUpdatedTime\n"
        "            $seekBasePos = $sec\n"
        "            $seekBaseTime = [DateTimeOffset]::UtcNow\n"
        "            $targetTicks = [long]($tl.StartTime.Ticks + [long]($sec * 10000000.0))\n"
        "            $null = Await ($cs.TryChangePlaybackPositionAsync($targetTicks)) ([bool])\n"
        "            $lastPos = $sec\n"
        "            Start-Sleep -Milliseconds 150\n"
        "          }\n"
        "        }\n"
        "        $tick = 4\n"
        "      }\n"
        "    }\n"
        "  }\n"
        "  if ($paused) {\n"
        "    Start-Sleep -Milliseconds 1500\n"
        "    continue\n"
        "  }\n"
        "  if ($tick % 4 -eq 0) {\n"
        "    $obj = @{ has = $false; playing = $false; title = ''; artist = ''; album = ''; app = ''; art = ''; pos = 0.0; dur = 0.0; canNext = $false; canPrev = $false; canSeek = $false; players = @() }\n"
        "    $s = PickSession\n"
        "    if ($mgr) {\n"
        "      $all = $mgr.GetSessions()\n"
        "      if ($all) {\n"
        "        $plist = @()\n"
        "        foreach ($item in $all) {\n"
        "          $ipb = $item.GetPlaybackInfo()\n"
        "          $ipr = Await ($item.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])\n"
        "          $plist += @{ id = [string]$item.SourceAppUserModelId; label = (AppLabel ([string]$item.SourceAppUserModelId)); title = $(if ($ipr) { [string]$ipr.Title } else { '' }); playing = ($ipb -and $ipb.PlaybackStatus -eq 'Playing') }\n"
        "        }\n"
        "        $obj.players = $plist\n"
        "      }\n"
        "    }\n"
        "    if ($s) {\n"
        "      $obj.has = $true\n"
        "      $obj.app = [string]$s.SourceAppUserModelId\n"
        "      $pb = $s.GetPlaybackInfo()\n"
        "      if ($pb) {\n"
        "        $obj.playing = ($pb.PlaybackStatus -eq 'Playing')\n"
        "        if ($pb.Controls) {\n"
        "          $obj.canNext = [bool]$pb.Controls.IsNextEnabled\n"
        "          $obj.canPrev = [bool]$pb.Controls.IsPreviousEnabled\n"
        "          $obj.canSeek = [bool]$pb.Controls.IsPlaybackPositionEnabled\n"
        "        }\n"
        "      }\n"
        "      $pr = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])\n"
        "      if ($pr) {\n"
        "        $obj.title = [string]$pr.Title\n"
        "        $obj.artist = [string]$pr.Artist\n"
        "        $obj.album = [string]$pr.AlbumTitle\n"
        "      }\n"
        "      $tl = $s.GetTimelineProperties()\n"
        "      if ($tl) {\n"
        "        $dur = ($tl.EndTime - $tl.StartTime).TotalSeconds\n"
        "        $pos = ($tl.Position - $tl.StartTime).TotalSeconds\n"
        "        if ($obj.playing -and $tl.LastUpdatedTime.Year -gt 2000) {\n"
        "          $elapsed = ([DateTimeOffset]::UtcNow - $tl.LastUpdatedTime).TotalSeconds\n"
        "          if ($elapsed -gt 0 -and $elapsed -lt 3600) { $pos += $elapsed }\n"
        "        }\n"
        "        if ($dur -lt 0) { $dur = 0 }\n"
        "        if ($pos -lt 0) { $pos = 0 }\n"
        "        if ($dur -gt 0 -and $pos -gt $dur) { $pos = $dur }\n"
        "        $obj.dur = [math]::Round($dur, 1)\n"
        "        $obj.pos = [math]::Round($pos, 1)\n"
        "      }\n"
        "      $tk = $obj.app + '|' + $obj.title + '|' + $obj.artist\n"
        "      if ($tk -ne $lastTrackKey) { $seekBasePos = -1.0 }\n"
        "      if ($seekBasePos -ge 0) {\n"
        "        $rawTlPos = if ($tl) { ($tl.Position - $tl.StartTime).TotalSeconds } else { 0.0 }\n"
        "        if ($tl -and $tl.LastUpdatedTime -gt $seekBaseTlUpdated -and $rawTlPos -gt 1.0 -and [math]::Abs($rawTlPos - $seekBasePos) -lt 10.0) {\n"
        "          $seekBasePos = -1.0\n"
        "        } else {\n"
        "          if (-not $obj.playing) {\n"
        "            if ($lastPlaying) { $seekBasePos = $lastPos }\n"
        "            $seekBaseTime = [DateTimeOffset]::UtcNow\n"
        "            $obj.pos = [math]::Round($seekBasePos, 1)\n"
        "          } else {\n"
        "            if (-not $lastPlaying) { $seekBaseTime = [DateTimeOffset]::UtcNow }\n"
        "            $spos = $seekBasePos + ([DateTimeOffset]::UtcNow - $seekBaseTime).TotalSeconds\n"
        "            if ($obj.dur -gt 0 -and $spos -gt $obj.dur) { $spos = $obj.dur }\n"
        "            $obj.pos = [math]::Round($spos, 1)\n"
        "          }\n"
        "        }\n"
        "      }\n"
        "      $lastPlaying = $obj.playing\n"
        "      if ($tk -eq $lastTrackKey -and $obj.dur -le 0 -and $lastDur -gt 0) {\n"
        "        $obj.dur = $lastDur\n"
        "        if ($obj.pos -le 0) { $obj.pos = $lastPos }\n"
        "      }\n"
        "      if ($obj.dur -gt 0) { $lastDur = $obj.dur; $lastPos = $obj.pos }\n"
        "      if ($tk -ne $lastTrackKey) {\n"
        "        $lastTrackKey = $tk\n"
        "        $lastDur = $obj.dur\n"
        "        $lastPos = $obj.pos\n"
        "        if ($cachedArt -ne '' -and [System.IO.File]::Exists($cachedArt)) { [System.IO.File]::Delete($cachedArt) }\n"
        "        $cachedArt = ''\n"
        "        if ($pr -and $pr.Thumbnail) {\n"
        "          $st = Await ($pr.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])\n"
        "          if ($st) {\n"
        "            $bytes = [WinRtStreamHelper]::ReadAll($st)\n"
        "            if ($bytes -and $bytes.Length -gt 0) {\n"
        "              $artSeq++\n"
        "              $outArt = Join-Path $artDir ('cover_' + $artSeq + '.png')\n"
        "              [System.IO.File]::WriteAllBytes($outArt, $bytes)\n"
        "              $cachedArt = $outArt\n"
        "            }\n"
        "          }\n"
        "        }\n"
        "      }\n"
        "      $obj.art = $cachedArt\n"
        "    } else {\n"
        "      if ($lastTrackKey -ne '') {\n"
        "        $lastTrackKey = ''\n"
        "        if ($cachedArt -ne '' -and [System.IO.File]::Exists($cachedArt)) { [System.IO.File]::Delete($cachedArt) }\n"
        "        $cachedArt = ''\n"
        "      }\n"
        "    }\n"
        "    $line = ($obj | ConvertTo-Json -Compress -Depth 4)\n"
        "    if ($line -ne $last) { $last = $line; [Console]::Out.WriteLine($line); [Console]::Out.Flush() }\n"
        "  }\n"
        "  $tick++\n"
        "  Start-Sleep -Milliseconds 250\n"
        "}\n"
    ).arg(escapedCmdPath, escapedArtDir).arg(QCoreApplication::applicationPid());

    const QByteArray utf16(reinterpret_cast<const char*>(script.utf16()),
                           script.size() * static_cast<int>(sizeof(char16_t)));
    const QString encoded = QString::fromLatin1(utf16.toBase64());

    m_proc->start(QStringLiteral("powershell.exe"),
                  { QStringLiteral("-NoLogo"),
                    QStringLiteral("-NoProfile"),
                    QStringLiteral("-NonInteractive"),
                    QStringLiteral("-WindowStyle"), QStringLiteral("Hidden"),
                    QStringLiteral("-EncodedCommand"), encoded });
#endif
}

void MediaService::onStdoutReady()
{
    if (!m_proc)
        return;
    m_buf.append(m_proc->readAllStandardOutput());
    int idx = -1;
    while ((idx = m_buf.indexOf('\n')) != -1) {
        const QByteArray line = m_buf.left(idx).trimmed();
        m_buf.remove(0, idx + 1);
        if (line.isEmpty())
            continue;
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (!doc.isObject())
            continue;
        const QJsonObject obj = doc.object();
        const QString artPath = obj.value(QStringLiteral("art")).toString();
        const QString artUrl = artPath.isEmpty()
            ? QString()
            : QUrl::fromLocalFile(artPath).toString();

        QVariantList playersList;
        const QJsonArray pArr = obj.value(QStringLiteral("players")).toArray();
        for (const QJsonValue& v : pArr) {
            if (!v.isObject())
                continue;
            const QJsonObject po = v.toObject();
            QVariantMap pm;
            pm.insert(QStringLiteral("id"), po.value(QStringLiteral("id")).toString());
            pm.insert(QStringLiteral("label"), po.value(QStringLiteral("label")).toString());
            pm.insert(QStringLiteral("title"), po.value(QStringLiteral("title")).toString());
            pm.insert(QStringLiteral("playing"), po.value(QStringLiteral("playing")).toBool(false));
            playersList.append(pm);
        }

        applySnapshot(obj.value(QStringLiteral("has")).toBool(false),
                      obj.value(QStringLiteral("playing")).toBool(false),
                      obj.value(QStringLiteral("title")).toString(),
                      obj.value(QStringLiteral("artist")).toString(),
                      obj.value(QStringLiteral("album")).toString(),
                      obj.value(QStringLiteral("app")).toString(),
                      artUrl,
                      obj.value(QStringLiteral("pos")).toDouble(0.0),
                      obj.value(QStringLiteral("dur")).toDouble(0.0),
                      obj.value(QStringLiteral("canNext")).toBool(false),
                      obj.value(QStringLiteral("canPrev")).toBool(false),
                      obj.value(QStringLiteral("canSeek")).toBool(false),
                      playersList);
    }
}

void MediaService::applySnapshot(bool hasSession, bool isPlaying,
                                 const QString& title, const QString& artist,
                                 const QString& album, const QString& sourceApp,
                                 const QString& artUrl, double posSec, double durSec,
                                 bool canNext, bool canPrev, bool canSeek,
                                 const QVariantList& players)
{
    const bool metaChanged = (m_hasSession != hasSession
        || m_isPlaying != isPlaying
        || m_title != title
        || m_artist != artist
        || m_album != album
        || m_sourceApp != sourceApp
        || m_artUrl != artUrl
        || qAbs(m_durationSec - durSec) > 0.2
        || m_canNext != canNext
        || m_canPrev != canPrev
        || m_canSeek != canSeek
        || m_players != players);

    const bool posChanged = qAbs(m_positionSec - posSec) > 0.2;

    if (!metaChanged && !posChanged)
        return;

    m_hasSession = hasSession;
    m_isPlaying = isPlaying;
    m_title = title;
    m_artist = artist;
    m_album = album;
    m_sourceApp = sourceApp;
    m_artUrl = artUrl;
    m_positionSec = posSec;
    m_durationSec = durSec;
    m_canNext = canNext;
    m_canPrev = canPrev;
    m_canSeek = canSeek;
    m_players = players;

    if (metaChanged)
        emit mediaChanged();
    if (posChanged || metaChanged)
        emit timelineChanged();
}
