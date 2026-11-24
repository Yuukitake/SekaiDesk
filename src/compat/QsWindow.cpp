#include "QsWindow.h"
#include "services/TaskbarManager.h"

#include <QCoreApplication>
#include <QEvent>
#include <QGuiApplication>
#include <QList>
#include <QPointer>
#include <QQuickItem>
#include <QSet>
#include <QVector>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#if !defined(_WIN32_WINNT) || (_WIN32_WINNT < 0x0601)
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <dwmapi.h>
#include <ole2.h>
#include <shellapi.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

static constexpr UINT kAppBarCallbackMsg = WM_APP + 0x55;
static constexpr UINT kAppBarWorkerSyncMsg = WM_APP + 0x56;
static constexpr UINT kAppBarWorkerQuitMsg = WM_APP + 0x57;
#endif

// ---------------------------------------------------------------------------
// MarginGroup / WindowAnchors
// ---------------------------------------------------------------------------

MarginGroup::MarginGroup(QObject* parent)
    : QObject(parent)
{
}

WindowAnchors::WindowAnchors(QObject* parent)
    : QObject(parent)
    , m_margins(new MarginGroup(this))
{
    connect(m_margins, &MarginGroup::changed, this, &WindowAnchors::changed);
}

// ---------------------------------------------------------------------------
// QsRegion
// ---------------------------------------------------------------------------

QsRegion::QsRegion(QObject* parent)
    : QObject(parent)
{
}

void QsRegion::setItem(QQuickItem* item)
{
    if (m_item == item)
        return;

    if (m_item)
        m_item->disconnect(this);

    m_item = item;
    handleItemChanged();
    emit itemChanged();
}

void QsRegion::setRegions(const QVariantList& regions)
{
    if (m_regions == regions)
        return;
    m_regions = regions;
    emit regionsChanged();
}

void QsRegion::handleItemChanged()
{
    if (!m_item)
        return;
    connect(m_item, &QQuickItem::xChanged, this, &QsRegion::regionsChanged, Qt::UniqueConnection);
    connect(m_item, &QQuickItem::yChanged, this, &QsRegion::regionsChanged, Qt::UniqueConnection);
    connect(m_item, &QQuickItem::widthChanged, this, &QsRegion::regionsChanged, Qt::UniqueConnection);
    connect(m_item, &QQuickItem::heightChanged, this, &QsRegion::regionsChanged, Qt::UniqueConnection);
}

QRegion QsRegion::regionRelativeTo(const QQuickWindow* win) const
{
    QRegion out;

    QPointF origin(0, 0);
    if (m_item) {
        const QRectF sceneRect = m_item->mapRectToScene(
            QRectF(0, 0, m_item->width(), m_item->height()));
        origin = sceneRect.topLeft();
        out += sceneRect.toAlignedRect();
    }

    for (const QVariant& v : m_regions) {
        const QVariantMap r = v.toMap();
        const QRectF rect(r.value(QStringLiteral("x")).toReal(),
                          r.value(QStringLiteral("y")).toReal(),
                          r.value(QStringLiteral("width")).toReal(),
                          r.value(QStringLiteral("height")).toReal());
        out += rect.translated(origin).toAlignedRect();
    }

    // Clamp to the window rect so SetWindowRgn never exceeds the window.
    if (win) {
        const QRect winRect(0, 0, win->width(), win->height());
        out = out.intersected(winRect);
    }
    return out;
}

#ifdef Q_OS_WIN
namespace {
QSet<HWND> s_desktopHwnds;
QSet<HWND> s_overlayTopmostHwnds;
QList<PanelWindow*> s_desktopWindows;
QList<PanelWindow*> s_allPanels;
bool s_globalHibernated = false;
uint64_t s_hibGeneration = 0;
HWINEVENTHOOK s_fgHook = nullptr;
HWINEVENTHOOK s_minHook = nullptr;
HWINEVENTHOOK s_reorderHook = nullptr;
HWINEVENTHOOK s_locChangeHook = nullptr;
HWINEVENTHOOK s_desktopSwitchHook = nullptr;
QTimer* s_restackTimer = nullptr;
QTimer* s_followupRestackTimer = nullptr;
QTimer* s_showDesktopWatchTimer = nullptr;
bool s_inRestack = false;
bool s_showDesktopPromoted = false;

bool isShellOrSystemWindowClass(HWND hwnd)
{
    wchar_t cls[64]{};
    if (GetClassNameW(hwnd, cls, 64) <= 0)
        return false;
    return wcscmp(cls, L"Progman") == 0
        || wcscmp(cls, L"WorkerW") == 0
        || wcscmp(cls, L"SHELLDLL_DefView") == 0
        || wcscmp(cls, L"Shell_TrayWnd") == 0
        || wcscmp(cls, L"Shell_SecondaryTrayWnd") == 0
        || wcscmp(cls, L"TaskListThumbnailWnd") == 0
        || wcscmp(cls, L"Windows.UI.Core.CoreWindow") == 0
        || wcscmp(cls, L"MultitaskingViewFrame") == 0
        || wcscmp(cls, L"NotifyIconOverflowWindow") == 0;
}

HWND findDesktopHostHwnd()
{
    HWND progman = FindWindowW(L"Progman", nullptr);
    if (progman && FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr))
        return progman;

    struct FindHostCtx {
        HWND host = nullptr;
    } ctx;
    EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
        wchar_t cls[64]{};
        if (GetClassNameW(hwnd, cls, 64) > 0
            && (wcscmp(cls, L"WorkerW") == 0 || wcscmp(cls, L"Progman") == 0)
            && FindWindowExW(hwnd, nullptr, L"SHELLDLL_DefView", nullptr)) {
            reinterpret_cast<FindHostCtx*>(lParam)->host = hwnd;
            return FALSE;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&ctx));
    return ctx.host ? ctx.host : progman;
}

HWND lowestOwnTopmostHwnd()
{
    HWND lowest = nullptr;
    HWND cur = GetTopWindow(nullptr);
    int steps = 0;
    while (cur && steps < 1024) {
        ++steps;
        if ((GetWindowLongPtrW(cur, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0)
            break;
        if (s_overlayTopmostHwnds.contains(cur) && IsWindowVisible(cur))
            lowest = cur;
        cur = GetWindow(cur, GW_HWNDNEXT);
    }
    return lowest;
}

bool isWindowBehind(HWND hwnd, HWND ref)
{
    if (!hwnd || !ref || !IsWindow(hwnd) || !IsWindow(ref))
        return false;
    HWND cur = GetWindow(ref, GW_HWNDNEXT);
    int steps = 0;
    while (cur && steps < 1024) {
        ++steps;
        if (cur == hwnd)
            return true;
        cur = GetWindow(cur, GW_HWNDNEXT);
    }
    return false;
}

bool isVisibleModalOrDialogWindow(HWND cur)
{
    if (!cur || !IsWindow(cur) || !IsWindowVisible(cur) || IsIconic(cur))
        return false;
    if (s_desktopHwnds.contains(cur) || s_overlayTopmostHwnds.contains(cur))
        return false;
    const LONG_PTR ex = GetWindowLongPtrW(cur, GWL_EXSTYLE);
    if ((ex & WS_EX_TOPMOST) != 0)
        return false;
    if ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_APPWINDOW) == 0)
        return false;
    if (isShellOrSystemWindowClass(cur))
        return false;
    BOOL cloaked = FALSE;
    if (SUCCEEDED(DwmGetWindowAttribute(cur, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked)
        return false;
    RECT rc{};
    if (!GetWindowRect(cur, &rc))
        return false;
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;
    if (w < 80 || h < 60)
        return false;
    wchar_t cls[64]{};
    if (GetClassNameW(cur, cls, 64) > 0 && wcscmp(cls, L"#32770") == 0)
        return true;
    // Also treat sizable owned modal dialogs / popups (>= 160x120) as active app UI
    return w >= 160 && h >= 120;
}

bool isNormalAppWindow(HWND cur)
{
    if (!cur || !IsWindow(cur) || !IsWindowVisible(cur) || IsIconic(cur))
        return false;
    if (s_desktopHwnds.contains(cur) || s_overlayTopmostHwnds.contains(cur))
        return false;
    const LONG_PTR ex = GetWindowLongPtrW(cur, GWL_EXSTYLE);
    if ((ex & WS_EX_TOPMOST) != 0 || ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_APPWINDOW) == 0))
        return false;
    if (GetWindow(cur, GW_OWNER) != nullptr && (ex & WS_EX_APPWINDOW) == 0) {
        if (!isVisibleModalOrDialogWindow(cur))
            return false;
    }
    if (isShellOrSystemWindowClass(cur))
        return false;
    BOOL cloaked = FALSE;
    if (SUCCEEDED(DwmGetWindowAttribute(cur, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked)
        return false;
    RECT rc{};
    if (!GetWindowRect(cur, &rc) || (rc.right - rc.left) <= 0 || (rc.bottom - rc.top) <= 0)
        return false;
    return true;
}

bool isShowDesktopActive(HWND host)
{
    if (s_desktopHwnds.isEmpty() || !host || !IsWindow(host))
        return false;

    const HWND fg = GetForegroundWindow();
    if (fg && fg != host && !s_desktopHwnds.contains(fg)
        && !s_overlayTopmostHwnds.contains(fg)
        && !isShellOrSystemWindowClass(fg)
        && !IsIconic(fg)) {
        wchar_t fgCls[64]{};
        const bool isDialog = GetClassNameW(fg, fgCls, 64) > 0 && wcscmp(fgCls, L"#32770") == 0;
        if ((isDialog || isNormalAppWindow(fg)) && !isWindowBehind(fg, host))
            return false;
    }

    // Walk top-to-bottom non-topmost windows before desktop host.
    HWND cur = GetTopWindow(nullptr);
    int steps = 0;
    while (cur && cur != host && steps < 1024) {
        ++steps;
        if (isNormalAppWindow(cur))
            return false;
        cur = GetWindow(cur, GW_HWNDNEXT);
    }

    if (!fg || fg == host || s_desktopHwnds.contains(fg)
        || s_overlayTopmostHwnds.contains(fg)
        || isShellOrSystemWindowClass(fg)
        || IsIconic(fg)) {
        return true;
    }

    // Win+D on Windows 10 can raise WorkerW/Progman above non-minimized normal windows.
    return isWindowBehind(fg, host);
}

HWND lowestNormalAppWindow()
{
    HWND lowest = nullptr;
    HWND cur = GetTopWindow(nullptr);
    int steps = 0;
    while (cur && steps < 1024) {
        ++steps;
        if (isNormalAppWindow(cur))
            lowest = cur;
        cur = GetWindow(cur, GW_HWNDNEXT);
    }
    return lowest;
}

HWND nonWidgetPrevAboveDesktopHost(HWND host, HWND self)
{
    if (!host || !IsWindow(host))
        return nullptr;
    HWND cur = GetWindow(host, GW_HWNDPREV);
    int steps = 0;
    while (cur && steps < 1024) {
        ++steps;
        if (cur != self && !s_desktopHwnds.contains(cur) && !s_overlayTopmostHwnds.contains(cur)
            && IsWindowVisible(cur) && !IsIconic(cur)) {
            const LONG_PTR ex = GetWindowLongPtrW(cur, GWL_EXSTYLE);
            if ((ex & WS_EX_TOPMOST) != 0)
                return nullptr;
            if ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_APPWINDOW) == 0) {
                cur = GetWindow(cur, GW_HWNDPREV);
                continue;
            }
            if (GetWindow(cur, GW_OWNER) != nullptr && (ex & WS_EX_APPWINDOW) == 0
                && !isVisibleModalOrDialogWindow(cur)) {
                cur = GetWindow(cur, GW_HWNDPREV);
                continue;
            }
            if (isShellOrSystemWindowClass(cur)) {
                cur = GetWindow(cur, GW_HWNDPREV);
                continue;
            }
            BOOL cloaked = FALSE;
            if (SUCCEEDED(DwmGetWindowAttribute(cur, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked) {
                cur = GetWindow(cur, GW_HWNDPREV);
                continue;
            }
            RECT rc{};
            if (!GetWindowRect(cur, &rc) || (rc.right - rc.left) <= 0 || (rc.bottom - rc.top) <= 0) {
                cur = GetWindow(cur, GW_HWNDPREV);
                continue;
            }
            return cur;
        }
        cur = GetWindow(cur, GW_HWNDPREV);
    }
    return nullptr;
}

HWND findAnyNonTopmostWindowAboveHost(HWND host, HWND self)
{
    if (host && IsWindow(host)) {
        HWND cur = GetWindow(host, GW_HWNDPREV);
        int steps = 0;
        while (cur && steps < 1024) {
            ++steps;
            if ((GetWindowLongPtrW(cur, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0)
                break;
            if (cur != self && !s_desktopHwnds.contains(cur) && !s_overlayTopmostHwnds.contains(cur)
                && IsWindowVisible(cur) && !IsIconic(cur) && !isShellOrSystemWindowClass(cur)) {
                BOOL cloaked = FALSE;
                if (!SUCCEEDED(DwmGetWindowAttribute(cur, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) || !cloaked)
                    return cur;
            }
            cur = GetWindow(cur, GW_HWNDPREV);
        }
    }
    const HWND fg = GetForegroundWindow();
    if (fg && fg != self && fg != host
        && !s_desktopHwnds.contains(fg) && !s_overlayTopmostHwnds.contains(fg)
        && IsWindowVisible(fg) && !IsIconic(fg) && !isShellOrSystemWindowClass(fg)
        && (GetWindowLongPtrW(fg, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0
        && (!host || !isWindowBehind(fg, host))) {
        return fg;
    }
    return nullptr;
}

void applySingleDesktopZOrder(HWND hwnd, HWND host, bool showDesk, HWND lowestTop)
{
    if (!hwnd || !IsWindow(hwnd))
        return;

    if (showDesk) {
        const HWND insertAfter = lowestTop ? lowestTop : HWND_TOPMOST;
        const bool hasTopmost = (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
        const bool needsMove = !hasTopmost
            || (lowestTop && isWindowBehind(lowestTop, hwnd))
            || (!lowestTop && GetWindow(hwnd, GW_HWNDPREV) != nullptr
                && !s_desktopHwnds.contains(GetWindow(hwnd, GW_HWNDPREV)));
        if (needsMove) {
            SetWindowPos(hwnd, insertAfter, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
        }
    } else {
        if ((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0) {
            SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
        }
        HWND targetAfter = nonWidgetPrevAboveDesktopHost(host, hwnd);
        if (!targetAfter)
            targetAfter = lowestNormalAppWindow();
        if (!targetAfter)
            targetAfter = findAnyNonTopmostWindowAboveHost(host, hwnd);

        if (targetAfter) {
            const bool behindTarget = isWindowBehind(hwnd, targetAfter);
            const bool aboveHost = !host || isWindowBehind(host, hwnd);
            if (behindTarget && aboveHost)
                return;
            SetWindowPos(hwnd, targetAfter, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
        } else {
            if (host && isWindowBehind(host, hwnd))
                return;
            const HWND insertAfter = host ? HWND_TOP : HWND_BOTTOM;
            SetWindowPos(hwnd, insertAfter, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
        }
    }
}

void restackAllDesktopWindows()
{
    if (s_inRestack)
        return;
    s_inRestack = true;
    const HWND host = findDesktopHostHwnd();
    const bool showDesk = isShowDesktopActive(host);
    s_showDesktopPromoted = showDesk;
    const HWND lowestTop = showDesk ? lowestOwnTopmostHwnd() : nullptr;

    const QList<PanelWindow*> wins = s_desktopWindows;
    for (PanelWindow* w : wins) {
        if (!w || !w->isVisible() || !w->desktopLayer() || w->isInNativeDrag())
            continue;
        HWND h = reinterpret_cast<HWND>(w->winId());
        if (!h || !IsWindow(h))
            continue;
        if (IsIconic(h))
            ShowWindow(h, SW_SHOWNOACTIVATE);
        applySingleDesktopZOrder(h, host, showDesk, lowestTop);
    }
    s_inRestack = false;
}

void CALLBACK desktopWinEventProc(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG idObject,
                                  LONG idChild, DWORD, DWORD)
{
    if (s_desktopWindows.isEmpty() || s_globalHibernated)
        return;
    if (event == EVENT_SYSTEM_FOREGROUND && idObject == OBJID_WINDOW && hwnd) {
        if (!IsWindow(hwnd) || GetAncestor(hwnd, GA_ROOT) != hwnd)
            return;
        const bool isDesktop = isShellOrSystemWindowClass(hwnd);
        if (!isDesktop && s_desktopHwnds.contains(hwnd))
            return;
        if (s_restackTimer)
            s_restackTimer->start(30);
        if (isDesktop && s_followupRestackTimer)
            s_followupRestackTimer->start(150);
    } else if (event == EVENT_SYSTEM_MINIMIZESTART || event == EVENT_SYSTEM_MINIMIZEEND
               || event == EVENT_SYSTEM_DESKTOPSWITCH) {
        if (s_restackTimer)
            s_restackTimer->start(30);
        if (s_followupRestackTimer)
            s_followupRestackTimer->start(150);
    } else if (event == EVENT_OBJECT_REORDER && idObject == OBJID_WINDOW && hwnd) {
        if (!IsWindow(hwnd) || GetAncestor(hwnd, GA_ROOT) != hwnd)
            return;
        const bool isHost = isShellOrSystemWindowClass(hwnd);
        if (s_desktopHwnds.contains(hwnd) || isHost) {
            if (s_restackTimer)
                s_restackTimer->start(30);
            if (isHost && s_followupRestackTimer)
                s_followupRestackTimer->start(150);
        }
    } else if (event == EVENT_OBJECT_LOCATIONCHANGE && idObject == OBJID_WINDOW
               && idChild == 0 /*CHILDID_SELF*/ && hwnd) {
        if (!IsWindow(hwnd) || GetAncestor(hwnd, GA_ROOT) != hwnd)
            return;
        if (!s_desktopHwnds.contains(hwnd) && !s_overlayTopmostHwnds.contains(hwnd)) {
            if (s_showDesktopPromoted || isShellOrSystemWindowClass(hwnd)) {
                if (s_restackTimer && !s_restackTimer->isActive())
                    s_restackTimer->start(30);
            }
        }
    }
}

void ensureDesktopHooksInstalled()
{
    if (!s_restackTimer) {
        s_restackTimer = new QTimer(QCoreApplication::instance());
        s_restackTimer->setSingleShot(true);
        QObject::connect(s_restackTimer, &QTimer::timeout, []() {
            restackAllDesktopWindows();
        });
    }
    if (!s_followupRestackTimer) {
        s_followupRestackTimer = new QTimer(QCoreApplication::instance());
        s_followupRestackTimer->setSingleShot(true);
        QObject::connect(s_followupRestackTimer, &QTimer::timeout, []() {
            restackAllDesktopWindows();
        });
    }
    if (!s_showDesktopWatchTimer) {
        s_showDesktopWatchTimer = new QTimer(QCoreApplication::instance());
        s_showDesktopWatchTimer->setInterval(350);
        QObject::connect(s_showDesktopWatchTimer, &QTimer::timeout, []() {
            if (s_inRestack || s_desktopWindows.isEmpty() || s_globalHibernated)
                return;
            const HWND host = findDesktopHostHwnd();
            const bool showDesk = isShowDesktopActive(host);
            bool needsRestack = (showDesk != s_showDesktopPromoted);
            if (!needsRestack) {
                const HWND lowestTop = showDesk ? lowestOwnTopmostHwnd() : nullptr;
                const HWND lowestApp = showDesk ? nullptr : lowestNormalAppWindow();
                for (PanelWindow* w : s_desktopWindows) {
                    if (!w || !w->isVisible() || !w->desktopLayer() || w->isInNativeDrag())
                        continue;
                    HWND h = reinterpret_cast<HWND>(w->winId());
                    if (!h || !IsWindow(h))
                        continue;
                    const bool hasTopmost = (GetWindowLongPtrW(h, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
                    if (showDesk) {
                        if (!hasTopmost || (lowestTop && isWindowBehind(lowestTop, h))) {
                            needsRestack = true;
                            break;
                        }
                    } else {
                        if (hasTopmost
                            || (host && isWindowBehind(h, host))
                            || (lowestApp && !isWindowBehind(h, lowestApp))) {
                            needsRestack = true;
                            break;
                        }
                    }
                }
            }
            if (needsRestack)
                restackAllDesktopWindows();
        });
    }
    if (!s_globalHibernated && !s_showDesktopWatchTimer->isActive())
        s_showDesktopWatchTimer->start();

    if (!s_fgHook) {
        s_fgHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                                   nullptr, desktopWinEventProc, 0, 0,
                                   WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    if (!s_minHook) {
        s_minHook = SetWinEventHook(EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND,
                                    nullptr, desktopWinEventProc, 0, 0,
                                    WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    if (!s_reorderHook) {
        s_reorderHook = SetWinEventHook(EVENT_OBJECT_REORDER, EVENT_OBJECT_REORDER,
                                        nullptr, desktopWinEventProc, 0, 0,
                                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    if (!s_locChangeHook) {
        s_locChangeHook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
                                          nullptr, desktopWinEventProc, 0, 0,
                                          WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    if (!s_desktopSwitchHook) {
        s_desktopSwitchHook = SetWinEventHook(EVENT_SYSTEM_DESKTOPSWITCH, EVENT_SYSTEM_DESKTOPSWITCH,
                                              nullptr, desktopWinEventProc, 0, 0,
                                              WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
}

void cleanupDesktopHooksIfEmpty()
{
    if (!s_desktopWindows.isEmpty())
        return;
    s_showDesktopPromoted = false;
    if (s_restackTimer)
        s_restackTimer->stop();
    if (s_followupRestackTimer)
        s_followupRestackTimer->stop();
    if (s_showDesktopWatchTimer)
        s_showDesktopWatchTimer->stop();
    if (s_fgHook) {
        UnhookWinEvent(s_fgHook);
        s_fgHook = nullptr;
    }
    if (s_minHook) {
        UnhookWinEvent(s_minHook);
        s_minHook = nullptr;
    }
    if (s_reorderHook) {
        UnhookWinEvent(s_reorderHook);
        s_reorderHook = nullptr;
    }
    if (s_locChangeHook) {
        UnhookWinEvent(s_locChangeHook);
        s_locChangeHook = nullptr;
    }
    if (s_desktopSwitchHook) {
        UnhookWinEvent(s_desktopSwitchHook);
        s_desktopSwitchHook = nullptr;
    }
}
} // namespace

// Dedicated Win32 worker thread for SHAppBarMessage so blocking Explorer/broadcast
// IPC (ABM_NEW / ABM_QUERYPOS / ABM_SETPOS / ABM_REMOVE) never freezes the Qt GUI thread.
class AppBarWorker {
public:
    struct PendingReq {
        PanelWindow* owner = nullptr;
        QPointer<PanelWindow> safeOwner;
        HMONITOR mon = nullptr;
        bool reserve = false;
        UINT edge = ABE_TOP;
        int physThickness = 30;
    };

    static AppBarWorker& instance()
    {
        static AppBarWorker s_worker;
        return s_worker;
    }

    ~AppBarWorker()
    {
        HWND ctrl = nullptr;
        {
            std::lock_guard<std::mutex> lk(m_mutex);
            m_stopping = true;
            ctrl = m_ctrlHwnd;
        }
        if (ctrl && IsWindow(ctrl))
            PostMessageW(ctrl, kAppBarWorkerQuitMsg, 0, 0);
        if (m_thread.joinable())
            m_thread.detach();
    }

    void enqueue(const PendingReq& req)
    {
        if (!ensureStarted())
            return;
        HWND ctrl = nullptr;
        {
            std::lock_guard<std::mutex> lk(m_mutex);
            if (m_stopping)
                return;
            m_pending[req.owner] = req;
            ctrl = m_ctrlHwnd;
        }
        if (ctrl)
            PostMessageW(ctrl, kAppBarWorkerSyncMsg, 0, 0);
    }

    void shutdown()
    {
        HWND ctrl = nullptr;
        {
            std::lock_guard<std::mutex> lk(m_mutex);
            if (m_stopping && !m_started)
                return;
            m_stopping = true;
            ctrl = m_ctrlHwnd;
        }
        if (ctrl)
            PostMessageW(ctrl, kAppBarWorkerQuitMsg, 0, 0);
        if (m_thread.joinable())
            m_thread.join();
    }

private:
    struct WorkerSlot {
        QPointer<PanelWindow> safeOwner;
        HWND barHwnd = nullptr;
        HMONITOR mon = nullptr;
        bool registered = false;
        bool inUpdate = false;
        UINT edge = ABE_TOP;
        int physThickness = 30;
        int lastEdge = -1;
        RECT lastRc{};
    };

    AppBarWorker() = default;

    bool ensureStarted()
    {
        std::unique_lock<std::mutex> lk(m_mutex);
        if (m_stopping)
            return false;
        if (m_started && m_ctrlHwnd)
            return true;
        if (!m_thread.joinable()) {
            m_ready = false;
            m_thread = std::thread(&AppBarWorker::threadMain, this);
        }
        m_cv.wait(lk, [this]() { return m_ready || m_stopping; });
        return m_started && m_ctrlHwnd != nullptr && !m_stopping;
    }

    void threadMain()
    {
        HINSTANCE hInst = GetModuleHandleW(nullptr);
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = &AppBarWorker::proxyWndProc;
        wc.hInstance = hInst;
        wc.lpszClassName = L"SekaiDesk_AppBarProxy";
        RegisterClassExW(&wc);

        HWND ctrl = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            L"SekaiDesk_AppBarProxy",
            L"SekaiDeskAppBarCtrl",
            WS_POPUP,
            -32000, -32000, 0, 0,
            nullptr, nullptr, hInst, this);

        {
            std::lock_guard<std::mutex> lk(m_mutex);
            m_ctrlHwnd = ctrl;
            m_started = (ctrl != nullptr);
            m_ready = true;
        }
        m_cv.notify_all();

        if (!ctrl)
            return;

        MSG msg{};
        while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        // Belt-and-suspenders cleanup if loop ended externally
        cleanupAllSlotsWorker();
        std::lock_guard<std::mutex> lk(m_mutex);
        m_ctrlHwnd = nullptr;
        m_started = false;
    }

    void updateBottomReservedFlag() const
    {
        bool anyBottom = false;
        for (const auto& kv : m_slots) {
            if (kv.second.registered && kv.second.edge == ABE_BOTTOM) {
                anyBottom = true;
                break;
            }
        }
        TaskbarManager::setBottomAppBarReserved(anyBottom);
    }

    static RECT computeEdgeRect(const MONITORINFO& mi, UINT uEdge, int physT)
    {
        RECT rc = mi.rcMonitor;
        const int clampedT = qMax(24, physT);
        switch (uEdge) {
        case ABE_BOTTOM: rc.top = rc.bottom - clampedT; break;
        case ABE_LEFT:   rc.right = rc.left + clampedT; break;
        case ABE_RIGHT:  rc.left = rc.right - clampedT; break;
        case ABE_TOP:
        default:         rc.bottom = rc.top + clampedT; break;
        }
        return rc;
    }

    static void clampQueryRect(RECT& rc, UINT uEdge, int physT)
    {
        const int clampedT = qMax(24, physT);
        switch (uEdge) {
        case ABE_BOTTOM: rc.top = rc.bottom - clampedT; break;
        case ABE_LEFT:   rc.right = rc.left + clampedT; break;
        case ABE_RIGHT:  rc.left = rc.right - clampedT; break;
        case ABE_TOP:
        default:         rc.bottom = rc.top + clampedT; break;
        }
    }

    void processSyncWorker()
    {
        std::vector<PendingReq> batch;
        {
            std::lock_guard<std::mutex> lk(m_mutex);
            if (m_pending.empty())
                return;
            batch.reserve(m_pending.size());
            for (const auto& kv : m_pending)
                batch.push_back(kv.second);
            m_pending.clear();
        }

        HINSTANCE hInst = GetModuleHandleW(nullptr);
        for (const PendingReq& req : batch) {
            if (!req.reserve) {
                auto it = m_slots.find(req.owner);
                if (it != m_slots.end()) {
                    WorkerSlot& slot = it->second;
                    if (slot.registered && slot.barHwnd && IsWindow(slot.barHwnd)) {
                        APPBARDATA abd{};
                        abd.cbSize = sizeof(abd);
                        abd.hWnd = slot.barHwnd;
                        SHAppBarMessage(ABM_REMOVE, &abd);
                    }
                    if (slot.barHwnd && IsWindow(slot.barHwnd))
                        DestroyWindow(slot.barHwnd);
                    m_slots.erase(it);
                }
                updateBottomReservedFlag();
                continue;
            }

            WorkerSlot& slot = m_slots[req.owner];
            slot.safeOwner = req.safeOwner;
            slot.mon = req.mon;
            slot.edge = req.edge;
            slot.physThickness = req.physThickness;

            if (!slot.barHwnd || !IsWindow(slot.barHwnd)) {
                slot.barHwnd = CreateWindowExW(
                    WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                    L"SekaiDesk_AppBarProxy",
                    L"SekaiDeskAppBarSlot",
                    WS_POPUP,
                    -32000, -32000, 0, 0,
                    nullptr, nullptr, hInst, this);
                if (slot.barHwnd) {
                    SetWindowLongPtrW(slot.barHwnd, GWLP_USERDATA,
                                      reinterpret_cast<LONG_PTR>(req.owner));
                }
            }
            if (!slot.barHwnd)
                continue;

            MONITORINFO mi{};
            mi.cbSize = sizeof(mi);
            if (!slot.mon || !GetMonitorInfoW(slot.mon, &mi)) {
                HMONITOR pri = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
                if (!GetMonitorInfoW(pri, &mi))
                    continue;
            }

            APPBARDATA abd{};
            abd.cbSize = sizeof(abd);
            abd.hWnd = slot.barHwnd;
            abd.uCallbackMessage = kAppBarCallbackMsg;
            abd.uEdge = slot.edge;
            abd.rc = computeEdgeRect(mi, slot.edge, slot.physThickness);

            const bool newlyRegistered = !slot.registered;
            if (!slot.registered) {
                SHAppBarMessage(ABM_NEW, &abd);
                slot.registered = true;
            }

            // Publish edge state before ABM_SETPOS triggers WM_SETTINGCHANGE in TaskbarManager
            updateBottomReservedFlag();

            slot.inUpdate = true;
            SHAppBarMessage(ABM_QUERYPOS, &abd);
            clampQueryRect(abd.rc, slot.edge, slot.physThickness);

            const bool rectChanged = newlyRegistered
                || slot.lastEdge != static_cast<int>(slot.edge)
                || !EqualRect(&slot.lastRc, &abd.rc);
            if (rectChanged) {
                slot.lastEdge = static_cast<int>(slot.edge);
                slot.lastRc = abd.rc;
                SHAppBarMessage(ABM_SETPOS, &abd);
            }
            slot.inUpdate = false;
        }
        updateBottomReservedFlag();
    }

    void cleanupAllSlotsWorker()
    {
        for (auto& kv : m_slots) {
            WorkerSlot& slot = kv.second;
            if (slot.registered && slot.barHwnd && IsWindow(slot.barHwnd)) {
                APPBARDATA abd{};
                abd.cbSize = sizeof(abd);
                abd.hWnd = slot.barHwnd;
                SHAppBarMessage(ABM_REMOVE, &abd);
            }
            if (slot.barHwnd && IsWindow(slot.barHwnd))
                DestroyWindow(slot.barHwnd);
        }
        m_slots.clear();
        TaskbarManager::setBottomAppBarReserved(false);
    }

    static LRESULT CALLBACK proxyWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
    {
        if (msg == WM_NCCREATE) {
            auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
            if (cs && cs->lpCreateParams)
                SetPropW(hwnd, L"AppBarWorkerPtr", cs->lpCreateParams);
            return TRUE;
        }

        auto* worker = reinterpret_cast<AppBarWorker*>(GetPropW(hwnd, L"AppBarWorkerPtr"));
        if (!worker)
            return DefWindowProcW(hwnd, msg, wParam, lParam);

        if (msg == kAppBarWorkerSyncMsg) {
            worker->processSyncWorker();
            return 0;
        }

        if (msg == kAppBarWorkerQuitMsg) {
            worker->cleanupAllSlotsWorker();
            HWND ctrl = nullptr;
            {
                std::lock_guard<std::mutex> lk(worker->m_mutex);
                ctrl = worker->m_ctrlHwnd;
                worker->m_ctrlHwnd = nullptr;
            }
            if (ctrl && IsWindow(ctrl))
                DestroyWindow(ctrl);
            PostQuitMessage(0);
            return 0;
        }

        if (msg == kAppBarCallbackMsg) {
            auto* ownerKey = reinterpret_cast<PanelWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
            auto it = worker->m_slots.find(ownerKey);
            if (it == worker->m_slots.end())
                return 0;
            WorkerSlot& slot = it->second;

            if (wParam == ABN_POSCHANGED && slot.registered && !slot.inUpdate) {
                MONITORINFO mi{};
                mi.cbSize = sizeof(mi);
                if (slot.mon && GetMonitorInfoW(slot.mon, &mi)) {
                    APPBARDATA abd{};
                    abd.cbSize = sizeof(abd);
                    abd.hWnd = slot.barHwnd;
                    abd.uCallbackMessage = kAppBarCallbackMsg;
                    abd.uEdge = slot.edge;
                    abd.rc = computeEdgeRect(mi, slot.edge, slot.physThickness);
                    slot.inUpdate = true;
                    SHAppBarMessage(ABM_QUERYPOS, &abd);
                    clampQueryRect(abd.rc, slot.edge, slot.physThickness);
                    if (!EqualRect(&slot.lastRc, &abd.rc)) {
                        slot.lastRc = abd.rc;
                        SHAppBarMessage(ABM_SETPOS, &abd);
                    }
                    slot.inUpdate = false;
                }
                if (auto* app = QCoreApplication::instance()) {
                    const QPointer<PanelWindow> safeOwner = slot.safeOwner;
                    QMetaObject::invokeMethod(app, [safeOwner]() {
                        if (safeOwner)
                            safeOwner->handleAppBarPosChanged();
                    }, Qt::QueuedConnection);
                }
            } else if (wParam == ABN_FULLSCREENAPP) {
                const bool fsHint = (lParam != 0);
                if (auto* app = QCoreApplication::instance()) {
                    const QPointer<PanelWindow> safeOwner = slot.safeOwner;
                    QMetaObject::invokeMethod(app, [safeOwner, fsHint]() {
                        if (safeOwner)
                            safeOwner->handleAppBarFullscreenHint(fsHint);
                    }, Qt::QueuedConnection);
                }
            }
            return 0;
        }

        if (msg == WM_NCDESTROY)
            RemovePropW(hwnd, L"AppBarWorkerPtr");

        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    std::mutex m_mutex;
    std::condition_variable m_cv;
    std::thread m_thread;
    HWND m_ctrlHwnd = nullptr;
    bool m_ready = false;
    bool m_started = false;
    bool m_stopping = false;
    std::unordered_map<PanelWindow*, PendingReq> m_pending;
    std::unordered_map<PanelWindow*, WorkerSlot> m_slots;
};
#endif

// ---------------------------------------------------------------------------
// PanelWindow
// ---------------------------------------------------------------------------

PanelWindow::PanelWindow(QWindow* parent)
    : QQuickWindow(parent)
    , m_anchors(new WindowAnchors(this))
{
    s_allPanels.append(this);
    setFlags(flags() | Qt::Tool | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint);
    setColor(Qt::transparent);

    // Request an alpha channel so per-pixel translucency actually works.
    QSurfaceFormat fmt = format();
    fmt.setAlphaBufferSize(8);
    setFormat(fmt);

    connect(m_anchors, &WindowAnchors::changed, this, &PanelWindow::recompute);
    connect(this, &QWindow::activeChanged, this, [this]() {
        if (!isActive())
            emit windowDeactivated();
    });
    // Content-driven sizing (QML sets height after anchors): keep the edge
    // placement honest whenever the window size changes.
    connect(this, &QWindow::widthChanged, this, &PanelWindow::recompute);
    connect(this, &QWindow::heightChanged, this, &PanelWindow::recompute);
    connect(this, &QWindow::visibleChanged, this, [this](bool vis) {
        if (vis) {
            m_hasAppliedMask = false;
            recomputeGeometry();
            applyClickThrough();
            updateMask();
            applyBlurBehind();
            applyDesktopLayer();
            applyFileDrops();
            update();
#ifdef Q_OS_WIN
            if (!m_desktopLayer && handle()) {
                HWND hwnd = reinterpret_cast<HWND>(winId());
                if (hwnd && IsWindow(hwnd)) {
                    s_overlayTopmostHwnds.insert(hwnd);
                    if (s_showDesktopPromoted && s_restackTimer)
                        s_restackTimer->start(10);
                }
            }
#endif
            if (m_reserveTopBar)
                scheduleAppBarSync();
            if (!m_desktopLayer) {
                verifyFullscreenState();
                if (!s_globalHibernated)
                    m_fsGuardTimer.start();
            }
            const QPointer<PanelWindow> safeThis(this);
            QTimer::singleShot(45, this, [safeThis]() {
                if (!safeThis || !safeThis->isVisible())
                    return;
                safeThis->m_hasAppliedMask = false;
                safeThis->updateMask();
                safeThis->applyBlurBehind();
                safeThis->update();
            });
            QTimer::singleShot(140, this, [safeThis]() {
                if (!safeThis || !safeThis->isVisible())
                    return;
                safeThis->updateMask();
                safeThis->applyBlurBehind();
                safeThis->update();
            });
        } else {
#ifdef Q_OS_WIN
            if (handle())
                s_overlayTopmostHwnds.remove(reinterpret_cast<HWND>(winId()));
#endif
            m_fsGuardTimer.stop();
            if (m_fullscreenActive) {
                m_fullscreenActive = false;
                emit fullscreenActiveChanged();
            }
            unregisterAppBar();
        }
    });
    m_fsGuardTimer.setInterval(500);
    connect(&m_fsGuardTimer, &QTimer::timeout, this, &PanelWindow::verifyFullscreenState);
    m_appBarDebounceTimer.setSingleShot(true);
    m_appBarDebounceTimer.setInterval(40);
    connect(&m_appBarDebounceTimer, &QTimer::timeout, this, &PanelWindow::syncAppBarNow);
    connect(this, &QWindow::screenChanged, this, [this](QScreen*) {
        recomputeGeometry();
        updateMask();
        if (m_reserveTopBar && isVisible())
            scheduleAppBarSync();
    });
    if (auto* app = QCoreApplication::instance()) {
        connect(app, &QCoreApplication::aboutToQuit, this, [this]() {
            unregisterAppBar();
#ifdef Q_OS_WIN
            AppBarWorker::instance().shutdown();
#endif
        });
    }
}

PanelWindow::~PanelWindow()
{
    s_allPanels.removeOne(this);
    m_fsGuardTimer.stop();
    m_inNativeDrag = false;
#ifdef Q_OS_WIN
    if (handle())
        s_overlayTopmostHwnds.remove(reinterpret_cast<HWND>(winId()));
#endif
    unregisterDesktopWindow();
    unregisterAppBar();
}

void PanelWindow::recompute()
{
    recomputeGeometry();
    updateMask();
    if (m_blurBehind && isVisible())
        applyBlurBehind();
}

void PanelWindow::setPanelGeometry(int gx, int gy, int gw, int gh)
{
    const int w = qMax(1, gw);
    const int h = qMax(1, gh);
    QScreen* pri = QGuiApplication::primaryScreen();
    if (pri && screen() != pri)
        setScreen(pri);

    if (x() != gx || y() != gy || width() != w || height() != h)
        setGeometry(gx, gy, w, h);

#ifdef Q_OS_WIN
    if (isVisible() && handle()) {
        HWND hwnd = reinterpret_cast<HWND>(winId());
        if (hwnd && IsWindow(hwnd)) {
            const HMONITOR mon = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
            MONITORINFO mi{};
            mi.cbSize = sizeof(mi);
            if (GetMonitorInfoW(mon, &mi)) {
                const qreal dpr = (pri && pri->devicePixelRatio() > 0.0)
                    ? pri->devicePixelRatio()
                    : ((devicePixelRatio() > 0.0) ? devicePixelRatio() : 1.0);
                const int px = mi.rcMonitor.left + qRound(gx * dpr);
                const int py = mi.rcMonitor.top + qRound(gy * dpr);
                const int pw = qMax(1, qRound(w * dpr));
                const int ph = qMax(1, qRound(h * dpr));
                SetWindowPos(hwnd, nullptr, px, py, pw, ph,
                             SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
            }
        }
    }
#endif

    updateMask();
    if (m_blurBehind && isVisible())
        applyBlurBehind();
}

void PanelWindow::recomputeGeometry()
{
    QScreen* scr = screen();
    if (!scr)
        scr = QGuiApplication::primaryScreen();
    if (!scr)
        return;

    const QRect geo = scr->geometry();
    const MarginGroup* mg = m_anchors->margins();
    const int mL = mg->left();
    const int mT = mg->top();
    const int mR = mg->right();
    const int mB = mg->bottom();

    int nx = x();
    int ny = y();
    int nw = qMax(1, width());
    int nh = qMax(1, height());

    // Horizontal placement. If both edges anchored, we own the width.
    if (m_anchors->left() && m_anchors->right()) {
        nw = qMax(1, geo.width() - mL - mR);
        nx = geo.left() + mL;
        m_geometryOwned = true;
    } else if (m_anchors->left()) {
        nx = geo.left() + mL;
        m_geometryOwned = true;
    } else if (m_anchors->right()) {
        nx = geo.right() + 1 - mR - nw;
        m_geometryOwned = true;
    } else if (m_geometryOwned) {
        nx = geo.center().x() - nw / 2;
    }

    // Vertical placement.
    if (m_anchors->top() && m_anchors->bottom()) {
        nh = qMax(1, geo.height() - mT - mB);
        ny = geo.top() + mT;
        m_geometryOwned = true;
    } else if (m_anchors->top()) {
        ny = geo.top() + mT;
        m_geometryOwned = true;
    } else if (m_anchors->bottom()) {
        ny = geo.bottom() + 1 - mB - nh;
        m_geometryOwned = true;
    } else if (m_geometryOwned) {
        ny = geo.center().y() - nh / 2;
    }

    if (x() != nx || y() != ny || width() != nw || height() != nh)
        setGeometry(nx, ny, nw, nh);
}

void PanelWindow::setClickThrough(bool on)
{
    if (m_clickThrough == on)
        return;
    m_clickThrough = on;
    applyClickThrough();
    emit clickThroughChanged();
}

void PanelWindow::applyClickThrough()
{
#ifdef Q_OS_WIN
    if (!isVisible())
        return;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    LONG_PTR exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (m_clickThrough)
        exStyle |= WS_EX_TRANSPARENT | WS_EX_LAYERED;
    else
        exStyle &= ~WS_EX_TRANSPARENT;
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle);
#endif
}

void PanelWindow::setMaskProperty(const QVariant& mask)
{
    m_mask = mask;

    // Track dynamic region sources (item-anchored masks move on layout).
    if (QObject* obj = m_mask.value<QObject*>()) {
        connect(obj, &QObject::destroyed, this, &PanelWindow::updateMask,
                Qt::UniqueConnection);
        if (auto* reg = qobject_cast<QsRegion*>(obj))
            connect(reg, &QsRegion::regionsChanged, this, &PanelWindow::updateMask,
                    Qt::UniqueConnection);
    }

    emit maskChanged();
    updateMask();
}

void PanelWindow::updateMask()
{
    if (!isVisible())
        return;

    QRegion next;
    if (QObject* obj = m_mask.value<QObject*>()) {
        if (auto* region = qobject_cast<QsRegion*>(obj)) {
            next = region->regionRelativeTo(this);
        }
    } else if (m_mask.canConvert<QVariantList>()) {
        const QVariantList rects = m_mask.toList();
        for (const QVariant& v : rects) {
            const QVariantMap r = v.toMap();
            next += QRect(r.value(QStringLiteral("x")).toInt(),
                          r.value(QStringLiteral("y")).toInt(),
                          r.value(QStringLiteral("width")).toInt(),
                          r.value(QStringLiteral("height")).toInt());
        }
    }

    if (m_blurBehind && !s_globalHibernated && next.isEmpty()) {
        applyBlurBehind();
        return;
    }

    if (m_hasAppliedMask && m_lastMask == next)
        return;
    m_lastMask = next;
    m_hasAppliedMask = true;
    setMask(next);
}

void PanelWindow::setBlurBehind(bool on)
{
    if (m_blurBehind == on)
        return;
    m_blurBehind = on;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::setBlurRadius(int r)
{
    if (m_blurRadius == r)
        return;
    m_blurRadius = r;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::setBlurInsetX(int v)
{
    if (m_blurInsetX == v)
        return;
    m_blurInsetX = v;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::setBlurInsetY(int v)
{
    if (m_blurInsetY == v)
        return;
    m_blurInsetY = v;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::setBlurInsetRight(int v)
{
    if (m_blurInsetRight == v)
        return;
    m_blurInsetRight = v;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::setBlurInsetBottom(int v)
{
    if (m_blurInsetBottom == v)
        return;
    m_blurInsetBottom = v;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::setBlurTint(const QColor& c)
{
    if (m_blurTint == c)
        return;
    m_blurTint = c;
    emit blurChanged();
    applyBlurBehind();
}

void PanelWindow::applyBlurBehind()
{
#ifdef Q_OS_WIN
    if (!isVisible())
        return;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd || !IsWindow(hwnd))
        return;

    struct AccentPolicy {
        int AccentState;
        int AccentFlags;
        DWORD GradientColor;
        int AnimationId;
    };
    struct WindowCompositionAttribData {
        int Attrib;
        PVOID pvData;
        SIZE_T cbData;
    };
    using FnSetWindowCompositionAttribute = BOOL(WINAPI*)(HWND, WindowCompositionAttribData*);
    static auto fnSetWCA = reinterpret_cast<FnSetWindowCompositionAttribute>(
        GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute"));

    if (m_blurBehind && !s_globalHibernated) {
        const bool overshotBothAxes = (width() > 300 && height() > 300);
        if (overshotBothAxes) {
            if (fnSetWCA) {
                AccentPolicy policy{};
                policy.AccentState = 0;
                WindowCompositionAttribData data{ 19, &policy, sizeof(policy) };
                fnSetWCA(hwnd, &data);
            }
            return;
        }
        if (fnSetWCA) {
            const DWORD a = static_cast<DWORD>(qBound(0, m_blurTint.alpha(), 255));
            const DWORD r = static_cast<DWORD>(m_blurTint.red());
            const DWORD g = static_cast<DWORD>(m_blurTint.green());
            const DWORD b = static_cast<DWORD>(m_blurTint.blue());
            AccentPolicy policy{};
            policy.AccentState = 4; // ACCENT_ENABLE_ACRYLICBLURBEHIND
            policy.AccentFlags = 2;
            policy.GradientColor = (a << 24) | (b << 16) | (g << 8) | r;
            WindowCompositionAttribData data{ 19 /*WCA_ACCENT_POLICY*/, &policy, sizeof(policy) };
            fnSetWCA(hwnd, &data);
        }

        const qreal dpr = devicePixelRatio();
        const int x1 = qRound(m_blurInsetX * dpr);
        const int y1 = qRound(m_blurInsetY * dpr);
        const int x2 = qMax(x1 + 2, qRound((width() - m_blurInsetRight) * dpr));
        const int y2 = qMax(y1 + 2, qRound((height() - m_blurInsetBottom) * dpr));
        const int rad = qMax(0, qRound(m_blurRadius * 2 * dpr));
        HRGN rgn = (rad > 0) ? CreateRoundRectRgn(x1, y1, x2 + 1, y2 + 1, rad, rad)
                             : CreateRectRgn(x1, y1, x2, y2);
        if (rgn)
            SetWindowRgn(hwnd, rgn, TRUE);
    } else if (fnSetWCA) {
        AccentPolicy policy{};
        policy.AccentState = 0; // ACCENT_DISABLED
        WindowCompositionAttribData data{ 19, &policy, sizeof(policy) };
        fnSetWCA(hwnd, &data);
        m_hasAppliedMask = false;
        if (!s_globalHibernated)
            updateMask();
    }
#endif
}

void PanelWindow::setGlobalHibernated(bool hibernated)
{
    if (s_globalHibernated == hibernated)
        return;
    s_globalHibernated = hibernated;
    ++s_hibGeneration;

#ifdef Q_OS_WIN
    if (hibernated) {
        if (s_showDesktopWatchTimer)
            s_showDesktopWatchTimer->stop();
        if (s_restackTimer)
            s_restackTimer->stop();
        if (s_followupRestackTimer)
            s_followupRestackTimer->stop();

        for (PanelWindow* p : std::as_const(s_allPanels)) {
            if (!p)
                continue;
            p->m_fsGuardTimer.stop();
            p->applyBlurBehind();
        }

        scheduleHiddenResourceRelease();
    } else {
        if (s_showDesktopWatchTimer && !s_desktopWindows.isEmpty())
            s_showDesktopWatchTimer->start();

        auto wakeAllVisiblePanels = []() {
            if (s_globalHibernated)
                return;
            for (PanelWindow* p : std::as_const(s_allPanels)) {
                if (!p || !p->isVisible())
                    continue;
                p->m_hasAppliedMask = false;
                p->updateMask();
                p->applyBlurBehind();
                p->update();
                if (!p->m_desktopLayer) {
                    p->verifyFullscreenState();
                    if (!p->m_fsGuardTimer.isActive())
                        p->m_fsGuardTimer.start();
                }
            }
        };
        wakeAllVisiblePanels();
        if (auto* app = QCoreApplication::instance()) {
            QTimer::singleShot(30, app, wakeAllVisiblePanels);
            QTimer::singleShot(120, app, wakeAllVisiblePanels);
        }
    }
#endif
}

void PanelWindow::scheduleHiddenResourceRelease()
{
#ifdef Q_OS_WIN
    if (!s_globalHibernated)
        return;
    const int gen = ++s_hibGeneration;
    QTimer::singleShot(180, QCoreApplication::instance(), [gen]() {
        if (!s_globalHibernated || s_hibGeneration != gen)
            return;
        for (QWindow* w : QGuiApplication::topLevelWindows()) {
            if (auto* qw = qobject_cast<QQuickWindow*>(w)) {
                if (qobject_cast<PanelWindow*>(qw))
                    continue;
                if (!qw->isVisible())
                    qw->releaseResources();
            }
        }
        SetProcessWorkingSetSize(GetCurrentProcess(),
                                 static_cast<SIZE_T>(-1),
                                 static_cast<SIZE_T>(-1));
    });
#endif
}

void PanelWindow::setReserveTopBar(bool on)
{
    if (m_reserveTopBar == on)
        return;
    m_reserveTopBar = on;
    emit reserveTopBarChanged();
    if (m_reserveTopBar && isVisible())
        scheduleAppBarSync();
    else if (!m_reserveTopBar)
        unregisterAppBar();
}

void PanelWindow::setReserveHeight(int h)
{
    if (m_reserveHeight == h)
        return;
    m_reserveHeight = h;
    emit reserveHeightChanged();
    if (m_reserveTopBar && isVisible())
        scheduleAppBarSync();
}

void PanelWindow::setReserveEdge(const QString& edge)
{
    QString norm = edge.trimmed().toLower();
    if (norm != QLatin1String("bottom") && norm != QLatin1String("left") && norm != QLatin1String("right"))
        norm = QStringLiteral("top");
    if (m_reserveEdge == norm)
        return;
    m_reserveEdge = norm;
    emit reserveEdgeChanged();
    // Never call ABM_REMOVE on edge switch; AppBarWorker swaps uEdge smoothly off-thread.
    if (m_reserveTopBar && isVisible())
        scheduleAppBarSync();
}

void PanelWindow::scheduleAppBarSync()
{
    if (!m_reserveTopBar || !isVisible()) {
        unregisterAppBar();
        return;
    }
    m_appBarDebounceTimer.start();
}

void PanelWindow::syncAppBarNow()
{
    registerOrUpdateAppBar();
}

void PanelWindow::registerOrUpdateAppBar()
{
#ifdef Q_OS_WIN
    if (!m_reserveTopBar || !isVisible())
        return;
    HWND hwnd = handle() ? reinterpret_cast<HWND>(winId()) : nullptr;
    if (!hwnd || !IsWindow(hwnd))
        return;

    const HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
    const int physT = qMax(24, qRound(m_reserveHeight * devicePixelRatio()));
    UINT uEdge = ABE_TOP;
    if (m_reserveEdge == QLatin1String("bottom"))
        uEdge = ABE_BOTTOM;
    else if (m_reserveEdge == QLatin1String("left"))
        uEdge = ABE_LEFT;
    else if (m_reserveEdge == QLatin1String("right"))
        uEdge = ABE_RIGHT;

    AppBarWorker::PendingReq req;
    req.owner = this;
    req.safeOwner = QPointer<PanelWindow>(this);
    req.mon = mon;
    req.reserve = true;
    req.edge = uEdge;
    req.physThickness = physT;
    m_appBarRegistered = true;
    AppBarWorker::instance().enqueue(req);
#endif
}

void PanelWindow::unregisterAppBar()
{
    m_appBarDebounceTimer.stop();
#ifdef Q_OS_WIN
    if (!m_appBarRegistered)
        return;
    m_appBarRegistered = false;
    m_lastAppBarEdge = -1;

    AppBarWorker::PendingReq req;
    req.owner = this;
    req.safeOwner = QPointer<PanelWindow>(this);
    req.reserve = false;
    AppBarWorker::instance().enqueue(req);
#endif
}

#ifdef Q_OS_WIN
static bool isGenuineFullscreenForeground(HWND selfHwnd)
{
    HWND fg = GetForegroundWindow();
    if (!fg || !IsWindow(fg) || !IsWindowVisible(fg) || IsIconic(fg))
        return false;

    wchar_t cls[64]{};
    GetClassNameW(fg, cls, 64);
    if (wcscmp(cls, L"Progman") == 0
        || wcscmp(cls, L"WorkerW") == 0
        || wcscmp(cls, L"Shell_TrayWnd") == 0
        || wcscmp(cls, L"Shell_SecondaryTrayWnd") == 0
        || wcscmp(cls, L"NotifyIconOverflowWindow") == 0) {
        return false;
    }

    DWORD fgPid = 0;
    GetWindowThreadProcessId(fg, &fgPid);
    if (fgPid == GetCurrentProcessId())
        return false;
    if (fgPid != 0) {
        HANDLE hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, fgPid);
        if (hProc) {
            wchar_t exePath[MAX_PATH]{};
            DWORD sz = MAX_PATH;
            if (QueryFullProcessImageNameW(hProc, 0, exePath, &sz)) {
                const wchar_t* base = wcsrchr(exePath, L'\\');
                const wchar_t* name = base ? base + 1 : exePath;
                if (_wcsicmp(name, L"wallpaper64.exe") == 0
                    || _wcsicmp(name, L"wallpaper32.exe") == 0
                    || _wcsicmp(name, L"explorer.exe") == 0
                    || _wcsicmp(name, L"ScreenClippingHost.exe") == 0
                    || _wcsicmp(name, L"SnippingTool.exe") == 0
                    || _wcsicmp(name, L"ShellExperienceHost.exe") == 0
                    || _wcsicmp(name, L"StartMenuExperienceHost.exe") == 0
                    || _wcsicmp(name, L"SearchHost.exe") == 0
                    || _wcsicmp(name, L"SearchApp.exe") == 0
                    || _wcsicmp(name, L"TextInputHost.exe") == 0
                    || _wcsicmp(name, L"PickerHost.exe") == 0
                    || _wcsicmp(name, L"LockApp.exe") == 0) {
                    CloseHandle(hProc);
                    return false;
                }
            }
            CloseHandle(hProc);
        }
    }

    const LONG_PTR exStyle = GetWindowLongPtrW(fg, GWL_EXSTYLE);
    if ((exStyle & WS_EX_TOOLWINDOW) && !(exStyle & WS_EX_APPWINDOW))
        return false;

    const HMONITOR mon = MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
    if (selfHwnd && IsWindow(selfHwnd)) {
        const HMONITOR selfMon = MonitorFromWindow(selfHwnd, MONITOR_DEFAULTTONEAREST);
        if (mon != selfMon)
            return false;
    }

    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi))
        return false;

    RECT rc{};
    if (FAILED(DwmGetWindowAttribute(fg, DWMWA_EXTENDED_FRAME_BOUNDS, &rc, sizeof(rc)))) {
        if (!GetWindowRect(fg, &rc))
            return false;
    }

    const bool coversMonitor = rc.left <= mi.rcMonitor.left
                            && rc.top <= mi.rcMonitor.top
                            && rc.right >= mi.rcMonitor.right
                            && rc.bottom >= mi.rcMonitor.bottom;
    if (!coversMonitor)
        return false;

    // A normal maximized window with WS_CAPTION on a monitor where rcWork == rcMonitor
    // (e.g. auto-hidden taskbar + barAutoHide) also covers rcMonitor, so distinguish it
    // from genuine borderless / D3D / presentation fullscreen.
    const LONG_PTR style = GetWindowLongPtrW(fg, GWL_STYLE);
    if ((style & WS_CAPTION) == WS_CAPTION && IsZoomed(fg)) {
        QUERY_USER_NOTIFICATION_STATE qns = QUNS_ACCEPTS_NOTIFICATIONS;
        if (FAILED(SHQueryUserNotificationState(&qns))
            || (qns != QUNS_RUNNING_D3D_FULL_SCREEN && qns != QUNS_PRESENTATION_MODE)) {
            return false;
        }
    }

    return true;
}
#endif

void PanelWindow::verifyFullscreenState()
{
#ifdef Q_OS_WIN
    HWND hwnd = handle() ? reinterpret_cast<HWND>(winId()) : nullptr;
    const bool fs = (!m_desktopLayer && isVisible() && hwnd)
                        ? isGenuineFullscreenForeground(hwnd)
                        : false;
    if (m_fullscreenActive != fs) {
        m_fullscreenActive = fs;
        emit fullscreenActiveChanged();
        if (!fs && !m_desktopLayer && isVisible() && hwnd) {
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }
#endif
}

void PanelWindow::handleAppBarPosChanged()
{
#ifdef Q_OS_WIN
    if (!m_fullscreenActive && !m_desktopLayer && isVisible() && handle()) {
        HWND hwnd = reinterpret_cast<HWND>(winId());
        if (hwnd && IsWindow(hwnd)) {
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }
#endif
}

void PanelWindow::handleAppBarFullscreenHint(bool fsHint)
{
#ifdef Q_OS_WIN
    HWND selfHwnd = handle() ? reinterpret_cast<HWND>(winId()) : nullptr;
    const bool fs = fsHint && !m_desktopLayer && isVisible() && selfHwnd
                        && isGenuineFullscreenForeground(selfHwnd);
    if (m_fullscreenActive != fs) {
        m_fullscreenActive = fs;
        emit fullscreenActiveChanged();
        if (!fs && !m_desktopLayer && isVisible() && selfHwnd) {
            SetWindowPos(selfHwnd, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }
#else
    Q_UNUSED(fsHint);
#endif
}

bool PanelWindow::event(QEvent* e)
{
    const bool res = QQuickWindow::event(e);
#ifdef Q_OS_WIN
    if (e->type() == QEvent::WinIdChange) {
        m_inNativeDrag = false;
        if (handle())
            s_overlayTopmostHwnds.remove(reinterpret_cast<HWND>(winId()));
        unregisterDesktopWindow();
        if (m_desktopLayer && isVisible())
            applyDesktopLayer();
        else if (!m_desktopLayer && isVisible() && handle())
            s_overlayTopmostHwnds.insert(reinterpret_cast<HWND>(winId()));
        if (m_acceptFileDrops && isVisible())
            applyFileDrops();
    } else if (e->type() == QEvent::Show) {
        if (m_desktopLayer)
            applyDesktopLayer();
        else if (handle())
            s_overlayTopmostHwnds.insert(reinterpret_cast<HWND>(winId()));
        if (m_acceptFileDrops)
            applyFileDrops();
    } else if (e->type() == QEvent::Hide) {
        m_inNativeDrag = false;
        if (handle())
            s_overlayTopmostHwnds.remove(reinterpret_cast<HWND>(winId()));
    }
#endif
    return res;
}

bool PanelWindow::nativeEvent(const QByteArray& eventType, void* message, qintptr* result)
{
#ifdef Q_OS_WIN
    if (eventType == "windows_generic_MSG" || eventType == "windows_dispatcher_MSG") {
        const MSG* msg = static_cast<const MSG*>(message);
        if (msg && !m_desktopLayer && msg->message == WM_ACTIVATE && LOWORD(msg->wParam) == WA_INACTIVE) {
            emit windowDeactivated();
        }
        if (msg && m_desktopLayer) {
            if (msg->message == WM_SYSCOMMAND) {
                const WPARAM cmd = msg->wParam & 0xFFF0;
                if (cmd == SC_MINIMIZE || cmd == SC_MAXIMIZE) {
                    if (result)
                        *result = 0;
                    return true;
                }
            } else if (msg->message == WM_MOUSEACTIVATE && !m_desktopAllowFocus) {
                if (result)
                    *result = MA_NOACTIVATE;
                return true;
            } else if (msg->message == WM_WINDOWPOSCHANGING) {
                if (!m_inNativeDrag && !s_inRestack) {
                    auto* pos = reinterpret_cast<WINDOWPOS*>(msg->lParam);
                    if (pos && !(pos->flags & SWP_NOZORDER)) {
                        if (s_showDesktopPromoted) {
                            const HWND lowestTop = lowestOwnTopmostHwnd();
                            pos->hwndInsertAfter = lowestTop ? lowestTop : HWND_TOPMOST;
                        } else {
                            const HWND host = findDesktopHostHwnd();
                            HWND targetAfter = nonWidgetPrevAboveDesktopHost(host, msg->hwnd);
                            if (!targetAfter)
                                targetAfter = lowestNormalAppWindow();
                            if (!targetAfter)
                                targetAfter = findAnyNonTopmostWindowAboveHost(host, msg->hwnd);
                            if (targetAfter)
                                pos->hwndInsertAfter = targetAfter;
                            else
                                pos->hwndInsertAfter = host ? HWND_TOP : HWND_BOTTOM;
                        }
                    }
                }
            }
        }
        if (msg && msg->message == WM_DROPFILES && m_acceptFileDrops) {
            HDROP hDrop = reinterpret_cast<HDROP>(msg->wParam);
            const UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
            QStringList dropped;
            for (UINT i = 0; i < count; ++i) {
                const UINT len = DragQueryFileW(hDrop, i, nullptr, 0);
                if (len == 0)
                    continue;
                QVector<wchar_t> buf(static_cast<int>(len) + 1, 0);
                DragQueryFileW(hDrop, i, buf.data(), len + 1);
                dropped << QString::fromWCharArray(buf.data(), static_cast<int>(len));
            }
            DragFinish(hDrop);
            if (!dropped.isEmpty())
                emit filesDropped(dropped);
            if (result)
                *result = 0;
            return true;
        }
    }
#else
    Q_UNUSED(eventType);
    Q_UNUSED(message);
    Q_UNUSED(result);
#endif
    return QQuickWindow::nativeEvent(eventType, message, result);
}

bool PanelWindow::isPointerOutsideAndPressed() const
{
#ifdef Q_OS_WIN
    const bool down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0
                   || (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
    if (!down)
        return false;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd)
        return false;
    RECT rc{};
    if (!GetWindowRect(hwnd, &rc))
        return false;
    POINT pt{};
    if (!GetCursorPos(&pt))
        return false;
    const bool insideRect = (pt.x >= rc.left && pt.x <= rc.right && pt.y >= rc.top && pt.y <= rc.bottom);
    if (!insideRect)
        return true;
    if (m_hasAppliedMask && !m_lastMask.isEmpty()) {
        const qreal dpr = (devicePixelRatio() > 0.0) ? devicePixelRatio() : 1.0;
        const int localX = qRound((pt.x - rc.left) / dpr);
        const int localY = qRound((pt.y - rc.top) / dpr);
        if (!m_lastMask.contains(QPoint(localX, localY)))
            return true;
    }
    return false;
#else
    return false;
#endif
}

void PanelWindow::setDesktopLayer(bool on)
{
    if (m_desktopLayer == on)
        return;
    m_desktopLayer = on;
    if (on) {
        m_fsGuardTimer.stop();
        if (m_fullscreenActive) {
            m_fullscreenActive = false;
            emit fullscreenActiveChanged();
        }
#ifdef Q_OS_WIN
        if (handle())
            s_overlayTopmostHwnds.remove(reinterpret_cast<HWND>(winId()));
#endif
        setFlags((flags() | Qt::Tool) & ~Qt::WindowStaysOnTopHint);
        applyDesktopLayer();
    } else {
        unregisterDesktopWindow();
        setFlags(flags() | Qt::WindowStaysOnTopHint);
#ifdef Q_OS_WIN
        if (isVisible()) {
            HWND hwnd = reinterpret_cast<HWND>(winId());
            if (hwnd && IsWindow(hwnd)) {
                s_overlayTopmostHwnds.insert(hwnd);
                LONG_PTR exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                exStyle &= ~WS_EX_NOACTIVATE;
                SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle);
                BOOL excl = FALSE;
                DwmSetWindowAttribute(hwnd, 12 /*DWMWA_EXCLUDED_FROM_PEEK*/, &excl, sizeof(excl));
                SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                             SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            }
            verifyFullscreenState();
            if (!s_globalHibernated)
                m_fsGuardTimer.start();
        }
#endif
    }
    emit desktopLayerChanged();
}

void PanelWindow::setDesktopAllowFocus(bool on)
{
    if (m_desktopAllowFocus == on)
        return;
    m_desktopAllowFocus = on;
#ifdef Q_OS_WIN
    if (m_desktopLayer && isVisible()) {
        HWND hwnd = reinterpret_cast<HWND>(winId());
        if (hwnd && IsWindow(hwnd)) {
            LONG_PTR exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            if (m_desktopAllowFocus)
                exStyle &= ~WS_EX_NOACTIVATE;
            else
                exStyle |= WS_EX_NOACTIVATE;
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle);
        }
    }
#endif
    emit desktopAllowFocusChanged();
}

void PanelWindow::applyDesktopLayer()
{
#ifdef Q_OS_WIN
    if (!m_desktopLayer || !isVisible())
        return;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd || !IsWindow(hwnd))
        return;

    if (m_desktopHwnd && m_desktopHwnd != hwnd)
        unregisterDesktopWindow();

    m_desktopHwnd = hwnd;
    s_desktopHwnds.insert(hwnd);
    if (!s_desktopWindows.contains(this))
        s_desktopWindows.append(this);
    ensureDesktopHooksInstalled();

    LONG_PTR exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    exStyle |= WS_EX_TOOLWINDOW;
    if (m_desktopAllowFocus)
        exStyle &= ~WS_EX_NOACTIVATE;
    else
        exStyle |= WS_EX_NOACTIVATE;
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle);

    BOOL excl = TRUE;
    DwmSetWindowAttribute(hwnd, 12 /*DWMWA_EXCLUDED_FROM_PEEK*/, &excl, sizeof(excl));

    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    restackOnDesktop();
#endif
}

void PanelWindow::restackOnDesktop()
{
#ifdef Q_OS_WIN
    if (!m_desktopLayer || !isVisible() || m_inNativeDrag)
        return;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd || !IsWindow(hwnd))
        return;
    const bool prevInRestack = s_inRestack;
    s_inRestack = true;
    const HWND host = findDesktopHostHwnd();
    const bool showDesk = isShowDesktopActive(host);
    s_showDesktopPromoted = showDesk;
    const HWND lowestTop = showDesk ? lowestOwnTopmostHwnd() : nullptr;
    applySingleDesktopZOrder(hwnd, host, showDesk, lowestTop);
    s_inRestack = prevInRestack;
#endif
}

void PanelWindow::unregisterDesktopWindow()
{
#ifdef Q_OS_WIN
    s_desktopWindows.removeAll(this);
    if (m_desktopHwnd) {
        s_desktopHwnds.remove(static_cast<HWND>(m_desktopHwnd));
        m_desktopHwnd = nullptr;
    }
    cleanupDesktopHooksIfEmpty();
#endif
}

void PanelWindow::raiseOnDesktop()
{
#ifdef Q_OS_WIN
    restackOnDesktop();
#endif
}

void PanelWindow::setAcceptFileDrops(bool on)
{
    if (m_acceptFileDrops == on)
        return;
    m_acceptFileDrops = on;
    applyFileDrops();
    emit acceptFileDropsChanged();
}

void PanelWindow::applyFileDrops()
{
#ifdef Q_OS_WIN
    if (!isVisible())
        return;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd || !IsWindow(hwnd))
        return;
    if (m_acceptFileDrops) {
        // Qt DropArea / OLE IDropTarget suppresses legacy WM_DROPFILES and fails across UIPI;
        // revoke any OLE drop target before enabling WM_DROPFILES + UIPI message filter.
        RevokeDragDrop(hwnd);
        using FnFilterEx = BOOL(WINAPI*)(HWND, UINT, DWORD, void*);
        static auto fnFilter = reinterpret_cast<FnFilterEx>(
            GetProcAddress(GetModuleHandleW(L"user32.dll"), "ChangeWindowMessageFilterEx"));
        if (fnFilter) {
            // Allow drag-drop from medium-integrity Explorer even if SekaiDesk runs elevated
            fnFilter(hwnd, WM_DROPFILES, 1 /*MSGFLT_ALLOW*/, nullptr);
            fnFilter(hwnd, WM_COPYDATA, 1 /*MSGFLT_ALLOW*/, nullptr);
            fnFilter(hwnd, 0x0049 /*WM_COPYGLOBALDATA*/, 1 /*MSGFLT_ALLOW*/, nullptr);
        }
    }
    DragAcceptFiles(hwnd, m_acceptFileDrops ? TRUE : FALSE);
#endif
}

void PanelWindow::focusActivate()
{
#ifdef Q_OS_WIN
    HWND hwnd = handle() ? reinterpret_cast<HWND>(winId()) : nullptr;
    if (hwnd && IsWindow(hwnd)) {
        HWND fg = GetForegroundWindow();
        const DWORD fgTid = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
        const DWORD curTid = GetCurrentThreadId();
        const bool attached = (fgTid != 0 && fgTid != curTid)
                              && (AttachThreadInput(fgTid, curTid, TRUE) != FALSE);
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        SetActiveWindow(hwnd);
        if (attached)
            AttachThreadInput(fgTid, curTid, FALSE);
    }
#endif
    requestActivate();
}

void PanelWindow::beginNativeDrag(int minLogicalX, int minLogicalY, int maxLogicalX, int maxLogicalY)
{
#ifdef Q_OS_WIN
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd || !IsWindow(hwnd))
        return;
    POINT pt{};
    if (!GetCursorPos(&pt))
        return;
    RECT rc{};
    if (!GetWindowRect(hwnd, &rc))
        return;

    const qreal dpr = (devicePixelRatio() > 0.0) ? devicePixelRatio() : 1.0;
    const int virtLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int virtTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int virtRight = virtLeft + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int virtBottom = virtTop + GetSystemMetrics(SM_CYVIRTUALSCREEN);
    const int winW = qMax(1, static_cast<int>(rc.right - rc.left));
    const int winH = qMax(1, static_cast<int>(rc.bottom - rc.top));

    int minPxX = 0;
    int minPxY = 0;
    int maxPxX = 0;
    int maxPxY = 0;

    if (virtRight > virtLeft && virtBottom > virtTop) {
        const int padPx = qMax(4, qRound(8 * dpr));
        const int minVisW = qMin(winW, qMax(80, qRound(100 * dpr)));
        const int minVisH = qMin(winH, qMax(60, qRound(80 * dpr)));
        minPxX = virtLeft + padPx;
        minPxY = virtTop + padPx;
        maxPxX = qMax(minPxX, virtRight - minVisW);
        maxPxY = qMax(minPxY, virtBottom - minVisH);

        // Apply caller's logical bounds only when a single monitor is active; on multi-monitor
        // setups widgets can cross freely across monitors regardless of primary screen size.
        if (QGuiApplication::screens().size() <= 1) {
            const QScreen* pri = QGuiApplication::primaryScreen();
            const qreal priDpr = (pri && pri->devicePixelRatio() > 0.0) ? pri->devicePixelRatio() : dpr;
            const int reqMinX = qRound(minLogicalX * priDpr);
            const int reqMinY = qRound(minLogicalY * priDpr);
            const int reqMaxX = qRound(maxLogicalX * priDpr);
            const int reqMaxY = qRound(maxLogicalY * priDpr);
            minPxX = qBound(virtLeft, reqMinX, maxPxX);
            minPxY = qBound(virtTop, reqMinY, maxPxY);
            maxPxX = qBound(minPxX, reqMaxX, maxPxX);
            maxPxY = qBound(minPxY, reqMaxY, maxPxY);
        }
    } else {
        minPxX = qRound(minLogicalX * dpr);
        minPxY = qRound(minLogicalY * dpr);
        maxPxX = qMax(minPxX, qRound(maxLogicalX * dpr));
        maxPxY = qMax(minPxY, qRound(maxLogicalY * dpr));
    }

    m_dragStartCursorPxX = pt.x;
    m_dragStartCursorPxY = pt.y;
    m_dragStartWinPxX = rc.left;
    m_dragStartWinPxY = rc.top;
    m_dragMinPxX = minPxX;
    m_dragMinPxY = minPxY;
    m_dragMaxPxX = maxPxX;
    m_dragMaxPxY = maxPxY;
    m_inNativeDrag = true;
#else
    Q_UNUSED(minLogicalX);
    Q_UNUSED(minLogicalY);
    Q_UNUSED(maxLogicalX);
    Q_UNUSED(maxLogicalY);
#endif
}

void PanelWindow::stepNativeDrag()
{
#ifdef Q_OS_WIN
    if (!m_inNativeDrag)
        return;
    HWND hwnd = reinterpret_cast<HWND>(winId());
    if (!hwnd || !IsWindow(hwnd))
        return;
    POINT cur{};
    if (!GetCursorPos(&cur))
        return;

    const int tx = qBound(m_dragMinPxX,
                          m_dragStartWinPxX + static_cast<int>(cur.x - m_dragStartCursorPxX),
                          m_dragMaxPxX);
    const int ty = qBound(m_dragMinPxY,
                          m_dragStartWinPxY + static_cast<int>(cur.y - m_dragStartCursorPxY),
                          m_dragMaxPxY);
    SetWindowPos(hwnd, nullptr, tx, ty, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
#endif
}

void PanelWindow::endNativeDrag()
{
    m_inNativeDrag = false;
}
