# Manages Bluetooth radio power, paired device listing, and Bluetooth audio connect/disconnect.
# Reads commands from stdin: list | radio on | radio off | connect <ADDR> | disconnect <ADDR>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Devices.Radios.Radio, Windows.Devices.Radios, ContentType=WindowsRuntime]
$null = [Windows.Devices.Radios.RadioKind, Windows.Devices.Radios, ContentType=WindowsRuntime]
$null = [Windows.Devices.Radios.RadioState, Windows.Devices.Radios, ContentType=WindowsRuntime]
$null = [Windows.Devices.Radios.RadioAccessStatus, Windows.Devices.Radios, ContentType=WindowsRuntime]

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type, $timeoutMs = 10000) {
  $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  if (-not $t.Wait($timeoutMs)) { throw 'Bluetooth request timed out' }
  $t.Result
}

$btCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public static class PlayerrBt {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME {
        public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct BLUETOOTH_DEVICE_INFO {
        public uint dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BLUETOOTH_DEVICE_SEARCH_PARAMS {
        public uint dwSize;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnAuthenticated;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnUnknown;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [DllImport("Bthprops.cpl", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BluetoothFindFirstDevice(ref BLUETOOTH_DEVICE_SEARCH_PARAMS pbtsp, ref BLUETOOTH_DEVICE_INFO pbtdi);

    [DllImport("Bthprops.cpl", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BluetoothFindNextDevice(IntPtr hFind, ref BLUETOOTH_DEVICE_INFO pbtdi);

    [DllImport("Bthprops.cpl", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BluetoothFindDeviceClose(IntPtr hFind);

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator {}

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection {
        int GetCount(out uint pcDevices);
        int Item(uint nDevice, out IMMDevice ppDevice);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [Guid("2A07407E-6497-4A18-9787-32F79BD0D98F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceTopology {
        int GetConnectorCount(out uint pCount);
        int GetConnector(uint nIndex, out IConnector ppConnector);
    }

    [Guid("9c2c4058-23f5-41de-877a-df3af236a09e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IConnector {
        int GetType(out int pType);
        int GetDataFlow(out int pFlow);
        int ConnectTo(IConnector pConnectTo);
        int Disconnect();
        int IsConnected(out bool pbConnected);
        int GetConnectedTo(out IConnector ppConTo);
        int GetConnectorIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string ppwstrConnectorId);
        int GetDeviceIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string ppwstrDeviceId);
    }

    [Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IKsControl {
        int KsProperty(ref KSPROPERTY Property, uint PropertyLength, IntPtr PropertyData, uint DataLength, out uint BytesReturned);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KSPROPERTY {
        public Guid Set;
        public uint Id;
        public uint Flags;
    }

    private static readonly Guid KSPROPSETID_BtAudio = new Guid("7FA06C40-B8F6-4C7E-8556-E8C33A12E54D");
    private static readonly Regex BtFilterRegex = new Regex(@"bthenum#\{([0-9a-f-]+)\}[^#]*#[^#]*&([0-9a-f]{12})_", RegexOptions.IgnoreCase);

    public class BtEndpoint {
        public string Addr;
        public string ServiceGuid;
        public string FilterId;
        public bool Active;
    }

    public class BtDeviceItem {
        public string Name;
        public string Addr;
        public bool Connected;
        public bool IsAudio;
        public bool CanControlAudio;
    }

    private static void Release(object obj) {
        if (obj != null && Marshal.IsComObject(obj)) {
            Marshal.ReleaseComObject(obj);
        }
    }

    private static List<BtEndpoint> GetBtAudioEndpoints() {
        var list = new List<BtEndpoint>();
        IMMDeviceEnumerator enumerator = null;
        IMMDeviceCollection col = null;
        try {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            // eRender = 0, DEVICE_STATE_ACTIVE (1) | DEVICE_STATE_UNPLUGGED (8) = 9
            if (enumerator.EnumAudioEndpoints(0, 9, out col) != 0 || col == null) return list;
            uint count;
            col.GetCount(out count);
            Guid iidTopo = typeof(IDeviceTopology).GUID;
            for (uint i = 0; i < count; i++) {
                IMMDevice ep = null;
                IDeviceTopology topo = null;
                IConnector conn = null;
                try {
                    col.Item(i, out ep);
                    int state = 0;
                    ep.GetState(out state);
                    object topoObj;
                    if (ep.Activate(ref iidTopo, 23, IntPtr.Zero, out topoObj) != 0) continue;
                    topo = (IDeviceTopology)topoObj;
                    if (topo.GetConnector(0, out conn) != 0 || conn == null) continue;
                    string devId;
                    if (conn.GetDeviceIdConnectedTo(out devId) != 0 || string.IsNullOrEmpty(devId)) continue;
                    var m = BtFilterRegex.Match(devId);
                    if (!m.Success) continue;
                    list.Add(new BtEndpoint {
                        ServiceGuid = m.Groups[1].Value.ToLowerInvariant(),
                        Addr = m.Groups[2].Value.ToUpperInvariant(),
                        FilterId = devId,
                        Active = (state == 1)
                    });
                } catch {
                } finally {
                    Release(conn);
                    Release(topo);
                    Release(ep);
                }
            }
        } catch {
        } finally {
            Release(col);
            Release(enumerator);
        }
        return list;
    }

    public static List<BtDeviceItem> GetDevices() {
        var endpoints = GetBtAudioEndpoints();
        var audioAddrs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var activeAudioAddrs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var ep in endpoints) {
            audioAddrs.Add(ep.Addr);
            if (ep.Active) activeAudioAddrs.Add(ep.Addr);
        }

        var devices = new List<BtDeviceItem>();
        var sp = new BLUETOOTH_DEVICE_SEARCH_PARAMS {
            dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_SEARCH_PARAMS)),
            fReturnAuthenticated = true,
            fReturnRemembered = true,
            fReturnUnknown = false,
            fReturnConnected = true,
            fIssueInquiry = false,
            cTimeoutMultiplier = 0,
            hRadio = IntPtr.Zero
        };
        var di = new BLUETOOTH_DEVICE_INFO {
            dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO))
        };
        IntPtr h = BluetoothFindFirstDevice(ref sp, ref di);
        if (h == IntPtr.Zero) return devices;
        try {
            do {
                string addr = di.Address.ToString("X12");
                uint majorClass = (di.ulClassofDevice >> 8) & 0x1F;
                bool isAudio = (majorClass == 4) || audioAddrs.Contains(addr);
                bool canControl = audioAddrs.Contains(addr);
                bool connected = di.fConnected || activeAudioAddrs.Contains(addr);
                devices.Add(new BtDeviceItem {
                    Name = string.IsNullOrWhiteSpace(di.szName) ? addr : di.szName,
                    Addr = addr,
                    Connected = connected,
                    IsAudio = isAudio,
                    CanControlAudio = canControl
                });
            } while (BluetoothFindNextDevice(h, ref di));
        } finally {
            BluetoothFindDeviceClose(h);
        }

        devices.Sort((a, b) => {
            int c = b.Connected.CompareTo(a.Connected);
            if (c != 0) return c;
            c = b.IsAudio.CompareTo(a.IsAudio);
            if (c != 0) return c;
            return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        });
        return devices;
    }

    public static string SetAudioConnection(string addr, bool connect) {
        var endpoints = GetBtAudioEndpoints();
        var matches = new List<BtEndpoint>();
        foreach (var ep in endpoints) {
            if (string.Equals(ep.Addr, addr, StringComparison.OrdinalIgnoreCase)) {
                matches.Add(ep);
            }
        }
        if (matches.Count == 0) {
            return "No Bluetooth audio profile found for this device.";
        }
        // Prefer A2DP Audio Sink (0000110b) first when connecting; disconnect all matching profiles when disconnecting.
        matches.Sort((a, b) => {
            bool aA2dp = a.ServiceGuid.StartsWith("0000110b");
            bool bA2dp = b.ServiceGuid.StartsWith("0000110b");
            return bA2dp.CompareTo(aA2dp);
        });

        IMMDeviceEnumerator enumerator = null;
        try {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            Guid iidKs = typeof(IKsControl).GUID;
            int lastHr = 0;
            bool anySuccess = false;
            foreach (var ep in matches) {
                if (connect && anySuccess && !ep.ServiceGuid.StartsWith("0000110b")) continue;
                IMMDevice filter = null;
                IKsControl ks = null;
                try {
                    if (enumerator.GetDevice(ep.FilterId, out filter) != 0 || filter == null) continue;
                    object ksObj;
                    if (filter.Activate(ref iidKs, 23, IntPtr.Zero, out ksObj) != 0 || ksObj == null) continue;
                    ks = (IKsControl)ksObj;
                    var prop = new KSPROPERTY {
                        Set = KSPROPSETID_BtAudio,
                        Id = connect ? 0u : 1u, // 0 = KSPROPERTY_ONESHOT_RECONNECT, 1 = KSPROPERTY_ONESHOT_DISCONNECT
                        Flags = 1u              // KSPROPERTY_TYPE_GET
                    };
                    uint bytesReturned;
                    int hr = ks.KsProperty(ref prop, (uint)Marshal.SizeOf(typeof(KSPROPERTY)), IntPtr.Zero, 0, out bytesReturned);
                    if (hr == 0) {
                        anySuccess = true;
                        if (connect) break;
                    } else {
                        lastHr = hr;
                    }
                } finally {
                    Release(ks);
                    Release(filter);
                }
            }
            if (anySuccess) return "";
            if (lastHr != 0) return "Device did not respond (0x" + lastHr.ToString("X8") + "). Make sure it is powered on and in range.";
            return "Could not access Bluetooth audio endpoint.";
        } finally {
            Release(enumerator);
        }
    }
}
'@
Add-Type -TypeDefinition $btCode

function Get-BtRadio {
  $radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
  foreach ($r in $radios) {
    if ($r.Kind -eq [Windows.Devices.Radios.RadioKind]::Bluetooth) { return $r }
  }
  return $null
}

function Emit-State([string]$err = '') {
  $radio = Get-BtRadio
  $radioState = if ($null -eq $radio) { 'unavailable' } elseif ($radio.State -eq [Windows.Devices.Radios.RadioState]::On) { 'on' } else { 'off' }
  $devs = @()
  if ($radioState -eq 'on') {
    foreach ($d in [PlayerrBt]::GetDevices()) {
      $devs += [ordered]@{
        name = $d.Name
        addr = $d.Addr
        connected = $d.Connected
        isAudio = $d.IsAudio
        canControl = $d.CanControlAudio
      }
    }
  }
  $payload = [ordered]@{
    radio = $radioState
    devices = $devs
  }
  if ($err) { $payload['error'] = $err }
  [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 4))
}

function Set-BtRadio([bool]$on) {
  $radio = Get-BtRadio
  if ($null -eq $radio) { Emit-State 'No Bluetooth adapter found.'; return }
  $target = if ($on) { [Windows.Devices.Radios.RadioState]::On } else { [Windows.Devices.Radios.RadioState]::Off }
  $status = Await ($radio.SetStateAsync($target)) ([Windows.Devices.Radios.RadioAccessStatus])
  if ($status -ne [Windows.Devices.Radios.RadioAccessStatus]::Allowed) {
    Emit-State "Bluetooth permission denied ($status)."
    return
  }
  Start-Sleep -Milliseconds 350
  Emit-State
}

Emit-State
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput())
while ($true) {
  $line = $stdin.ReadLine()
  if ($null -eq $line) { break }
  $trimmed = $line.Trim()
  if (-not $trimmed) { continue }
  $parts = $trimmed -split '\s+', 2
  $err = ''
  try {
    switch ($parts[0]) {
      'list'       { }
      'radio'      { Set-BtRadio ($parts[1] -eq 'on'); continue }
      'connect'    { $err = [PlayerrBt]::SetAudioConnection($parts[1], $true); Start-Sleep -Milliseconds 400 }
      'disconnect' { $err = [PlayerrBt]::SetAudioConnection($parts[1], $false); Start-Sleep -Milliseconds 300 }
    }
  } catch {
    $err = $_.Exception.Message
  }
  Emit-State $err
}
