// SekaiDesk main entry — Phase 0 smoke test shell.
//
// Boot sequence:
//   1. QGuiApplication (Qt Quick scene graph, Win32 platform integration)
//   2. Register Quickshell compat types (URI "Quickshell" / "Quickshell.Io")
//   3. Add import paths: <exe>/qml (compat modules + qs junction) and the
//      vendored SekaiPop shell root for plain `qs.`-free imports later.
//   4. Load qrc:/qml/Shell.qml (smoke test; replaced by the full shell in
//      later phases).

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QIcon>
#include <QMutex>
#include <QMutexLocker>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <QStandardPaths>
#include <QTextStream>
#include <QUrl>
#include <cstdlib>
#include <cstring>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <cstring>
#include <cwctype>
#include <string>
#endif

#include "compat/QsCore.h"
#include "compat/QsIo.h"
#include "compat/QsWindow.h"
#include "core/SettingsStore.h"
#include "services/AppLauncher.h"
#include "services/DwmThumbnailItem.h"
#include "services/MediaService.h"
#include "services/AudioService.h"
#include "services/SystemControlService.h"
#include "services/TrayService.h"
#include "services/TrashService.h"
#include "services/WinIconProvider.h"
#include "services/WindowTracker.h"
#include "services/ClipboardService.h"
#include "services/DeskExtrasService.h"
#include "services/NotificationService.h"
#include "services/VisualizerService.h"
#include "services/WallpaperService.h"
#include "services/TaskbarManager.h"
#include "services/GameModeService.h"
#include "services/UpdateService.h"
#include "services/RamCleanerService.h"

namespace {
QFile* g_logFile = nullptr;
QMutex g_logMutex;

void sekaiMessageHandler(QtMsgType type, const QMessageLogContext&, const QString& msg)
{
    QMutexLocker lock(&g_logMutex);
    if (!g_logFile || !g_logFile->isOpen())
        return;
    const char* tag = "DBG";
    switch (type) {
    case QtDebugMsg:    tag = "DBG"; break;
    case QtInfoMsg:     tag = "INF"; break;
    case QtWarningMsg:  tag = "WRN"; break;
    case QtCriticalMsg: tag = "CRT"; break;
    case QtFatalMsg:    tag = "FTL"; break;
    }
    QTextStream ts(g_logFile);
    ts << QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz "))
       << "[" << tag << "] " << msg << "\n";
    ts.flush();
}

#ifdef Q_OS_WIN
LONG WINAPI sekaiUnhandledExceptionFilter(EXCEPTION_POINTERS* /*info*/) noexcept
{
    TaskbarManager::emergencyRestoreAllNoAlloc();
    return EXCEPTION_CONTINUE_SEARCH;
}
#endif
}

int main(int argc, char* argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (!argv[i])
            continue;
        if (std::strcmp(argv[i], "--restore") == 0) {
            QCoreApplication restoreApp(argc, argv);
            QCoreApplication::setOrganizationName(QStringLiteral("SekaiDesk"));
            QCoreApplication::setApplicationName(QStringLiteral("SekaiDesk"));
            SettingsStore restoreSettings;
            restoreSettings.ensureLoaded();
            TaskbarManager::emergencyRestoreAll(&restoreSettings);
            return 0;
        }
        if (std::strcmp(argv[i], "--register-startup") == 0) {
            QCoreApplication startupApp(argc, argv);
            QCoreApplication::setOrganizationName(QStringLiteral("SekaiDesk"));
            QCoreApplication::setApplicationName(QStringLiteral("SekaiDesk"));
            return SystemControlService::registerStartupForCurrentExe() ? 0 : 1;
        }
        if (std::strcmp(argv[i], "--unregister-startup") == 0) {
            QCoreApplication startupApp(argc, argv);
            QCoreApplication::setOrganizationName(QStringLiteral("SekaiDesk"));
            QCoreApplication::setApplicationName(QStringLiteral("SekaiDesk"));
            return SystemControlService::unregisterStartupForCurrentExe() ? 0 : 1;
        }
        if (std::strncmp(argv[i], "--fake-battery=", 15) == 0) {
            qputenv("SEKAIDESK_FAKE_BATTERY", argv[i] + 15);
        }
    }

#ifdef Q_OS_WIN
    std::wstring instanceTag;
    bool hasWaitGame = false;
    unsigned long waitGamePid = 0;
    std::string waitExeArg;
    for (int i = 1; i < argc; ++i) {
        if (!argv[i])
            continue;
        const char* arg = argv[i];
        const char* rawVal = nullptr;
        if (std::strcmp(arg, "--instance") == 0 && (i + 1) < argc && argv[i + 1]) {
            rawVal = argv[++i];
        } else if (std::strncmp(arg, "--instance=", 11) == 0) {
            rawVal = arg + 11;
        } else if (std::strcmp(arg, "--wait-game") == 0 && (i + 1) < argc && argv[i + 1]) {
            hasWaitGame = true;
            waitGamePid = std::strtoul(argv[++i], nullptr, 10);
        } else if (std::strncmp(arg, "--wait-game=", 12) == 0) {
            hasWaitGame = true;
            waitGamePid = std::strtoul(arg + 12, nullptr, 10);
        } else if (std::strcmp(arg, "--wait-exe") == 0 && (i + 1) < argc && argv[i + 1]) {
            waitExeArg = argv[++i];
        } else if (std::strncmp(arg, "--wait-exe=", 11) == 0) {
            waitExeArg = arg + 11;
        }
        if (rawVal) {
            instanceTag.clear();
            for (const char* p = rawVal; *p != '\0' && instanceTag.size() < 48; ++p) {
                const wchar_t wc = static_cast<unsigned char>(*p);
                if (std::iswalnum(wc) || wc == L'_' || wc == L'-' || wc == L'.')
                    instanceTag.push_back(wc);
            }
        }
    }
    if (hasWaitGame) {
        return GameModeService::runWaitGameWatchdog(
            waitGamePid,
            QString::fromLocal8Bit(waitExeArg.c_str()),
            QString::fromStdWString(instanceTag));
    }

    SetUnhandledExceptionFilter(sekaiUnhandledExceptionFilter);
    const std::wstring mutexName = instanceTag.empty()
        ? std::wstring(L"Local\\SekaiDesk_SingleInstance_v1")
        : (std::wstring(L"Local\\SekaiDesk_SingleInstance_") + instanceTag);

    HANDLE singleInstanceMutex = CreateMutexW(nullptr, FALSE, mutexName.c_str());
    const DWORD mutexErr = GetLastError();
    if (!singleInstanceMutex || mutexErr == ERROR_ALREADY_EXISTS || mutexErr == ERROR_ACCESS_DENIED) {
        if (singleInstanceMutex)
            CloseHandle(singleInstanceMutex);
        qInfo("SekaiDesk: another instance is already running; exiting.");
        return 0;
    }
#endif

    // SekaiDesk is a decorative shell: enable software fallback-friendly
    // defaults, keep the default RHI (D3D11 on Windows).
    QGuiApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("SekaiDesk"));
    app.setApplicationName(QStringLiteral("SekaiDesk"));
#ifndef SEKAIDESK_VERSION
#define SEKAIDESK_VERSION "0.3.0"
#endif
    app.setApplicationDisplayName(QStringLiteral("SekaiDesk"));
    app.setApplicationVersion(QStringLiteral(SEKAIDESK_VERSION));
    app.setWindowIcon(QIcon(QStringLiteral(":/qml/icons/sekai-app-icon.png")));
    app.setQuitOnLastWindowClosed(false);

    {
        const QString baseDir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
        const QString logDir = QDir(baseDir.isEmpty() ? QCoreApplication::applicationDirPath() : baseDir)
                                   .absoluteFilePath(QStringLiteral("SekaiDesk"));
        QDir().mkpath(logDir);
        static QFile logFile(QDir(logDir).absoluteFilePath(QStringLiteral("startup.log")));
        if (logFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            g_logFile = &logFile;
            qInstallMessageHandler(sekaiMessageHandler);
            qInfo("SekaiDesk booting...");
        }
    }

    static SettingsStore settings;
    settings.ensureLoaded();

    static AppLauncher appLauncher(&settings);
    static WindowTracker windowTracker;
    static TrashService trashService;
    static MediaService mediaService;
    static AudioService audioService;
    static SystemControlService systemControl;
    systemControl.setSuppressStockOsd(
        settings.boolValue(QStringLiteral("ui.osdEnabled"), true));
    QObject::connect(&systemControl, &SystemControlService::volumeStepRequested,
                     &audioService, [&audioService](int delta) {
                         audioService.setMasterVolume(audioService.masterVolume() + delta);
                     });
    QObject::connect(&systemControl, &SystemControlService::volumeMuteToggleRequested,
                     &audioService, &AudioService::toggleMasterMute);
    QObject::connect(&audioService, &AudioService::osdRequested,
                     &systemControl, [&systemControl](const QString& kind, int, bool) {
                         if (kind == QLatin1String("volume"))
                             systemControl.hideStockOsdIfActive();
                     });
    static TrayService trayService;
    static ClipboardService clipboardService;
    static LyricsService lyricsService(&mediaService);
    static WeatherService weatherService(&settings);
    static DropShelfService dropShelfService;
    static NotificationService notificationService;
    static VisualizerService visualizerService(&settings, &mediaService);
    static WallpaperService wallpaperService(&settings);
    static TaskbarManager taskbarManager(&settings);
    static GameModeService gameModeService;
    static UpdateService updateService;
    static RamCleanerService ramCleanerService(&settings);
#ifdef Q_OS_WIN
    if (!instanceTag.empty())
        gameModeService.setInstanceTag(QString::fromStdWString(instanceTag));
#endif
    QObject::connect(&updateService, &UpdateService::quitForUpdateRequested,
                     &systemControl, &SystemControlService::quitApp);
    static bool s_skipTaskbarRestoreOnQuit = false;
    systemControl.setBeforeQuitCallback([]() {
        trayService.stop();
        taskbarManager.prepareForExit();
    });
    QObject::connect(&app, &QCoreApplication::aboutToQuit, []() {
        trayService.stop();
        if (!s_skipTaskbarRestoreOnQuit)
            taskbarManager.prepareForExit();
    });
    QObject::connect(&systemControl, &SystemControlService::taskbarToggleRequested,
                     &taskbarManager, &TaskbarManager::toggleTemporary);
    QObject::connect(&systemControl, &SystemControlService::gameModeToggleRequested,
                     &gameModeService, &GameModeService::toggleManual);
    QObject::connect(&gameModeService, &GameModeService::hibernateChanged,
                     &app, [](bool hibernated, const QString&) {
                         PanelWindow::setGlobalHibernated(hibernated);
                         trayService.setPaused(hibernated);
                         windowTracker.setPaused(hibernated);
                         audioService.setPaused(hibernated);
                         lyricsService.setPaused(hibernated);
                         mediaService.setPaused(hibernated);
                         notificationService.setPaused(hibernated);
                         systemControl.setPaused(hibernated);
                     });
    QObject::connect(&gameModeService, &GameModeService::zeroFootprintRequested,
                     &app, []() {
                         trayService.stop();
                         if (gameModeService.restoreTaskbarInZero())
                             taskbarManager.prepareForExit();
                         else
                             s_skipTaskbarRestoreOnQuit = true;
                         QCoreApplication::quit();
                     });
    QObject::connect(&gameModeService, &GameModeService::spotlightHiddenWhileHibernated,
                     &app, []() {
                         PanelWindow::scheduleHiddenResourceRelease();
                     });

    // --- Quickshell compat registrations -----------------------------------
    // Unversioned imports (`import Quickshell`) resolve to the highest
    // registered version; everything is registered as 1.0.
    qmlRegisterSingletonInstance("Quickshell", 1, 0,
                                 "Quickshell", QsGlobal::instance());
    qmlRegisterSingletonInstance("Quickshell", 1, 0,
                                 "SystemClock", SystemClock::instance());
    qmlRegisterType<Variants>("Quickshell", 1, 0,
                              "Variants");
    qmlRegisterType<PanelWindow>("Quickshell", 1, 0,
                                 "PanelWindow");
    qmlRegisterType<QsRegion>("Quickshell", 1, 0,
                              "Region");

    qmlRegisterType<QsProcess>("Quickshell.Io", 1, 0,
                               "Process");
    qmlRegisterType<QsStdioCollector>("Quickshell.Io", 1, 0,
                                      "StdioCollector");
    qmlRegisterType<QsFileView>("Quickshell.Io", 1, 0,
                                "FileView");

    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "ConfigStore", &settings);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "AppLauncher", &appLauncher);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "WindowTracker", &windowTracker);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "TrashService", &trashService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "MediaService", &mediaService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "AudioService", &audioService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "SystemControl", &systemControl);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "TrayService", &trayService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "ClipboardService", &clipboardService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "LyricsService", &lyricsService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "WeatherService", &weatherService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "DropShelfService", &dropShelfService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "NotificationService", &notificationService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "VisualizerService", &visualizerService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "WallpaperService", &wallpaperService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "TaskbarManager", &taskbarManager);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "GameModeService", &gameModeService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "UpdateService", &updateService);
    qmlRegisterSingletonInstance("SekaiDesk", 1, 0,
                                 "RamCleanerService", &ramCleanerService);
    qmlRegisterType<DwmThumbnailItem>("SekaiDesk", 1, 0,
                                      "DwmThumbnail");

    // --- Engine + import paths ----------------------------------------------
    QQmlApplicationEngine engine;
    engine.addImageProvider(QStringLiteral("winicon"), new WinIconProvider());

    // <exe>/qml: qml module dirs deployed by windeployqt + the `qs` junction
    // created by CMake (build/qml/qs -> SekaiPop/sekaipop).
    engine.addImportPath(QCoreApplication::applicationDirPath()
                         + QStringLiteral("/qml"));

    // Optional external QML override directory (SEKAIDESK_SHELL_DIR).
    const QString shellDir = QsGlobal::resolveShellDir();
    if (!shellDir.isEmpty()) {
        engine.addImportPath(shellDir);
        engine.rootContext()->setContextProperty(
            QStringLiteral("shellDir"), shellDir);
    }

    // --restore: emergency work-area / taskbar rescue (implemented Phase 1).
    // --edit / other flags handled in later phases.

    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app,
                     [](const QList<QQmlError>& warnings) {
                         for (const auto& w : warnings)
                             qWarning("QML: %s", qPrintable(w.toString()));
                     });

    engine.load(QUrl(QStringLiteral("qrc:/qml/Shell.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical("SekaiDesk: failed to load Shell.qml");
#ifdef Q_OS_WIN
        CloseHandle(singleInstanceMutex);
#endif
        return 1;
    }
    qInfo("SekaiDesk: Shell.qml loaded (%lld root objects)", static_cast<long long>(engine.rootObjects().size()));

    const int exitCode = app.exec();
#ifdef Q_OS_WIN
    CloseHandle(singleInstanceMutex);
#endif
    return exitCode;
}
