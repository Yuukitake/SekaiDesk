#pragma once
// SystemControlService — Global Ctrl+Alt+A hotkey, DDC/CI monitor brightness
// (dxva2.dll), Windows Dark/Light theme toggle, and Power/Settings actions.

#include <QAbstractNativeEventFilter>
#include <QElapsedTimer>
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <atomic>
#include <functional>

class SystemControlService : public QObject, public QAbstractNativeEventFilter {
    Q_OBJECT
    Q_PROPERTY(bool brightnessSupported READ brightnessSupported NOTIFY stateChanged)
    Q_PROPERTY(int brightness READ brightness NOTIFY stateChanged)
    Q_PROPERTY(QString monitorName READ monitorName NOTIFY stateChanged)
    Q_PROPERTY(QVariantList monitors READ monitors NOTIFY stateChanged)
    Q_PROPERTY(bool darkMode READ darkMode NOTIFY stateChanged)
    Q_PROPERTY(QString localIp READ localIp NOTIFY stateChanged)
    Q_PROPERTY(QString networkType READ networkType NOTIFY stateChanged)
    Q_PROPERTY(bool wifiSupported READ wifiSupported NOTIFY wifiChanged)
    Q_PROPERTY(bool wifiEnabled READ wifiEnabled NOTIFY wifiChanged)
    Q_PROPERTY(QVariantList wifiNetworks READ wifiNetworks NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiConnectingSsid READ wifiConnectingSsid NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiStatusText READ wifiStatusText NOTIFY wifiChanged)
    Q_PROPERTY(bool wifiScanning READ wifiScanning NOTIFY wifiChanged)
    Q_PROPERTY(bool bluetoothSupported READ bluetoothSupported NOTIFY bluetoothChanged)
    Q_PROPERTY(bool bluetoothEnabled READ bluetoothEnabled NOTIFY bluetoothChanged)
    Q_PROPERTY(QVariantList bluetoothDevices READ bluetoothDevices NOTIFY bluetoothChanged)
    Q_PROPERTY(bool btScanning READ btScanning NOTIFY bluetoothChanged)
    Q_PROPERTY(qreal downloadBps READ downloadBps NOTIFY netSpeedChanged)
    Q_PROPERTY(qreal uploadBps READ uploadBps NOTIFY netSpeedChanged)
    Q_PROPERTY(bool keepAwake READ keepAwake NOTIFY keepAwakeChanged)
    Q_PROPERTY(bool suppressStockOsd READ suppressStockOsd WRITE setSuppressStockOsd NOTIFY suppressStockOsdChanged)
    Q_PROPERTY(bool launchAtStartup READ launchAtStartup WRITE setLaunchAtStartup NOTIFY launchAtStartupChanged)

public:
    explicit SystemControlService(QObject* parent = nullptr);
    ~SystemControlService() override;

    bool brightnessSupported() const { return m_brightnessSupported; }
    int brightness() const { return m_brightness; }
    QString monitorName() const { return m_monitorName; }
    QVariantList monitors() const { return m_monitors; }
    bool darkMode() const { return m_darkMode; }
    QString localIp() const { return m_localIp; }
    QString networkType() const { return m_networkType; }
    bool wifiSupported() const { return m_wifiSupported; }
    bool wifiEnabled() const { return m_wifiEnabled; }
    QVariantList wifiNetworks() const { return m_wifiNetworks; }
    QString wifiConnectingSsid() const { return m_wifiConnectingSsid; }
    QString wifiStatusText() const { return m_wifiStatusText; }
    bool wifiScanning() const { return m_wifiScanning; }
    bool bluetoothSupported() const { return m_bluetoothSupported; }
    bool bluetoothEnabled() const { return m_bluetoothEnabled; }
    QVariantList bluetoothDevices() const { return m_bluetoothDevices; }
    bool btScanning() const { return m_btScanning; }
    qreal downloadBps() const { return m_downloadBps; }
    qreal uploadBps() const { return m_uploadBps; }
    bool keepAwake() const { return m_keepAwake; }
    bool suppressStockOsd() const { return m_suppressStockOsd; }
    bool launchAtStartup() const { return m_launchAtStartup; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void refreshWifi();
    Q_INVOKABLE void toggleWifi();
    Q_INVOKABLE void connectWifi(const QString& ssid);
    Q_INVOKABLE void connectWifiWithPassword(const QString& ssid, const QString& password);
    Q_INVOKABLE void forgetWifi(const QString& profileName);
    Q_INVOKABLE void refreshBluetooth();
    Q_INVOKABLE void scanBluetooth();
    Q_INVOKABLE void forgetBluetooth(const QString& addressStr);
    Q_INVOKABLE void openAddDeviceDialog();
    Q_INVOKABLE void toggleBluetooth();
    Q_INVOKABLE void setNetSpeedActive(bool active);
    Q_INVOKABLE void toggleKeepAwake();
    Q_INVOKABLE void setBrightness(int percent);
    Q_INVOKABLE void setMonitorBrightness(int index, int percent);
    Q_INVOKABLE void setDisplayMode(const QString& mode);
    Q_INVOKABLE void toggleDarkMode();
    Q_INVOKABLE void openSettings(const QString& uri);
    Q_INVOKABLE void lockScreen();
    Q_INVOKABLE void sleepPc();
    Q_INVOKABLE void shutdownPc();
    Q_INVOKABLE void restartPc();
    Q_INVOKABLE void hibernatePc();
    Q_INVOKABLE void signOut();
    Q_INVOKABLE QString pickImageFile(const QString& title = QStringLiteral("Select Image"));
    Q_INVOKABLE QString pickExecutableFile(const QString& title = QStringLiteral("Select Game Executable"));
    void setPaused(bool paused);
    Q_INVOKABLE void setSuppressStockOsd(bool on);
    Q_INVOKABLE void hideStockOsdIfActive();
    Q_INVOKABLE void setLaunchAtStartup(bool on);
    Q_INVOKABLE void toggleLaunchAtStartup();
    static bool registerStartupForCurrentExe();
    static bool unregisterStartupForCurrentExe();
    Q_INVOKABLE void quitApp();
    void setBeforeQuitCallback(std::function<void()> cb);

    bool nativeEventFilter(const QByteArray& eventType, void* message, qintptr* result) override;

signals:
    void stateChanged();
    void wifiChanged();
    void bluetoothChanged();
    void netSpeedChanged();
    void keepAwakeChanged();
    void suppressStockOsdChanged();
    void launchAtStartupChanged();
    void quickPanelToggleRequested();
    void spotlightToggleRequested();
    void clipboardToggleRequested();
    void brightnessOsdRequested(int percent);
    void darkModeOsdRequested(bool darkMode);
    void volumeStepRequested(int delta);
    void volumeMuteToggleRequested();
    void taskbarToggleRequested();
    void gameModeToggleRequested();

private:
    void readBrightness();
    void readDarkMode();
    void readNetwork();
    void readLaunchAtStartup();
    void refreshBluetoothInternal(bool activeInquiry);
    void sampleNetSpeed();
    void registerHotkeys();
    void triggerQuickPanelToggle();
    void applyStockOsdSuppression(bool on);

    bool m_brightnessSupported = false;
    int m_brightness = 100;
    QString m_monitorName;
    QVariantList m_monitors;
    bool m_darkMode = true;
    QString m_localIp;
    QString m_networkType = QStringLiteral("Offline");
    bool m_wifiSupported = false;
    bool m_wifiEnabled = false;
    QVariantList m_wifiNetworks;
    QString m_wifiConnectingSsid;
    QString m_wifiStatusText;
    bool m_wifiScanning = false;
    bool m_bluetoothSupported = false;
    bool m_bluetoothEnabled = false;
    QVariantList m_bluetoothDevices;
    bool m_btScanning = false;
    qreal m_downloadBps = 0.0;
    qreal m_uploadBps = 0.0;
    bool m_netSpeedActive = false;
    bool m_hasNetBaseline = false;
    quint64 m_prevRxBytes = 0;
    quint64 m_prevTxBytes = 0;
    QTimer m_netSpeedTimer;
    QElapsedTimer m_netElapsed;
    bool m_keepAwake = false;
    bool m_hotkeyRegistered = false;
    bool m_spotlightHotkeyRegistered = false;
    bool m_clipboardHotkeyRegistered = false;
    bool m_taskbarHotkeyRegistered = false;
    bool m_gameModeHotkeyRegistered = false;
    bool m_paused = false;
    void* m_kbdHook = nullptr;
    void* m_hotkeyMsgHwnd = nullptr;
    QTimer m_hotkeyRetryTimer;
    QElapsedTimer m_quickPanelToggleTimer;
    QElapsedTimer m_startupTimer;
    bool m_brightnessInitialized = false;
    qint64 m_lastSelfBrightnessMs = 0;
    bool m_suppressStockOsd = false;
    bool m_launchAtStartup = false;
    bool m_startupChecked = false;
    std::atomic<bool> m_wifiBusy{false};
    std::atomic<bool> m_btBusy{false};
    std::function<void()> m_beforeQuitCallback;
};
