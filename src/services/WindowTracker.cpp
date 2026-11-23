#include "WindowTracker.h"

#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QHash>
#include <QRegularExpression>
#include <QScreen>
#include <QStandardPaths>
#include <QUrl>
#include <cmath>
#include <vector>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#if !defined(_WIN32_WINNT) || (_WIN32_WINNT < 0x0600)
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <winsock2.h>
#include <ws2ipdef.h>
#include <windows.h>
#include <dxgi.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <dwmapi.h>
#include <pdh.h>
#include <psapi.h>
#include <shellapi.h>
#include <tlhelp32.h>
#endif

namespace {

QString normalizeExeKey(const QString& path)
{
    QString p = path.trimmed();
    p.replace(QLatin1Char('/'), QLatin1Char('\\'));
    return p.toLower();
}

QString friendlyNameFromExe(const QString& exePath)
{
    const QString base = QFileInfo(exePath).completeBaseName();
    if (base.isEmpty())
        return QStringLiteral("App");
    QString out = base;
    out[0] = out[0].toUpper();
    return out;
}

#ifdef Q_OS_WIN
struct EnumContext {
    DWORD selfPid = 0;
    HWND foreground = nullptr;
    QHash<QString, QPair<QString, QList<HWND>>> byExe;
    QHash<QString, QString> firstTitle;
};

static bool isAltTabCandidate(HWND hwnd, DWORD selfPid)
{
    if (!IsWindowVisible(hwnd))
        return false;

    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0 || pid == selfPid)
        return false;

    if (GetWindowTextLengthW(hwnd) <= 0)
        return false;

    const LONG_PTR exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if ((exStyle & WS_EX_TOOLWINDOW) && !(exStyle & WS_EX_APPWINDOW))
        return false;

    if (GetWindow(hwnd, GW_OWNER) != nullptr && !(exStyle & WS_EX_APPWINDOW))
        return false;

    // Skip cloaked UWP / other-virtual-desktop windows.
    BOOL cloaked = FALSE;
    if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))
        && cloaked) {
        return false;
    }

    wchar_t cls[128] = {};
    if (GetClassNameW(hwnd, cls, 128) > 0) {
        const QString className = QString::fromWCharArray(cls);
        if (className == QStringLiteral("Progman")
            || className == QStringLiteral("WorkerW")
            || className == QStringLiteral("Shell_TrayWnd")
            || className == QStringLiteral("Windows.UI.Core.CoreWindow")) {
            return false;
        }
    }

    return true;
}

static QHash<DWORD, QString>& pidExeCache()
{
    static QHash<DWORD, QString> s_cache;
    return s_cache;
}

static QString queryProcessExe(HWND hwnd)
{
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0)
        return {};

    auto& cache = pidExeCache();
    auto it = cache.constFind(pid);
    if (it != cache.constEnd())
        return it.value();

    HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!proc)
        return {};

    wchar_t buf[MAX_PATH * 2] = {};
    DWORD len = MAX_PATH * 2;
    QString result;
    if (QueryFullProcessImageNameW(proc, 0, buf, &len) && len > 0)
        result = QString::fromWCharArray(buf, static_cast<int>(len));
    CloseHandle(proc);
    if (!result.isEmpty()) {
        if (cache.size() > 512)
            cache.clear();
        cache.insert(pid, result);
    }
    return result;
}

static BOOL CALLBACK enumWindowsProc(HWND hwnd, LPARAM lParam)
{
    auto* ctx = reinterpret_cast<EnumContext*>(lParam);
    if (!isAltTabCandidate(hwnd, ctx->selfPid))
        return TRUE;

    const QString exe = queryProcessExe(hwnd);
    if (exe.isEmpty())
        return TRUE;

    const QString key = normalizeExeKey(exe);
    if (!ctx->byExe.contains(key)) {
        ctx->byExe.insert(key, { exe, { hwnd } });
        wchar_t title[256] = {};
        if (GetWindowTextW(hwnd, title, 256) > 0)
            ctx->firstTitle.insert(key, QString::fromWCharArray(title));
    } else {
        ctx->byExe[key].second.append(hwnd);
    }
    return TRUE;
}

static QString readRegSz64(HKEY root, const wchar_t* subKey, const wchar_t* valueName)
{
    HKEY hKey = nullptr;
    if (RegOpenKeyExW(root, subKey, 0, KEY_READ | KEY_WOW64_64KEY, &hKey) != ERROR_SUCCESS)
        return {};
    wchar_t buf[512] = {};
    DWORD type = 0;
    DWORD cb = sizeof(buf) - sizeof(wchar_t);
    QString out;
    if (RegQueryValueExW(hKey, valueName, nullptr, &type, reinterpret_cast<LPBYTE>(buf), &cb) == ERROR_SUCCESS
        && (type == REG_SZ || type == REG_EXPAND_SZ) && cb >= sizeof(wchar_t)) {
        out = QString::fromWCharArray(buf).trimmed();
    }
    RegCloseKey(hKey);
    return out;
}

static QString queryCpuSpec()
{
    QString raw = readRegSz64(
        HKEY_LOCAL_MACHINE,
        L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
        L"ProcessorNameString");
    if (raw.isEmpty())
        return QStringLiteral("Unknown CPU");
    static const QRegularExpression tmRe(QStringLiteral(R"(\((?:R|TM|r|tm)\))"));
    static const QRegularExpression cpuWordRe(QStringLiteral(R"(\bCPU\b)"));
    static const QRegularExpression freqRe(QStringLiteral(R"(\s+@.*$)"));
    raw.remove(tmRe);
    raw.remove(cpuWordRe);
    raw.remove(freqRe);
    raw = raw.simplified();
    return raw.isEmpty() ? QStringLiteral("Unknown CPU") : raw;
}

static QString queryRamSpec()
{
    MEMORYSTATUSEX ms{};
    ms.dwLength = sizeof(ms);
    QString capStr;
    if (GlobalMemoryStatusEx(&ms) && ms.ullTotalPhys > 0) {
        const double gb = static_cast<double>(ms.ullTotalPhys) / (1024.0 * 1024.0 * 1024.0);
        if (gb >= 1.0)
            capStr = QStringLiteral("%1 GB").arg(static_cast<qint64>(std::llround(gb)));
        else
            capStr = QStringLiteral("%1 MB").arg(static_cast<qint64>(std::llround(static_cast<double>(ms.ullTotalPhys) / (1024.0 * 1024.0))));
    } else {
        capStr = QStringLiteral("Unknown RAM");
    }

    QString ddrType;
    const DWORD needed = GetSystemFirmwareTable('RSMB', 0, nullptr, 0);
    if (needed > 8 && needed <= 512 * 1024) {
        std::vector<BYTE> buf(needed);
        if (GetSystemFirmwareTable('RSMB', 0, buf.data(), needed) == needed) {
            const DWORD tableLen = *reinterpret_cast<const DWORD*>(buf.data() + 4);
            const size_t startOff = 8;
            const size_t endOff = qMin(buf.size(), startOff + static_cast<size_t>(tableLen));
            size_t off = startOff;
            while (off + 4 <= endOff) {
                const BYTE type = buf[off];
                const BYTE hdrLen = buf[off + 1];
                if (hdrLen < 4 || off + hdrLen > endOff)
                    break;
                if (type == 17 && hdrLen >= 0x13) {
                    const WORD memSize = static_cast<WORD>(buf[off + 0x0C])
                        | (static_cast<WORD>(buf[off + 0x0D]) << 8);
                    if (memSize > 0) {
                        const BYTE mtype = buf[off + 0x12];
                        switch (mtype) {
                        case 0x13: ddrType = QStringLiteral("DDR2"); break;
                        case 0x18: ddrType = QStringLiteral("DDR3"); break;
                        case 0x1A: ddrType = QStringLiteral("DDR4"); break;
                        case 0x1E: ddrType = QStringLiteral("LPDDR4"); break;
                        case 0x22: ddrType = QStringLiteral("DDR5"); break;
                        case 0x23: ddrType = QStringLiteral("LPDDR5"); break;
                        default: break;
                        }
                        if (!ddrType.isEmpty())
                            break;
                    }
                }
                size_t p = off + hdrLen;
                while (p + 1 < endOff && !(buf[p] == 0 && buf[p + 1] == 0))
                    ++p;
                if (p + 1 >= endOff)
                    break;
                off = p + 2;
            }
        }
    }

    return ddrType.isEmpty() ? capStr : QStringLiteral("%1 %2").arg(capStr, ddrType);
}

static QString queryGpuSpec()
{
    QString bestName;
    SIZE_T bestVram = 0;

    if (HMODULE dxgiMod = LoadLibraryW(L"dxgi.dll")) {
        using PfnCreateDXGIFactory1 = HRESULT(WINAPI*)(REFIID, void**);
        const auto pCreate = reinterpret_cast<PfnCreateDXGIFactory1>(
            GetProcAddress(dxgiMod, "CreateDXGIFactory1"));
        if (pCreate) {
            static const GUID kIidDXGIFactory1 = {
                0x770aae78, 0xf26f, 0x4dba, { 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 }
            };
            IDXGIFactory1* factory = nullptr;
            if (SUCCEEDED(pCreate(kIidDXGIFactory1, reinterpret_cast<void**>(&factory))) && factory) {
                for (UINT idx = 0; ; ++idx) {
                    IDXGIAdapter1* adapter = nullptr;
                    if (factory->EnumAdapters1(idx, &adapter) == DXGI_ERROR_NOT_FOUND)
                        break;
                    if (adapter) {
                        DXGI_ADAPTER_DESC1 desc{};
                        if (SUCCEEDED(adapter->GetDesc1(&desc))) {
                            if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                                const QString name = QString::fromWCharArray(desc.Description).trimmed();
                                if (!name.isEmpty() && (bestName.isEmpty() || desc.DedicatedVideoMemory > bestVram)) {
                                    bestName = name;
                                    bestVram = desc.DedicatedVideoMemory;
                                }
                            }
                        }
                        adapter->Release();
                    }
                }
                factory->Release();
            }
        }
        FreeLibrary(dxgiMod);
    }

    if (bestName.isEmpty()) {
        DISPLAY_DEVICEW dd{};
        dd.cb = sizeof(dd);
        if (EnumDisplayDevicesW(nullptr, 0, &dd, 0))
            bestName = QString::fromWCharArray(dd.DeviceString).trimmed();
    }

    if (bestName.isEmpty())
        return QStringLiteral("Unknown GPU");

    if (bestVram >= static_cast<SIZE_T>(512ULL * 1024ULL * 1024ULL)
        && !bestName.contains(QStringLiteral("GB"), Qt::CaseInsensitive)) {
        const int gb = static_cast<int>(std::llround(
            static_cast<double>(bestVram) / (1024.0 * 1024.0 * 1024.0)));
        if (gb > 0)
            bestName += QStringLiteral(" %1GB").arg(gb);
    }
    return bestName;
}

static QString queryOsSpec()
{
    const wchar_t* sub = L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    QString product = readRegSz64(HKEY_LOCAL_MACHINE, sub, L"ProductName");
    QString dispVer = readRegSz64(HKEY_LOCAL_MACHINE, sub, L"DisplayVersion");
    if (dispVer.isEmpty())
        dispVer = readRegSz64(HKEY_LOCAL_MACHINE, sub, L"ReleaseId");
    const QString build = readRegSz64(HKEY_LOCAL_MACHINE, sub, L"CurrentBuildNumber");

    if (!build.isEmpty() && build.toInt() >= 22000 && product.contains(QStringLiteral("Windows 10")))
        product.replace(QStringLiteral("Windows 10"), QStringLiteral("Windows 11"));

    if (product.isEmpty())
        product = QStringLiteral("Windows");
    if (!dispVer.isEmpty() && !build.isEmpty())
        return QStringLiteral("%1 · %2 (%3)").arg(product, dispVer, build);
    if (!build.isEmpty())
        return QStringLiteral("%1 (%2)").arg(product, build);
    return product;
}
#endif

} // namespace

WindowTracker::WindowTracker(QObject* parent)
    : QObject(parent)
{
#ifdef Q_OS_WIN
    wchar_t comp[128] = {};
    DWORD compLen = 128;
    if (GetComputerNameW(comp, &compLen))
        m_machineName = QString::fromWCharArray(comp, static_cast<int>(compLen));
    m_userName = qEnvironmentVariable("USERNAME");
    m_cpuSpec = queryCpuSpec();
    m_ramSpec = queryRamSpec();
    m_gpuSpec = queryGpuSpec();
    m_osSpec = queryOsSpec();
#endif
    if (m_machineName.isEmpty())
        m_machineName = QStringLiteral("Windows");
    if (m_userName.isEmpty())
        m_userName = QStringLiteral("User");
    if (m_cpuSpec.isEmpty())
        m_cpuSpec = QStringLiteral("Unknown CPU");
    if (m_ramSpec.isEmpty())
        m_ramSpec = QStringLiteral("Unknown RAM");
    if (m_gpuSpec.isEmpty())
        m_gpuSpec = QStringLiteral("Unknown GPU");
    if (m_osSpec.isEmpty())
        m_osSpec = QStringLiteral("Windows");

    m_pollTimer.setInterval(1000);
    connect(&m_pollTimer, &QTimer::timeout, this, &WindowTracker::refresh);
    m_pollTimer.start();

    m_edgeTimer.setInterval(80);
    connect(&m_edgeTimer, &QTimer::timeout, this, &WindowTracker::pollEdgeAndOverlap);
    if (m_edgePollingNeeded)
        m_edgeTimer.start();

    refresh();
    if (m_edgePollingNeeded)
        pollEdgeAndOverlap();
}

void WindowTracker::checkLowBatteryAlert()
{
    m_batteryAlertArmed = true;
    m_lowBatteryAlertTier = 0;
    updateSystemStats();
}

void WindowTracker::setEdgePollingNeeded(bool needed)
{
    if (m_edgePollingNeeded == needed)
        return;
    m_edgePollingNeeded = needed;
#ifdef Q_OS_WIN
    if (!m_edgePollingNeeded) {
        m_edgeTimer.stop();
        if (m_dockOverlap) { m_dockOverlap = false; emit dockOverlapChanged(); }
        if (m_topOverlap) { m_topOverlap = false; emit topOverlapChanged(); }
        if (m_leftOverlap) { m_leftOverlap = false; emit leftOverlapChanged(); }
        if (m_rightOverlap) { m_rightOverlap = false; emit rightOverlapChanged(); }
        if (m_bottomEdgeHovered) { m_bottomEdgeHovered = false; emit bottomEdgeHoveredChanged(); }
        if (m_topEdgeHovered) { m_topEdgeHovered = false; emit topEdgeHoveredChanged(); }
        if (m_leftEdgeHovered) { m_leftEdgeHovered = false; emit leftEdgeHoveredChanged(); }
        if (m_rightEdgeHovered) { m_rightEdgeHovered = false; emit rightEdgeHoveredChanged(); }
    } else if (!m_paused) {
        m_overlapSubTick = 0;
        if (!m_edgeTimer.isActive())
            m_edgeTimer.start();
        pollEdgeAndOverlap();
    }
#endif
}

void WindowTracker::setPaused(bool paused)
{
    if (m_paused == paused)
        return;
    m_paused = paused;
#ifdef Q_OS_WIN
    if (m_paused) {
        m_pollTimer.stop();
        m_edgeTimer.stop();
    } else {
        m_overlapSubTick = 0;
        if (!m_pollTimer.isActive())
            m_pollTimer.start();
        if (m_edgePollingNeeded && !m_edgeTimer.isActive())
            m_edgeTimer.start();
        refresh();
        if (m_edgePollingNeeded)
            pollEdgeAndOverlap();
    }
#endif
}

QVariantList WindowTracker::runningExeNames() const
{
    QVariantList out;
    QSet<QString> seen;
    for (auto it = m_groups.constBegin(); it != m_groups.constEnd(); ++it) {
        const QString base = QFileInfo(it.value().exePath).fileName().toLower();
        if (base.isEmpty() || seen.contains(base))
            continue;
        seen.insert(base);
        QVariantMap m;
        m.insert(QStringLiteral("exe"), base);
        m.insert(QStringLiteral("name"), it.value().name);
        out.append(m);
    }
    return out;
}

void WindowTracker::refresh()
{
    QHash<QString, AppGroup> nextGroups;
    QVariantList nextList;

#ifdef Q_OS_WIN
    static int s_cacheSweepTick = 0;
    if (++s_cacheSweepTick >= 60) {
        s_cacheSweepTick = 0;
        pidExeCache().clear();
    }
    EnumContext ctx;
    ctx.selfPid = GetCurrentProcessId();
    ctx.foreground = GetForegroundWindow();
    EnumWindows(enumWindowsProc, reinterpret_cast<LPARAM>(&ctx));

    // Preserve deterministic order by exePath
    QStringList keys = ctx.byExe.keys();
    keys.sort();

    for (const QString& key : keys) {
        const auto& pair = ctx.byExe.value(key);
        AppGroup g;
        g.exePath = pair.first;
        g.exeKey = key;
        g.name = friendlyNameFromExe(g.exePath);

        bool allMin = true;
        quintptr bestHwnd = 0;
        for (HWND h : pair.second) {
            const auto ptr = reinterpret_cast<quintptr>(h);
            g.hwnds.append(ptr);
            if (h == ctx.foreground) {
                g.active = true;
                bestHwnd = ptr;
            }
            if (!IsIconic(h)) {
                allMin = false;
                if (bestHwnd == 0)
                    bestHwnd = ptr;
            }
        }
        if (bestHwnd == 0 && !g.hwnds.isEmpty())
            bestHwnd = g.hwnds.first();
        g.primaryHwnd = bestHwnd;
        g.allMinimized = allMin;

        nextGroups.insert(key, g);

        QVariantMap item;
        item.insert(QStringLiteral("name"), g.name);
        item.insert(QStringLiteral("target"), g.exePath);
        item.insert(QStringLiteral("exeKey"), g.exeKey);
        item.insert(QStringLiteral("count"), g.hwnds.size());
        item.insert(QStringLiteral("active"), g.active);
        item.insert(QStringLiteral("minimized"), g.allMinimized);
        nextList.append(item);
    }
#endif

    m_groups = std::move(nextGroups);
    if (m_runningApps != nextList) {
        m_runningApps = std::move(nextList);
        emit runningAppsChanged();
    }

#ifdef Q_OS_WIN
    bool nextOccluded = false;
    if (ctx.foreground && IsWindow(ctx.foreground) && IsWindowVisible(ctx.foreground) && !IsIconic(ctx.foreground)) {
        DWORD fgPid = 0;
        GetWindowThreadProcessId(ctx.foreground, &fgPid);
        if (fgPid != ctx.selfPid) {
            wchar_t cls[64] = {};
            GetClassNameW(ctx.foreground, cls, 64);
            const QString clsName = QString::fromWCharArray(cls);
            QString nextApp = m_activeAppName;
            QString nextTitle = m_activeWindowTitle;
            if (clsName == QStringLiteral("Progman") || clsName == QStringLiteral("WorkerW")) {
                nextApp = QStringLiteral("Desktop");
                nextTitle.clear();
            } else if (clsName != QStringLiteral("Shell_TrayWnd") && clsName != QStringLiteral("Shell_SecondaryTrayWnd")) {
                const QString exe = queryProcessExe(ctx.foreground);
                nextApp = exe.isEmpty() ? QStringLiteral("Window") : friendlyNameFromExe(exe);
                wchar_t tbuf[256] = {};
                GetWindowTextW(ctx.foreground, tbuf, 256);
                nextTitle = QString::fromWCharArray(tbuf).trimmed();

                const HMONITOR priMon = MonitorFromPoint(POINT{ 0, 0 }, MONITOR_DEFAULTTOPRIMARY);
                if (MonitorFromWindow(ctx.foreground, MONITOR_DEFAULTTONEAREST) == priMon) {
                    if (IsZoomed(ctx.foreground)) {
                        nextOccluded = true;
                    } else {
                        MONITORINFO mi{};
                        mi.cbSize = sizeof(mi);
                        RECT rc{};
                        if (GetMonitorInfoW(priMon, &mi)
                            && (SUCCEEDED(DwmGetWindowAttribute(ctx.foreground, DWMWA_EXTENDED_FRAME_BOUNDS, &rc, sizeof(rc)))
                                || GetWindowRect(ctx.foreground, &rc))) {
                            const int monW = qMax(1, static_cast<int>(mi.rcWork.right - mi.rcWork.left));
                            const int monH = qMax(1, static_cast<int>(mi.rcWork.bottom - mi.rcWork.top));
                            const int winW = qMax(0, static_cast<int>(rc.right - rc.left));
                            const int winH = qMax(0, static_cast<int>(rc.bottom - rc.top));
                            if (winW >= (monW * 95) / 100 && winH >= (monH * 95) / 100)
                                nextOccluded = true;
                        }
                    }
                }
            }
            if (nextApp != m_activeAppName || nextTitle != m_activeWindowTitle) {
                m_activeAppName = nextApp;
                m_activeWindowTitle = nextTitle;
                emit activeWindowChanged();
            }
        }
    } else if (!ctx.foreground) {
        if (m_activeAppName != QStringLiteral("Desktop") || !m_activeWindowTitle.isEmpty()) {
            m_activeAppName = QStringLiteral("Desktop");
            m_activeWindowTitle.clear();
            emit activeWindowChanged();
        }
    }
    if (nextOccluded != m_desktopOccluded) {
        m_desktopOccluded = nextOccluded;
        emit desktopOccludedChanged();
    }
    updateSystemStats();
#endif
}

void WindowTracker::updateSystemStats()
{
#ifdef Q_OS_WIN
    int nextCpu = m_cpuUsage;
    FILETIME idleFt{}, kernelFt{}, userFt{};
    if (GetSystemTimes(&idleFt, &kernelFt, &userFt)) {
        const auto toU64 = [](const FILETIME& ft) -> quint64 {
            return (static_cast<quint64>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        };
        const quint64 idle = toU64(idleFt);
        const quint64 total = toU64(kernelFt) + toU64(userFt);
        m_cpuSamples.append(CpuSample{ idle, total });
        if (m_cpuSamples.size() > 7)
            m_cpuSamples.removeFirst();

        if (m_cpuSamples.size() >= 2) {
            const CpuSample& oldest = m_cpuSamples.first();
            const CpuSample& newest = m_cpuSamples.last();
            if (newest.total > oldest.total && newest.idle >= oldest.idle) {
                const quint64 totalDiff = newest.total - oldest.total;
                const quint64 idleDiff = newest.idle - oldest.idle;
                if (idleDiff <= totalDiff) {
                    const double rawWindowPct =
                        (static_cast<double>(totalDiff - idleDiff) * 100.0) / static_cast<double>(totalDiff);
                    if (m_cpuEma < 0.0) {
                        m_cpuEma = rawWindowPct;
                        nextCpu = qBound(0, qRound(m_cpuEma), 100);
                    } else {
                        m_cpuEma = 0.25 * rawWindowPct + 0.75 * m_cpuEma;
                        if ((m_cpuTick % 2) == 0)
                            nextCpu = qBound(0, qRound(m_cpuEma), 100);
                    }
                }
            }
        }
        ++m_cpuTick;
    }

    int nextRam = m_ramUsage;
    QString nextRamDetail = m_ramDetailText;
    MEMORYSTATUSEX ms{};
    ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) {
        nextRam = static_cast<int>(ms.dwMemoryLoad);
        const double totalGb = static_cast<double>(ms.ullTotalPhys) / (1024.0 * 1024.0 * 1024.0);
        const double usedGb = static_cast<double>(ms.ullTotalPhys - ms.ullAvailPhys) / (1024.0 * 1024.0 * 1024.0);
        nextRamDetail = QStringLiteral("%1 / %2 GB")
            .arg(QString::number(usedGb, 'f', 1))
            .arg(QString::number(totalGb, 'f', 1));
    }

    static auto queryCpuTempC = []() -> int {
        // Priority 1: WinRing0 / R0Temperature kernel driver (exact Intel CPU Package/Core DTS MSR)
        static bool s_r0Tried = false;
        static HANDLE s_r0Handle = INVALID_HANDLE_VALUE;
        if (!s_r0Tried) {
            s_r0Tried = true;
            s_r0Handle = CreateFileW(L"\\\\.\\WinRing0_1_2_0",
                                     GENERIC_READ | GENERIC_WRITE,
                                     0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        }
        if (s_r0Handle != INVALID_HANDLE_VALUE) {
            constexpr DWORD IOCTL_OLS_READ_MSR = 0x9C402084;
            DWORD msrAddr = 0x1A2; // MSR_TEMPERATURE_TARGET
            quint64 val = 0;
            DWORD bytesRet = 0;
            int tjMax = 100;
            if (DeviceIoControl(s_r0Handle, IOCTL_OLS_READ_MSR, &msrAddr, sizeof(msrAddr),
                                &val, sizeof(val), &bytesRet, nullptr)) {
                const int t = static_cast<int>((val >> 16) & 0xFF);
                if (t > 50 && t < 130)
                    tjMax = t;
            }
            msrAddr = 0x1B1; // IA32_PACKAGE_THERM_STATUS
            if (DeviceIoControl(s_r0Handle, IOCTL_OLS_READ_MSR, &msrAddr, sizeof(msrAddr),
                                &val, sizeof(val), &bytesRet, nullptr) && (val & 0x80000000ULL)) {
                const int dts = static_cast<int>((val >> 16) & 0x7F);
                const int temp = tjMax - dts;
                if (temp >= 0 && temp <= 125)
                    return temp;
            }
            msrAddr = 0x19C; // IA32_THERM_STATUS (Core 0)
            if (DeviceIoControl(s_r0Handle, IOCTL_OLS_READ_MSR, &msrAddr, sizeof(msrAddr),
                                &val, sizeof(val), &bytesRet, nullptr) && (val & 0x80000000ULL)) {
                const int dts = static_cast<int>((val >> 16) & 0x7F);
                const int temp = tjMax - dts;
                if (temp >= 0 && temp <= 125)
                    return temp;
            }
        }

        // Priority 2: Windows PDH ACPI Thermal Zone (non-admin fallback)
        using FnOpenQuery = PDH_STATUS(WINAPI*)(LPCWSTR, DWORD_PTR, PDH_HQUERY*);
        using FnAddCounter = PDH_STATUS(WINAPI*)(PDH_HQUERY, LPCWSTR, DWORD_PTR, PDH_HCOUNTER*);
        using FnCollect = PDH_STATUS(WINAPI*)(PDH_HQUERY);
        using FnGetArray = PDH_STATUS(WINAPI*)(PDH_HCOUNTER, DWORD, LPDWORD, LPDWORD, PPDH_FMT_COUNTERVALUE_ITEM_W);

        static bool s_inited = false;
        static PDH_HQUERY s_query = nullptr;
        static PDH_HCOUNTER s_counter = nullptr;
        static FnCollect s_collect = nullptr;
        static FnGetArray s_getArray = nullptr;

        if (!s_inited) {
            s_inited = true;
            HMODULE mod = LoadLibraryW(L"pdh.dll");
            if (mod) {
                auto pOpen = reinterpret_cast<FnOpenQuery>(GetProcAddress(mod, "PdhOpenQueryW"));
                auto pAdd = reinterpret_cast<FnAddCounter>(GetProcAddress(mod, "PdhAddEnglishCounterW"));
                s_collect = reinterpret_cast<FnCollect>(GetProcAddress(mod, "PdhCollectQueryData"));
                s_getArray = reinterpret_cast<FnGetArray>(GetProcAddress(mod, "PdhGetFormattedCounterArrayW"));
                if (pOpen && pAdd && s_collect && s_getArray) {
                    if (pOpen(nullptr, 0, &s_query) == ERROR_SUCCESS) {
                        if (pAdd(s_query, L"\\Thermal Zone Information(*)\\High Precision Temperature", 0, &s_counter) == ERROR_SUCCESS) {
                            s_collect(s_query);
                        } else {
                            s_counter = nullptr;
                        }
                    }
                }
            }
        }
        if (!s_query || !s_counter || !s_collect || !s_getArray)
            return -1;
        if (s_collect(s_query) != ERROR_SUCCESS)
            return -1;

        DWORD bufSize = 0, itemCount = 0;
        s_getArray(s_counter, PDH_FMT_DOUBLE, &bufSize, &itemCount, nullptr);
        if (bufSize == 0)
            return -1;
        QByteArray buf(static_cast<int>(bufSize), '\0');
        auto* items = reinterpret_cast<PPDH_FMT_COUNTERVALUE_ITEM_W>(buf.data());
        if (s_getArray(s_counter, PDH_FMT_DOUBLE, &bufSize, &itemCount, items) != ERROR_SUCCESS)
            return -1;

        int maxC = -1;
        double maxRaw = -1.0;
        for (DWORD i = 0; i < itemCount; ++i) {
            if (items[i].FmtValue.CStatus != ERROR_SUCCESS)
                continue;
            const double raw = items[i].FmtValue.doubleValue;
            double celsius = -1.0;
            if (raw > 2000.0 && raw < 4500.0)
                celsius = (raw / 10.0) - 273.15;
            else if (raw > 200.0 && raw < 450.0)
                celsius = raw - 273.15;
            if (celsius >= 0.0 && celsius <= 125.0) {
                const int c = qRound(celsius);
                if (c > maxC) {
                    maxC = c;
                    maxRaw = raw;
                }
            }
        }
        static double s_lastAcpiRaw = -1.0;
        static bool s_acpiDynamic = false;
        if (maxC >= 0) {
            if (s_lastAcpiRaw >= 0.0 && qAbs(maxRaw - s_lastAcpiRaw) > 0.05)
                s_acpiDynamic = true;
            s_lastAcpiRaw = maxRaw;
            if (!s_acpiDynamic && maxC <= 32)
                return -1; // Suppress static BIOS ACPI stub (e.g. constant 28-30C TZ00/TZ01)
        }
        return maxC;
    };

    static auto queryGpuTempC = []() -> int {
        using FnNvmlInit = int(*)();
        using FnNvmlHandle = int(*)(unsigned int, void**);
        using FnNvmlTemp = int(*)(void*, unsigned int, unsigned int*);
        static bool s_inited = false;
        static void* s_dev = nullptr;
        static FnNvmlTemp s_getTemp = nullptr;

        if (!s_inited) {
            s_inited = true;
            HMODULE mod = LoadLibraryW(L"nvml.dll");
            if (!mod)
                mod = LoadLibraryW(L"C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvml.dll");
            if (mod) {
                auto pInit = reinterpret_cast<FnNvmlInit>(GetProcAddress(mod, "nvmlInit_v2"));
                if (!pInit)
                    pInit = reinterpret_cast<FnNvmlInit>(GetProcAddress(mod, "nvmlInit"));
                auto pHandle = reinterpret_cast<FnNvmlHandle>(GetProcAddress(mod, "nvmlDeviceGetHandleByIndex_v2"));
                if (!pHandle)
                    pHandle = reinterpret_cast<FnNvmlHandle>(GetProcAddress(mod, "nvmlDeviceGetHandleByIndex"));
                s_getTemp = reinterpret_cast<FnNvmlTemp>(GetProcAddress(mod, "nvmlDeviceGetTemperature"));
                if (pInit && pHandle && s_getTemp && pInit() == 0) {
                    if (pHandle(0, &s_dev) != 0)
                        s_dev = nullptr;
                }
            }
        }
        if (!s_dev || !s_getTemp)
            return -1;
        unsigned int temp = 0;
        if (s_getTemp(s_dev, 0, &temp) == 0)
            return static_cast<int>(temp);
        return -1;
    };

    static int s_tempTick = 0;
    static double s_cpuEma = -1.0;
    static double s_gpuEma = -1.0;
    int nextCpuTemp = m_cpuTemp;
    int nextGpuTemp = m_gpuTemp;

    if (s_tempTick == 0 || (s_tempTick % 3) == 0) {
        const int rawCpu = queryCpuTempC();
        if (rawCpu >= 0) {
            s_cpuEma = (s_cpuEma < 0.0) ? static_cast<double>(rawCpu) : (0.35 * rawCpu + 0.65 * s_cpuEma);
            nextCpuTemp = qRound(s_cpuEma);
        }
        const int rawGpu = queryGpuTempC();
        if (rawGpu >= 0) {
            s_gpuEma = (s_gpuEma < 0.0) ? static_cast<double>(rawGpu) : (0.40 * rawGpu + 0.60 * s_gpuEma);
            nextGpuTemp = qRound(s_gpuEma);
        }
    }
    ++s_tempTick;

    // System uptime from GetTickCount64()
    const quint64 totalMins = GetTickCount64() / 60000ULL;
    const quint64 days = totalMins / (60ULL * 24ULL);
    const quint64 hrs = (totalMins / 60ULL) % 24ULL;
    const quint64 mins = totalMins % 60ULL;
    QString nextUptime;
    if (days > 0)
        nextUptime = QStringLiteral("%1d %2h").arg(days).arg(hrs);
    else if (hrs > 0)
        nextUptime = QStringLiteral("%1h %2m").arg(hrs).arg(mins);
    else
        nextUptime = QStringLiteral("%1m").arg(mins);

    double nextDownBps = m_downloadBps;
    double nextUpBps = m_uploadBps;
    const qint64 nowNetMs = QDateTime::currentMSecsSinceEpoch();
    if (m_prevNetMs == 0 || (nowNetMs - m_prevNetMs) >= 700) {
        PMIB_IF_TABLE2 table = nullptr;
        if (GetIfTable2(&table) == NO_ERROR && table) {
            quint64 rxTotal = 0;
            quint64 txTotal = 0;
            for (ULONG i = 0; i < table->NumEntries; ++i) {
                const MIB_IF_ROW2& row = table->Table[i];
                if (row.OperStatus != IfOperStatusUp)
                    continue;
                if (row.Type == IF_TYPE_SOFTWARE_LOOPBACK || row.Type == IF_TYPE_TUNNEL)
                    continue;
                if (row.InterfaceAndOperStatusFlags.HardwareInterface ||
                    row.Type == IF_TYPE_ETHERNET_CSMACD ||
                    row.Type == IF_TYPE_IEEE80211) {
                    rxTotal += row.InOctets;
                    txTotal += row.OutOctets;
                }
            }
            FreeMibTable(table);

            if (m_prevNetMs > 0 && nowNetMs > m_prevNetMs &&
                rxTotal >= m_prevRxBytes && txTotal >= m_prevTxBytes) {
                const double dt = static_cast<double>(nowNetMs - m_prevNetMs) / 1000.0;
                const double rawDown = static_cast<double>(rxTotal - m_prevRxBytes) / dt;
                const double rawUp = static_cast<double>(txTotal - m_prevTxBytes) / dt;
                nextDownBps = (rawDown < 10.0 && m_downloadBps < 50.0)
                    ? rawDown
                    : (0.45 * rawDown + 0.55 * m_downloadBps);
                nextUpBps = (rawUp < 10.0 && m_uploadBps < 50.0)
                    ? rawUp
                    : (0.45 * rawUp + 0.55 * m_uploadBps);
            }
            m_prevRxBytes = rxTotal;
            m_prevTxBytes = txTotal;
            m_prevNetMs = nowNetMs;
        }
    }

    bool nextHasBattery = m_hasBattery;
    int nextBatteryPct = m_batteryPercent;
    bool nextBatteryCharging = m_batteryCharging;
    QString nextBatteryTime = m_batteryTimeText;
    SYSTEM_POWER_STATUS sps{};
    if (GetSystemPowerStatus(&sps)) {
        const bool present = ((sps.BatteryFlag & 128) == 0)
            && (sps.BatteryFlag != 255)
            && (sps.BatteryLifePercent <= 100);
        nextHasBattery = present;
        if (present) {
            nextBatteryPct = qBound(0, static_cast<int>(sps.BatteryLifePercent), 100);
            nextBatteryCharging = (sps.ACLineStatus == 1) || ((sps.BatteryFlag & 8) != 0);
            if (nextBatteryCharging) {
                nextBatteryTime = (nextBatteryPct >= 99)
                    ? QStringLiteral("Fully Charged")
                    : QStringLiteral("Plugged in (Charging)");
            } else if (sps.BatteryLifeTime != 0xFFFFFFFF && sps.BatteryLifeTime > 0) {
                const int mins = static_cast<int>(sps.BatteryLifeTime / 60);
                const int h = mins / 60;
                const int m = mins % 60;
                nextBatteryTime = h > 0
                    ? QStringLiteral("%1h %2m remaining").arg(h).arg(m)
                    : QStringLiteral("%1m remaining").arg(qMax(1, m));
            } else {
                nextBatteryTime = QStringLiteral("On Battery");
            }
        } else {
            nextBatteryPct = 100;
            nextBatteryCharging = false;
            nextBatteryTime.clear();
        }
    }

    const QString fakeBatt = qEnvironmentVariable("SEKAIDESK_FAKE_BATTERY").trimmed();
    if (!fakeBatt.isEmpty()) {
        const QStringList parts = fakeBatt.split(QLatin1Char(','));
        bool ok = false;
        const int pct = parts.value(0).trimmed().toInt(&ok);
        if (ok) {
            nextHasBattery = true;
            nextBatteryPct = qBound(0, pct, 100);
            const QString mode = parts.value(1).trimmed().toLower();
            nextBatteryCharging = (mode == QStringLiteral("charging") || mode == QStringLiteral("ac") || mode == QStringLiteral("1"));
            nextBatteryTime = nextBatteryCharging
                ? QStringLiteral("Plugged in (Simulated)")
                : QStringLiteral("Simulated Battery");
        }
    }

    bool historyUpdated = false;
    ++m_historyTick;
    if (m_cpuHistory.isEmpty() || (m_historyTick % 3) == 0) {
        m_cpuHistory.append(nextCpu);
        if (m_cpuHistory.size() > 30)
            m_cpuHistory.removeFirst();
        m_ramHistory.append(nextRam);
        if (m_ramHistory.size() > 30)
            m_ramHistory.removeFirst();
        historyUpdated = true;
    }

    if (historyUpdated
        || nextCpu != m_cpuUsage || nextRam != m_ramUsage
        || nextRamDetail != m_ramDetailText
        || nextCpuTemp != m_cpuTemp || nextGpuTemp != m_gpuTemp
        || nextUptime != m_uptimeText
        || nextHasBattery != m_hasBattery
        || nextBatteryPct != m_batteryPercent
        || nextBatteryCharging != m_batteryCharging
        || nextBatteryTime != m_batteryTimeText
        || qRound(nextDownBps) != qRound(m_downloadBps)
        || qRound(nextUpBps) != qRound(m_uploadBps)) {
        m_cpuUsage = nextCpu;
        m_ramUsage = nextRam;
        m_ramDetailText = nextRamDetail;
        m_cpuTemp = nextCpuTemp;
        m_gpuTemp = nextGpuTemp;
        m_uptimeText = nextUptime;
        m_hasBattery = nextHasBattery;
        m_batteryPercent = nextBatteryPct;
        m_batteryCharging = nextBatteryCharging;
        m_batteryTimeText = nextBatteryTime;
        m_downloadBps = nextDownBps;
        m_uploadBps = nextUpBps;
        emit statsChanged();
    }

    if (m_batteryAlertArmed) {
        if (!m_hasBattery || m_batteryCharging || m_batteryPercent > 25) {
            m_lowBatteryAlertTier = 0;
        } else if (m_batteryPercent <= 10 && m_lowBatteryAlertTier < 2) {
            m_lowBatteryAlertTier = 2;
            emit lowBatteryAlert(m_batteryPercent, true);
        } else if (m_batteryPercent <= 20 && m_lowBatteryAlertTier < 1) {
            m_lowBatteryAlertTier = 1;
            emit lowBatteryAlert(m_batteryPercent, false);
        }
    }
#endif
}

void WindowTracker::pollEdgeAndOverlap()
{
#ifdef Q_OS_WIN
    const HMONITOR mon = MonitorFromPoint(POINT{ 0, 0 }, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi))
        return;

    using FnGetDpiForMonitor = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
    static FnGetDpiForMonitor fnGetDpiForMonitor = []() -> FnGetDpiForMonitor {
        if (HMODULE mod = LoadLibraryW(L"shcore.dll"))
            return reinterpret_cast<FnGetDpiForMonitor>(GetProcAddress(mod, "GetDpiForMonitor"));
        return nullptr;
    }();
    double dpr = 1.0;
    bool gotDpi = false;
    if (fnGetDpiForMonitor) {
        UINT dpiX = 96, dpiY = 96;
        if (SUCCEEDED(fnGetDpiForMonitor(mon, 0 /*MDT_EFFECTIVE_DPI*/, &dpiX, &dpiY)) && dpiX > 0) {
            dpr = qMax(1.0, static_cast<double>(dpiX) / 96.0);
            gotDpi = true;
        }
    }
    if (!gotDpi) {
        if (QScreen* scr = QGuiApplication::primaryScreen())
            dpr = qMax(1.0, scr->devicePixelRatio());
    }

    POINT pt{};
    bool nextBottomEdge = m_bottomEdgeHovered;
    bool nextTopEdge = m_topEdgeHovered;
    bool nextLeftEdge = m_leftEdgeHovered;
    bool nextRightEdge = m_rightEdgeHovered;
    if (GetCursorPos(&pt)) {
        const bool inX = (pt.x >= mi.rcMonitor.left && pt.x <= mi.rcMonitor.right);
        const bool inY = (pt.y >= mi.rcMonitor.top && pt.y <= mi.rcMonitor.bottom);

        const int botTriggerY = m_bottomEdgeHovered
            ? (mi.rcMonitor.bottom - qRound(136 * dpr))
            : (mi.rcMonitor.bottom - qMax(4, qRound(10 * dpr)));
        nextBottomEdge = inX && (pt.y >= botTriggerY) && (pt.y <= mi.rcMonitor.bottom);

        const int topTriggerY = m_topEdgeHovered
            ? (mi.rcMonitor.top + qRound(136 * dpr))
            : (mi.rcMonitor.top + qMax(3, qRound(6 * dpr)));
        const bool avoidWindowControls = !m_topEdgeHovered && (pt.x >= mi.rcMonitor.right - qRound(150 * dpr));
        nextTopEdge = inX && !avoidWindowControls && (pt.y >= mi.rcMonitor.top) && (pt.y <= topTriggerY);

        const int leftTriggerX = m_leftEdgeHovered
            ? (mi.rcMonitor.left + qRound(136 * dpr))
            : (mi.rcMonitor.left + qMax(6, qRound(14 * dpr)));
        nextLeftEdge = inY && (pt.x >= mi.rcMonitor.left) && (pt.x <= leftTriggerX);

        const int rightTriggerX = m_rightEdgeHovered
            ? (mi.rcMonitor.right - qRound(136 * dpr))
            : (mi.rcMonitor.right - qMax(6, qRound(14 * dpr)));
        const bool avoidTopRightClose = !m_rightEdgeHovered && (pt.y <= mi.rcMonitor.top + qRound(42 * dpr));
        nextRightEdge = inY && !avoidTopRightClose && (pt.x >= rightTriggerX) && (pt.x <= mi.rcMonitor.right);
    }
    if (nextBottomEdge != m_bottomEdgeHovered) {
        m_bottomEdgeHovered = nextBottomEdge;
        emit bottomEdgeHoveredChanged();
    }
    if (nextTopEdge != m_topEdgeHovered) {
        m_topEdgeHovered = nextTopEdge;
        emit topEdgeHoveredChanged();
    }
    if (nextLeftEdge != m_leftEdgeHovered) {
        m_leftEdgeHovered = nextLeftEdge;
        emit leftEdgeHoveredChanged();
    }
    if (nextRightEdge != m_rightEdgeHovered) {
        m_rightEdgeHovered = nextRightEdge;
        emit rightEdgeHoveredChanged();
    }

    // Throttle expensive EnumWindows + DwmGetWindowAttribute overlap scan to ~320ms
    const bool runOverlapNow = ((m_overlapSubTick++ % 4) == 0);
    if (!runOverlapNow)
        return;

    struct OverlapCtx {
        DWORD selfPid = 0;
        HMONITOR mon = nullptr;
        RECT rcMon{};
        int dockBandPx = 92;
        int topBandPx = 52;
        int sideBandPx = 92;
        bool dockOverlap = false;
        bool topOverlap = false;
        bool leftOverlap = false;
        bool rightOverlap = false;
    } ctx;
    ctx.selfPid = GetCurrentProcessId();
    ctx.mon = mon;
    ctx.rcMon = mi.rcMonitor;
    ctx.dockBandPx = qRound(92 * dpr);
    ctx.topBandPx = qRound(52 * dpr);
    ctx.sideBandPx = qRound(92 * dpr);

    EnumWindows([](HWND h, LPARAM lParam) -> BOOL {
        auto* c = reinterpret_cast<OverlapCtx*>(lParam);
        if (!IsWindowVisible(h) || IsIconic(h))
            return TRUE;

        DWORD pid = 0;
        GetWindowThreadProcessId(h, &pid);
        if (pid == 0 || pid == c->selfPid)
            return TRUE;

        const LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_APPWINDOW) == 0)
            return TRUE;

        if (GetWindow(h, GW_OWNER) != nullptr && (ex & WS_EX_APPWINDOW) == 0)
            return TRUE;

        BOOL cloaked = FALSE;
        if (SUCCEEDED(DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked)
            return TRUE;

        wchar_t cls[64] = {};
        if (GetClassNameW(h, cls, 64) > 0) {
            if (wcscmp(cls, L"Progman") == 0
                || wcscmp(cls, L"WorkerW") == 0
                || wcscmp(cls, L"Shell_TrayWnd") == 0
                || wcscmp(cls, L"Shell_SecondaryTrayWnd") == 0
                || wcscmp(cls, L"Windows.UI.Core.CoreWindow") == 0
                || wcscmp(cls, L"SHELLDLL_DefView") == 0
                || wcscmp(cls, L"NotifyIconOverflowWindow") == 0
                || wcscmp(cls, L"TaskListThumbnailWnd") == 0
                || wcscmp(cls, L"MultitaskingViewFrame") == 0) {
                return TRUE;
            }
        }

        const bool zoomed = (IsZoomed(h) != FALSE);
        if (GetWindowTextLengthW(h) <= 0 && !zoomed)
            return TRUE;

        if (MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST) != c->mon)
            return TRUE;

        RECT rc{};
        if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &rc, sizeof(rc)))) {
            if (!GetWindowRect(h, &rc))
                return TRUE;
        }
        if ((rc.right - rc.left) <= 0 || (rc.bottom - rc.top) <= 0)
            return TRUE;

        const bool inScreenX = (rc.right > c->rcMon.left) && (rc.left < c->rcMon.right);
        const bool inScreenY = (rc.bottom > c->rcMon.top) && (rc.top < c->rcMon.bottom);

        if (inScreenX) {
            if (zoomed || (rc.top < c->rcMon.bottom && rc.bottom >= c->rcMon.bottom - c->dockBandPx))
                c->dockOverlap = true;
            if (zoomed || (rc.bottom > c->rcMon.top && rc.top <= c->rcMon.top + c->topBandPx))
                c->topOverlap = true;
        }
        if (inScreenY) {
            if (zoomed || (rc.right > c->rcMon.left && rc.left <= c->rcMon.left + c->sideBandPx))
                c->leftOverlap = true;
            if (zoomed || (rc.left < c->rcMon.right && rc.right >= c->rcMon.right - c->sideBandPx))
                c->rightOverlap = true;
        }

        return (c->dockOverlap && c->topOverlap && c->leftOverlap && c->rightOverlap) ? FALSE : TRUE;
    }, reinterpret_cast<LPARAM>(&ctx));

    if (ctx.dockOverlap != m_dockOverlap) {
        m_dockOverlap = ctx.dockOverlap;
        emit dockOverlapChanged();
    }
    if (ctx.topOverlap != m_topOverlap) {
        m_topOverlap = ctx.topOverlap;
        emit topOverlapChanged();
    }
    if (ctx.leftOverlap != m_leftOverlap) {
        m_leftOverlap = ctx.leftOverlap;
        emit leftOverlapChanged();
    }
    if (ctx.rightOverlap != m_rightOverlap) {
        m_rightOverlap = ctx.rightOverlap;
        emit rightOverlapChanged();
    }
#endif
}

QVariantMap WindowTracker::stateForTarget(const QString& target) const
{
    const QString key = normalizeExeKey(target);
    QVariantMap m;
    if (!m_groups.contains(key)) {
        m.insert(QStringLiteral("running"), false);
        m.insert(QStringLiteral("count"), 0);
        m.insert(QStringLiteral("active"), false);
        m.insert(QStringLiteral("minimized"), false);
        return m;
    }
    const AppGroup& g = m_groups.value(key);
    m.insert(QStringLiteral("running"), true);
    m.insert(QStringLiteral("count"), g.hwnds.size());
    m.insert(QStringLiteral("active"), g.active);
    m.insert(QStringLiteral("minimized"), g.allMinimized);
    return m;
}

bool WindowTracker::activateOrToggle(const QString& target)
{
#ifdef Q_OS_WIN
    const QString key = normalizeExeKey(target);
    if (!m_groups.contains(key))
        return false;

    const AppGroup& g = m_groups.value(key);
    HWND hwnd = reinterpret_cast<HWND>(g.primaryHwnd);
    if (!hwnd || !IsWindow(hwnd))
        return false;

    if (g.active && !IsIconic(hwnd)) {
        ShowWindow(hwnd, SW_MINIMIZE);
    } else {
        if (IsIconic(hwnd))
            ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
    }
    refresh();
    return true;
#else
    Q_UNUSED(target);
    return false;
#endif
}

QVariantList WindowTracker::windowsForTarget(const QString& target) const
{
    QVariantList out;
#ifdef Q_OS_WIN
    const QString key = normalizeExeKey(target);
    if (!m_groups.contains(key))
        return out;

    const HWND fg = GetForegroundWindow();
    const AppGroup& g = m_groups.value(key);
    for (quintptr raw : g.hwnds) {
        HWND h = reinterpret_cast<HWND>(raw);
        if (!IsWindow(h))
            continue;
        wchar_t titleBuf[256] = {};
        GetWindowTextW(h, titleBuf, 256);
        QVariantMap m;
        m.insert(QStringLiteral("hwnd"), static_cast<qulonglong>(raw));
        m.insert(QStringLiteral("title"), QString::fromWCharArray(titleBuf));
        m.insert(QStringLiteral("active"), h == fg);
        m.insert(QStringLiteral("minimized"), static_cast<bool>(IsIconic(h)));
        out.append(m);
    }
#else
    Q_UNUSED(target);
#endif
    return out;
}

bool WindowTracker::activateHwnd(qulonglong hwnd)
{
#ifdef Q_OS_WIN
    HWND h = reinterpret_cast<HWND>(static_cast<quintptr>(hwnd));
    if (!h || !IsWindow(h))
        return false;
    if (IsIconic(h))
        ShowWindow(h, SW_RESTORE);
    SetForegroundWindow(h);
    refresh();
    return true;
#else
    Q_UNUSED(hwnd);
    return false;
#endif
}

bool WindowTracker::minimizeHwnd(qulonglong hwnd)
{
#ifdef Q_OS_WIN
    HWND h = reinterpret_cast<HWND>(static_cast<quintptr>(hwnd));
    if (!h || !IsWindow(h))
        return false;
    ShowWindow(h, SW_MINIMIZE);
    refresh();
    return true;
#else
    Q_UNUSED(hwnd);
    return false;
#endif
}

bool WindowTracker::closeHwnd(qulonglong hwnd)
{
#ifdef Q_OS_WIN
    HWND h = reinterpret_cast<HWND>(static_cast<quintptr>(hwnd));
    if (!h || !IsWindow(h))
        return false;
    PostMessageW(h, WM_CLOSE, 0, 0);
    QTimer::singleShot(150, this, &WindowTracker::refresh);
    return true;
#else
    Q_UNUSED(hwnd);
    return false;
#endif
}

bool WindowTracker::openSpecialFolder(const QString& kind)
{
#ifdef Q_OS_WIN
    const QString home = qEnvironmentVariable("USERPROFILE");
    QString target = home;
    if (kind == QStringLiteral("downloads"))
        target = home + QStringLiteral("\\Downloads");
    else if (kind == QStringLiteral("desktop"))
        target = home + QStringLiteral("\\Desktop");
    else if (kind == QStringLiteral("documents"))
        target = home + QStringLiteral("\\Documents");
    else if (kind == QStringLiteral("pictures"))
        target = home + QStringLiteral("\\Pictures");
    else if (kind == QStringLiteral("recyclebin"))
        target = QStringLiteral("shell:RecycleBinFolder");

    if (target.isEmpty())
        return false;
    ShellExecuteW(nullptr, L"open", reinterpret_cast<const wchar_t*>(target.utf16()),
                  nullptr, nullptr, SW_SHOWNORMAL);
    return true;
#else
    Q_UNUSED(kind);
    return false;
#endif
}

void WindowTracker::lockWorkstation()
{
#ifdef Q_OS_WIN
    LockWorkStation();
#endif
}

void WindowTracker::sleepComputer()
{
#ifdef Q_OS_WIN
    ShellExecuteW(nullptr, L"open", L"rundll32.exe",
                  L"powrprof.dll,SetSuspendState 0,1,0", nullptr, SW_HIDE);
#endif
}

void WindowTracker::takeScreenshot()
{
#ifdef Q_OS_WIN
    ShellExecuteW(nullptr, L"open", L"ms-screenclip:", nullptr, nullptr, SW_SHOWNORMAL);
#endif
}

QString WindowTracker::resolveFolderPath(const QString& kindOrPath) const
{
    const QString raw = kindOrPath.trimmed();
    const QString low = raw.toLower();
    if (low.isEmpty() || low == QStringLiteral("downloads")) {
        QString p = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
        if (p.isEmpty())
            p = QDir::homePath() + QStringLiteral("/Downloads");
        return QDir::cleanPath(p);
    }
    if (low == QStringLiteral("desktop")) {
        QString p = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
        if (p.isEmpty())
            p = QDir::homePath() + QStringLiteral("/Desktop");
        return QDir::cleanPath(p);
    }
    if (low == QStringLiteral("documents")) {
        QString p = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
        if (p.isEmpty())
            p = QDir::homePath() + QStringLiteral("/Documents");
        return QDir::cleanPath(p);
    }
    if (low == QStringLiteral("pictures")) {
        QString p = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
        if (p.isEmpty())
            p = QDir::homePath() + QStringLiteral("/Pictures");
        return QDir::cleanPath(p);
    }
    return QDir::cleanPath(QDir::fromNativeSeparators(raw));
}

QVariantList WindowTracker::listFolderFiles(const QString& kindOrPath, int maxItems) const
{
    QVariantList out;
    const QString folder = resolveFolderPath(kindOrPath);
    if (folder.isEmpty() || !QFileInfo::exists(folder))
        return out;

    const QDir dir(folder);
    QFileInfoList entries = dir.entryInfoList(
        QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot | QDir::Readable,
        QDir::DirsFirst | QDir::Time);

    auto formatSize = [](qint64 bytes) -> QString {
        if (bytes < 1024)
            return QStringLiteral("%1 B").arg(bytes);
        if (bytes < 1024 * 1024)
            return QStringLiteral("%1 KB").arg(qMax<qint64>(1, bytes / 1024));
        if (bytes < 1024LL * 1024LL * 1024LL)
            return QStringLiteral("%1 MB").arg(QString::number(static_cast<double>(bytes) / (1024.0 * 1024.0), 'f', 1));
        return QStringLiteral("%1 GB").arg(QString::number(static_cast<double>(bytes) / (1024.0 * 1024.0 * 1024.0), 'f', 2));
    };

    const int cap = qBound(1, maxItems, 120);
    for (const QFileInfo& fi : entries) {
        if (out.size() >= cap)
            break;
        const bool isDir = fi.isDir();
        const QString ext = fi.suffix().toLower();
        const bool isImg = !isDir && (ext == QStringLiteral("png") || ext == QStringLiteral("jpg")
            || ext == QStringLiteral("jpeg") || ext == QStringLiteral("webp")
            || ext == QStringLiteral("bmp") || ext == QStringLiteral("gif"));
        const QString cleanPath = QDir::cleanPath(fi.absoluteFilePath());
        QVariantMap item;
        item.insert(QStringLiteral("name"), fi.fileName());
        item.insert(QStringLiteral("path"), cleanPath);
        item.insert(QStringLiteral("fileUrl"), QUrl::fromLocalFile(cleanPath).toString());
        item.insert(QStringLiteral("isDir"), isDir);
        item.insert(QStringLiteral("ext"), isDir ? QStringLiteral("DIR") : (ext.isEmpty() ? QStringLiteral("FILE") : ext.toUpper()));
        item.insert(QStringLiteral("isImage"), isImg);
        item.insert(QStringLiteral("sizeText"), isDir ? QStringLiteral("Folder") : formatSize(fi.size()));
        item.insert(QStringLiteral("modifiedText"), fi.lastModified().toString(QStringLiteral("MM/dd HH:mm")));
        out.append(item);
    }
    return out;
}

bool WindowTracker::openPath(const QString& path) const
{
#ifdef Q_OS_WIN
    QString clean = path.trimmed();
    if (clean.startsWith(QStringLiteral("file://"), Qt::CaseInsensitive)) {
        const QUrl u(clean);
        if (u.isLocalFile())
            clean = u.toLocalFile();
    }
    clean = QDir::toNativeSeparators(clean);
    if (clean.isEmpty())
        return false;
    const HINSTANCE res = ShellExecuteW(
        nullptr, L"open", reinterpret_cast<const wchar_t*>(clean.utf16()),
        nullptr, nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<qintptr>(res) > 32;
#else
    Q_UNUSED(path);
    return false;
#endif
}

void WindowTracker::openTaskManager() const
{
#ifdef Q_OS_WIN
    ShellExecuteW(nullptr, L"open", L"taskmgr.exe", nullptr, nullptr, SW_SHOWNORMAL);
#endif
}

QVariantList WindowTracker::topProcesses(int limit) const
{
    QVariantList out;
#ifdef Q_OS_WIN
    const int cap = qBound(1, limit, 16);
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return out;

    struct ProcAgg {
        QString name;
        quint64 bytes = 0;
        int instances = 0;
        DWORD samplePid = 0;
    };
    QHash<QString, ProcAgg> agg;

    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            if (pe.th32ProcessID <= 4)
                continue;
            HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, FALSE, pe.th32ProcessID);
            if (!proc)
                proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
            if (!proc)
                continue;
            PROCESS_MEMORY_COUNTERS pmc{};
            pmc.cb = sizeof(pmc);
            if (GetProcessMemoryInfo(proc, &pmc, sizeof(pmc))) {
                const QString rawName = QString::fromWCharArray(pe.szExeFile);
                const QString key = rawName.toLower();
                ProcAgg& entry = agg[key];
                if (entry.name.isEmpty()) {
                    entry.name = rawName;
                    entry.samplePid = pe.th32ProcessID;
                }
                entry.bytes += static_cast<quint64>(pmc.WorkingSetSize);
                entry.instances += 1;
            }
            CloseHandle(proc);
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);

    QList<ProcAgg> list = agg.values();
    std::sort(list.begin(), list.end(), [](const ProcAgg& a, const ProcAgg& b) {
        return a.bytes > b.bytes;
    });

    for (int i = 0; i < list.size() && i < cap; ++i) {
        const ProcAgg& p = list.at(i);
        const double mb = static_cast<double>(p.bytes) / (1024.0 * 1024.0);
        QString disp = p.name;
        if (disp.endsWith(QStringLiteral(".exe"), Qt::CaseInsensitive))
            disp.chop(4);
        QVariantMap m;
        m.insert(QStringLiteral("name"), disp);
        m.insert(QStringLiteral("instances"), p.instances);
        m.insert(QStringLiteral("pid"), static_cast<qulonglong>(p.samplePid));
        m.insert(QStringLiteral("ramMb"), qRound(mb));
        out.append(m);
    }
#else
    Q_UNUSED(limit);
#endif
    return out;
}
