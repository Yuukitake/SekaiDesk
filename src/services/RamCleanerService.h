#pragma once

#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QTimer>
#include <atomic>
#include <thread>

class SettingsStore;

// ===========================================================================
// RamCleanerService — Native Windows RAM Cleaner (ported from RamNuker)
//
// Two distinct modes matching RamNuker's Win32/NT primitives:
//  1) Auto Clean (stutter-free): invokes NtSetSystemInformation(0x50, 5)
//     (Priority-0 Standby List only). Never trims active working sets or
//     hot game textures/assets -> zero micro-stutter in games.
//  2) Manual Deep Clean: trims accessible user-process working sets
//     (EmptyWorkingSet), flushes ModifiedPageList (cmd=3), and purges
//     StandbyList (cmd=4) for maximum reclaim on demand.
// ===========================================================================

class RamCleanerService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool autoEnabled READ autoEnabled WRITE setAutoEnabled NOTIFY configChanged)
    Q_PROPERTY(int thresholdPercent READ thresholdPercent WRITE setThresholdPercent NOTIFY configChanged)
    Q_PROPERTY(int intervalSeconds READ intervalSeconds WRITE setIntervalSeconds NOTIFY configChanged)
    Q_PROPERTY(bool cleaning READ cleaning NOTIFY stateChanged)
    Q_PROPERTY(bool elevated READ elevated CONSTANT)
    Q_PROPERTY(int lastFreedMb READ lastFreedMb NOTIFY stateChanged)
    Q_PROPERTY(QString lastResultText READ lastResultText NOTIFY stateChanged)
    Q_PROPERTY(QString lastCleanTime READ lastCleanTime NOTIFY stateChanged)

public:
    explicit RamCleanerService(SettingsStore* settings, QObject* parent = nullptr);
    ~RamCleanerService() override;

    bool autoEnabled() const { return m_autoEnabled; }
    int thresholdPercent() const { return m_thresholdPercent; }
    int intervalSeconds() const { return m_intervalSeconds; }
    bool cleaning() const { return m_cleaning; }
    bool elevated() const { return m_elevated; }
    int lastFreedMb() const { return m_lastFreedMb; }
    QString lastResultText() const { return m_lastResultText; }
    QString lastCleanTime() const { return m_lastCleanTime; }

    Q_INVOKABLE void cleanNowDeep();
    Q_INVOKABLE void cleanNowStutterFree();
    Q_INVOKABLE void setAutoEnabled(bool on);
    Q_INVOKABLE void setThresholdPercent(int pct);
    Q_INVOKABLE void setIntervalSeconds(int sec);

signals:
    void configChanged();
    void stateChanged();

private slots:
    void onAutoTimer();

private:
    void joinWorkerIfFinished();
    void startCleanWorker(bool deepMode, bool isAuto);

    SettingsStore* m_settings = nullptr;
    bool m_autoEnabled = true;
    int m_thresholdPercent = 80;
    int m_intervalSeconds = 300;
    bool m_cleaning = false;
    bool m_elevated = false;
    int m_lastFreedMb = 0;
    QString m_lastResultText;
    QString m_lastCleanTime;

    QTimer m_autoTimer;
    QElapsedTimer m_lastAutoElapsed;
    std::atomic<bool> m_busy{false};
    std::atomic<bool> m_destroyed{false};
    std::thread m_worker;
};
