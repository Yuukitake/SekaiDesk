#include "AppLauncher.h"
#include "core/SettingsStore.h"

#include <QDateTime>
#include <QDirIterator>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QVariantMap>
#include <algorithm>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <propsys.h>
#include <objbase.h>

namespace {
QString expandEnvVars(const QString& raw)
{
    if (raw.isEmpty())
        return {};
    wchar_t expanded[MAX_PATH * 4] = {};
    const DWORD n = ExpandEnvironmentStringsW(
        reinterpret_cast<const wchar_t*>(raw.utf16()),
        expanded, MAX_PATH * 4);
    if (n > 0 && n < MAX_PATH * 4)
        return QString::fromWCharArray(expanded);
    return raw;
}

bool isUriOrShellTarget(const QString& target)
{
    if (target.startsWith(QStringLiteral("ms-settings:"), Qt::CaseInsensitive)
        || target.startsWith(QStringLiteral("shell:"), Qt::CaseInsensitive)) {
        return true;
    }
    return target.contains(QStringLiteral("://"));
}

struct ResolvedTarget {
    QString inputPath;
    QString resolvedPath;
    QString shortcutArgs;
    QString workingDir;
    bool isUriOrShell = false;
    bool isShortcut = false;
    bool inputExists = false;
    bool inputIsDir = false;
    bool targetExists = false;
    bool targetIsDir = false;
};

ResolvedTarget resolveTargetDetails(const QString& rawTarget)
{
    ResolvedTarget out;
    QString clean = rawTarget.trimmed();
    if (clean.size() >= 2 && clean.startsWith(QLatin1Char('"')) && clean.endsWith(QLatin1Char('"')))
        clean = clean.mid(1, clean.size() - 2).trimmed();
    if (clean.isEmpty())
        return out;

    if (isUriOrShellTarget(clean)) {
        out.isUriOrShell = true;
        out.inputPath = clean;
        out.resolvedPath = clean;
        return out;
    }

    clean = QDir::toNativeSeparators(expandEnvVars(clean).trimmed());
    if (!clean.contains(QLatin1Char('\\')) && !clean.contains(QLatin1Char('/'))
        && !clean.contains(QLatin1Char(':'))) {
        wchar_t found[MAX_PATH * 2] = {};
        if (SearchPathW(nullptr,
                        reinterpret_cast<const wchar_t*>(clean.utf16()),
                        nullptr, MAX_PATH * 2, found, nullptr) > 0) {
            clean = QDir::toNativeSeparators(QString::fromWCharArray(found));
        }
    }

    out.inputPath = clean;
    out.resolvedPath = clean;

    const QFileInfo inputFi(out.inputPath);
    out.inputExists = inputFi.exists();
    out.inputIsDir = inputFi.isDir();

    if (out.inputExists && !out.inputIsDir
        && inputFi.suffix().compare(QStringLiteral("lnk"), Qt::CaseInsensitive) == 0) {
        out.isShortcut = true;
        out.resolvedPath.clear();

        static const CLSID kCLSID_ShellLink = {
            0x00021401, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}
        };
        static const IID kIID_IShellLinkW = {
            0x000214F9, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}
        };
        static const IID kIID_IPersistFile = {
            0x0000010B, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}
        };

        const HRESULT hrCom = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        IShellLinkW* psl = nullptr;
        if (SUCCEEDED(CoCreateInstance(kCLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                       kIID_IShellLinkW, reinterpret_cast<void**>(&psl))) && psl) {
            IPersistFile* ppf = nullptr;
            if (SUCCEEDED(psl->QueryInterface(kIID_IPersistFile, reinterpret_cast<void**>(&ppf))) && ppf) {
                if (SUCCEEDED(ppf->Load(reinterpret_cast<const wchar_t*>(out.inputPath.utf16()), STGM_READ))) {
                    wchar_t targetBuf[MAX_PATH * 4] = {};
                    HRESULT hrPath = psl->GetPath(targetBuf, MAX_PATH * 4, nullptr, 0);
                    if (FAILED(hrPath) || targetBuf[0] == L'\0') {
                        targetBuf[0] = L'\0';
                        hrPath = psl->GetPath(targetBuf, MAX_PATH * 4, nullptr, SLGP_RAWPATH);
                    }
                    if (SUCCEEDED(hrPath) && targetBuf[0] != L'\0') {
                        const QString expanded = expandEnvVars(QString::fromWCharArray(targetBuf)).trimmed();
                        if (!expanded.isEmpty())
                            out.resolvedPath = QDir::toNativeSeparators(expanded);
                    }

                    wchar_t argBuf[2048] = {};
                    if (SUCCEEDED(psl->GetArguments(argBuf, 2048)) && argBuf[0] != L'\0')
                        out.shortcutArgs = QString::fromWCharArray(argBuf).trimmed();

                    wchar_t dirBuf[MAX_PATH * 4] = {};
                    if (SUCCEEDED(psl->GetWorkingDirectory(dirBuf, MAX_PATH * 4)) && dirBuf[0] != L'\0') {
                        out.workingDir = QDir::toNativeSeparators(
                            expandEnvVars(QString::fromWCharArray(dirBuf)).trimmed());
                    }
                }
                ppf->Release();
            }
            psl->Release();
        }
        if (SUCCEEDED(hrCom))
            CoUninitialize();
    }

    if (!out.resolvedPath.isEmpty()) {
        const QFileInfo targetFi(out.resolvedPath);
        out.targetExists = targetFi.exists();
        out.targetIsDir = targetFi.isDir();
        if (out.workingDir.isEmpty() && out.targetExists) {
            out.workingDir = out.targetIsDir
                ? out.resolvedPath
                : QDir::toNativeSeparators(targetFi.absolutePath());
        }
    }

    return out;
}

bool shellExecuteVerb(const wchar_t* verb, const QString& file,
                      const QString& args, const QString& workDir)
{
    if (file.isEmpty())
        return false;
    SHELLEXECUTEINFOW sei = {};
    sei.cbSize = sizeof(sei);
    sei.fMask = 0;
    sei.lpVerb = verb;
    sei.lpFile = reinterpret_cast<const wchar_t*>(file.utf16());
    sei.lpParameters = args.isEmpty() ? nullptr : reinterpret_cast<const wchar_t*>(args.utf16());
    sei.lpDirectory = workDir.isEmpty() ? nullptr : reinterpret_cast<const wchar_t*>(workDir.utf16());
    sei.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&sei) != FALSE;
}

QString combineArgs(const QString& shortcutArgs, const QString& extraArgs)
{
    const QString a = shortcutArgs.trimmed();
    const QString b = extraArgs.trimmed();
    if (a.isEmpty())
        return b;
    if (b.isEmpty())
        return a;
    return a + QLatin1Char(' ') + b;
}
} // namespace
#endif

AppLauncher::AppLauncher(SettingsStore* settings, QObject* parent)
    : QObject(parent)
    , m_settings(settings)
{
    reload();
    refreshInstalledApps();
}

void AppLauncher::reload()
{
    m_pinnedApps.clear();
    m_customApps.clear();
    m_drawerFolders.clear();
    bool hasKey = false;
    if (m_settings) {
        hasKey = m_settings->has(QStringLiteral("dock.pinnedApps"));
        const QVariant raw = m_settings->get(QStringLiteral("dock.pinnedApps"));
        if (raw.canConvert<QVariantList>()) {
            for (const QVariant& v : raw.toList()) {
                if (v.toMap().value(QStringLiteral("kind")).toString() != QStringLiteral("separator"))
                    m_pinnedApps << v;
            }
        }
        const QVariant rawCustom = m_settings->get(QStringLiteral("launcher.customApps"));
        if (rawCustom.canConvert<QVariantList>())
            m_customApps = rawCustom.toList();
        const QVariant rawFolders = m_settings->get(QStringLiteral("launcher.folders"));
        if (rawFolders.canConvert<QVariantList>())
            m_drawerFolders = rawFolders.toList();
        m_usageCounts = m_settings->get(QStringLiteral("launcher.usage")).toMap();
        m_hiddenApps = m_settings->get(QStringLiteral("launcher.hiddenApps")).toMap();
    }
    if (!hasKey)
        seedDefaultsIfEmpty();
    emit pinnedAppsChanged();
    emit hiddenAppsChanged();
    emit drawerFoldersChanged();
}

void AppLauncher::seedDefaultsIfEmpty()
{
    if (!m_pinnedApps.isEmpty())
        return;

    auto makeEntry = [](const QString& name, const QString& target,
                        const QString& args = {}) {
        QVariantMap m;
        m.insert(QStringLiteral("name"), name);
        m.insert(QStringLiteral("target"), target);
        if (!args.isEmpty())
            m.insert(QStringLiteral("args"), args);
        return QVariant(m);
    };

    m_pinnedApps << makeEntry(QStringLiteral("Files"),
                              QStringLiteral("C:\\Windows\\explorer.exe"));

#ifdef Q_OS_WIN
    wchar_t wtPath[MAX_PATH] = {};
    if (SearchPathW(nullptr, L"wt.exe", nullptr, MAX_PATH, wtPath, nullptr) > 0) {
        m_pinnedApps << makeEntry(QStringLiteral("Terminal"),
                                  QString::fromWCharArray(wtPath));
    } else {
        m_pinnedApps << makeEntry(QStringLiteral("Terminal"),
                                  QStringLiteral("C:\\Windows\\System32\\cmd.exe"));
    }

    const QString edge32 = QStringLiteral("C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe");
    const QString edge64 = QStringLiteral("C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe");
    if (QFileInfo::exists(edge64))
        m_pinnedApps << makeEntry(QStringLiteral("Edge"), edge64);
    else if (QFileInfo::exists(edge32))
        m_pinnedApps << makeEntry(QStringLiteral("Edge"), edge32);
#else
    m_pinnedApps << makeEntry(QStringLiteral("Terminal"),
                              QStringLiteral("cmd.exe"));
#endif

    m_pinnedApps << makeEntry(QStringLiteral("Notepad"),
                              QStringLiteral("C:\\Windows\\System32\\notepad.exe"));
    m_pinnedApps << makeEntry(QStringLiteral("Calculator"),
                              QStringLiteral("C:\\Windows\\System32\\calc.exe"));
    m_pinnedApps << makeEntry(QStringLiteral("Settings"),
                              QStringLiteral("ms-settings:"));

    savePinnedApps();
}

void AppLauncher::savePinnedApps()
{
    if (m_settings)
        m_settings->set(QStringLiteral("dock.pinnedApps"), m_pinnedApps);
}

void AppLauncher::saveHiddenApps()
{
    if (m_settings)
        m_settings->set(QStringLiteral("launcher.hiddenApps"), m_hiddenApps);
}

void AppLauncher::saveCustomApps()
{
    if (m_settings)
        m_settings->set(QStringLiteral("launcher.customApps"), m_customApps);
}

void AppLauncher::saveDrawerFolders()
{
    if (m_settings)
        m_settings->set(QStringLiteral("launcher.folders"), m_drawerFolders);
}

bool AppLauncher::stripTargetFromFolders(const QString& normTarget, const QString& keepFolderId)
{
    if (normTarget.isEmpty())
        return false;
    bool changed = false;
    QVariantList next;
    for (const QVariant& fv : m_drawerFolders) {
        QVariantMap fm = fv.toMap();
        const QString fid = fm.value(QStringLiteral("id")).toString();
        if (!keepFolderId.isEmpty() && fid == keepFolderId) {
            next.append(fm);
            continue;
        }
        const QVariantList apps = fm.value(QStringLiteral("apps")).toList();
        QVariantList filtered;
        bool folderTouched = false;
        for (const QVariant& av : apps) {
            if (av.toString().trimmed().toLower() == normTarget) {
                folderTouched = true;
                changed = true;
            } else {
                filtered.append(av);
            }
        }
        if (filtered.isEmpty()) {
            changed = true;
            continue;
        }
        if (folderTouched)
            fm.insert(QStringLiteral("apps"), filtered);
        next.append(fm);
    }
    if (changed)
        m_drawerFolders = next;
    return changed;
}

void AppLauncher::recordUsage(const QString& target)
{
    const QString key = target.trimmed().toLower();
    if (key.isEmpty())
        return;
    m_usageCounts.insert(key, m_usageCounts.value(key, 0).toInt() + 1);
    if (m_settings)
        m_settings->set(QStringLiteral("launcher.usage"), m_usageCounts);
}

bool AppLauncher::launch(const QString& target, const QString& args)
{
    const QString cleanTarget = target.trimmed();
    if (cleanTarget.isEmpty())
        return false;

#ifdef Q_OS_WIN
    if (cleanTarget.startsWith(QStringLiteral("shell:"), Qt::CaseInsensitive)) {
        const HINSTANCE res = ShellExecuteW(
            nullptr,
            L"open",
            L"explorer.exe",
            reinterpret_cast<const wchar_t*>(cleanTarget.utf16()),
            nullptr,
            SW_SHOWNORMAL);
        const auto code = reinterpret_cast<INT_PTR>(res);
        if (code <= 32) {
            qWarning("AppLauncher: explorer launch(%s) failed with code %lld",
                     qPrintable(cleanTarget), static_cast<long long>(code));
            return false;
        }
        recordUsage(target);
        return true;
    }

    const HINSTANCE res = ShellExecuteW(
        nullptr,
        L"open",
        reinterpret_cast<const wchar_t*>(cleanTarget.utf16()),
        args.isEmpty() ? nullptr : reinterpret_cast<const wchar_t*>(args.utf16()),
        nullptr,
        SW_SHOWNORMAL);

    const auto code = reinterpret_cast<INT_PTR>(res);
    if (code <= 32) {
        qWarning("AppLauncher: ShellExecuteW(%s) failed with code %lld",
                 qPrintable(target), static_cast<long long>(code));
        return false;
    }
    recordUsage(target);
    return true;
#else
    Q_UNUSED(args);
    return false;
#endif
}

bool AppLauncher::runAsDifferentUser(const QString& target, const QString& args)
{
#ifdef Q_OS_WIN
    if (target.trimmed().isEmpty())
        return false;
    const ResolvedTarget details = resolveTargetDetails(target);
    if (details.isUriOrShell || details.resolvedPath.isEmpty()
        || !details.targetExists || details.targetIsDir) {
        return false;
    }
    const QString combinedArgs = combineArgs(details.shortcutArgs, args);
    if (!shellExecuteVerb(L"runasuser", details.resolvedPath, combinedArgs, details.workingDir))
        return false;
    recordUsage(target);
    return true;
#else
    Q_UNUSED(target);
    Q_UNUSED(args);
    return false;
#endif
}

bool AppLauncher::runElevated(const QString& target, const QString& args)
{
#ifdef Q_OS_WIN
    const QString raw = target.trimmed();
    if (raw.isEmpty())
        return false;
    const ResolvedTarget details = resolveTargetDetails(raw);
    const bool useResolved = !details.isUriOrShell && !details.resolvedPath.isEmpty()
                             && details.targetExists && !details.targetIsDir;
    const QString execFile = useResolved ? details.resolvedPath : raw;
    const QString combinedArgs = useResolved
        ? combineArgs(details.shortcutArgs, args)
        : args.trimmed();
    if (!shellExecuteVerb(L"runas", execFile, combinedArgs, details.workingDir))
        return false;
    recordUsage(target);
    return true;
#else
    Q_UNUSED(target);
    Q_UNUSED(args);
    return false;
#endif
}

bool AppLauncher::openContainingFolder(const QString& target)
{
#ifdef Q_OS_WIN
    const ResolvedTarget details = resolveTargetDetails(target);
    if (details.isUriOrShell || details.inputPath.isEmpty() || !details.inputExists)
        return false;
    const QString arg = QStringLiteral("/select,\"%1\"").arg(details.inputPath);
    const HINSTANCE res = ShellExecuteW(
        nullptr, L"open", L"explorer.exe",
        reinterpret_cast<const wchar_t*>(arg.utf16()),
        nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<INT_PTR>(res) > 32;
#else
    Q_UNUSED(target);
    return false;
#endif
}

bool AppLauncher::openTargetFolder(const QString& target)
{
#ifdef Q_OS_WIN
    const ResolvedTarget details = resolveTargetDetails(target);
    if (details.isUriOrShell || details.resolvedPath.isEmpty() || !details.targetExists)
        return false;
    if (details.targetIsDir) {
        const HINSTANCE res = ShellExecuteW(
            nullptr, L"open",
            reinterpret_cast<const wchar_t*>(details.resolvedPath.utf16()),
            nullptr, nullptr, SW_SHOWNORMAL);
        return reinterpret_cast<INT_PTR>(res) > 32;
    }
    const QString arg = QStringLiteral("/select,\"%1\"").arg(details.resolvedPath);
    const HINSTANCE res = ShellExecuteW(
        nullptr, L"open", L"explorer.exe",
        reinterpret_cast<const wchar_t*>(arg.utf16()),
        nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<INT_PTR>(res) > 32;
#else
    Q_UNUSED(target);
    return false;
#endif
}

bool AppLauncher::revealInExplorer(const QString& target)
{
    return openContainingFolder(target);
}

void AppLauncher::hideApp(const QString& target, const QString& name)
{
    const QString key = target.trimmed().toLower();
    if (key.isEmpty())
        return;
    QString displayName = name.trimmed();
    if (displayName.isEmpty()) {
        const QString base = QFileInfo(target.trimmed()).completeBaseName();
        displayName = base.isEmpty() ? target.trimmed() : base;
    }
    m_hiddenApps.insert(key, displayName);
    saveHiddenApps();
    emit hiddenAppsChanged();
}

void AppLauncher::unhideApp(const QString& target)
{
    const QString key = target.trimmed().toLower();
    if (key.isEmpty() || !m_hiddenApps.contains(key))
        return;
    m_hiddenApps.remove(key);
    saveHiddenApps();
    emit hiddenAppsChanged();
}

void AppLauncher::clearHiddenApps()
{
    if (m_hiddenApps.isEmpty())
        return;
    m_hiddenApps.clear();
    saveHiddenApps();
    emit hiddenAppsChanged();
}

bool AppLauncher::isHidden(const QString& target) const
{
    const QString key = target.trimmed().toLower();
    return !key.isEmpty() && m_hiddenApps.contains(key);
}

QVariantList AppLauncher::hiddenApps() const
{
    QVariantList out;
    out.reserve(m_hiddenApps.size());
    for (auto it = m_hiddenApps.constBegin(); it != m_hiddenApps.constEnd(); ++it) {
        QVariantMap m;
        m.insert(QStringLiteral("name"), it.value().toString());
        m.insert(QStringLiteral("target"), it.key());
        out.append(m);
    }
    std::sort(out.begin(), out.end(), [](const QVariant& a, const QVariant& b) {
        const QString na = a.toMap().value(QStringLiteral("name")).toString().toLower();
        const QString nb = b.toMap().value(QStringLiteral("name")).toString().toLower();
        if (na != nb)
            return na < nb;
        return a.toMap().value(QStringLiteral("target")).toString()
             < b.toMap().value(QStringLiteral("target")).toString();
    });
    return out;
}

QVariantMap AppLauncher::inspectTarget(const QString& target) const
{
    QVariantMap caps;
#ifdef Q_OS_WIN
    const ResolvedTarget details = resolveTargetDetails(target);
    const bool isLocal = !details.isUriOrShell && (details.inputExists || details.targetExists);
    const bool isDir = details.isShortcut ? details.targetIsDir : details.inputIsDir;
    const QString suffix = details.resolvedPath.isEmpty()
        ? QString()
        : QFileInfo(details.resolvedPath).suffix().toLower();
    const bool canRunAsUser = !details.isUriOrShell && details.targetExists
                              && !details.targetIsDir && suffix == QStringLiteral("exe");
    const bool canElevate = !details.isUriOrShell && details.targetExists
                            && !details.targetIsDir
                            && (suffix == QStringLiteral("exe")
                                || suffix == QStringLiteral("bat")
                                || suffix == QStringLiteral("cmd")
                                || suffix == QStringLiteral("msc")
                                || suffix == QStringLiteral("msi"));
    const bool canOpenContaining = !details.isUriOrShell && details.inputExists;
    const bool canOpenTarget = !details.isUriOrShell && details.targetExists;

    caps.insert(QStringLiteral("isLocal"), isLocal);
    caps.insert(QStringLiteral("isShortcut"), details.isShortcut);
    caps.insert(QStringLiteral("isDir"), isDir);
    caps.insert(QStringLiteral("canRunAsUser"), canRunAsUser);
    caps.insert(QStringLiteral("canElevate"), canElevate);
    caps.insert(QStringLiteral("canOpenContaining"), canOpenContaining);
    caps.insert(QStringLiteral("canOpenTarget"), canOpenTarget);
#else
    Q_UNUSED(target);
    caps.insert(QStringLiteral("isLocal"), false);
    caps.insert(QStringLiteral("isShortcut"), false);
    caps.insert(QStringLiteral("isDir"), false);
    caps.insert(QStringLiteral("canRunAsUser"), false);
    caps.insert(QStringLiteral("canElevate"), false);
    caps.insert(QStringLiteral("canOpenContaining"), false);
    caps.insert(QStringLiteral("canOpenTarget"), false);
#endif
    return caps;
}

void AppLauncher::addPinnedApp(const QString& name, const QString& target,
                               const QString& args)
{
    const QString norm = target.trimmed().toLower();
    for (const QVariant& v : m_pinnedApps) {
        if (v.toMap().value(QStringLiteral("target")).toString().trimmed().toLower() == norm)
            return;
    }
    QVariantMap m;
    m.insert(QStringLiteral("name"), name);
    m.insert(QStringLiteral("target"), target);
    if (!args.isEmpty())
        m.insert(QStringLiteral("args"), args);
    m_pinnedApps << m;
    savePinnedApps();
    emit pinnedAppsChanged();
}

void AppLauncher::removePinnedApp(int index)
{
    if (index < 0 || index >= m_pinnedApps.size())
        return;
    m_pinnedApps.removeAt(index);
    savePinnedApps();
    emit pinnedAppsChanged();
}

void AppLauncher::removePinnedByTarget(const QString& target)
{
    const QString norm = target.trimmed().toLower();
    for (int i = m_pinnedApps.size() - 1; i >= 0; --i) {
        const QString t = m_pinnedApps.at(i).toMap().value(QStringLiteral("target")).toString().trimmed().toLower();
        if (t == norm) {
            m_pinnedApps.removeAt(i);
            savePinnedApps();
            emit pinnedAppsChanged();
            return;
        }
    }
}

void AppLauncher::movePinnedApp(int fromIndex, int toIndex)
{
    const int n = m_pinnedApps.size();
    if (fromIndex < 0 || fromIndex >= n || toIndex < 0 || toIndex >= n || fromIndex == toIndex)
        return;
    m_pinnedApps.move(fromIndex, toIndex);
    savePinnedApps();
    emit pinnedAppsChanged();
}

void AppLauncher::insertSeparatorAt(int index)
{
    const int clamped = qBound(0, index, m_pinnedApps.size());
    QVariantMap sep;
    sep.insert(QStringLiteral("kind"), QStringLiteral("separator"));
    m_pinnedApps.insert(clamped, sep);
    savePinnedApps();
    emit pinnedAppsChanged();
}

void AppLauncher::pinAppAt(const QString& name, const QString& target,
                           const QString& args, int index)
{
    const QString norm = target.trimmed().toLower();
    for (int i = 0; i < m_pinnedApps.size(); ++i) {
        if (m_pinnedApps.at(i).toMap().value(QStringLiteral("target")).toString().trimmed().toLower() == norm) {
            movePinnedApp(i, qBound(0, index, m_pinnedApps.size() - 1));
            return;
        }
    }
    QVariantMap m;
    m.insert(QStringLiteral("name"), name);
    m.insert(QStringLiteral("target"), target);
    if (!args.isEmpty())
        m.insert(QStringLiteral("args"), args);
    const int clamped = qBound(0, index, m_pinnedApps.size());
    m_pinnedApps.insert(clamped, m);
    savePinnedApps();
    emit pinnedAppsChanged();
}

void AppLauncher::reorderDock(const QVariantList& currentAppItems,
                              int fromIndex, int toIndex)
{
    const int n = currentAppItems.size();
    if (fromIndex < 0 || fromIndex >= n || toIndex < 0 || toIndex >= n || fromIndex == toIndex)
        return;

    QVariantList reordered = currentAppItems;
    reordered.move(fromIndex, toIndex);

    int cutoff = toIndex;
    for (int i = n - 1; i >= 0; --i) {
        if (reordered.at(i).toMap().value(QStringLiteral("pinned")).toBool()) {
            cutoff = qMax(cutoff, i);
            break;
        }
    }

    QVariantList nextPinned;
    QSet<QString> seen;
    for (int i = 0; i <= cutoff; ++i) {
        const QVariantMap src = reordered.at(i).toMap();
        const QString target = src.value(QStringLiteral("target")).toString().trimmed();
        const QString key = target.toLower();
        if (target.isEmpty() || seen.contains(key))
            continue;
        seen.insert(key);

        QVariantMap entry;
        entry.insert(QStringLiteral("name"), src.value(QStringLiteral("name")).toString());
        entry.insert(QStringLiteral("target"), target);
        const QString args = src.value(QStringLiteral("args")).toString();
        if (!args.isEmpty())
            entry.insert(QStringLiteral("args"), args);
        nextPinned.append(entry);
    }

    m_pinnedApps = nextPinned;
    savePinnedApps();
    emit pinnedAppsChanged();
}

static QString displayNameForDroppedPath(const QFileInfo& fi)
{
    if (fi.isDir()) {
        const QString dirName = fi.fileName();
        return dirName.isEmpty() ? QDir::toNativeSeparators(fi.absoluteFilePath()) : dirName;
    }
    const QString ext = fi.suffix().toLower();
    if (ext == QStringLiteral("lnk") || ext == QStringLiteral("url")
        || ext == QStringLiteral("exe") || ext == QStringLiteral("bat")
        || ext == QStringLiteral("cmd") || ext == QStringLiteral("msc")) {
        const QString base = fi.completeBaseName();
        if (!base.isEmpty())
            return base;
    }
    const QString fn = fi.fileName();
    return fn.isEmpty() ? QDir::toNativeSeparators(fi.absoluteFilePath()) : fn;
}

int AppLauncher::pinDroppedFiles(const QStringList& paths)
{
    int added = 0;
    for (const QString& raw : paths) {
        const QString clean = raw.trimmed();
        if (clean.isEmpty())
            continue;
        const QFileInfo fi(clean);
        if (!fi.exists())
            continue;
        const QString nativeTarget = QDir::toNativeSeparators(fi.absoluteFilePath());
        const QString norm = nativeTarget.toLower();
        bool exists = false;
        for (const QVariant& v : m_pinnedApps) {
            if (v.toMap().value(QStringLiteral("target")).toString().trimmed().toLower() == norm) {
                exists = true;
                break;
            }
        }
        if (exists)
            continue;
        addPinnedApp(displayNameForDroppedPath(fi), nativeTarget, QString());
        ++added;
    }
    return added;
}

bool AppLauncher::addCustomApp(const QString& path)
{
    const QString clean = path.trimmed();
    if (clean.isEmpty())
        return false;
    const QFileInfo fi(clean);
    if (!fi.exists())
        return false;

    const QString nativeTarget = QDir::toNativeSeparators(fi.absoluteFilePath());
    const QString norm = nativeTarget.toLower();
    const QString name = displayNameForDroppedPath(fi);

    if (isHidden(nativeTarget))
        unhideApp(nativeTarget);

    for (const QVariant& v : m_customApps) {
        if (v.toMap().value(QStringLiteral("target")).toString().trimmed().toLower() == norm)
            return false;
    }
    QVariantMap entry;
    entry.insert(QStringLiteral("name"), name);
    entry.insert(QStringLiteral("target"), nativeTarget);
    m_customApps.append(entry);
    saveCustomApps();
    refreshInstalledApps();
    return true;
}

void AppLauncher::removeCustomApp(const QString& target)
{
    const QString norm = target.trimmed().toLower();
    if (norm.isEmpty())
        return;
    bool removed = false;
    for (int i = m_customApps.size() - 1; i >= 0; --i) {
        if (m_customApps.at(i).toMap().value(QStringLiteral("target")).toString().trimmed().toLower() == norm) {
            m_customApps.removeAt(i);
            removed = true;
        }
    }
    if (removed) {
        saveCustomApps();
        refreshInstalledApps();
    }
}

QString AppLauncher::createFolder(const QString& name, const QString& targetA,
                                  const QString& targetB)
{
    const QString ta = targetA.trimmed();
    const QString tb = targetB.trimmed();
    const QString na = ta.toLower();
    const QString nb = tb.toLower();
    if (na.isEmpty() || nb.isEmpty() || na == nb)
        return {};

    stripTargetFromFolders(na);
    stripTargetFromFolders(nb);

    const QString fid = QStringLiteral("fld_%1").arg(QDateTime::currentMSecsSinceEpoch());
    QString cleanName = name.trimmed();
    if (cleanName.isEmpty())
        cleanName = QStringLiteral("Folder");

    QVariantMap folder;
    folder.insert(QStringLiteral("id"), fid);
    folder.insert(QStringLiteral("name"), cleanName);
    folder.insert(QStringLiteral("apps"), QVariantList{ ta, tb });
    m_drawerFolders.append(folder);
    saveDrawerFolders();
    emit drawerFoldersChanged();
    return fid;
}

QString AppLauncher::createFolderMulti(const QString& name, const QStringList& targets)
{
    QVariantList apps;
    QSet<QString> seen;
    for (const QString& raw : targets) {
        const QString clean = raw.trimmed();
        const QString norm = clean.toLower();
        if (norm.isEmpty() || seen.contains(norm))
            continue;
        seen.insert(norm);
        apps.append(clean);
    }
    if (apps.size() < 2)
        return {};

    for (const QString& norm : seen)
        stripTargetFromFolders(norm);

    const QString fid = QStringLiteral("fld_%1").arg(QDateTime::currentMSecsSinceEpoch());
    QString cleanName = name.trimmed();
    if (cleanName.isEmpty())
        cleanName = QStringLiteral("Folder");

    QVariantMap folder;
    folder.insert(QStringLiteral("id"), fid);
    folder.insert(QStringLiteral("name"), cleanName);
    folder.insert(QStringLiteral("apps"), apps);
    m_drawerFolders.append(folder);
    saveDrawerFolders();
    emit drawerFoldersChanged();
    return fid;
}

void AppLauncher::hideApps(const QVariantList& items)
{
    bool changed = false;
    for (const QVariant& v : items) {
        const QVariantMap item = v.toMap();
        const QString target = item.value(QStringLiteral("target")).toString().trimmed();
        const QString key = target.toLower();
        if (key.isEmpty())
            continue;
        QString displayName = item.value(QStringLiteral("name")).toString().trimmed();
        if (displayName.isEmpty()) {
            const QString base = QFileInfo(target).completeBaseName();
            displayName = base.isEmpty() ? target : base;
        }
        m_hiddenApps.insert(key, displayName);
        changed = true;
    }
    if (changed) {
        saveHiddenApps();
        emit hiddenAppsChanged();
    }
}

void AppLauncher::addAppToFolder(const QString& folderId, const QString& target)
{
    const QString t = target.trimmed();
    const QString norm = t.toLower();
    if (folderId.isEmpty() || norm.isEmpty())
        return;

    bool changed = stripTargetFromFolders(norm, folderId);
    for (int i = 0; i < m_drawerFolders.size(); ++i) {
        QVariantMap fm = m_drawerFolders.at(i).toMap();
        if (fm.value(QStringLiteral("id")).toString() != folderId)
            continue;
        QVariantList apps = fm.value(QStringLiteral("apps")).toList();
        bool already = false;
        for (const QVariant& av : apps) {
            if (av.toString().trimmed().toLower() == norm) {
                already = true;
                break;
            }
        }
        if (!already) {
            apps.append(t);
            fm.insert(QStringLiteral("apps"), apps);
            m_drawerFolders[i] = fm;
            changed = true;
        }
        break;
    }
    if (changed) {
        saveDrawerFolders();
        emit drawerFoldersChanged();
    }
}

void AppLauncher::addAppsToFolder(const QString& folderId, const QStringList& targets)
{
    if (folderId.isEmpty() || targets.isEmpty())
        return;

    bool changed = false;
    QStringList cleanList;
    QSet<QString> seen;
    for (const QString& raw : targets) {
        const QString t = raw.trimmed();
        const QString norm = t.toLower();
        if (norm.isEmpty() || seen.contains(norm))
            continue;
        seen.insert(norm);
        cleanList.append(t);
        if (stripTargetFromFolders(norm, folderId))
            changed = true;
    }
    if (cleanList.isEmpty())
        return;

    for (int i = 0; i < m_drawerFolders.size(); ++i) {
        QVariantMap fm = m_drawerFolders.at(i).toMap();
        if (fm.value(QStringLiteral("id")).toString() != folderId)
            continue;
        QVariantList apps = fm.value(QStringLiteral("apps")).toList();
        QSet<QString> existing;
        for (const QVariant& av : apps)
            existing.insert(av.toString().trimmed().toLower());
        bool folderTouched = false;
        for (const QString& t : cleanList) {
            const QString norm = t.toLower();
            if (!existing.contains(norm)) {
                existing.insert(norm);
                apps.append(t);
                folderTouched = true;
                changed = true;
            }
        }
        if (folderTouched) {
            fm.insert(QStringLiteral("apps"), apps);
            m_drawerFolders[i] = fm;
        }
        break;
    }
    if (changed) {
        saveDrawerFolders();
        emit drawerFoldersChanged();
    }
}

void AppLauncher::removeAppFromFolder(const QString& folderId, const QString& target)
{
    const QString norm = target.trimmed().toLower();
    if (folderId.isEmpty() || norm.isEmpty())
        return;

    bool changed = false;
    for (int i = m_drawerFolders.size() - 1; i >= 0; --i) {
        QVariantMap fm = m_drawerFolders.at(i).toMap();
        if (fm.value(QStringLiteral("id")).toString() != folderId)
            continue;
        QVariantList apps = fm.value(QStringLiteral("apps")).toList();
        for (int j = apps.size() - 1; j >= 0; --j) {
            if (apps.at(j).toString().trimmed().toLower() == norm) {
                apps.removeAt(j);
                changed = true;
            }
        }
        if (apps.isEmpty()) {
            m_drawerFolders.removeAt(i);
            changed = true;
        } else if (changed) {
            fm.insert(QStringLiteral("apps"), apps);
            m_drawerFolders[i] = fm;
        }
        break;
    }
    if (changed) {
        saveDrawerFolders();
        emit drawerFoldersChanged();
    }
}

void AppLauncher::renameFolder(const QString& folderId, const QString& newName)
{
    const QString clean = newName.trimmed();
    if (folderId.isEmpty() || clean.isEmpty())
        return;

    for (int i = 0; i < m_drawerFolders.size(); ++i) {
        QVariantMap fm = m_drawerFolders.at(i).toMap();
        if (fm.value(QStringLiteral("id")).toString() == folderId) {
            if (fm.value(QStringLiteral("name")).toString() == clean)
                return;
            fm.insert(QStringLiteral("name"), clean);
            m_drawerFolders[i] = fm;
            saveDrawerFolders();
            emit drawerFoldersChanged();
            return;
        }
    }
}

void AppLauncher::deleteFolder(const QString& folderId)
{
    if (folderId.isEmpty())
        return;
    for (int i = m_drawerFolders.size() - 1; i >= 0; --i) {
        if (m_drawerFolders.at(i).toMap().value(QStringLiteral("id")).toString() == folderId) {
            m_drawerFolders.removeAt(i);
            saveDrawerFolders();
            emit drawerFoldersChanged();
            return;
        }
    }
}

void AppLauncher::refreshInstalledApps()
{
    QVariantList out;
    QSet<QString> seenNames;

    auto addItem = [&](const QString& name, const QString& target,
                       const QString& category, const QString& args = {}) {
        const QString clean = name.trimmed();
        if (clean.isEmpty())
            return;
        const QString key = clean.toLower();
        if (seenNames.contains(key))
            return;
        seenNames.insert(key);
        QVariantMap m;
        m.insert(QStringLiteral("name"), clean);
        m.insert(QStringLiteral("target"), target);
        m.insert(QStringLiteral("args"), args);
        m.insert(QStringLiteral("category"), category);
        out.append(m);
    };

    for (const QVariant& v : m_pinnedApps) {
        const QVariantMap pm = v.toMap();
        if (pm.value(QStringLiteral("kind")).toString() == QStringLiteral("separator"))
            continue;
        addItem(pm.value(QStringLiteral("name")).toString(),
                pm.value(QStringLiteral("target")).toString(),
                QStringLiteral("Pinned"),
                pm.value(QStringLiteral("args")).toString());
    }

    for (const QVariant& v : m_customApps) {
        const QVariantMap cm = v.toMap();
        addItem(cm.value(QStringLiteral("name")).toString(),
                cm.value(QStringLiteral("target")).toString(),
                QStringLiteral("Custom"));
    }

#ifdef Q_OS_WIN
    addItem(QStringLiteral("Task Manager"), QStringLiteral("taskmgr.exe"), QStringLiteral("System"));
    addItem(QStringLiteral("Control Panel"), QStringLiteral("control.exe"), QStringLiteral("System"));
    addItem(QStringLiteral("Display Settings"), QStringLiteral("ms-settings:display"), QStringLiteral("System"));
    addItem(QStringLiteral("Sound Settings"), QStringLiteral("ms-settings:sound"), QStringLiteral("System"));
    addItem(QStringLiteral("Windows Settings"), QStringLiteral("ms-settings:"), QStringLiteral("System"));
    addItem(QStringLiteral("Device Manager"), QStringLiteral("devmgmt.msc"), QStringLiteral("System"));
    addItem(QStringLiteral("Registry Editor"), QStringLiteral("regedit.exe"), QStringLiteral("System"));

    const QString progData = qEnvironmentVariable("ProgramData");
    const QString appData = qEnvironmentVariable("AppData");
    const QString publicDir = qEnvironmentVariable("PUBLIC");
    const QString userDesktop = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);

    auto isNoiseName = [](const QString& low) {
        return low.contains(QStringLiteral("uninstall"))
            || low.contains(QStringLiteral("readme"))
            || low.contains(QStringLiteral("help"))
            || low.contains(QStringLiteral("manual"))
            || low.contains(QStringLiteral("website"));
    };

    auto scanShortcutDir = [&](const QString& root, bool recursive) {
        if (root.isEmpty() || !QFileInfo::exists(root))
            return;
        const QDirIterator::IteratorFlags flags = recursive
            ? QDirIterator::Subdirectories
            : QDirIterator::NoIteratorFlags;
        QDirIterator it(root,
                        QStringList() << QStringLiteral("*.lnk") << QStringLiteral("*.url"),
                        QDir::Files, flags);
        while (it.hasNext()) {
            const QString filePath = QDir::toNativeSeparators(it.next());
            const QFileInfo fi(filePath);
            const QString base = fi.completeBaseName();
            if (isNoiseName(base.toLower()))
                continue;
            addItem(base, filePath, QStringLiteral("App"));
        }
    };

    if (!progData.isEmpty()) {
        scanShortcutDir(progData + QStringLiteral("\\Microsoft\\Windows\\Start Menu\\Programs"), true);
        scanShortcutDir(progData + QStringLiteral("\\Microsoft\\Windows\\Start Menu"), false);
    }
    if (!appData.isEmpty()) {
        scanShortcutDir(appData + QStringLiteral("\\Microsoft\\Windows\\Start Menu\\Programs"), true);
        scanShortcutDir(appData + QStringLiteral("\\Microsoft\\Windows\\Start Menu"), false);
    }

    // Enumerate shell:AppsFolder (MSIX / Store / UWP apps like Windows Terminal)
    {
        static constexpr GUID kFOLDERID_AppsFolder = {
            0x1E87508D, 0x89C2, 0x42F0, {0x8A, 0x7E, 0x64, 0x5A, 0x0F, 0x50, 0xCA, 0x58}
        };
        static constexpr GUID kBHID_EnumItems = {
            0x94F60519, 0x2850, 0x4924, {0xAA, 0x5A, 0xD1, 0x5E, 0x84, 0x86, 0x80, 0x39}
        };
        static constexpr IID kIID_IShellItem = {
            0x43826D1E, 0xE718, 0x42EE, {0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE}
        };
        static constexpr IID kIID_IShellItem2 = {
            0x7E9FB0D3, 0x919F, 0x4307, {0xAB, 0x2E, 0x9B, 0x18, 0x60, 0x31, 0x0C, 0x93}
        };
        static constexpr IID kIID_IEnumShellItems = {
            0x70629033, 0xE363, 0x4A28, {0xA5, 0x67, 0x0D, 0xB7, 0x80, 0x06, 0xE6, 0xD7}
        };
        static constexpr PROPERTYKEY kPKEY_AppUserModel_ID = {
            {0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}},
            5
        };

        using FnSHGetKnownFolderItem = HRESULT(WINAPI*)(const GUID&, DWORD, HANDLE, REFIID, void**);
        HMODULE shell32 = GetModuleHandleW(L"shell32.dll");
        auto fnKnownFolderItem = shell32
            ? reinterpret_cast<FnSHGetKnownFolderItem>(GetProcAddress(shell32, "SHGetKnownFolderItem"))
            : nullptr;
        if (fnKnownFolderItem) {
            const HRESULT hrCom = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
            IShellItem* appsFolder = nullptr;
            if (SUCCEEDED(fnKnownFolderItem(kFOLDERID_AppsFolder, 0, nullptr,
                                            kIID_IShellItem, reinterpret_cast<void**>(&appsFolder)))
                && appsFolder) {
                IEnumShellItems* enumItems = nullptr;
                if (SUCCEEDED(appsFolder->BindToHandler(nullptr, kBHID_EnumItems,
                                                        kIID_IEnumShellItems,
                                                        reinterpret_cast<void**>(&enumItems)))
                    && enumItems) {
                    IShellItem* child = nullptr;
                    ULONG fetched = 0;
                    while (enumItems->Next(1, &child, &fetched) == S_OK && child) {
                        QString appName;
                        PWSTR dispRaw = nullptr;
                        if (SUCCEEDED(child->GetDisplayName(SIGDN_NORMALDISPLAY, &dispRaw)) && dispRaw) {
                            appName = QString::fromWCharArray(dispRaw).trimmed();
                            CoTaskMemFree(dispRaw);
                        }

                        QString aumid;
                        IShellItem2* child2 = nullptr;
                        if (SUCCEEDED(child->QueryInterface(kIID_IShellItem2,
                                                            reinterpret_cast<void**>(&child2)))
                            && child2) {
                            PWSTR aumidRaw = nullptr;
                            if (SUCCEEDED(child2->GetString(kPKEY_AppUserModel_ID, &aumidRaw)) && aumidRaw) {
                                aumid = QString::fromWCharArray(aumidRaw).trimmed();
                                CoTaskMemFree(aumidRaw);
                            }
                            child2->Release();
                        }
                        if (aumid.isEmpty()) {
                            PWSTR relRaw = nullptr;
                            if (SUCCEEDED(child->GetDisplayName(SIGDN_PARENTRELATIVEPARSING, &relRaw)) && relRaw) {
                                aumid = QString::fromWCharArray(relRaw).trimmed();
                                CoTaskMemFree(relRaw);
                            }
                        }

                        child->Release();
                        if (!appName.isEmpty() && !aumid.isEmpty() && !isNoiseName(appName.toLower())) {
                            addItem(appName, QStringLiteral("shell:AppsFolder\\") + aumid, QStringLiteral("App"));
                        }
                    }
                    enumItems->Release();
                }
                appsFolder->Release();
            }
            if (SUCCEEDED(hrCom))
                CoUninitialize();
        }
    }

    // Desktop shortcuts (.lnk and Steam/game .url shortcuts)
    if (!userDesktop.isEmpty())
        scanShortcutDir(QDir::toNativeSeparators(userDesktop), false);
    if (!publicDir.isEmpty())
        scanShortcutDir(publicDir + QStringLiteral("\\Desktop"), false);

    // Explicit Windows Terminal fallback if not already indexed
    if (!seenNames.contains(QStringLiteral("terminal"))
        && !seenNames.contains(QStringLiteral("windows terminal"))) {
        wchar_t wtPath[MAX_PATH * 2] = {};
        if (SearchPathW(nullptr, L"wt.exe", nullptr, MAX_PATH * 2, wtPath, nullptr) > 0)
            addItem(QStringLiteral("Terminal"), QString::fromWCharArray(wtPath), QStringLiteral("System"));
    }
#endif

    std::sort(out.begin(), out.end(), [](const QVariant& a, const QVariant& b) {
        const QString na = a.toMap().value(QStringLiteral("name")).toString().toLower();
        const QString nb = b.toMap().value(QStringLiteral("name")).toString().toLower();
        return na < nb;
    });

    m_installedApps = std::move(out);
    emit installedAppsChanged();
}

static int fuzzyMatchScore(const QString& nameRaw, const QString& query)
{
    const QString name = nameRaw.toLower();
    if (name == query)
        return 1000;
    if (name.startsWith(query))
        return 850 - qMin(100, name.size() - query.size());

    // Word-boundary or CamelCase acronym matching ("vsc" -> "Visual Studio Code")
    QString initials;
    QStringList words = name.split(QRegularExpression(QStringLiteral("[\\s\\-_\\.]+")), Qt::SkipEmptyParts);
    for (const QString& w : words)
        initials.append(w.at(0));
    if (initials.startsWith(query))
        return 760;

    const int subIdx = name.indexOf(query);
    if (subIdx >= 0) {
        const bool atWordStart = (subIdx == 0 || !name.at(subIdx - 1).isLetterOrNumber());
        return (atWordStart ? 680 : 540) - qMin(80, subIdx);
    }

    // Tight subsequence fuzzy match
    int qi = 0;
    int lastMatch = -1;
    int gapSum = 0;
    for (int ni = 0; ni < name.size() && qi < query.size(); ++ni) {
        if (name.at(ni) == query.at(qi)) {
            if (lastMatch >= 0)
                gapSum += (ni - lastMatch - 1);
            lastMatch = ni;
            ++qi;
        }
    }
    if (qi == query.size() && gapSum <= name.size())
        return qMax(120, 420 - gapSum * 8);

    return 0;
}

QVariantList AppLauncher::searchApps(const QString& query) const
{
    const QString q = query.trimmed().toLower();
    if (q.isEmpty()) {
        QVariantList ranked;
        ranked.reserve(m_installedApps.size());
        for (const QVariant& v : m_installedApps) {
            if (!isHidden(v.toMap().value(QStringLiteral("target")).toString()))
                ranked.append(v);
        }
        std::stable_sort(ranked.begin(), ranked.end(), [this](const QVariant& a, const QVariant& b) {
            const QVariantMap ma = a.toMap();
            const QVariantMap mb = b.toMap();
            const int ua = m_usageCounts.value(ma.value(QStringLiteral("target")).toString().toLower(), 0).toInt();
            const int ub = m_usageCounts.value(mb.value(QStringLiteral("target")).toString().toLower(), 0).toInt();
            if (ua != ub)
                return ua > ub;
            const bool pa = ma.value(QStringLiteral("category")).toString() == QStringLiteral("Pinned");
            const bool pb = mb.value(QStringLiteral("category")).toString() == QStringLiteral("Pinned");
            return pa && !pb;
        });
        return ranked.size() > 8 ? ranked.mid(0, 8) : ranked;
    }

    struct Scored {
        int score;
        QVariantMap item;
    };
    QList<Scored> matches;
    for (const QVariant& v : m_installedApps) {
        QVariantMap m = v.toMap();
        const QString target = m.value(QStringLiteral("target")).toString();
        const int base = fuzzyMatchScore(m.value(QStringLiteral("name")).toString(), q);
        if (base <= 0)
            continue;
        const int usage = m_usageCounts.value(target.toLower(), 0).toInt();
        const int visibleBonus = isHidden(target) ? 0 : 15;
        const int bonus = qMin(180, usage * 25)
            + (m.value(QStringLiteral("category")).toString() == QStringLiteral("Pinned") ? 30 : 0)
            + visibleBonus;
        m.insert(QStringLiteral("score"), base + bonus);
        matches.append({ base + bonus, m });
    }

    std::sort(matches.begin(), matches.end(), [](const Scored& a, const Scored& b) {
        if (a.score != b.score)
            return a.score > b.score;
        return a.item.value(QStringLiteral("name")).toString() < b.item.value(QStringLiteral("name")).toString();
    });

    QVariantList res;
    for (int i = 0; i < matches.size() && i < 32; ++i)
        res.append(matches.at(i).item);
    return res;
}

QVariantList AppLauncher::listPathSuggestions(const QString& rawPath) const
{
    QVariantList out;
    QString p = rawPath.trimmed();
    if (p.startsWith(QLatin1Char('~')))
        p = qEnvironmentVariable("USERPROFILE") + p.mid(1);
    p.replace(QLatin1Char('/'), QLatin1Char('\\'));

    QFileInfo direct(p);
    QString dirPath;
    QString prefix;
    if (direct.exists() && direct.isDir()) {
        dirPath = direct.absoluteFilePath();
    } else {
        const int slash = p.lastIndexOf(QLatin1Char('\\'));
        if (slash < 0)
            return out;
        dirPath = p.left(slash + 1);
        prefix = p.mid(slash + 1).toLower();
    }

    QDir dir(dirPath);
    if (!dir.exists())
        return out;

    const QFileInfoList entries = dir.entryInfoList(
        QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot,
        QDir::DirsFirst | QDir::Name | QDir::IgnoreCase);
    for (const QFileInfo& fi : entries) {
        if (!prefix.isEmpty() && !fi.fileName().toLower().contains(prefix))
            continue;
        QVariantMap m;
        m.insert(QStringLiteral("name"), fi.fileName());
        m.insert(QStringLiteral("target"), QDir::toNativeSeparators(fi.absoluteFilePath()));
        m.insert(QStringLiteral("args"), QString());
        m.insert(QStringLiteral("category"), fi.isDir() ? QStringLiteral("Folder") : QStringLiteral("File"));
        m.insert(QStringLiteral("isPath"), true);
        out.append(m);
        if (out.size() >= 10)
            break;
    }
    return out;
}
