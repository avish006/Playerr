# Windows Core Audio helper for Playerr (master volume, mute, default output device name).
$audioSource = @'
using System;
using System.Runtime.InteropServices;

public static class PlayerrAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator {}

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PROPERTYKEY pkey);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(out uint pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPVARIANT {
        public ushort vt, r1, r2, r3;
        public IntPtr p1, p2;
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    private static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY {
        fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
        pid = 14
    };

    private static void Release(object obj) {
        if (obj != null && Marshal.IsComObject(obj)) {
            Marshal.ReleaseComObject(obj);
        }
    }

    private static IMMDevice GetDefaultRenderDevice(out IMMDeviceEnumerator enumerator) {
        enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice device;
        int hr = enumerator.GetDefaultAudioEndpoint(0, 1, out device); // eRender = 0, eMultimedia = 1
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        return device;
    }

    public static void ReadState(out int volumePercent, out bool muted, out string deviceName) {
        volumePercent = 0;
        muted = false;
        deviceName = "";
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        IPropertyStore props = null;
        IAudioEndpointVolume vol = null;
        try {
            device = GetDefaultRenderDevice(out enumerator);
            Guid iidVol = typeof(IAudioEndpointVolume).GUID;
            object volObj;
            Marshal.ThrowExceptionForHR(device.Activate(ref iidVol, 23, IntPtr.Zero, out volObj));
            vol = (IAudioEndpointVolume)volObj;

            float scalar;
            Marshal.ThrowExceptionForHR(vol.GetMasterVolumeLevelScalar(out scalar));
            volumePercent = Math.Max(0, Math.Min(100, (int)Math.Round(scalar * 100f)));

            bool isMuted;
            Marshal.ThrowExceptionForHR(vol.GetMute(out isMuted));
            muted = isMuted;

            if (device.OpenPropertyStore(0, out props) == 0 && props != null) {
                PROPVARIANT pv;
                var key = PKEY_Device_FriendlyName;
                if (props.GetValue(ref key, out pv) == 0) {
                    if (pv.vt == 31 && pv.p1 != IntPtr.Zero) {
                        deviceName = Marshal.PtrToStringUni(pv.p1) ?? "";
                    }
                    PropVariantClear(ref pv);
                }
            }
        } catch {
            // Leave defaults if no active audio output endpoint is present.
        } finally {
            Release(vol);
            Release(props);
            Release(device);
            Release(enumerator);
        }
    }

    public static void SetVolumePercent(int percent) {
        int clamped = Math.Max(0, Math.Min(100, percent));
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        IAudioEndpointVolume vol = null;
        try {
            device = GetDefaultRenderDevice(out enumerator);
            Guid iidVol = typeof(IAudioEndpointVolume).GUID;
            object volObj;
            Marshal.ThrowExceptionForHR(device.Activate(ref iidVol, 23, IntPtr.Zero, out volObj));
            vol = (IAudioEndpointVolume)volObj;
            Marshal.ThrowExceptionForHR(vol.SetMasterVolumeLevelScalar(clamped / 100f, Guid.Empty));
            if (clamped > 0) {
                bool isMuted;
                if (vol.GetMute(out isMuted) == 0 && isMuted) {
                    vol.SetMute(false, Guid.Empty);
                }
            }
        } finally {
            Release(vol);
            Release(device);
            Release(enumerator);
        }
    }

    public static void ToggleMute() {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        IAudioEndpointVolume vol = null;
        try {
            device = GetDefaultRenderDevice(out enumerator);
            Guid iidVol = typeof(IAudioEndpointVolume).GUID;
            object volObj;
            Marshal.ThrowExceptionForHR(device.Activate(ref iidVol, 23, IntPtr.Zero, out volObj));
            vol = (IAudioEndpointVolume)volObj;
            bool isMuted;
            Marshal.ThrowExceptionForHR(vol.GetMute(out isMuted));
            Marshal.ThrowExceptionForHR(vol.SetMute(!isMuted, Guid.Empty));
        } finally {
            Release(vol);
            Release(device);
            Release(enumerator);
        }
    }
}
'@

if (-not ('PlayerrAudio' -as [type])) {
    Add-Type -TypeDefinition $audioSource
}

function Get-AudioState {
    $vol = 0; $muted = $false; $name = ''
    [PlayerrAudio]::ReadState([ref]$vol, [ref]$muted, [ref]$name)
    return @{ vol = $vol; muted = $muted; audioOut = $name }
}

function Set-MasterVolume([int]$percent) {
    try { [PlayerrAudio]::SetVolumePercent($percent) } catch {}
}

function Toggle-MasterMute {
    try { [PlayerrAudio]::ToggleMute() } catch {}
}
