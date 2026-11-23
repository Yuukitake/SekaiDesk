#pragma once
// WindowTracker — enumerates active top-level Windows applications for the Dock
// (running dots, unpinned running apps, click-to-focus / minimize toggle).

#include <QHash>
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

class WindowTracker : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList runningApps READ runningApps NOTIFY runningAppsChanged)
    Q_PROPERTY(bool dockOverlap READ dockOverlap NOTIFY dockOverlapChanged)
    Q_PROPERTY(bool bottomEdgeHovered READ bottomEdgeHovered NOTIFY bottomEdgeHoveredChanged)
    Q_PROPERTY(bool topOverlap READ topOverlap NOTIFY topOverlapChanged)
    Q_PROPERTY(bool topEdgeHovered READ topEdgeHovered NOTIFY topEdgeHoveredChanged)
    Q_PROPERTY(bool leftOverlap READ leftOverlap NOTIFY leftOverlapChanged)
    Q_PROPERTY(bool leftEdgeHovered READ leftEdgeHovered NOTIFY leftEdgeHoveredChanged)
    Q_PROPERTY(bool rightOverlap READ rightOverlap NOTIFY rightOverlapChanged)
    Q_PROPERTY(bool rightEdgeHovered READ rightEdgeHovered NOTIFY rightEdgeHoveredChanged)
    Q_PROPERTY(QString activeAppName READ activeAppName NOTIFY activeWindowChanged)
    Q_PROPERTY(QString activeWindowTitle READ activeWindowTitle NOTIFY activeWindowChanged)
    Q_PROPERTY(int cpuUsage READ cpuUsage NOTIFY statsChanged)
    Q_PROPERTY(int ramUsage READ ramUsage NOTIFY statsChanged)
    Q_PROPERTY(int cpuTemp READ cpuTemp NOTIFY statsChanged)
    Q_PROPERTY(int gpuTemp READ gpuTemp NOTIFY statsChanged)
    Q_PROPERTY(QString uptimeText READ uptimeText NOTIFY statsChanged)
    Q_PROPERTY(double downloadBps READ downloadBps NOTIFY statsChanged)
    Q_PROPERTY(double uploadBps READ uploadBps NOTIFY statsChanged)
    Q_PROPERTY(bool hasBattery READ hasBattery NOTIFY statsChanged)
    Q_PROPERTY(int batteryPercent READ batteryPercent NOTIFY statsChanged)
    Q_PROPERTY(bool batteryCharging READ batteryCharging NOTIFY statsChanged)
    Q_PROPERTY(QString batteryTimeText READ batteryTimeText NOTIFY statsChanged)
    Q_PROPERTY(QVariantList cpuHistory READ cpuHistory NOTIFY statsChanged)
    Q_PROPERTY(QVariantList ramHistory READ ramHistory NOTIFY statsChanged)
    Q_PROPERTY(QString ramDetailText READ ramDetailText NOTIFY statsChanged)
    Q_PROPERTY(QString machineName READ machineName CONSTANT)
    Q_PROPERTY(QString userName READ userName CONSTANT)
    Q_PROPERTY(QString cpuSpec READ cpuSpec CONSTANT)
    Q_PROPERTY(QString ramSpec READ ramSpec CONSTANT)
    Q_PROPERTY(QString gpuSpec READ gpuSpec CONSTANT)
    Q_PROPERTY(QString osSpec READ osSpec CONSTANT)
    Q_PROPERTY(bool desktopOccluded READ desktopOccluded NOTIFY desktopOccludedChanged)

public:
    explicit WindowTracker(QObject* parent = nullptr);

    QVariantList runningApps() const { return m_runningApps; }
    bool dockOverlap() const { return m_dockOverlap; }
    bool desktopOccluded() const { return m_desktopOccluded; }
    bool bottomEdgeHovered() const { return m_bottomEdgeHovered; }
    bool topOverlap() const { return m_topOverlap; }
    bool topEdgeHovered() const { return m_topEdgeHovered; }
    bool leftOverlap() const { return m_leftOverlap; }
    bool leftEdgeHovered() const { return m_leftEdgeHovered; }
    bool rightOverlap() const { return m_rightOverlap; }
    bool rightEdgeHovered() const { return m_rightEdgeHovered; }
    QString activeAppName() const { return m_activeAppName; }
    QString activeWindowTitle() const { return m_activeWindowTitle; }
    int cpuUsage() const { return m_cpuUsage; }
    int ramUsage() const { return m_ramUsage; }
    int cpuTemp() const { return m_cpuTemp; }
    int gpuTemp() const { return m_gpuTemp; }
    QString uptimeText() const { return m_uptimeText; }
    double downloadBps() const { return m_downloadBps; }
    double uploadBps() const { return m_uploadBps; }
    bool hasBattery() const { return m_hasBattery; }
    int batteryPercent() const { return m_batteryPercent; }
    bool batteryCharging() const { return m_batteryCharging; }
    QString batteryTimeText() const { return m_batteryTimeText; }
    QVariantList cpuHistory() const { return m_cpuHistory; }
    QVariantList ramHistory() const { return m_ramHistory; }
    QString ramDetailText() const { return m_ramDetailText; }
    QString machineName() const { return m_machineName; }
    QString userName() const { return m_userName; }
    QString cpuSpec() const { return m_cpuSpec; }
    QString ramSpec() const { return m_ramSpec; }
    QString gpuSpec() const { return m_gpuSpec; }
    QString osSpec() const { return m_osSpec; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE QVariantMap stateForTarget(const QString& target) const;
    Q_INVOKABLE bool activateOrToggle(const QString& target);
    Q_INVOKABLE QVariantList windowsForTarget(const QString& target) const;
    Q_INVOKABLE bool activateHwnd(qulonglong hwnd);
    Q_INVOKABLE bool minimizeHwnd(qulonglong hwnd);
    Q_INVOKABLE bool closeHwnd(qulonglong hwnd);
    Q_INVOKABLE bool openSpecialFolder(const QString& kind);
    Q_INVOKABLE QString resolveFolderPath(const QString& kindOrPath) const;
    Q_INVOKABLE QVariantList listFolderFiles(const QString& kindOrPath, int maxItems = 48) const;
    Q_INVOKABLE bool openPath(const QString& path) const;
    Q_INVOKABLE void openTaskManager() const;
    Q_INVOKABLE QVariantList topProcesses(int limit = 6) const;
    Q_INVOKABLE QVariantList runningExeNames() const;
    Q_INVOKABLE void setEdgePollingNeeded(bool needed);
    void setPaused(bool paused);
    Q_INVOKABLE void lockWorkstation();
    Q_INVOKABLE void sleepComputer();
    Q_INVOKABLE void takeScreenshot();
    Q_INVOKABLE void checkLowBatteryAlert();

signals:
    void runningAppsChanged();
    void dockOverlapChanged();
    void bottomEdgeHoveredChanged();
    void topOverlapChanged();
    void topEdgeHoveredChanged();
    void leftOverlapChanged();
    void leftEdgeHoveredChanged();
    void rightOverlapChanged();
    void rightEdgeHoveredChanged();
    void activeWindowChanged();
    void statsChanged();
    void lowBatteryAlert(int percent, bool critical);
    void desktopOccludedChanged();

private:
    void pollEdgeAndOverlap();
    void updateSystemStats();
    struct AppGroup {
        QString exePath;
        QString exeKey;
        QString name;
        QList<quintptr> hwnds;
        quintptr primaryHwnd = 0;
        bool active = false;
        bool allMinimized = true;
    };

    QTimer m_pollTimer;
    QTimer m_edgeTimer;
    bool m_dockOverlap = false;
    bool m_desktopOccluded = false;
    bool m_edgePollingNeeded = true;
    bool m_paused = false;
    int m_overlapSubTick = 0;
    bool m_bottomEdgeHovered = false;
    bool m_topOverlap = false;
    bool m_topEdgeHovered = false;
    bool m_leftOverlap = false;
    bool m_leftEdgeHovered = false;
    bool m_rightOverlap = false;
    bool m_rightEdgeHovered = false;
    QString m_activeAppName = QStringLiteral("Desktop");
    QString m_activeWindowTitle;
    int m_cpuUsage = 0;
    int m_ramUsage = 0;
    int m_cpuTemp = -1;
    int m_gpuTemp = -1;
    QString m_uptimeText = QStringLiteral("0m");
    double m_downloadBps = 0.0;
    double m_uploadBps = 0.0;
    quint64 m_prevRxBytes = 0;
    quint64 m_prevTxBytes = 0;
    qint64 m_prevNetMs = 0;
    bool m_hasBattery = false;
    int m_batteryPercent = 100;
    bool m_batteryCharging = false;
    QString m_batteryTimeText;
    int m_lowBatteryAlertTier = 0; // 0 = none, 1 = warned (<=20%), 2 = critical (<=10%)
    bool m_batteryAlertArmed = false;
    QString m_ramDetailText;
    QVariantList m_cpuHistory;
    QVariantList m_ramHistory;
    int m_historyTick = 0;
    QString m_machineName;
    QString m_userName;
    QString m_cpuSpec;
    QString m_ramSpec;
    QString m_gpuSpec;
    QString m_osSpec;
    struct CpuSample {
        quint64 idle = 0;
        quint64 total = 0;
    };
    QVector<CpuSample> m_cpuSamples;
    double m_cpuEma = -1.0;
    int m_cpuTick = 0;
    QVariantList m_runningApps;
    QHash<QString, AppGroup> m_groups;
};
