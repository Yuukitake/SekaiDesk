#include "NotificationService.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrl>
#include <QVariantMap>

#include <algorithm>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace {
#ifdef Q_OS_WIN
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
#endif

QString formatNotifTimeText(qint64 timestampMs)
{
    if (timestampMs <= 0)
        return QStringLiteral("now");
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 diffSec = qMax<qint64>(0, (nowMs - timestampMs) / 1000);
    if (diffSec < 60)
        return QStringLiteral("now");
    if (diffSec < 3600)
        return QStringLiteral("%1m").arg(diffSec / 60);
    const QDateTime dt = QDateTime::fromMSecsSinceEpoch(timestampMs).toLocalTime();
    if (dt.date() == QDateTime::currentDateTime().date())
        return dt.toString(QStringLiteral("HH:mm"));
    return dt.toString(QStringLiteral("MMM d"));
}
} // namespace

NotificationService::NotificationService(QObject* parent)
    : QObject(parent)
{
#ifdef Q_OS_WIN
    const qint64 pid = QCoreApplication::applicationPid();
    m_cmdFile = QDir::tempPath() + QStringLiteral("/sekaidesk_notif_cmd_%1.txt").arg(pid);
    m_iconDir = QDir::tempPath() + QStringLiteral("/sekaidesk_notif_icons_%1").arg(pid);
    QDir().mkpath(m_iconDir);

    m_ageTimer.setInterval(30000);
    connect(&m_ageTimer, &QTimer::timeout, this, &NotificationService::refreshTimeTexts);
    m_ageTimer.start();

    QTimer::singleShot(550, this, &NotificationService::startWorker);
#endif
}

NotificationService::~NotificationService()
{
    m_ageTimer.stop();
    if (m_proc) {
        m_proc->kill();
        m_proc->waitForFinished(300);
    }
    if (!m_cmdFile.isEmpty())
        QFile::remove(m_cmdFile);
    if (!m_iconDir.isEmpty())
        QDir(m_iconDir).removeRecursively();
}

void NotificationService::sendCommand(const QString& cmd)
{
#ifdef Q_OS_WIN
    if (m_cmdFile.isEmpty())
        return;
    QFile f(m_cmdFile);
    if (f.open(QIODevice::WriteOnly | QIODevice::Append)) {
        f.write(cmd.toUtf8());
        f.write("\n");
        f.close();
    }
#else
    Q_UNUSED(cmd);
#endif
}

void NotificationService::dismiss(quint32 id)
{
#ifdef Q_OS_WIN
    bool removed = false;
    for (int i = m_notifications.size() - 1; i >= 0; --i) {
        if (m_notifications.at(i).toMap().value(QStringLiteral("id")).toUInt() == id) {
            m_notifications.removeAt(i);
            removed = true;
        }
    }
    if (removed)
        emit notificationsChanged();
    sendCommand(QStringLiteral("dismiss:%1").arg(id));
#else
    Q_UNUSED(id);
#endif
}

void NotificationService::clearAll()
{
#ifdef Q_OS_WIN
    if (!m_notifications.isEmpty()) {
        m_notifications.clear();
        emit notificationsChanged();
    }
    sendCommand(QStringLiteral("clear"));
#endif
}

void NotificationService::refresh()
{
#ifdef Q_OS_WIN
    sendCommand(QStringLiteral("refresh"));
#endif
}

void NotificationService::setPaused(bool paused)
{
#ifdef Q_OS_WIN
    if (paused) {
        m_ageTimer.stop();
        sendCommand(QStringLiteral("pause"));
    } else {
        if (!m_ageTimer.isActive())
            m_ageTimer.start();
        sendCommand(QStringLiteral("resume"));
    }
#else
    Q_UNUSED(paused);
#endif
}

void NotificationService::emitTestNotification()
{
    QVariantMap m;
    m.insert(QStringLiteral("id"), 999999u);
    m.insert(QStringLiteral("app"), QStringLiteral("SekaiDesk"));
    m.insert(QStringLiteral("title"), QStringLiteral("Test Alert"));
    m.insert(QStringLiteral("body"), QStringLiteral("Notification peek is working!"));
    m.insert(QStringLiteral("timeText"), QStringLiteral("now"));
    m.insert(QStringLiteral("iconUrl"), QString());
    emit newNotificationReceived(m);
}

void NotificationService::refreshTimeTexts()
{
    if (m_notifications.isEmpty())
        return;
    bool changed = false;
    for (int i = 0; i < m_notifications.size(); ++i) {
        QVariantMap m = m_notifications.at(i).toMap();
        const qint64 tsMs = m.value(QStringLiteral("timestampMs")).toLongLong();
        const QString nextText = formatNotifTimeText(tsMs);
        if (m.value(QStringLiteral("timeText")).toString() != nextText) {
            m.insert(QStringLiteral("timeText"), nextText);
            m_notifications[i] = m;
            changed = true;
        }
    }
    if (changed)
        emit notificationsChanged();
}

void NotificationService::startWorker()
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
            this, &NotificationService::onStdoutReady);

    QString escapedCmdPath = m_cmdFile;
    escapedCmdPath.replace(QLatin1Char('\''), QStringLiteral("''"));
    QString escapedIconDir = m_iconDir;
    escapedIconDir.replace(QLatin1Char('\''), QStringLiteral("''"));

    const QString script = QStringLiteral(
        "$ErrorActionPreference = 'SilentlyContinue'\n"
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n"
        "Add-Type -AssemblyName System.Runtime.WindowsRuntime\n"
        "$thCode = @'\n"
        "using System;\n"
        "using System.IO;\n"
        "using System.Runtime.InteropServices;\n"
        "using System.Runtime.InteropServices.ComTypes;\n"
        "public static class WinRtNotifStreamHelper {\n"
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
        "                        if (ms.Length > 4194304) break;\n"
        "                    }\n"
        "                } finally { Marshal.FreeHGlobal(readPtr); }\n"
        "                return ms.ToArray();\n"
        "            }\n"
        "        } finally { Marshal.ReleaseComObject(istream); }\n"
        "    }\n"
        "}\n"
        "'@\n"
        "Add-Type -TypeDefinition $thCode\n"
        "[Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications.Management, ContentType = WindowsRuntime] | Out-Null\n"
        "[Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus, Windows.UI.Notifications.Management, ContentType = WindowsRuntime] | Out-Null\n"
        "[Windows.UI.Notifications.NotificationKinds, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null\n"
        "[Windows.UI.Notifications.KnownNotificationBindings, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null\n"
        "[Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null\n"
        "[Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null\n"
        "$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]\n"
        "function Await($op, $t) {\n"
        "  if ($null -eq $op -or $null -eq $t) { return $null }\n"
        "  $m = $asTask.MakeGenericMethod($t)\n"
        "  $tsk = $m.Invoke($null, @($op))\n"
        "  $tsk.Wait(2000) | Out-Null\n"
        "  return $tsk.Result\n"
        "}\n"
        "$notifListType = [Windows.UI.Notifications.Management.UserNotificationListener].GetMethod('GetNotificationsAsync').ReturnType.GetGenericArguments()[0]\n"
        "$accessType = [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]\n"
        "$streamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]\n"
        "$logoSize = [Windows.Foundation.Size]::new(64, 64)\n"
        "function FallbackAppName($aumid) {\n"
        "  if ([string]::IsNullOrWhiteSpace($aumid)) { return 'Notification' }\n"
        "  $tail = ($aumid -split '!')[-1] -replace '\\.exe$',''\n"
        "  if ($tail -match '([A-Za-z0-9 _-]+)$') { return $matches[1] }\n"
        "  return $aumid\n"
        "}\n"
        "$cmdFile = '%1'\n"
        "$iconDir = '%2'\n"
        "$parentPid = %3\n"
        "$listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current\n"
        "$logoCache = @{}\n"
        "$logoSeq = 0\n"
        "$last = ''\n"
        "$tick = 0\n"
        "$paused = $false\n"
        "while ($true) {\n"
        "  if (($tick % 12) -eq 0 -and -not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }\n"
        "  if ([System.IO.File]::Exists($cmdFile)) {\n"
        "    $rawCmds = [System.IO.File]::ReadAllLines($cmdFile)\n"
        "    [System.IO.File]::Delete($cmdFile)\n"
        "    foreach ($rawLine in $rawCmds) {\n"
        "      $cmd = $rawLine.Trim()\n"
        "      if ($cmd -eq '') { continue }\n"
        "      if ($cmd -eq 'pause') { $paused = $true; continue }\n"
        "      if ($cmd -eq 'resume') { $paused = $false; continue }\n"
        "      if ($listener) {\n"
        "        if ($cmd -eq 'clear') {\n"
        "          $listener.ClearNotifications()\n"
        "        } elseif ($cmd.StartsWith('dismiss:')) {\n"
        "          $idNum = [uint32]0\n"
        "          if ([uint32]::TryParse($cmd.Substring(8), [ref]$idNum)) {\n"
        "            $listener.RemoveNotification($idNum)\n"
        "          }\n"
        "        }\n"
        "      }\n"
        "    }\n"
        "    $tick = 6\n"
        "  }\n"
        "  if ($paused) {\n"
        "    Start-Sleep -Milliseconds 1500\n"
        "    continue\n"
        "  }\n"
        "  if ($tick % 6 -eq 0) {\n"
        "    $granted = $false\n"
        "    $items = [System.Collections.Generic.List[object]]::new()\n"
        "    if ($listener) {\n"
        "      $st = $listener.GetAccessStatus()\n"
        "      if ($st -eq [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]::Unspecified) {\n"
        "        $st = Await ($listener.RequestAccessAsync()) $accessType\n"
        "      }\n"
        "      $granted = ($st -eq [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]::Allowed)\n"
        "      if ($granted) {\n"
        "        $res = Await ($listener.GetNotificationsAsync([Windows.UI.Notifications.NotificationKinds]::Toast)) $notifListType\n"
        "        if ($res) {\n"
        "          foreach ($n in $res) {\n"
        "            $aumid = ''\n"
        "            $appName = ''\n"
        "            $iconPath = ''\n"
        "            if ($n.AppInfo) {\n"
        "              $aumid = [string]$n.AppInfo.AppUserModelId\n"
        "              if ($n.AppInfo.DisplayInfo) {\n"
        "                $appName = [string]$n.AppInfo.DisplayInfo.DisplayName\n"
        "                $cacheKey = if ($aumid -ne '') { $aumid } else { $appName }\n"
        "                if ($cacheKey -ne '') {\n"
        "                  if ($logoCache.ContainsKey($cacheKey)) {\n"
        "                    $iconPath = $logoCache[$cacheKey]\n"
        "                  } else {\n"
        "                    $saved = ''\n"
        "                    try {\n"
        "                      $logoRef = $n.AppInfo.DisplayInfo.GetLogo($logoSize)\n"
        "                      if ($logoRef) {\n"
        "                        $rst = Await ($logoRef.OpenReadAsync()) $streamType\n"
        "                        if ($rst) {\n"
        "                          $bytes = [WinRtNotifStreamHelper]::ReadAll($rst)\n"
        "                          if ($bytes -and $bytes.Length -gt 0) {\n"
        "                            $logoSeq++\n"
        "                            $outPng = Join-Path $iconDir ('app_' + $logoSeq + '.png')\n"
        "                            [System.IO.File]::WriteAllBytes($outPng, $bytes)\n"
        "                            $saved = $outPng\n"
        "                          }\n"
        "                        }\n"
        "                      }\n"
        "                    } catch {}\n"
        "                    $logoCache[$cacheKey] = $saved\n"
        "                    $iconPath = $saved\n"
        "                  }\n"
        "                }\n"
        "              }\n"
        "            }\n"
        "            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = FallbackAppName $aumid }\n"
        "            $lines = [System.Collections.Generic.List[string]]::new()\n"
        "            if ($n.Notification -and $n.Notification.Visual) {\n"
        "              $binding = $n.Notification.Visual.GetBinding([Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric)\n"
        "              if (-not $binding -and $n.Notification.Visual.Bindings.Count -gt 0) {\n"
        "                $binding = $n.Notification.Visual.Bindings[0]\n"
        "              }\n"
        "              if ($binding) {\n"
        "                foreach ($te in $binding.GetTextElements()) {\n"
        "                  $txt = [string]$te.Text\n"
        "                  if (-not [string]::IsNullOrWhiteSpace($txt)) { $lines.Add($txt.Trim()) }\n"
        "                }\n"
        "              }\n"
        "            }\n"
        "            $title = if ($lines.Count -gt 0) { $lines[0] } else { '' }\n"
        "            $body = ''\n"
        "            if ($lines.Count -gt 1) {\n"
        "              $rest = @()\n"
        "              for ($li = 1; $li -lt $lines.Count; $li++) { $rest += $lines[$li] }\n"
        "              $body = ($rest -join \"`n\")\n"
        "            }\n"
        "            $tsMs = [int64]$n.CreationTime.ToUnixTimeMilliseconds()\n"
        "            $items.Add(@{ id = [uint32]$n.Id; app = $appName; aumid = $aumid; title = $title; body = $body; timestampMs = $tsMs; icon = $iconPath })\n"
        "          }\n"
        "        }\n"
        "      }\n"
        "    }\n"
        "    $payload = @{ granted = $granted; items = $items }\n"
        "    $line = ($payload | ConvertTo-Json -Compress -Depth 4)\n"
        "    if ($line -ne $last) { $last = $line; [Console]::Out.WriteLine($line); [Console]::Out.Flush() }\n"
        "  }\n"
        "  $tick++\n"
        "  Start-Sleep -Milliseconds 250\n"
        "}\n"
    ).arg(escapedCmdPath, escapedIconDir).arg(QCoreApplication::applicationPid());

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

void NotificationService::onStdoutReady()
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

        const bool nextGranted = obj.value(QStringLiteral("granted")).toBool(false);
        if (m_accessGranted != nextGranted) {
            m_accessGranted = nextGranted;
            emit accessGrantedChanged();
        }

        QJsonArray arr;
        const QJsonValue itemsVal = obj.value(QStringLiteral("items"));
        if (itemsVal.isArray())
            arr = itemsVal.toArray();
        else if (itemsVal.isObject())
            arr.append(itemsVal.toObject());

        QVariantList nextList;
        nextList.reserve(arr.size());
        for (const QJsonValue& v : arr) {
            if (!v.isObject())
                continue;
            const QJsonObject item = v.toObject();
            const quint32 id = static_cast<quint32>(item.value(QStringLiteral("id")).toInteger(0));
            const qint64 tsMs = static_cast<qint64>(item.value(QStringLiteral("timestampMs")).toDouble(0.0));
            const QString iconPath = item.value(QStringLiteral("icon")).toString();
            const QString iconUrl = iconPath.isEmpty()
                ? QString()
                : QUrl::fromLocalFile(iconPath).toString();

            QVariantMap m;
            m.insert(QStringLiteral("id"), id);
            m.insert(QStringLiteral("app"), item.value(QStringLiteral("app")).toString());
            m.insert(QStringLiteral("aumid"), item.value(QStringLiteral("aumid")).toString());
            m.insert(QStringLiteral("title"), item.value(QStringLiteral("title")).toString());
            m.insert(QStringLiteral("body"), item.value(QStringLiteral("body")).toString());
            m.insert(QStringLiteral("timestampMs"), tsMs);
            m.insert(QStringLiteral("timeText"), formatNotifTimeText(tsMs));
            m.insert(QStringLiteral("iconUrl"), iconUrl);
            nextList.append(m);
        }

        std::sort(nextList.begin(), nextList.end(), [](const QVariant& a, const QVariant& b) {
            const QVariantMap ma = a.toMap();
            const QVariantMap mb = b.toMap();
            const qint64 ta = ma.value(QStringLiteral("timestampMs")).toLongLong();
            const qint64 tb = mb.value(QStringLiteral("timestampMs")).toLongLong();
            if (ta != tb)
                return ta > tb;
            return ma.value(QStringLiteral("id")).toUInt() > mb.value(QStringLiteral("id")).toUInt();
        });

        QVariantList newlyArrived;
        if (!m_initialPollDone) {
            for (const QVariant& v : nextList) {
                const QVariantMap m = v.toMap();
                const QString key = QStringLiteral("%1:%2")
                    .arg(m.value(QStringLiteral("id")).toUInt())
                    .arg(m.value(QStringLiteral("timestampMs")).toLongLong());
                m_seenToastKeys.insert(key);
            }
            m_initialPollDone = true;
        } else {
            if (m_seenToastKeys.size() > 500) {
                m_seenToastKeys.clear();
                for (const QVariant& v : m_notifications) {
                    const QVariantMap m = v.toMap();
                    m_seenToastKeys.insert(QStringLiteral("%1:%2")
                        .arg(m.value(QStringLiteral("id")).toUInt())
                        .arg(m.value(QStringLiteral("timestampMs")).toLongLong()));
                }
            }
            for (const QVariant& v : nextList) {
                const QVariantMap m = v.toMap();
                const QString key = QStringLiteral("%1:%2")
                    .arg(m.value(QStringLiteral("id")).toUInt())
                    .arg(m.value(QStringLiteral("timestampMs")).toLongLong());
                if (!m_seenToastKeys.contains(key)) {
                    m_seenToastKeys.insert(key);
                    if (newlyArrived.size() < 3)
                        newlyArrived.append(m);
                }
            }
        }

        if (m_notifications != nextList) {
            m_notifications = std::move(nextList);
            emit notificationsChanged();
        }

        for (int i = newlyArrived.size() - 1; i >= 0; --i)
            emit newNotificationReceived(newlyArrived.at(i).toMap());
    }
}
