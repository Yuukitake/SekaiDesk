#include "AudioService.h"

#include <QDateTime>
#include <QFileInfo>
#include <QSet>
#include <QUrl>
#include <QVariantMap>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <audiopolicy.h>
#include <propsys.h>
#include <objbase.h>
#endif

namespace {
#ifdef Q_OS_WIN
QString processImagePath(DWORD pid)
{
    if (pid == 0)
        return {};
    HANDLE hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!hProc)
        return {};
    wchar_t buf[MAX_PATH * 2]{};
    DWORD len = MAX_PATH * 2;
    QString out;
    if (QueryFullProcessImageNameW(hProc, 0, buf, &len) && len > 0)
        out = QString::fromWCharArray(buf, static_cast<int>(len));
    CloseHandle(hProc);
    return out;
}

QString friendlyAppName(const QString& exePath, const QString& displayName, DWORD pid)
{
    if (!displayName.isEmpty() && !displayName.startsWith(QLatin1Char('@')))
        return displayName;
    if (!exePath.isEmpty()) {
        const QString base = QFileInfo(exePath).completeBaseName();
        if (!base.isEmpty())
            return base.at(0).toUpper() + base.mid(1);
    }
    return pid == 0 ? QStringLiteral("System Sounds") : QStringLiteral("App %1").arg(pid);
}

template <typename Fn>
bool withCachedEndpointVolume(AudioService* svc, EDataFlow flow, Fn&& fn)
{
    auto* pVol = static_cast<IAudioEndpointVolume*>(
        svc->ensureEndpointVolume(static_cast<int>(flow), false));
    if (!pVol)
        return false;
    HRESULT hr = fn(pVol);
    if (FAILED(hr)) {
        pVol = static_cast<IAudioEndpointVolume*>(
            svc->ensureEndpointVolume(static_cast<int>(flow), true));
        if (!pVol)
            return false;
        hr = fn(pVol);
    }
    return SUCCEEDED(hr);
}
#endif
} // namespace

AudioService::AudioService(QObject* parent)
    : QObject(parent)
{
#ifdef Q_OS_WIN
    m_startupTimer.start();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    readMasterState(false);
    readMicState(false);
    refreshOutputDevices();
    m_initialized = true;
    m_pollTimer.setInterval(500);
    connect(&m_pollTimer, &QTimer::timeout, this, &AudioService::pollMaster);
    m_pollTimer.start();
#endif
}

AudioService::~AudioService()
{
    m_pollTimer.stop();
#ifdef Q_OS_WIN
    releaseCachedEndpoints(true);
    CoUninitialize();
#endif
}

void AudioService::releaseCachedEndpoints(bool includeEnumerator)
{
#ifdef Q_OS_WIN
    if (m_renderVol) {
        static_cast<IAudioEndpointVolume*>(m_renderVol)->Release();
        m_renderVol = nullptr;
    }
    if (m_captureVol) {
        static_cast<IAudioEndpointVolume*>(m_captureVol)->Release();
        m_captureVol = nullptr;
    }
    if (includeEnumerator && m_enumerator) {
        static_cast<IMMDeviceEnumerator*>(m_enumerator)->Release();
        m_enumerator = nullptr;
    }
#else
    Q_UNUSED(includeEnumerator);
#endif
}

void* AudioService::ensureEndpointVolume(int flow, bool forceReacquire)
{
#ifdef Q_OS_WIN
    void** slot = (flow == static_cast<int>(eCapture)) ? &m_captureVol : &m_renderVol;
    if (forceReacquire && *slot) {
        static_cast<IAudioEndpointVolume*>(*slot)->Release();
        *slot = nullptr;
    }
    if (*slot)
        return *slot;

    if (forceReacquire && m_enumerator) {
        static_cast<IMMDeviceEnumerator*>(m_enumerator)->Release();
        m_enumerator = nullptr;
    }
    if (!m_enumerator) {
        IMMDeviceEnumerator* pEnum = nullptr;
        if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                    __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&pEnum))) || !pEnum) {
            return nullptr;
        }
        m_enumerator = pEnum;
    }

    auto* pEnum = static_cast<IMMDeviceEnumerator*>(m_enumerator);
    IMMDevice* pDev = nullptr;
    if (SUCCEEDED(pEnum->GetDefaultAudioEndpoint(static_cast<EDataFlow>(flow), eConsole, &pDev)) && pDev) {
        IAudioEndpointVolume* pVol = nullptr;
        if (SUCCEEDED(pDev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                                     reinterpret_cast<void**>(&pVol))) && pVol) {
            *slot = pVol;
        }
        pDev->Release();
    }
    return *slot;
#else
    Q_UNUSED(flow);
    Q_UNUSED(forceReacquire);
    return nullptr;
#endif
}

void AudioService::setPaused(bool paused)
{
#ifdef Q_OS_WIN
    if (paused) {
        m_pollTimer.stop();
        releaseCachedEndpoints(false);
    } else if (!m_pollTimer.isActive()) {
        m_pollTimer.start();
        pollMaster();
    }
#else
    Q_UNUSED(paused);
#endif
}

void AudioService::pollMaster()
{
#ifdef Q_OS_WIN
    // Re-resolve default endpoints every ~15s (30 ticks) to catch external device switches cleanly.
    if (++m_endpointRefreshTick >= 30) {
        m_endpointRefreshTick = 0;
        releaseCachedEndpoints(false);
    }
#endif
    readMasterState(true);
    readMicState(true);
}

void AudioService::readMasterState(bool emitOsdIfExternal)
{
#ifdef Q_OS_WIN
    float scalar = 0.0f;
    BOOL muted = FALSE;
    const bool ok = withCachedEndpointVolume(this, eRender, [&](IAudioEndpointVolume* pVol) -> HRESULT {
        HRESULT hr = pVol->GetMasterVolumeLevelScalar(&scalar);
        if (FAILED(hr))
            return hr;
        return pVol->GetMute(&muted);
    });
    if (!ok)
        return;

    const int newVol = qBound(0, qRound(scalar * 100.0f), 100);
    const bool newMute = (muted != FALSE);
    if (!m_initialized || newVol != m_masterVolume || newMute != m_masterMuted) {
        const bool changed = m_initialized && (newVol != m_masterVolume || newMute != m_masterMuted);
        m_masterVolume = newVol;
        m_masterMuted = newMute;
        emit masterChanged();
        if (changed && emitOsdIfExternal) {
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            if (now - m_lastSelfChangeMs > 350) {
                emit volumeOsdRequested(m_masterVolume, m_masterMuted);
                if (!m_startupTimer.isValid() || m_startupTimer.elapsed() >= 600)
                    emit osdRequested(QStringLiteral("volume"), m_masterVolume, m_masterMuted);
            }
        }
    }
#else
    Q_UNUSED(emitOsdIfExternal);
#endif
}

void AudioService::readMicState(bool emitOsdIfExternal)
{
#ifdef Q_OS_WIN
    bool nextSupported = false;
    int nextVol = 0;
    bool nextMute = false;
    withCachedEndpointVolume(this, eCapture, [&](IAudioEndpointVolume* pVol) -> HRESULT {
        float scalar = 0.0f;
        BOOL muted = FALSE;
        HRESULT hr = pVol->GetMasterVolumeLevelScalar(&scalar);
        if (FAILED(hr))
            return hr;
        hr = pVol->GetMute(&muted);
        if (FAILED(hr))
            return hr;
        nextSupported = true;
        nextVol = qBound(0, qRound(scalar * 100.0f), 100);
        nextMute = (muted != FALSE);
        return S_OK;
    });
    if (!m_initialized || nextSupported != m_micSupported
        || nextVol != m_micVolume || nextMute != m_micMuted) {
        const bool changed = m_initialized && m_micSupported && nextSupported
                             && (nextVol != m_micVolume || nextMute != m_micMuted);
        m_micSupported = nextSupported;
        m_micVolume = nextVol;
        m_micMuted = nextMute;
        emit micChanged();
        if (changed && emitOsdIfExternal
            && (!m_startupTimer.isValid() || m_startupTimer.elapsed() >= 600)) {
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            if (now - m_lastMicSelfChangeMs > 350)
                emit osdRequested(QStringLiteral("mic"), m_micVolume, m_micMuted);
        }
    }
#else
    Q_UNUSED(emitOsdIfExternal);
#endif
}

void AudioService::setMasterVolume(int volume)
{
#ifdef Q_OS_WIN
    const int clamped = qBound(0, volume, 100);
    if (!withCachedEndpointVolume(this, eRender, [&](IAudioEndpointVolume* pVol) -> HRESULT {
            return pVol->SetMasterVolumeLevelScalar(static_cast<float>(clamped) / 100.0f, nullptr);
        })) {
        return;
    }
    m_lastSelfChangeMs = QDateTime::currentMSecsSinceEpoch();
    if (m_masterVolume != clamped) {
        m_masterVolume = clamped;
        emit masterChanged();
    }
    if (!m_startupTimer.isValid() || m_startupTimer.elapsed() >= 600)
        emit osdRequested(QStringLiteral("volume"), m_masterVolume, m_masterMuted);
#else
    Q_UNUSED(volume);
#endif
}

void AudioService::toggleMasterMute()
{
#ifdef Q_OS_WIN
    BOOL next = FALSE;
    if (!withCachedEndpointVolume(this, eRender, [&](IAudioEndpointVolume* pVol) -> HRESULT {
            BOOL cur = FALSE;
            HRESULT hr = pVol->GetMute(&cur);
            if (FAILED(hr))
                return hr;
            next = cur ? FALSE : TRUE;
            return pVol->SetMute(next, nullptr);
        })) {
        return;
    }
    m_lastSelfChangeMs = QDateTime::currentMSecsSinceEpoch();
    m_masterMuted = (next != FALSE);
    emit masterChanged();
    if (!m_startupTimer.isValid() || m_startupTimer.elapsed() >= 600)
        emit osdRequested(QStringLiteral("volume"), m_masterVolume, m_masterMuted);
#endif
}

void AudioService::setMicVolume(int volume)
{
#ifdef Q_OS_WIN
    const int clamped = qBound(0, volume, 100);
    const bool ok = withCachedEndpointVolume(this, eCapture, [&](IAudioEndpointVolume* pVol) -> HRESULT {
        return pVol->SetMasterVolumeLevelScalar(static_cast<float>(clamped) / 100.0f, nullptr);
    });
    if (ok) {
        m_lastMicSelfChangeMs = QDateTime::currentMSecsSinceEpoch();
        if (!m_micSupported || m_micVolume != clamped) {
            m_micSupported = true;
            m_micVolume = clamped;
            emit micChanged();
        }
        if (!m_startupTimer.isValid() || m_startupTimer.elapsed() >= 600)
            emit osdRequested(QStringLiteral("mic"), m_micVolume, m_micMuted);
    }
#else
    Q_UNUSED(volume);
#endif
}

void AudioService::toggleMicMute()
{
#ifdef Q_OS_WIN
    bool nextMute = m_micMuted;
    const bool ok = withCachedEndpointVolume(this, eCapture, [&](IAudioEndpointVolume* pVol) -> HRESULT {
        BOOL cur = FALSE;
        HRESULT hr = pVol->GetMute(&cur);
        if (FAILED(hr))
            return hr;
        const BOOL next = cur ? FALSE : TRUE;
        hr = pVol->SetMute(next, nullptr);
        if (SUCCEEDED(hr))
            nextMute = (next != FALSE);
        return hr;
    });
    if (ok) {
        m_lastMicSelfChangeMs = QDateTime::currentMSecsSinceEpoch();
        m_micSupported = true;
        m_micMuted = nextMute;
        emit micChanged();
        if (!m_startupTimer.isValid() || m_startupTimer.elapsed() >= 600)
            emit osdRequested(QStringLiteral("mic"), m_micVolume, m_micMuted);
    }
#endif
}

void AudioService::refreshSessions()
{
#ifdef Q_OS_WIN
    QVariantList out;
    IMMDeviceEnumerator* pEnum = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&pEnum))) || !pEnum)
        return;

    IMMDevice* pDev = nullptr;
    if (SUCCEEDED(pEnum->GetDefaultAudioEndpoint(eRender, eConsole, &pDev)) && pDev) {
        IAudioSessionManager2* pMgr = nullptr;
        if (SUCCEEDED(pDev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                     reinterpret_cast<void**>(&pMgr))) && pMgr) {
            IAudioSessionEnumerator* pList = nullptr;
            if (SUCCEEDED(pMgr->GetSessionEnumerator(&pList)) && pList) {
                int count = 0;
                pList->GetCount(&count);
                QSet<QString> seenKeys;
                for (int i = 0; i < count; ++i) {
                    IAudioSessionControl* pCtrl = nullptr;
                    if (FAILED(pList->GetSession(i, &pCtrl)) || !pCtrl)
                        continue;

                    AudioSessionState state = AudioSessionStateExpired;
                    pCtrl->GetState(&state);
                    if (state == AudioSessionStateExpired) {
                        pCtrl->Release();
                        continue;
                    }

                    IAudioSessionControl2* pCtrl2 = nullptr;
                    DWORD pid = 0;
                    QString dispName;
                    bool isSys = false;
                    if (SUCCEEDED(pCtrl->QueryInterface(__uuidof(IAudioSessionControl2),
                                                        reinterpret_cast<void**>(&pCtrl2))) && pCtrl2) {
                        pCtrl2->GetProcessId(&pid);
                        isSys = (pCtrl2->IsSystemSoundsSession() == S_OK);
                        LPWSTR dn = nullptr;
                        if (SUCCEEDED(pCtrl2->GetDisplayName(&dn)) && dn) {
                            dispName = QString::fromWCharArray(dn);
                            CoTaskMemFree(dn);
                        }
                        pCtrl2->Release();
                    }

                    ISimpleAudioVolume* pSimple = nullptr;
                    float vol = 1.0f;
                    BOOL muted = FALSE;
                    if (SUCCEEDED(pCtrl->QueryInterface(__uuidof(ISimpleAudioVolume),
                                                        reinterpret_cast<void**>(&pSimple))) && pSimple) {
                        pSimple->GetMasterVolume(&vol);
                        pSimple->GetMute(&muted);
                        pSimple->Release();
                    }

                    const QString exePath = isSys ? QString() : processImagePath(pid);
                    const QString key = isSys ? QStringLiteral("system")
                        : (!exePath.isEmpty() ? exePath.toLower() : QString::number(pid));

                    if (!seenKeys.contains(key)) {
                        seenKeys.insert(key);
                        QVariantMap m;
                        m.insert(QStringLiteral("id"), key);
                        m.insert(QStringLiteral("pid"), static_cast<qint64>(pid));
                        m.insert(QStringLiteral("name"), isSys ? QStringLiteral("System Sounds")
                                                               : friendlyAppName(exePath, dispName, pid));
                        m.insert(QStringLiteral("volume"), qBound(0, qRound(vol * 100.0f), 100));
                        m.insert(QStringLiteral("muted"), muted != FALSE);
                        if (!exePath.isEmpty()) {
                            m.insert(QStringLiteral("iconUrl"),
                                     QStringLiteral("image://winicon/exe/")
                                         + QString::fromLatin1(QUrl::toPercentEncoding(exePath)));
                        } else {
                            m.insert(QStringLiteral("iconUrl"), QString());
                        }
                        out.append(m);
                    }
                    pCtrl->Release();
                }
                pList->Release();
            }
            pMgr->Release();
        }
        pDev->Release();
    }
    pEnum->Release();

    if (m_sessions != out) {
        m_sessions = out;
        emit sessionsChanged();
    }
#endif
}

void AudioService::setAppVolume(const QString& sessionId, int volume)
{
#ifdef Q_OS_WIN
    const float target = static_cast<float>(qBound(0, volume, 100)) / 100.0f;
    IMMDeviceEnumerator* pEnum = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&pEnum))) || !pEnum)
        return;

    IMMDevice* pDev = nullptr;
    if (SUCCEEDED(pEnum->GetDefaultAudioEndpoint(eRender, eConsole, &pDev)) && pDev) {
        IAudioSessionManager2* pMgr = nullptr;
        if (SUCCEEDED(pDev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                     reinterpret_cast<void**>(&pMgr))) && pMgr) {
            IAudioSessionEnumerator* pList = nullptr;
            if (SUCCEEDED(pMgr->GetSessionEnumerator(&pList)) && pList) {
                int count = 0;
                pList->GetCount(&count);
                for (int i = 0; i < count; ++i) {
                    IAudioSessionControl* pCtrl = nullptr;
                    if (FAILED(pList->GetSession(i, &pCtrl)) || !pCtrl)
                        continue;
                    IAudioSessionControl2* pCtrl2 = nullptr;
                    DWORD pid = 0;
                    bool isSys = false;
                    if (SUCCEEDED(pCtrl->QueryInterface(__uuidof(IAudioSessionControl2),
                                                        reinterpret_cast<void**>(&pCtrl2))) && pCtrl2) {
                        pCtrl2->GetProcessId(&pid);
                        isSys = (pCtrl2->IsSystemSoundsSession() == S_OK);
                        pCtrl2->Release();
                    }
                    const QString exePath = isSys ? QString() : processImagePath(pid);
                    const QString key = isSys ? QStringLiteral("system")
                        : (!exePath.isEmpty() ? exePath.toLower() : QString::number(pid));
                    if (key == sessionId) {
                        ISimpleAudioVolume* pSimple = nullptr;
                        if (SUCCEEDED(pCtrl->QueryInterface(__uuidof(ISimpleAudioVolume),
                                                            reinterpret_cast<void**>(&pSimple))) && pSimple) {
                            pSimple->SetMasterVolume(target, nullptr);
                            pSimple->Release();
                        }
                    }
                    pCtrl->Release();
                }
                pList->Release();
            }
            pMgr->Release();
        }
        pDev->Release();
    }
    pEnum->Release();
    refreshSessions();
#else
    Q_UNUSED(sessionId);
    Q_UNUSED(volume);
#endif
}

void AudioService::toggleAppMute(const QString& sessionId)
{
#ifdef Q_OS_WIN
    IMMDeviceEnumerator* pEnum = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&pEnum))) || !pEnum)
        return;

    IMMDevice* pDev = nullptr;
    if (SUCCEEDED(pEnum->GetDefaultAudioEndpoint(eRender, eConsole, &pDev)) && pDev) {
        IAudioSessionManager2* pMgr = nullptr;
        if (SUCCEEDED(pDev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                     reinterpret_cast<void**>(&pMgr))) && pMgr) {
            IAudioSessionEnumerator* pList = nullptr;
            if (SUCCEEDED(pMgr->GetSessionEnumerator(&pList)) && pList) {
                int count = 0;
                pList->GetCount(&count);
                bool nextMuteSet = false;
                BOOL nextMute = FALSE;
                for (int i = 0; i < count; ++i) {
                    IAudioSessionControl* pCtrl = nullptr;
                    if (FAILED(pList->GetSession(i, &pCtrl)) || !pCtrl)
                        continue;
                    IAudioSessionControl2* pCtrl2 = nullptr;
                    DWORD pid = 0;
                    bool isSys = false;
                    if (SUCCEEDED(pCtrl->QueryInterface(__uuidof(IAudioSessionControl2),
                                                        reinterpret_cast<void**>(&pCtrl2))) && pCtrl2) {
                        pCtrl2->GetProcessId(&pid);
                        isSys = (pCtrl2->IsSystemSoundsSession() == S_OK);
                        pCtrl2->Release();
                    }
                    const QString exePath = isSys ? QString() : processImagePath(pid);
                    const QString key = isSys ? QStringLiteral("system")
                        : (!exePath.isEmpty() ? exePath.toLower() : QString::number(pid));
                    if (key == sessionId) {
                        ISimpleAudioVolume* pSimple = nullptr;
                        if (SUCCEEDED(pCtrl->QueryInterface(__uuidof(ISimpleAudioVolume),
                                                            reinterpret_cast<void**>(&pSimple))) && pSimple) {
                            if (!nextMuteSet) {
                                BOOL cur = FALSE;
                                pSimple->GetMute(&cur);
                                nextMute = cur ? FALSE : TRUE;
                                nextMuteSet = true;
                            }
                            pSimple->SetMute(nextMute, nullptr);
                            pSimple->Release();
                        }
                    }
                    pCtrl->Release();
                }
                pList->Release();
            }
            pMgr->Release();
        }
        pDev->Release();
    }
    pEnum->Release();
    refreshSessions();
#else
    Q_UNUSED(sessionId);
#endif
}

namespace {
#ifdef Q_OS_WIN
const PROPERTYKEY kFriendlyNameKey = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14
};

const CLSID kClsidPolicyConfigVista = {
    0x294935ce, 0xf637, 0x4e7c, {0xa4, 0x1b, 0xab, 0x25, 0x54, 0x60, 0xb8, 0x62}
};

const IID kIidPolicyConfigVista = {
    0x568b9108, 0x44bf, 0x40b4, {0x90, 0x06, 0x86, 0xaf, 0xe5, 0xb5, 0xa6, 0x20}
};
#endif
} // namespace

void AudioService::refreshOutputDevices()
{
#ifdef Q_OS_WIN
    QVariantList nextList;
    QString nextDefaultId;

    IMMDeviceEnumerator* pEnum = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&pEnum))) || !pEnum) {
        return;
    }

    IMMDevice* pDef = nullptr;
    if (SUCCEEDED(pEnum->GetDefaultAudioEndpoint(eRender, eConsole, &pDef)) && pDef) {
        LPWSTR defIdW = nullptr;
        if (SUCCEEDED(pDef->GetId(&defIdW)) && defIdW) {
            nextDefaultId = QString::fromWCharArray(defIdW);
            CoTaskMemFree(defIdW);
        }
        pDef->Release();
    }

    IMMDeviceCollection* pCol = nullptr;
    if (SUCCEEDED(pEnum->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &pCol)) && pCol) {
        UINT count = 0;
        pCol->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
            IMMDevice* pDev = nullptr;
            if (FAILED(pCol->Item(i, &pDev)) || !pDev)
                continue;
            QString devId;
            LPWSTR idW = nullptr;
            if (SUCCEEDED(pDev->GetId(&idW)) && idW) {
                devId = QString::fromWCharArray(idW);
                CoTaskMemFree(idW);
            }
            QString devName = QStringLiteral("Audio Device");
            IPropertyStore* pProps = nullptr;
            if (SUCCEEDED(pDev->OpenPropertyStore(STGM_READ, &pProps)) && pProps) {
                PROPVARIANT varName;
                PropVariantInit(&varName);
                if (SUCCEEDED(pProps->GetValue(kFriendlyNameKey, &varName))) {
                    if (varName.vt == VT_LPWSTR && varName.pwszVal)
                        devName = QString::fromWCharArray(varName.pwszVal);
                    PropVariantClear(&varName);
                }
                pProps->Release();
            }
            pDev->Release();

            if (!devId.isEmpty()) {
                QVariantMap m;
                m.insert(QStringLiteral("id"), devId);
                m.insert(QStringLiteral("name"), devName);
                m.insert(QStringLiteral("isDefault"), devId == nextDefaultId);
                nextList.append(m);
            }
        }
        pCol->Release();
    }
    pEnum->Release();

    m_outputDevices = nextList;
    m_defaultOutputId = nextDefaultId;
    emit outputDevicesChanged();
#endif
}

bool AudioService::setDefaultOutputDevice(const QString& deviceId)
{
#ifdef Q_OS_WIN
    if (deviceId.isEmpty())
        return false;
    IUnknown* pPol = nullptr;
    HRESULT hr = CoCreateInstance(kClsidPolicyConfigVista, nullptr, CLSCTX_INPROC_SERVER,
                                  kIidPolicyConfigVista, reinterpret_cast<void**>(&pPol));
    if (FAILED(hr) || !pPol)
        return false;

    void** vtbl = *reinterpret_cast<void***>(pPol);
    using FnSetDefaultEndpoint = HRESULT(WINAPI*)(void*, PCWSTR, int);
    auto fnSetDefault = reinterpret_cast<FnSetDefaultEndpoint>(vtbl[12]);

    const std::wstring wid = deviceId.toStdWString();
    hr = fnSetDefault(pPol, wid.c_str(), 0); // eConsole
    fnSetDefault(pPol, wid.c_str(), 1);      // eMultimedia
    fnSetDefault(pPol, wid.c_str(), 2);      // eCommunications
    pPol->Release();

    if (SUCCEEDED(hr)) {
        releaseCachedEndpoints(false);
        m_lastSelfChangeMs = QDateTime::currentMSecsSinceEpoch();
        QTimer::singleShot(60, this, [this]() {
            readMasterState(false);
            refreshOutputDevices();
            refreshSessions();
        });
        return true;
    }
    return false;
#else
    Q_UNUSED(deviceId);
    return false;
#endif
}
