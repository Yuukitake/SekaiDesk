#pragma once
// VisualizerService — Real-time WASAPI loopback audio spectrum & energy analyzer.
// Captures system render audio in a background thread, runs a 1024-point Hann-windowed
// radix-2 FFT, and exposes 32 smoothed logarithmic bands to QML.

#include <QObject>
#include <QTimer>
#include <QVariantList>

#include <array>
#include <atomic>
#include <mutex>
#include <thread>

class SettingsStore;
class MediaService;

class VisualizerService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString style READ style WRITE setStyle NOTIFY styleChanged)
    Q_PROPERTY(int sizeIndex READ sizeIndex WRITE setSizeIndex NOTIFY sizeIndexChanged)
    Q_PROPERTY(int colorMode READ colorMode WRITE setColorMode NOTIFY colorModeChanged)
    Q_PROPERTY(qreal sensitivity READ sensitivity WRITE setSensitivity NOTIFY sensitivityChanged)
    Q_PROPERTY(bool alwaysListen READ alwaysListen WRITE setAlwaysListen NOTIFY alwaysListenChanged)
    Q_PROPERTY(bool stayWhenPaused READ stayWhenPaused WRITE setStayWhenPaused NOTIFY stayWhenPausedChanged)
    Q_PROPERTY(bool suppressed READ suppressed WRITE setSuppressed NOTIFY suppressedChanged)
    Q_PROPERTY(qreal posX READ posX WRITE setPosX NOTIFY positionChanged)
    Q_PROPERTY(qreal posY READ posY WRITE setPosY NOTIFY positionChanged)
    Q_PROPERTY(int customWidth READ customWidth WRITE setCustomWidth NOTIFY customSizeChanged)
    Q_PROPERTY(int customHeight READ customHeight WRITE setCustomHeight NOTIFY customSizeChanged)
    Q_PROPERTY(bool transparentBg READ transparentBg WRITE setTransparentBg NOTIFY transparentBgChanged)

    Q_PROPERTY(QVariantList bands READ bands NOTIFY frameChanged)
    Q_PROPERTY(qreal level READ level NOTIFY frameChanged)
    Q_PROPERTY(qreal bass READ bass NOTIFY frameChanged)
    Q_PROPERTY(bool audioActive READ audioActive NOTIFY frameChanged)

public:
    explicit VisualizerService(SettingsStore* settings, MediaService* media, QObject* parent = nullptr);
    ~VisualizerService() override;

    bool enabled() const { return m_enabled; }
    QString style() const { return m_style; }
    int sizeIndex() const { return m_sizeIndex; }
    int colorMode() const { return m_colorMode; }
    qreal sensitivity() const { return m_sensitivity; }
    bool alwaysListen() const { return m_alwaysListen; }
    bool stayWhenPaused() const { return m_stayWhenPaused; }
    bool suppressed() const { return m_suppressed; }
    qreal posX() const { return m_posX; }
    qreal posY() const { return m_posY; }
    int customWidth() const { return m_customWidth; }
    int customHeight() const { return m_customHeight; }
    bool transparentBg() const { return m_transparentBg; }

    QVariantList bands() const { return m_bands; }
    qreal level() const { return m_level; }
    qreal bass() const { return m_bass; }
    bool audioActive() const { return m_audioActive; }

    void setEnabled(bool enabled);
    void setStyle(const QString& style);
    void setSizeIndex(int index);
    void setColorMode(int mode);
    void setSensitivity(qreal value);
    void setAlwaysListen(bool always);
    void setStayWhenPaused(bool stay);
    void setSuppressed(bool suppressed);
    void setPosX(qreal x);
    void setPosY(qreal y);
    void setCustomWidth(int w);
    void setCustomHeight(int h);
    void setTransparentBg(bool transparent);

    Q_INVOKABLE void cycleSize();
    Q_INVOKABLE void cycleColorMode();
    Q_INVOKABLE void setPosition(qreal x, qreal y);
    Q_INVOKABLE void setCustomSize(int w, int h);
    Q_INVOKABLE void resetPosition();

signals:
    void enabledChanged();
    void styleChanged();
    void sizeIndexChanged();
    void colorModeChanged();
    void sensitivityChanged();
    void alwaysListenChanged();
    void stayWhenPausedChanged();
    void suppressedChanged();
    void configChanged();
    void positionChanged();
    void customSizeChanged();
    void transparentBgChanged();
    void frameChanged();

private:
    void syncCaptureState();
    void startWorker();
    void stopWorker();
    void workerLoop();
    void onFrameTimer();

    SettingsStore* m_settings = nullptr;
    MediaService* m_media = nullptr;

    bool m_enabled = false;
    QString m_style = QStringLiteral("tide");
    int m_sizeIndex = 1;
    int m_colorMode = 0;
    qreal m_sensitivity = 1.0;
    bool m_alwaysListen = true;
    bool m_stayWhenPaused = true;
    bool m_suppressed = false;
    qreal m_posX = -1.0;
    qreal m_posY = -1.0;
    int m_customWidth = 0;
    int m_customHeight = 0;
    bool m_transparentBg = true;

    QVariantList m_bands;
    qreal m_level = 0.0;
    qreal m_bass = 0.0;
    bool m_audioActive = false;

    QTimer m_frameTimer;
    std::atomic<bool> m_stopFlag{false};
    std::atomic<float> m_atomicSensitivity{1.0f};
    std::thread m_worker;

    mutable std::mutex m_sharedMutex;
    std::array<float, 32> m_sharedBands{};
    float m_sharedLevel = 0.0f;
    float m_sharedBass = 0.0f;
    qint64 m_lastAudioMs = 0;
};
