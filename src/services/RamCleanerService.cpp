#include "RamCleanerService.h"
#include "core/SettingsStore.h"

#include <QMetaObject>
#include <QPointer>
#include <QTime>
#include <vector>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <psapi.h>
#endif

namespace {

#ifdef Q_OS_WIN
bool isCurrentProcessElevated()
{
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
        return false;
    TOKEN_ELEVATION elev{};
    DWORD len = 0;
    const BOOL ok = GetTokenInformation(token, TokenElevation, &elev, sizeof(elev), &len);
    CloseHandle(token);
    return ok && elev.TokenIsElevated != 0;
}

bool enableProcessPrivilege(const wchar_t* privName)
{
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
        return false;

    LUID luid{};
    if (!LookupPrivilegeValueW(nullptr, privName, &luid)) {
        CloseHandle(token);
        return false;
    }

    TOKEN_PRIVILEGES tp{};
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Luid = luid;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

    const BOOL ok = AdjustTokenPrivileges(token, FALSE, &tp, sizeof(tp), nullptr, nullptr);
    const DWORD err = GetLastError();
    CloseHandle(token);
    return ok && err != ERROR_NOT_ALL_ASSIGNED;
}

quint64 queryAvailRamBytes()
{
    MEMORYSTATUSEX ms{};
    ms.dwLength = sizeof(ms);
    if (!GlobalMemoryStatusEx(&ms))
        return 0;
    return ms.ullAvailPhys;
}

int queryRamLoadPercent()
{
    MEMORYSTATUSEX ms{};
    ms.dwLength = sizeof(ms);
    if (!GlobalMemoryStatusEx(&ms))
        return 0;
    return static_cast<int>(ms.dwMemoryLoad);
}

using FnNtSetSystemInformation = LONG(NTAPI*)(ULONG, PVOID, ULONG);

bool runMemoryListCommand(ULONG command, LONG* outStatus = nullptr)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (!ntdll)
        return false;
    static auto fnNtSetSysInfo = reinterpret_cast<FnNtSetSystemInformation>(
        GetProcAddress(ntdll, "NtSetSystemInformation"));
    if (!fnNtSetSysInfo)
        return false;

    const LONG status = fnNtSetSysInfo(0x50 /* SystemMemoryListInformation */, &command, sizeof(command));
    if (outStatus)
        *outStatus = status;
    return status == 0;
}

int trimUserWorkingSets(DWORD skipPid)
{
    std::vector<DWORD> pids(1024, 0);
    DWORD bytesNeeded = 0;
    while (true) {
        if (!EnumProcesses(pids.data(), static_cast<DWORD>(pids.size() * sizeof(DWORD)), &bytesNeeded))
            return 0;
        const size_t count = bytesNeeded / sizeof(DWORD);
        if (count < pids.size()) {
            pids.resize(count);
            break;
        }
        if (pids.size() >= 131072)
            break;
        pids.resize(pids.size() * 2, 0);
    }

    const DWORD selfPid = GetCurrentProcessId();
    int trimmed = 0;
    for (DWORD pid : pids) {
        if (pid == 0 || pid == 4 || pid == selfPid || pid == skipPid)
            continue;
        HANDLE hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA, FALSE, pid);
        if (!hProc)
            continue;
        if (EmptyWorkingSet(hProc))
            ++trimmed;
        CloseHandle(hProc);
    }
    return trimmed;
}
#endif

} // namespace

RamCleanerService::RamCleanerService(SettingsStore* settings, QObject* parent)
    : QObject(parent)
    , m_settings(settings)
{
    if (m_settings) {
        m_autoEnabled = m_settings->boolValue(QStringLiteral("ramCleaner.autoEnabled"), true);
        m_thresholdPercent = qBound(60, m_settings->intValue(QStringLiteral("ramCleaner.thresholdPct"), 80), 95);
        m_intervalSeconds = qBound(60, m_settings->intValue(QStringLiteral("ramCleaner.intervalSec"), 300), 1800);
    }

#ifdef Q_OS_WIN
    m_elevated = isCurrentProcessElevated();
    if (m_elevated) {
        enableProcessPrivilege(L"SeProfileSingleProcessPrivilege");
        enableProcessPrivilege(L"SeIncreaseQuotaPrivilege");
    }
#endif

    m_autoTimer.setInterval(15000);
    m_autoTimer.setTimerType(Qt::CoarseTimer);
    connect(&m_autoTimer, &QTimer::timeout, this, &RamCleanerService::onAutoTimer);
    if (m_autoEnabled)
        m_autoTimer.start();
}

RamCleanerService::~RamCleanerService()
{
    m_destroyed.store(true);
    m_autoTimer.stop();
    if (m_worker.joinable())
        m_worker.join();
}

void RamCleanerService::joinWorkerIfFinished()
{
    if (!m_busy.load() && m_worker.joinable())
        m_worker.join();
}

void RamCleanerService::setAutoEnabled(bool on)
{
    if (m_autoEnabled == on)
        return;
    m_autoEnabled = on;
    if (m_settings)
        m_settings->set(QStringLiteral("ramCleaner.autoEnabled"), on);
    if (on)
        m_autoTimer.start();
    else
        m_autoTimer.stop();
    emit configChanged();
}

void RamCleanerService::setThresholdPercent(int pct)
{
    const int clamped = qBound(60, pct, 95);
    if (m_thresholdPercent == clamped)
        return;
    m_thresholdPercent = clamped;
    if (m_settings)
        m_settings->set(QStringLiteral("ramCleaner.thresholdPct"), clamped);
    emit configChanged();
}

void RamCleanerService::setIntervalSeconds(int sec)
{
    const int clamped = qBound(60, sec, 1800);
    if (m_intervalSeconds == clamped)
        return;
    m_intervalSeconds = clamped;
    if (m_settings)
        m_settings->set(QStringLiteral("ramCleaner.intervalSec"), clamped);
    emit configChanged();
}

void RamCleanerService::onAutoTimer()
{
    if (!m_autoEnabled || m_busy.load() || m_destroyed.load())
        return;
    if (m_lastAutoElapsed.isValid() && m_lastAutoElapsed.elapsed() < static_cast<qint64>(m_intervalSeconds) * 1000)
        return;
#ifdef Q_OS_WIN
    if (queryRamLoadPercent() >= m_thresholdPercent) {
        m_lastAutoElapsed.restart();
        startCleanWorker(false, true);
    }
#endif
}

void RamCleanerService::cleanNowDeep()
{
    startCleanWorker(true, false);
}

void RamCleanerService::cleanNowStutterFree()
{
    startCleanWorker(false, false);
}

void RamCleanerService::startCleanWorker(bool deepMode, bool isAuto)
{
    if (m_busy.load() || m_destroyed.load())
        return;
    joinWorkerIfFinished();

    m_busy.store(true);
    m_cleaning = true;
    emit stateChanged();

#ifdef Q_OS_WIN
    const QPointer<RamCleanerService> self(this);
    m_worker = std::thread([this, self, deepMode, isAuto]() {
        enableProcessPrivilege(L"SeProfileSingleProcessPrivilege");
        enableProcessPrivilege(L"SeIncreaseQuotaPrivilege");

        const quint64 availBefore = queryAvailRamBytes();
        int trimmedProcs = 0;
        bool p0Ok = false;
        bool modOk = false;
        bool standbyOk = false;

        if (deepMode) {
            trimmedProcs = trimUserWorkingSets(0);
            modOk = runMemoryListCommand(3);     // ModifiedPageList
            standbyOk = runMemoryListCommand(4); // StandbyList
            if (!standbyOk)
                p0Ok = runMemoryListCommand(5);  // Fallback Priority0StandbyList
            Sleep(120);
        } else {
            p0Ok = runMemoryListCommand(5);      // Priority0StandbyList only (stutter-free)
            Sleep(80);
        }

        const quint64 availAfter = queryAvailRamBytes();
        const qint64 diffMb = (availAfter > availBefore)
            ? static_cast<qint64>((availAfter - availBefore) / (1024ULL * 1024ULL))
            : 0;

        QString summary;
        if (deepMode) {
            if (diffMb > 0) {
                summary = QStringLiteral("Deep Clean: +%1 MB free · %2 procs")
                              .arg(diffMb)
                              .arg(trimmedProcs);
            } else if (standbyOk || modOk || trimmedProcs > 0) {
                summary = QStringLiteral("Deep Clean: %1 procs & cache trimmed")
                              .arg(trimmedProcs);
            } else {
                summary = QStringLiteral("Deep Clean: run as Admin for standby purge");
            }
        } else {
            const QString prefix = isAuto ? QStringLiteral("Auto P0 Standby") : QStringLiteral("P0 Standby");
            if (p0Ok && diffMb > 0) {
                summary = QStringLiteral("%1: +%2 MB free").arg(prefix).arg(diffMb);
            } else if (p0Ok) {
                summary = QStringLiteral("%1: standby cache trimmed").arg(prefix);
            } else {
                summary = QStringLiteral("%1: requires Admin privilege").arg(prefix);
            }
        }

        const QString timeStr = QTime::currentTime().toString(QStringLiteral("HH:mm:ss"));

        m_busy.store(false);
        if (m_destroyed.load())
            return;

        QMetaObject::invokeMethod(this, [self, diffMb, summary, timeStr]() {
            if (!self || self->m_destroyed.load())
                return;
            self->m_lastFreedMb = static_cast<int>(diffMb);
            self->m_lastResultText = summary;
            self->m_lastCleanTime = timeStr;
            self->m_cleaning = false;
            emit self->stateChanged();
        }, Qt::QueuedConnection);
    });
#else
    m_busy.store(false);
    m_cleaning = false;
    emit stateChanged();
#endif
}
