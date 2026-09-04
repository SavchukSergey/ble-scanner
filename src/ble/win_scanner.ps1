# ble-scanner Windows backend: WinRT BLE advertisement watcher.
#
# Why this exists: PowerShell scriptblocks cannot receive WinRT events
# (Register-ObjectEvent rejects them outright and add_Received handlers never
# fire while the pipeline is blocked). So the watcher runs as inline C#,
# compiled once with the in-box .NET Framework csc.exe and cached in %TEMP%.
#
# Emits one JSON object per line on stdout (same schema as --replay files):
#   {"mac":"AA:BB:CC:DD:EE:FF","atype":0|1,"etype":"ConnectableUndirected",
#    "rssi":-60,"name":"..."|null,"tx":null,"secs":[{"t":N,"d":"HEX"}],
#    "ts":<epoch_ms>}
# Status lines: {"status":"started"} / {"status":"stopped"} / {"error":"..."}
#
# Runs under Windows PowerShell 5.1. The parent process kills us on exit.

$ErrorActionPreference = 'Stop'

function Emit($o) {
    try {
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $o -Compress))
        [Console]::Out.Flush()
    } catch { }
}

# ---------------------------------------------------------------------------
# Embedded C# watcher
# ---------------------------------------------------------------------------
$cs = @'
using System;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

public static class BleWatch {
    static void Handler(BluetoothLEAdvertisementWatcher s, BluetoothLEAdvertisementReceivedEventArgs e) {
        try {
            var sb = new System.Text.StringBuilder(512);
            ulong a = e.BluetoothAddress;
            sb.Append("{\"mac\":\"")
              .Append(((a >> 40) & 0xFF).ToString("X2")).Append(':')
              .Append(((a >> 32) & 0xFF).ToString("X2")).Append(':')
              .Append(((a >> 24) & 0xFF).ToString("X2")).Append(':')
              .Append(((a >> 16) & 0xFF).ToString("X2")).Append(':')
              .Append(((a >> 8) & 0xFF).ToString("X2")).Append(':')
              .Append((a & 0xFF).ToString("X2"))
              .Append("\",\"atype\":").Append(e.BluetoothAddressType == BluetoothAddressType.Random ? 1 : 0)
              .Append(",\"etype\":\"").Append(e.AdvertisementType).Append("\"")
              .Append(",\"rssi\":").Append(e.RawSignalStrengthInDBm)
              .Append(",\"name\":");
            var n = e.Advertisement.LocalName;
            if (string.IsNullOrEmpty(n)) sb.Append("null");
            else {
                sb.Append('"');
                foreach (var c in n) {
                    if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                    else if (c < 0x20) sb.Append(' ');
                    else sb.Append(c);
                }
                sb.Append('"');
            }
            sb.Append(",\"tx\":null");
            sb.Append(",\"secs\":[");
            bool first = true;
            foreach (var sec in e.Advertisement.DataSections) {
                if (!first) sb.Append(',');
                first = false;
                sb.Append("{\"t\":").Append((int)sec.DataType).Append(",\"d\":\"");
                IBuffer buf = sec.Data;
                var reader = DataReader.FromBuffer(buf);
                var bytes = new byte[buf.Length];
                reader.ReadBytes(bytes);
                const string hexd = "0123456789ABCDEF";
                foreach (var b in bytes) {
                    sb.Append(hexd[b >> 4]).Append(hexd[b & 0xF]);
                }
                sb.Append("\"}");
            }
            sb.Append("],\"ts\":").Append(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).Append("}");
            Console.Out.WriteLine(sb.ToString());
            Console.Out.Flush();
        } catch { }
    }

    public static void Go() {
        try {
            var w = new BluetoothLEAdvertisementWatcher();
            w.ScanningMode = BluetoothLEScanningMode.Active;
            w.Received += Handler;
            w.Start();
            Console.Out.WriteLine("{\"status\":\"started\"}");
            Console.Out.Flush();
        } catch (Exception ex) {
            Console.Out.WriteLine("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            Console.Out.Flush();
            return;
        }
        while (true) System.Threading.Thread.Sleep(60000);
    }
}
'@

# ---------------------------------------------------------------------------
# Compile once (cached by source hash) and run
# ---------------------------------------------------------------------------
try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cs))
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').Substring(0, 16)

    $dir = Join-Path $env:TEMP 'ble-scanner'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dll = Join-Path $dir "BleWatch-$hash.dll"

    if (-not (Test-Path $dll)) {
        $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path $csc)) {
            $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        }
        if (-not (Test-Path $csc)) {
            Emit @{ error = 'csc.exe not found (.NET Framework runtime missing)' }
            exit 1
        }

        $wm = Join-Path $env:windir 'System32\WinMetadata'
        $fwDir = Split-Path -Parent $csc
        $refs = @(
            (Join-Path $wm 'Windows.Devices.winmd'),
            (Join-Path $wm 'Windows.Storage.winmd'),
            (Join-Path $wm 'Windows.Foundation.winmd'),
            (Join-Path $fwDir 'System.Runtime.dll')
        )
        # System.Runtime.InteropServices.WindowsRuntime (EventRegistrationToken)
        try {
            $srwr = [System.Reflection.Assembly]::Load(
                'System.Runtime.InteropServices.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
            if ($srwr -and $srwr.Location) { $refs += $srwr.Location }
        } catch {
            $gac = Get-ChildItem "$env:windir\Microsoft.NET\assembly\GAC_MSIL\System.Runtime.InteropServices.WindowsRuntime\*\System.Runtime.InteropServices.WindowsRuntime.dll" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($gac) { $refs += $gac.FullName }
        }

        $csFile = Join-Path $dir "BleWatch-$hash.cs"
        Set-Content -Path $csFile -Value $cs -Encoding ASCII

        $argList = @('-nologo', '-target:library', "-out:$dll")
        foreach ($r in $refs) { $argList += "-r:$r" }
        $argList += $csFile
        $out = & $csc @argList 2>&1
        if ($LASTEXITCODE -ne 0) {
            Emit @{ error = 'compile failed: ' + ($out | Out-String) }
            exit 1
        }
    }

    Add-Type -Path $dll
    [BleWatch]::Go()
    exit 0
} catch {
    Emit @{ error = $_.Exception.Message }
    exit 1
}
