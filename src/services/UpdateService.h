#pragma once

#include <QObject>
#include <QString>
#include <atomic>
#include <thread>

// ===========================================================================
// UpdateService — Native WinHTTP + SHA-256 Auto Updater for SekaiDesk
//
// Queries GitHub Releases (`Yuukitake/SekaiDesk/releases/latest`), verifies
// SHA-256 against `SHA256SUMS.txt`, and performs hands-free self-update:
//   - Installer installs (`Uninstall.exe` present): downloads Setup.exe and
//     runs `/S /D=<appDir>` after SekaiDesk exits, then relaunches.
//   - Portable installs: downloads `-win64.zip`, extracts via detached
//     PowerShell helper after SekaiDesk exits, rotates `SekaiTrayHook.dll`,
//     copies updated files into `<appDir>`, and relaunches.
// ===========================================================================

class UpdateService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString currentVersion READ currentVersion CONSTANT)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY stateChanged)
    Q_PROPERTY(QString releaseNotes READ releaseNotes NOTIFY stateChanged)
    Q_PROPERTY(QString releaseUrl READ releaseUrl NOTIFY stateChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY stateChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY stateChanged)
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY stateChanged)
    Q_PROPERTY(bool toastVisible READ toastVisible NOTIFY stateChanged)
    Q_PROPERTY(double downloadProgress READ downloadProgress NOTIFY progressChanged)
    Q_PROPERTY(qint64 downloadedBytes READ downloadedBytes NOTIFY progressChanged)
    Q_PROPERTY(qint64 totalBytes READ totalBytes NOTIFY progressChanged)
    Q_PROPERTY(bool isInstallerInstall READ isInstallerInstall CONSTANT)

public:
    explicit UpdateService(QObject* parent = nullptr);
    ~UpdateService() override;

    QString currentVersion() const { return m_currentVersion; }
    QString latestVersion() const { return m_latestVersion; }
    QString releaseNotes() const { return m_releaseNotes; }
    QString releaseUrl() const { return m_releaseUrl; }
    QString status() const { return m_status; }
    QString statusText() const { return m_statusText; }
    QString errorMessage() const { return m_errorMessage; }
    bool updateAvailable() const { return m_updateAvailable; }
    bool toastVisible() const { return m_toastVisible; }
    double downloadProgress() const { return m_downloadProgress; }
    qint64 downloadedBytes() const { return m_downloadedBytes; }
    qint64 totalBytes() const { return m_totalBytes; }
    bool isInstallerInstall() const { return m_isInstallerInstall; }

    Q_INVOKABLE void checkForUpdates(bool silent = false);
    Q_INVOKABLE void startUpdate();
    Q_INVOKABLE void dismissToast();

signals:
    void stateChanged();
    void progressChanged();
    void quitForUpdateRequested();

private:
    void joinWorkerIfFinished();
    void setState(const QString& status,
                  const QString& statusText,
                  const QString& errorMessage = {});

    QString m_currentVersion;
    QString m_latestVersion;
    QString m_releaseNotes;
    QString m_releaseUrl;
    QString m_targetAssetName;
    QString m_targetAssetUrl;
    QString m_sumsUrl;

    QString m_status = QStringLiteral("idle");
    QString m_statusText = QStringLiteral("Ready to check for updates");
    QString m_errorMessage;
    bool m_updateAvailable = false;
    bool m_toastVisible = false;
    bool m_isInstallerInstall = false;

    double m_downloadProgress = 0.0;
    qint64 m_downloadedBytes = 0;
    qint64 m_totalBytes = 0;

    std::atomic<bool> m_busy{false};
    std::atomic<bool> m_destroyed{false};
    std::thread m_worker;
};
