@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $d='@'+[char]35+'@PSSTART@'+[char]35+'@'; $f='%~f0'; $_dir=Split-Path -Parent $f; $src=[System.IO.File]::ReadAllText($f,[System.Text.Encoding]::UTF8); iex(($src -split $d)[1]) }"
goto :eof
@#@PSSTART@#@
# --- Port Monitor v2.0 - Self-contained launcher ---
# All components are generated on first Setup from this single file.

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dir          = $_dir
$dataDir      = Join-Path $dir "components"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$scriptFile   = Join-Path $dataDir "port-monitor.ps1"
$readmeScript = Join-Path $dataDir "readme-viewer.ps1"
$stateFile    = Join-Path $dataDir "port-monitor-state.json"
$configFile   = Join-Path $dataDir "port-monitor.config.json"
$passwordFile = Join-Path $dataDir "readme-password.json"
$icoFile      = Join-Path $dataDir "port-monitor.ico"
$logFile      = Join-Path $dataDir "port-monitor.log"

$DEFAULT_HASH = "5994471ABB01112AFCC18159F6CC74B4F511B99806DA59B3CAF5A9C173CACFC5"

# ==================== EMBEDDED: port-monitor.ps1 ====================
$PM_SCRIPT = @'
#Requires -Version 5.1
# port-monitor.ps1 - Open-port monitor with tamper protection
# Usage:
#   Normal (Task Scheduler) : powershell -ExecutionPolicy Bypass -File port-monitor.ps1
#   Demo / test             : powershell -ExecutionPolicy Bypass -File port-monitor.ps1 -Demo
# Setup is handled by port-monitor.bat (the launcher).

param([switch]$Demo)

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir  = Split-Path -Parent $scriptPath
$logFile    = Join-Path $scriptDir "port-monitor.log"
$stateFile  = Join-Path $scriptDir "port-monitor-state.json"
$configFile = Join-Path $scriptDir "port-monitor.config.json"

$IDLE_ALERT_MIN = 60
$DIALOG_TIMEOUT = 45

$builtinProcesses = @(
    'svchost','System','lsass','wininit','spoolsv','services','jhi_service',
    'MsMpEng','SecurityHealthService','SgrmBroker','WmiPrvSE','dllhost',
    'RuntimeBroker','ApplicationFrameHost','ShellExperienceHost','TextInputHost',
    'TabTip','ctfmon','SearchIndexer','explorer','msiexec','TiWorker',
    'Spotify','chrome','firefox','msedge','OneDrive','OneDrive.Sync.Service',
    'Teams','slack','zoom','discord','Skype','outlook',
    'Code','Cursor','idea64','pycharm64','devenv','node','python','java',
    'FortiSSLVPNdaemon','openvpn','vpnkit','AnyDesk','TeamViewer',
    'PlexMediaServer','plex','vlc','HandBrake'
)

$builtinPorts = @(
    80,135,139,443,445,902,912,1900,3306,3389,3555,5040,5357,
    5353,5900,7680,8053,8080,8443,9009,10243,33060,42050,49664
)

$builtinUDPPorts = @(
    53,67,68,123,137,138,500,1900,1980,3544,3702,4500,
    5004,5005,5050,5353,5355,5938,8053
)

$activeStates = @('Established','CloseWait','SynReceived','SynSent','FinWait1','FinWait2','TimeWait')

function Write-Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg" | Add-Content -Path $logFile
}

function Load-State {
    if (Test-Path $stateFile) {
        try { return Get-Content $stateFile -Raw | ConvertFrom-Json } catch {}
    }
    return [PSCustomObject]@{ consentGiven=$false; scriptHash=$null; lastAlertedAt=$null; idle=@(); active=@() }
}

function Save-State([object]$state) {
    $state | ConvertTo-Json -Depth 3 | Set-Content $stateFile
}

function Get-ScriptHash {
    return (Get-FileHash -Path $scriptPath -Algorithm SHA256).Hash
}

function Load-Config {
    $cfg = [PSCustomObject]@{ extraProcesses=@(); extraPorts=@(); extraUDPPorts=@() }
    if (Test-Path $configFile) {
        try {
            $raw = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($raw.extraProcesses) { $cfg.extraProcesses = $raw.extraProcesses }
            if ($raw.extraPorts)     { $cfg.extraPorts     = $raw.extraPorts }
            if ($raw.extraUDPPorts)  { $cfg.extraUDPPorts  = $raw.extraUDPPorts }
        } catch {}
    }
    return $cfg
}

function Set-ScriptReadOnly([bool]$ro) {
    try { Set-ItemProperty -Path $scriptPath -Name IsReadOnly -Value $ro } catch {}
}

function Invoke-TamperCheck([object]$state) {
    if (-not $state.scriptHash) { return }
    $current = Get-ScriptHash
    if ($current -ne $state.scriptHash) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "port-monitor.ps1 has been modified since it was last verified.`n`nThe script will NOT run.`nRun port-monitor.bat and click Re-run Setup to re-verify.",
            "Port Monitor - Tamper Detected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Stop
        ) | Out-Null
        Write-Log "TAMPER DETECTED - hash mismatch. Aborting."
        exit 1
    }
}

function Show-SummaryWindow([object[]]$entries) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:countdown = $DIALOG_TIMEOUT
    $sorted     = $entries | Sort-Object { [datetime]$_.FirstSeenIdle }
    $oldestPort = $sorted[0].Port

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Port Monitor - Idle Ports Detected"
    $form.Size            = New-Object System.Drawing.Size(500, 330)
    $form.StartPosition   = "Manual"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $true

    $screen        = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($screen.Right - $form.Width - 12), ($screen.Bottom - $form.Height - 12))

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Ports idle 1+ hour. Check boxes to close:"
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(468, 20)
    $form.Controls.Add($lbl)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location     = New-Object System.Drawing.Point(12, 38)
    $clb.Size         = New-Object System.Drawing.Size(468, 175)
    $clb.CheckOnClick = $true
    foreach ($e in $sorted) {
        $mins     = [int]((Get-Date) - [datetime]$e.FirstSeenIdle).TotalMinutes
        $isOldest = ($e.Port -eq $oldestPort)
        $proto    = if ($e.Protocol) { $e.Protocol } else { 'TCP' }
        $label    = "[$proto]  Port $($e.Port)  -  $($e.Process)  (idle $mins min)"
        if ($isOldest) { $label += "  [triggered alert]" }
        $clb.Items.Add($label, $isOldest) | Out-Null
    }
    $form.Controls.Add($clb)

    $btnSelAll           = New-Object System.Windows.Forms.Button
    $btnSelAll.Text      = "Select All"
    $btnSelAll.Location  = New-Object System.Drawing.Point(12, 223)
    $btnSelAll.Size      = New-Object System.Drawing.Size(86, 26)
    $btnSelAll.Add_Click({ for ($i=0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i,$true) } })
    $form.Controls.Add($btnSelAll)

    $timerLbl           = New-Object System.Windows.Forms.Label
    $timerLbl.Text      = "Auto-closing in $script:countdown s"
    $timerLbl.Location  = New-Object System.Drawing.Point(106, 227)
    $timerLbl.Size      = New-Object System.Drawing.Size(182, 18)
    $timerLbl.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($timerLbl)

    $btnClose           = New-Object System.Windows.Forms.Button
    $btnClose.Text      = "Close Selected"
    $btnClose.Location  = New-Object System.Drawing.Point(298, 223)
    $btnClose.Size      = New-Object System.Drawing.Size(99, 26)
    $btnClose.Add_Click({ $form.Tag = "close"; $form.Close() })
    $form.Controls.Add($btnClose)

    $btnIgnore           = New-Object System.Windows.Forms.Button
    $btnIgnore.Text      = "Ignore"
    $btnIgnore.Location  = New-Object System.Drawing.Point(405, 223)
    $btnIgnore.Size      = New-Object System.Drawing.Size(72, 26)
    $btnIgnore.Add_Click({ $form.Close() })
    $form.Controls.Add($btnIgnore)

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:countdown--
        $timerLbl.Text = "Auto-closing in $script:countdown s"
        if ($script:countdown -le 0) { $timer.Stop(); $form.Close() }
    })
    $timer.Start()
    $null = $form.ShowDialog()
    $timer.Stop()

    if ($form.Tag -eq "close") {
        $out = @()
        for ($i=0; $i -lt $clb.Items.Count; $i++) {
            if ($clb.GetItemChecked($i)) { $out += $sorted[$i] }
        }
        return $out
    }
    return @()
}

function Invoke-Demo {
    Write-Host "Starting demo listener on port 12345..."
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $listenerCode = '$l=New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any,12345);$l.Start();Start-Sleep 300;$l.Stop()'
    [System.IO.File]::WriteAllText($tmp, $listenerCode, [System.Text.Encoding]::ASCII)
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -File `"$tmp`""
    Start-Sleep -Seconds 2

    $conn = Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 12345
    if (-not $conn) { Write-Host "Could not open port 12345."; exit 1 }
    Write-Host "Port 12345 listening (PID $($conn.OwningProcess)). Registering..."

    $ds = Load-State
    $ds.idle = @($ds.idle | Where-Object { -not ($_.Port -eq 12345 -and ($_.Protocol -eq 'TCP' -or -not $_.Protocol)) })
    $ds.lastAlertedAt = (Get-Date).ToString("o")
    Save-State $ds

    Invoke-Scan

    $state = Load-State
    $entry = $state.idle | Where-Object { $_.Port -eq 12345 -and ($_.Protocol -eq 'TCP' -or -not $_.Protocol) } | Select-Object -First 1
    if ($entry) {
        $entry.FirstSeenIdle = (Get-Date).AddMinutes(-65).ToString("o")
        $state.lastAlertedAt = $null
        Save-State $state
        Write-Host "Rewound to 65 min idle. Triggering alert..."
        Invoke-Scan
    } else {
        Write-Host "Port 12345 not in idle list. Current idle:"
        $state.idle | Select-Object Protocol, Port, Process | Format-Table
    }
    exit 0
}

function Invoke-Scan {
    $cfg        = Load-Config
    $safeProcs  = $builtinProcesses + $cfg.extraProcesses
    $sTCPPorts  = $builtinPorts     + $cfg.extraPorts
    $sUDPPorts  = $builtinUDPPorts  + $cfg.extraUDPPorts + $cfg.extraPorts

    # --- TCP ---
    $allConns    = Get-NetTCPConnection
    $listening   = $allConns | Where-Object State -eq 'Listen' | Sort-Object LocalPort -Unique
    $activeConns = $allConns | Where-Object { $_.State -in $activeStates }

    $enrichedTCP = $listening | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess
        [PSCustomObject]@{
            Port     = $_.LocalPort
            Address  = $_.LocalAddress
            PID      = $_.OwningProcess
            Process  = if ($proc) { $proc.Name } else { 'unknown' }
            Protocol = 'TCP'
        }
    }

    $unknownTCP = $enrichedTCP | Where-Object {
        $_.Process -notin $safeProcs -and $_.Port -notin $sTCPPorts -and $_.Port -lt 49152 -and
        $_.Address -notin @('127.0.0.1', '::1', '0:0:0:0:0:0:0:1')
    }

    $tcpIdleNow = [System.Collections.Generic.List[object]]::new()
    $activeNow  = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $unknownTCP) {
        $rel = $activeConns | Where-Object { $_.LocalPort -eq $e.Port -or $_.RemotePort -eq $e.Port }
        if ($rel) { $activeNow.Add($e) } else { $tcpIdleNow.Add($e) }
    }

    # --- UDP ---
    $udpEndpoints = Get-NetUDPEndpoint | Sort-Object LocalPort -Unique
    $enrichedUDP  = $udpEndpoints | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess
        [PSCustomObject]@{
            Port     = $_.LocalPort
            Address  = $_.LocalAddress
            PID      = $_.OwningProcess
            Process  = if ($proc) { $proc.Name } else { 'unknown' }
            Protocol = 'UDP'
        }
    }

    $udpIdleNow = [System.Collections.Generic.List[object]]::new()
    foreach ($e in ($enrichedUDP | Where-Object {
        $_.Process -notin $safeProcs -and $_.Port -notin $sUDPPorts -and $_.Port -lt 49152
    })) { $udpIdleNow.Add($e) }

    # --- Track idle times (TCP + UDP combined) ---
    $state = Load-State
    $now   = Get-Date

    $updatedIdle = [System.Collections.Generic.List[object]]::new()

    foreach ($e in $tcpIdleNow) {
        $key  = "TCP:$($e.Process):$($e.Port)"
        $prev = $state.idle | Where-Object { "TCP:$($_.Process):$($_.Port)" -eq $key -or ($_.Port -eq $e.Port -and $_.Process -eq $e.Process -and -not $_.Protocol) } | Select-Object -First 1
        $fs   = if ($prev -and $prev.FirstSeenIdle) { [datetime]$prev.FirstSeenIdle } else { $now }
        $updatedIdle.Add([PSCustomObject]@{
            Port=($e.Port); Address=($e.Address); PID=($e.PID); Process=($e.Process)
            Protocol='TCP'; FirstSeenIdle=$fs.ToString("o")
        })
    }

    foreach ($e in $udpIdleNow) {
        $key  = "UDP:$($e.Process):$($e.Port)"
        $prev = $state.idle | Where-Object { "UDP:$($_.Process):$($_.Port)" -eq $key } | Select-Object -First 1
        $fs   = if ($prev -and $prev.FirstSeenIdle) { [datetime]$prev.FirstSeenIdle } else { $now }
        $updatedIdle.Add([PSCustomObject]@{
            Port=($e.Port); Address=($e.Address); PID=($e.PID); Process=($e.Process)
            Protocol='UDP'; FirstSeenIdle=$fs.ToString("o")
        })
    }

    $lastAlert    = if ($state.lastAlertedAt) { [datetime]$state.lastAlertedAt } else { $null }
    $oldestMin    = if ($updatedIdle.Count -gt 0) {
        ($updatedIdle | ForEach-Object { ($now - [datetime]$_.FirstSeenIdle).TotalMinutes } | Measure-Object -Minimum).Minimum
    } else { 0 }
    $sinceAlert   = if ($lastAlert) { ($now - $lastAlert).TotalMinutes } else { [double]::MaxValue }
    $shouldAlert  = ($updatedIdle.Count -gt 0) -and ($oldestMin -ge $IDLE_ALERT_MIN) -and ($sinceAlert -ge $IDLE_ALERT_MIN)

    if ($shouldAlert) {
        $desc = ($updatedIdle | ForEach-Object { "$($_.Protocol) Port $($_.Port)/$($_.Process)" }) -join ", "
        Write-Log "IDLE-ALERT (oldest=$([int]$oldestMin) min): $desc"
        $toClose = Show-SummaryWindow @($updatedIdle)
        $state.lastAlertedAt = $now.ToString("o")
        foreach ($e in $toClose) {
            $proc = Get-Process -Id $e.PID
            if ($proc) { Stop-Process -Id $e.PID -Force; Write-Log "CLOSED: $($e.Protocol) Port $($e.Port) - $($e.Process) (PID $($e.PID))" }
        }
    }

    $state.idle   = @($updatedIdle)
    $state.active = @($activeNow)
    Save-State $state

    Write-Log "Scan | TCP listen=$($enrichedTCP.Count) unknown=$($unknownTCP.Count) idle=$($tcpIdleNow.Count) active=$($activeNow.Count) | UDP listen=$($enrichedUDP.Count) unknown=$($udpIdleNow.Count)"
    if ($activeNow.Count -gt 0) {
        Write-Log "INFO active-unknown TCP: $(($activeNow | ForEach-Object { "Port $($_.Port)/$($_.Process)" }) -join ", ")"
    }
}

# Entry point
if ($Demo) { Invoke-Demo; exit 0 }

$state = Load-State
if (-not $state.consentGiven) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Port Monitor has not been set up on this computer.`n`nRun port-monitor.bat and click Setup to initialize.",
        "Port Monitor - Setup Required",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}
Invoke-TamperCheck $state
Invoke-Scan
'@
# ==================== EMBEDDED: readme-viewer.ps1 ====================
$RV_SCRIPT = @'
#Requires -Version 5.1
# readme-viewer.ps1 - Password-protected README viewer for Port Monitor
# Default password: 12345
# To change password: use "Change Password" button inside, or ask Claude Code.
# Run: powershell -ExecutionPolicy Bypass -File readme-viewer.ps1

param([switch]$SetupMode)

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$passwordFile = Join-Path $scriptDir "readme-password.json"

$DEFAULT_HASH = "5994471ABB01112AFCC18159F6CC74B4F511B99806DA59B3CAF5A9C173CACFC5"

function Get-Hash([string]$plain) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $hash  = $sha.ComputeHash($bytes)
    return ($hash | ForEach-Object { $_.ToString("X2") }) -join ""
}

function Load-StoredHash {
    if (Test-Path $passwordFile) {
        try {
            $obj = Get-Content $passwordFile -Raw | ConvertFrom-Json
            if ($obj.hash) { return $obj.hash.ToUpper() }
        } catch {}
    }
    return $DEFAULT_HASH
}

function Save-Hash([string]$hash) {
    @{ hash = $hash.ToUpper(); updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } |
        ConvertTo-Json | Set-Content $passwordFile
}

function Show-Content {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $isSetup = [bool]$SetupMode

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = if ($isSetup) { "Port Monitor - About This Tool (Setup)" } else { "Port Monitor - README" }
    $form.Size            = New-Object System.Drawing.Size(780, 720)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MinimumSize     = New-Object System.Drawing.Size(600, 500)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock      = "Fill"
    $rtb.ReadOnly  = $true
    $rtb.Font      = New-Object System.Drawing.Font("Consolas", 10)
    $rtb.WordWrap  = $true
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
    $rtb.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)

    $rtb.Text = @"
================================================================
        PORT MONITOR - README
        Monitor for open ports & security alerts
================================================================

ENGLISH
-------

WHAT IS THIS TOOL?
  Port Monitor is a lightweight background security tool for Windows.
  It watches for TCP and UDP ports that are open (listening) but have no
  active traffic - these are called "idle" ports.

  An idle port that stays open for a long time without being used
  could indicate a forgotten process, a leftover tool from a
  security exercise, or - in the worst case - a backdoor.

WHY PORT MONITOR?
  Tools like nmap or netstat give a point-in-time snapshot:
  "what is open RIGHT NOW?" They cannot tell you whether a
  port should still be open, or how long it has been idle.

  Port Monitor runs continuously INSIDE your machine and
  tracks how long each unknown port has been idle.
  It alerts only after one full hour of no active connections.

  Key advantages:
  * Idle time tracking: a forgotten listener sits idle for
    hours. A real service always has traffic. Port Monitor
    catches exactly this difference.
  * Automatic: runs every 15 min via Task Scheduler.
    No manual scanning or external machine needed.
  * Smart whitelist: ~35 known-safe processes, ~25 ports.
    Only genuinely unknown listeners trigger alerts.
  * Localhost exclusion: 127.0.0.1 listeners are ignored.
    Pentest tools that accept remote connections MUST use
    0.0.0.0 - loopback is unreachable from the network.
  * Process identification: alerts show who owns the port.
    "[TCP] Port 4444 - powershell (idle 87 min)"
  * Single file: no Python, no Node.js, no installer.
    Copy the .bat file anywhere and run it.
  * Pentest-workflow aware: built for Kali VM exercises
    where reverse shell listeners get forgotten.

HOW DOES IT WORK?
  1. Every 15 minutes, a hidden background task scans all open TCP
     and UDP ports.
  2. For each unknown TCP port, it checks: does it have any active
     connections (Established, CloseWait, etc.)? If yes -> ignored.
     If no connections for 1 hour -> ALERT.
     For unknown UDP ports (connectionless): tracked from first
     appearance. Same UDP listener open for 1 hour -> ALERT.
  3. A small window appears in the BOTTOM-RIGHT of your screen
     listing all idle ports. It auto-closes after 45 seconds.
  4. You can check the ports you want to close and click
     "Close Selected". The system will terminate that process.
  5. The port that triggered the alert is pre-checked by default.

WHAT IT DOES NOT DO:
  - Does NOT send data over the internet
  - Does NOT log your traffic or keystrokes
  - Does NOT run as a persistent background service (Task Scheduler only)
  - Does NOT modify your firewall rules
  - Does NOT interfere with ports it recognizes as normal

TAMPER PROTECTION:
  After first-time setup, the monitoring script becomes read-only.
  Every time it runs, it verifies its own integrity automatically.
  If the file was modified (e.g. by malware injecting a backdoor),
  the script refuses to run and shows a red warning.
  To re-approve after an intentional update: run Setup again.

WHITELIST - WHAT GETS IGNORED:
  Common Windows processes and ports are ignored automatically:
  svchost, System, lsass, MsMpEng (Defender), explorer,
  Chrome, Firefox, Spotify, Teams, Zoom, AnyDesk, Plex, MySQL,
  TCP ports: 80, 443, 445, 3306, 3389, 9009 and many more.
  UDP ports: 53 (DNS), 67/68 (DHCP), 123 (NTP), 1900 (SSDP),
             5353 (mDNS), 5355 (LLMNR) and many more.

  To add your own exceptions, edit:
  port-monitor.config.json  (created in the same folder as the script)
  Example:
    { "extraProcesses": ["myapp"], "extraPorts": [8888], "extraUDPPorts": [1234] }

LAUNCHER (port-monitor.bat):
  Double-click port-monitor.bat to open the control panel:
  - [Setup / Re-run Setup]  - first-time install or re-approve
  - [Run Demo]              - test the alert window (requires setup first)
  - [Disable Monitoring]    - stops scheduled scans (PASSWORD REQUIRED)
  - [Enable Monitoring]     - resumes scheduled scans (no password needed)

  WHY is Disable password-protected but Enable is not?
  An attacker who gains access to your machine might want to DISABLE
  monitoring to avoid detection before planting a backdoor.
  Re-enabling monitoring is always safe, so it needs no protection.

README VIEWER:
  This file. Password-protected after first-time setup.
  Default password: 12345
  - During Setup, you can read this file without a password.
    After that, a password is required every time.
  - On first login with the default password, you will be asked
    to change it.
  - The password is stored securely (never as plain text).
  - To change password: use the "Change Password" button below.
  - If you forget your password: ask Claude Code to reset it.
    Claude will update readme-password.json with a new value.

HOW TO INSTALL ON A NEW COMPUTER:
  1. Copy port-monitor.bat to any location (single file is enough).
  2. Double-click port-monitor.bat.
  3. Read the consent dialog, check the box, and click Approve.
  4. When offered, you can read about the tool right here (no password).
  5. Done. Task Scheduler and Desktop shortcuts are created automatically.

HOW TO RUN A DEMO:
  Double-click port-monitor.bat -> click "Run Demo".
  This opens a test listener on port 12345, simulates 65 minutes
  of idle time, and shows the alert window so you can see it work.
  The launcher stays open - you can run Setup or other actions
  without reopening it after the demo.

FILES IN THIS FOLDER:
  port-monitor.bat          - Main launcher (double-click to open)
  port-monitor.ps1          - Monitoring script (read-only after setup)
  readme-viewer.ps1         - This README viewer
  readme-password.json      - Stores access password (securely)
  port-monitor-state.json   - Created on first run: tracks idle ports
  port-monitor.config.json  - Created on setup: your whitelist additions
  port-monitor.log          - Created on first run: scan history

----------------------------------------------------------------

עברית
-----

מה זה הכלי הזה?
  כלי האבטחה Port Monitor הוא קל-משקל ל-Windows.
  הוא סורק פורטים TCP ו-UDP פתוחים שאינם בשימוש פעיל -
  כלומר, אין תעבורת נתונים דרכם.

  פורט שנמצא פתוח שעה שלמה ללא שימוש עלול להעיד על:
  כלי pentest שנשכח פתוח לאחר תרגיל, תהליך שנשאר
  פעיל בטעות, או - במקרה הגרוע - backdoor.

למה Port Monitor?
  כלים כמו nmap ו-netstat נותנים תמונת מצב ברגע נתון:
  "מה פתוח עכשיו?" הם לא יכולים לענות אם פורט
  אמור להיות פתוח, או כמה זמן הוא עומד ריק.

  הגישה שונה: ניטור רציף מתוך המחשב שלך עצמו.
  עוקב כמה זמן כל פורט לא-מוכר עומד ללא חיבורים.
  התראה מופיעה רק אחרי שעה שלמה של idle.

  יתרונות מרכזיים:
  • מעקב idle: listener שנשכח שעות ריק — שירות לגיטימי תמיד פעיל.
  • אוטומטי: רץ כל 15 דקות דרך Task Scheduler,
    ללא הפעלה ידנית.
  • רשימת היתרים חכמה: 35+ תהליכים, 25+ פורטים.
    רק listeners לא-מוכרים מייצרים התראה.
  • סינון localhost: listeners על 127.0.0.1 מוחרגים.
    כלי pentest שצריך חיבורים מרוחקים חייב 0.0.0.0.
  • זיהוי תהליך: "[TCP] Port 4444 - powershell (idle 87 min)".
  • קובץ יחיד: אין Python, אין Node.js, אין installer.
    מעתיקים את ה-.bat לכל מקום ומריצים.
  • מותאם לפנטסט: מיועד לתרגילי Kali VM שבהם
    נשכחים פתוחים — reverse shell listeners.

איך זה עובד?
  • כל 15 דקות משימת רקע סורקת פורטי TCP ו-UDP.
  • לכל פורט TCP לא-מוכר: יש חיבורים פעילים? כן - מתעלמים.
    לא - צבר שעה ללא תעבורה - התראה.
    פורט UDP לא-מוכר, connectionless: נשמר פתוח שעה? - התראה.
  • חלון קטן מופיע בפינה ימין-תחתון עם רשימת הפורטים.
    נסגר אוטומטית אחרי 45 שניות.
  • ניתן לסמן פורטים לסגירה וללחוץ "Close Selected".
    המערכת תסיים את התהליך המחזיק אותו.
  • הפורט שהפעיל את ההתראה מסומן מראש כברירת-מחדל.

מה זה לא עושה:
  - אינו שולח נתונים לאינטרנט
  - אינו מתעד תעבורה או הקשות
  - אינו רץ כשירות קבוע - רק Task Scheduler
  - אינו משנה כללי חומת האש
  - אינו מפריע לפורטים לגיטימיים

הגנת קובץ — Tamper Protection:
  לאחר ההתקנה, סקריפט הניטור הופך לקריאה-בלבד.
  בכל הפעלה הוא מאמת את שלמות עצמו אוטומטית.
  אם הקובץ שונה ללא רשות, למשל על-ידי תוכנת זדון,
  הסקריפט מסרב לרוץ ומציג אזהרה אדומה.

לאונצ'ר — port-monitor.bat:
  לחיצה כפולה על port-monitor.bat פותחת לוח שליטה:
  • התקנה ראשונה / אישור מחדש  — [Setup]
  • הדגמת חלון ההתראה          — [Run Demo]
  • עצירת הסריקות, דורש סיסמא  — [Disable]
  • חזרת הסריקות, ללא סיסמא    — [Enable]

  למה Disable מוגן בסיסמא אבל Enable לא?
  תוקף שמשיג גישה למחשב ינסה להשבית את הניטור
  לפני שיטמין backdoor. הפעלה מחדש היא תמיד
  פעולה בטוחה ואינה מוגנת.

גישה ל-README — סיסמא:
  סיסמאת ברירת-מחדל: 12345
  - במהלך ההתקנה ניתן לקרוא ללא סיסמא, פעם אחת.
  - לאחר ההתקנה נדרשת סיסמא בכל כניסה.
  - הסיסמא נשמרת בצורה מאובטחת - לא בטקסט רגיל.
  - לשינוי סיסמא: לחץ "Change Password" בחלון.
  - שכחת סיסמא? פנה ל-Claude Code לאיפוס.
    יעדכן Claude את readme-password.json עם ערך חדש.

התקנה על מחשב חדש:
  • העבר את קובץ port-monitor.bat בלבד, קובץ יחיד מספיק.
  • לחץ לחיצה כפולה על port-monitor.bat.
  • קרא את חלון ההסכמה, סמן את התיבה, לחץ Approve.
  • ניתן לקרוא מדריך זה ללא סיסמא מיד לאחר ההתקנה.
  • זהו. Task Scheduler וקיצורי דרך נוצרים אוטומטית.

================================================================
  גרסה: 2.0 | שאלות ואיפוס סיסמא — פנה ל-Claude Code
================================================================
"@

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock   = "Bottom"
    $panel.Height = 50

    $btnClose          = New-Object System.Windows.Forms.Button
    $btnClose.Text     = "Close"
    $btnClose.Size     = New-Object System.Drawing.Size(100, 32)
    $btnClose.Anchor   = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top
    $btnClose.Location = New-Object System.Drawing.Point(($panel.Width - 115), 9)
    $btnClose.Add_Click({ $form.Close() })
    $panel.Controls.Add($btnClose)

    if (-not $isSetup) {
        $btnChangePwd          = New-Object System.Windows.Forms.Button
        $btnChangePwd.Text     = "Change Password"
        $btnChangePwd.Size     = New-Object System.Drawing.Size(140, 32)
        $btnChangePwd.Anchor   = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top
        $btnChangePwd.Location = New-Object System.Drawing.Point(($panel.Width - 265), 9)
        $btnChangePwd.Add_Click({
            $form.Hide()
            Invoke-ChangePassword
            $form.Close()
        })
        $panel.Controls.Add($btnChangePwd)
    }

    $form.Controls.Add($panel)
    $form.Controls.Add($rtb)

    # BiDi fix v4 - RTF-based: SelectionRightToLeft proved unreliable on Windows 11.
    # Build content as RTF with \ltrpar for English and \rtlpar\qr\rtlch for Hebrew.
    $form.Add_Shown({
        function ConvertTo-RtfEscape([string]$text) {
            $sb = New-Object System.Text.StringBuilder
            foreach ($c in $text.ToCharArray()) {
                $n = [int]$c
                if    ($n -eq 92)   { $sb.Append('\\') }
                elseif ($n -eq 123) { $sb.Append('\{') }
                elseif ($n -eq 125) { $sb.Append('\}') }
                elseif ($n -lt 128) { $sb.Append([char]$n) }
                else {
                    $signed = if ($n -gt 32767) { $n - 65536 } else { $n }
                    $sb.Append("\u${signed}?")
                }
            }
            return $sb.ToString()
        }

        $sep    = "----------------------------------------------------------------"
        $full   = $rtb.Text
        $sepIdx = $full.IndexOf($sep)
        if ($sepIdx -lt 0) { return }

        $enLines = ($full.Substring(0, $sepIdx + $sep.Length)) -split "`r?`n"
        $heLines = ($full.Substring($sepIdx + $sep.Length)) -split "`r?`n" | Select-Object -Skip 1

        $r = New-Object System.Text.StringBuilder
        $r.Append('{\rtf1\ansi\deff0')
        $r.Append('{\fonttbl{\f0\fnil\fcharset0 Consolas;}}')
        $r.Append('{\colortbl;\red220\green220\blue220;}')
        $r.Append('\viewkind4\uc1 ')
        foreach ($line in $enLines) {
            $r.Append('\pard\ltrpar\ql\f0\fs20\cf1 ')
            $r.Append((ConvertTo-RtfEscape $line))
            $r.Append('\par ')
        }
        foreach ($line in $heLines) {
            $r.Append('\pard\rtlpar\qr\rtlch\f0\fs20\cf1 ')
            $r.Append((ConvertTo-RtfEscape $line))
            $r.Append('\par ')
        }
        $r.Append('}')

        $rtb.ReadOnly = $false
        $rtb.Rtf = $r.ToString()
        $rtb.ReadOnly = $true
        $rtb.SelectionStart = 0
        $rtb.ScrollToCaret()
    })

    $form.Add_Resize({
        $btnClose.Location = New-Object System.Drawing.Point(($panel.Width - 115), 9)
        if ($btnChangePwd) {
            $btnChangePwd.Location = New-Object System.Drawing.Point(($panel.Width - 265), 9)
        }
    })

    $null = $form.ShowDialog()
}

function Invoke-ChangePassword {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Change Password"
    $form.Size            = New-Object System.Drawing.Size(380, 220)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.TopMost         = $true

    $lbl1          = New-Object System.Windows.Forms.Label
    $lbl1.Text     = "New password:"
    $lbl1.Location = New-Object System.Drawing.Point(20, 22)
    $lbl1.Size     = New-Object System.Drawing.Size(115, 20)
    $form.Controls.Add($lbl1)

    $txtNew          = New-Object System.Windows.Forms.TextBox
    $txtNew.Location = New-Object System.Drawing.Point(143, 20)
    $txtNew.Size     = New-Object System.Drawing.Size(209, 22)
    $txtNew.UseSystemPasswordChar = $true
    $form.Controls.Add($txtNew)

    $lbl2          = New-Object System.Windows.Forms.Label
    $lbl2.Text     = "Confirm password:"
    $lbl2.Location = New-Object System.Drawing.Point(20, 56)
    $lbl2.Size     = New-Object System.Drawing.Size(115, 20)
    $form.Controls.Add($lbl2)

    $txtConfirm          = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(143, 54)
    $txtConfirm.Size     = New-Object System.Drawing.Size(209, 22)
    $txtConfirm.UseSystemPasswordChar = $true
    $form.Controls.Add($txtConfirm)

    $lblStatus          = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(20, 90)
    $lblStatus.Size     = New-Object System.Drawing.Size(332, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::Red
    $form.Controls.Add($lblStatus)

    $btnCancel          = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(247, 128)
    $btnCancel.Size     = New-Object System.Drawing.Size(110, 30)
    $btnCancel.Add_Click({ $form.Close() })
    $form.Controls.Add($btnCancel)

    $btnSave          = New-Object System.Windows.Forms.Button
    $btnSave.Text     = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(129, 128)
    $btnSave.Size     = New-Object System.Drawing.Size(110, 30)
    $btnSave.Add_Click({
        if ($txtNew.Text.Length -lt 4) { $lblStatus.Text = "Password must be at least 4 characters."; return }
        if ($txtNew.Text -ne $txtConfirm.Text) { $lblStatus.Text = "Passwords do not match."; return }
        Save-Hash (Get-Hash $txtNew.Text)
        $form.Tag = "saved"; $form.Close()
    })
    $form.Controls.Add($btnSave)

    $null = $form.ShowDialog()
    if ($form.Tag -eq "saved") {
        [System.Windows.Forms.MessageBox]::Show("Password changed successfully.", "Password Changed",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}

function Show-LoginDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $storedHash = Load-StoredHash
    $isDefault  = ($storedHash -eq $DEFAULT_HASH)

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Port Monitor - README Access"
    $form.Size            = New-Object System.Drawing.Size(380, 215)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.TopMost         = $true

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Enter password to view README:"
    $lbl.Location = New-Object System.Drawing.Point(20, 20)
    $lbl.Size     = New-Object System.Drawing.Size(332, 20)
    $form.Controls.Add($lbl)

    $txtPwd          = New-Object System.Windows.Forms.TextBox
    $txtPwd.Location = New-Object System.Drawing.Point(20, 50)
    $txtPwd.Size     = New-Object System.Drawing.Size(332, 22)
    $txtPwd.UseSystemPasswordChar = $true
    $form.Controls.Add($txtPwd)

    $lblErr          = New-Object System.Windows.Forms.Label
    $lblErr.Location = New-Object System.Drawing.Point(20, 82)
    $lblErr.Size     = New-Object System.Drawing.Size(332, 20)
    $lblErr.ForeColor = [System.Drawing.Color]::Red
    $form.Controls.Add($lblErr)

    $btnCancel          = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(247, 120)
    $btnCancel.Size     = New-Object System.Drawing.Size(110, 32)
    $btnCancel.Add_Click({ $form.Close() })
    $form.Controls.Add($btnCancel)

    $btnOk          = New-Object System.Windows.Forms.Button
    $btnOk.Text     = "Open"
    $btnOk.Location = New-Object System.Drawing.Point(129, 120)
    $btnOk.Size     = New-Object System.Drawing.Size(110, 32)
    $form.AcceptButton = $btnOk
    $btnOk.Add_Click({
        if ((Get-Hash $txtPwd.Text) -eq $storedHash) { $form.Tag = "ok"; $form.Close() }
        else { $lblErr.Text = "Incorrect password."; $txtPwd.Clear(); $txtPwd.Focus() }
    })
    $form.Controls.Add($btnOk)

    $txtPwd.Select()
    $null = $form.ShowDialog()
    if ($form.Tag -ne "ok") { exit 0 }

    if ($isDefault) {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "You are using the default password.`nWould you like to change it now?",
            "First Login", [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ask -eq "Yes") { Invoke-ChangePassword }
    }
    Show-Content
}

if ($SetupMode) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Show-Content
} else {
    Show-LoginDialog
}
'@
# =====================================================================

function Get-Hash([string]$plain) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("X2") }) -join ""
}

function Get-StoredHash {
    if (Test-Path $passwordFile) {
        try {
            $obj = Get-Content $passwordFile -Raw | ConvertFrom-Json
            if ($obj.hash) { return $obj.hash.ToUpper() }
        } catch {}
    }
    return $DEFAULT_HASH
}

function New-PortMonitorIcon([string]$path) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # Handle (draw first so lens covers its base)
    $penH = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,110,65,20), 4)
    $penH.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $penH.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($penH, 18, 18, 29, 29)

    # Lens fill (semi-transparent blue tint)
    $bLens = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45,80,150,230))
    $g.FillEllipse($bLens, 1, 1, 20, 20)

    # Lens border (dark blue)
    $penL = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,30,80,190), 2.5)
    $g.DrawEllipse($penL, 1, 1, 20, 20)

    # Lock body (golden fill + border)
    $bBody = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240,210,155,35))
    $penB  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,155,105,10), 1.2)
    $g.FillRectangle($bBody, 5, 14, 12, 7)
    $g.DrawRectangle($penB, 5, 14, 12, 7)

    # Keyhole (small dark circle)
    $g.FillEllipse([System.Drawing.Brushes]::DimGray, 9, 16, 4, 3)

    # Open shackle: left post, arc over top, right post raised (open side)
    $penS = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,155,105,10), 1.8)
    $g.DrawLine($penS, 8, 14, 8, 9)          # left post
    $g.DrawArc($penS, 8, 6, 6, 6, 180, -180) # top arc (counterclockwise = top half)
    $g.DrawLine($penS, 14, 9, 14, 5)          # right post raised = open lock

    $g.Dispose(); $penH.Dispose(); $bLens.Dispose(); $penL.Dispose()
    $bBody.Dispose(); $penB.Dispose(); $penS.Dispose()

    # Save as ICO (6-byte header + 16-byte dir entry + PNG image data)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray(); $ms.Dispose(); $bmp.Dispose()

    $ico = New-Object System.IO.MemoryStream
    $w   = New-Object System.IO.BinaryWriter($ico)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)  # header
    $w.Write([byte]32);  $w.Write([byte]32);  $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$png.Length); $w.Write([uint32]22)
    $w.Write($png, 0, $png.Length); $w.Flush()
    [System.IO.File]::WriteAllBytes($path, $ico.ToArray())
    $w.Dispose(); $ico.Dispose()
}

function Invoke-Setup {
    # Form: 540 wide, 490 tall  |  Client ~532 x 456
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Port Monitor - Setup"
    $form.Size            = New-Object System.Drawing.Size(540, 490)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.TopMost         = $true

    $title      = New-Object System.Windows.Forms.Label
    $title.Text = "Port Monitor"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(20, 15)
    $title.Size     = New-Object System.Drawing.Size(492, 30)
    $form.Controls.Add($title)

    $desc             = New-Object System.Windows.Forms.RichTextBox
    $desc.ReadOnly    = $true
    $desc.BackColor   = $form.BackColor
    $desc.BorderStyle = "None"
    $desc.Font        = New-Object System.Drawing.Font("Segoe UI", 9)
    $desc.Location    = New-Object System.Drawing.Point(20, 55)
    $desc.Size        = New-Object System.Drawing.Size(492, 260)
    $desc.Text        = "This tool monitors open TCP ports and alerts you when a suspicious port has been idle for 1 hour.`r`n`r`nWhat it does:`r`n  - Runs silently every 15 min via Task Scheduler`r`n  - Shows one non-intrusive window bottom-right when an idle unknown port is found`r`n  - Lets you close suspicious processes from that window`r`n  - Does NOT make network connections or send data anywhere`r`n`r`nSecurity:`r`n  - The monitoring script becomes read-only after approval`r`n  - Integrity is automatically verified on every run`r`n  - If the file is modified without your approval, the script refuses to run`r`n`r`nWhitelist:`r`n  - Common Windows processes and ports are ignored automatically`r`n  - Add your own: edit port-monitor.config.json (created in this folder)`r`n`r`nNote: Windows Defender may warn on first run. Verify the script source before allowing."
    $form.Controls.Add($desc)

    $chkConsent          = New-Object System.Windows.Forms.CheckBox
    $chkConsent.Text     = "I understand what this tool does and allow it to run on this computer"
    $chkConsent.Location = New-Object System.Drawing.Point(20, 328)
    $chkConsent.Size     = New-Object System.Drawing.Size(492, 20)
    $form.Controls.Add($chkConsent)

    $chkTask          = New-Object System.Windows.Forms.CheckBox
    $chkTask.Text     = "Install Task Scheduler entry (runs every 15 min, recommended)"
    $chkTask.Location = New-Object System.Drawing.Point(20, 354)
    $chkTask.Size     = New-Object System.Drawing.Size(492, 20)
    $chkTask.Checked  = $true
    $form.Controls.Add($chkTask)

    $chkDesktop          = New-Object System.Windows.Forms.CheckBox
    $chkDesktop.Text     = "Create Desktop shortcut"
    $chkDesktop.Location = New-Object System.Drawing.Point(20, 380)
    $chkDesktop.Size     = New-Object System.Drawing.Size(240, 20)
    $chkDesktop.Checked  = $true
    $form.Controls.Add($chkDesktop)

    $chkStart          = New-Object System.Windows.Forms.CheckBox
    $chkStart.Text     = "Create Start Menu shortcut"
    $chkStart.Location = New-Object System.Drawing.Point(270, 380)
    $chkStart.Size     = New-Object System.Drawing.Size(242, 20)
    $chkStart.Checked  = $true
    $form.Controls.Add($chkStart)

    # Buttons right-aligned: right edge at 517 (532-15)
    $btnApprove          = New-Object System.Windows.Forms.Button
    $btnApprove.Text     = "Approve and Setup"
    $btnApprove.Location = New-Object System.Drawing.Point(279, 408)
    $btnApprove.Size     = New-Object System.Drawing.Size(120, 32)
    $btnApprove.Enabled  = $false
    $btnApprove.Add_Click({ $form.Tag = "approve"; $form.Close() })
    $form.Controls.Add($btnApprove)

    $btnCancel           = New-Object System.Windows.Forms.Button
    $btnCancel.Text      = "Cancel"
    $btnCancel.Location  = New-Object System.Drawing.Point(407, 408)
    $btnCancel.Size      = New-Object System.Drawing.Size(110, 32)
    $btnCancel.Add_Click({ $form.Close() })
    $form.Controls.Add($btnCancel)

    $chkConsent.Add_CheckedChanged({ $btnApprove.Enabled = $chkConsent.Checked })
    $null = $form.ShowDialog()

    if ($form.Tag -ne "approve") { return }

    # --- Extract component scripts ---
    try { Set-ItemProperty -Path $scriptFile -Name IsReadOnly -Value $false } catch {}
    [System.IO.File]::WriteAllText($scriptFile,   $PM_SCRIPT, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($readmeScript, $RV_SCRIPT, [System.Text.Encoding]::UTF8)

    # Password file - only create if not already set
    if (-not (Test-Path $passwordFile)) {
        @{ hash = $DEFAULT_HASH; updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss");
           note = "Password stored securely. To reset, ask Claude Code." } |
            ConvertTo-Json | Set-Content $passwordFile
    }

    # Config file
    if (-not (Test-Path $configFile)) {
        @{ extraProcesses=@(); extraPorts=@(); extraUDPPorts=@() } | ConvertTo-Json | Set-Content $configFile
    }

    # Compute hash of extracted script and save state
    $hash  = (Get-FileHash -Path $scriptFile -Algorithm SHA256).Hash
    $state = [PSCustomObject]@{ consentGiven=$true; scriptHash=$hash; lastAlertedAt=$null; idle=@(); active=@() }
    if (Test-Path $stateFile) {
        try {
            $ex = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($ex.idle)   { $state.idle   = $ex.idle }
            if ($ex.active) { $state.active = $ex.active }
        } catch {}
    }
    $state | ConvertTo-Json -Depth 3 | Set-Content $stateFile
    try { Set-ItemProperty -Path $scriptFile -Name IsReadOnly -Value $true } catch {}

    # Task Scheduler
    $taskMsg = "Task Scheduler: skipped."
    if ($chkTask.Checked) {
        $action   = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptFile`""
        $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 15) `
            -RepetitionDuration (New-TimeSpan -Days 9999)
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskName "PortMonitor" -TaskPath "\Security\" `
            -Action $action -Trigger $trigger -Settings $settings `
            -Description "Monitors open ports for idle suspicious listeners" `
            -RunLevel Limited -Force | Out-Null
        $taskMsg = "Task Scheduler entry created (runs every 15 min)."
    }

    # Create custom icon
    New-PortMonitorIcon $icoFile

    # Create shortcuts
    $batPath = Join-Path $dir "port-monitor.bat"
    $rvBat   = Join-Path $dir "readme-viewer.bat"
    $shell   = New-Object -ComObject WScript.Shell

    # Local shortcut (always create in same folder)
    $sc = $shell.CreateShortcut((Join-Path $dir "Port Monitor.lnk"))
    $sc.TargetPath = $batPath; $sc.IconLocation = "$icoFile,0"
    $sc.Description = "Port Monitor - Idle port security scanner"; $sc.Save()

    # README shortcut (local)
    if (Test-Path $rvBat) {
        $sc2 = $shell.CreateShortcut((Join-Path $dir "View README.lnk"))
        $sc2.TargetPath = $rvBat
        $sc2.IconLocation = "C:\Windows\System32\shell32.dll,1"
        $sc2.Description = "Port Monitor README"; $sc2.Save()
    }

    if ($chkDesktop.Checked) {
        $lnkD = Join-Path ([System.Environment]::GetFolderPath("Desktop")) "Port Monitor.lnk"
        $sc3  = $shell.CreateShortcut($lnkD)
        $sc3.TargetPath = $batPath; $sc3.IconLocation = "$icoFile,0"
        $sc3.Description = "Port Monitor - Idle port security scanner"; $sc3.Save()
    }

    if ($chkStart.Checked) {
        $startProg = Join-Path ([System.Environment]::GetFolderPath("StartMenu")) "Programs"
        if (Test-Path $startProg) {
            $lnkS = Join-Path $startProg "Port Monitor.lnk"
            $sc4  = $shell.CreateShortcut($lnkS)
            $sc4.TargetPath = $batPath; $sc4.IconLocation = "$icoFile,0"
            $sc4.Description = "Port Monitor - Idle port security scanner"; $sc4.Save()
        }
    }

    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SETUP completed." | Add-Content -Path $logFile

    [System.Windows.Forms.MessageBox]::Show(
        "Setup complete!`n`n$taskMsg`n`nPort Monitor is now active on this computer.`n`nTo customize exceptions, edit:`n$configFile",
        "Port Monitor - Ready",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    # Offer README (no password required right after setup)
    if (Test-Path $readmeScript) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Would you like to read about what Port Monitor does?`n`nYou can view this now. A password will be required later.",
            "Port Monitor - Learn More",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($ans -eq "Yes") {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$readmeScript`" -SetupMode" -Wait
        }
    }
}

function Show-PasswordPrompt {
    # Form: 340 wide, 190 tall  |  Client ~332 x 156
    $pf = New-Object System.Windows.Forms.Form
    $pf.Text            = "Disable Monitoring - Confirm"
    $pf.Size            = New-Object System.Drawing.Size(340, 190)
    $pf.StartPosition   = "CenterScreen"
    $pf.FormBorderStyle = "FixedDialog"
    $pf.MaximizeBox     = $false
    $pf.TopMost         = $true

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Enter password to disable monitoring:"
    $lbl.Location = New-Object System.Drawing.Point(15, 18)
    $lbl.Size     = New-Object System.Drawing.Size(302, 20)
    $pf.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(15, 45)
    $txt.Size     = New-Object System.Drawing.Size(302, 22)
    $txt.UseSystemPasswordChar = $true
    $pf.Controls.Add($txt)

    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.Location  = New-Object System.Drawing.Point(15, 74)
    $lblErr.Size      = New-Object System.Drawing.Size(302, 18)
    $lblErr.ForeColor = [System.Drawing.Color]::Red
    $pf.Controls.Add($lblErr)

    # Buttons right-aligned: right edge at 317 (332-15)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(215, 105)
    $btnCancel.Size     = New-Object System.Drawing.Size(102, 30)
    $btnCancel.Add_Click({ $pf.Close() })
    $pf.Controls.Add($btnCancel)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text      = "Confirm"
    $btnOk.Location  = New-Object System.Drawing.Point(105, 105)
    $btnOk.Size      = New-Object System.Drawing.Size(102, 30)
    $pf.AcceptButton = $btnOk
    $btnOk.Add_Click({
        if ((Get-Hash $txt.Text) -eq (Get-StoredHash)) {
            $pf.Tag = "ok"; $pf.Close()
        } else {
            $lblErr.Text = "Incorrect password."
            $txt.Clear(); $txt.Focus()
        }
    })
    $pf.Controls.Add($btnOk)

    $txt.Select()
    $null = $pf.ShowDialog()
    return ($pf.Tag -eq "ok")
}

# --- Determine state ---
$ready = $false
if (Test-Path $stateFile) {
    try { $ready = [bool](Get-Content $stateFile -Raw | ConvertFrom-Json).consentGiven } catch {}
}

$task        = Get-ScheduledTask -TaskName "PortMonitor" -TaskPath "\Security\" -ErrorAction SilentlyContinue
$taskExists  = $null -ne $task
$taskEnabled = $taskExists -and ($task.State -ne "Disabled")

# --- Main launcher form ---
# Form: 430 wide, 260 tall  |  Client ~422 x 226

$form = New-Object System.Windows.Forms.Form
$form.Text            = "Port Monitor"
$form.Size            = New-Object System.Drawing.Size(430, 260)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false
$form.TopMost         = $true

# Try to set custom icon if available
if (Test-Path $icoFile) {
    try { $form.Icon = New-Object System.Drawing.Icon($icoFile) } catch {}
}

$lbl          = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point(15, 16)
$lbl.Size     = New-Object System.Drawing.Size(392, 20)
$lbl.Text     = if ($ready) { "Port Monitor is installed. What would you like to do?" } `
                else         { "Port Monitor is not set up yet on this computer." }
$form.Controls.Add($lbl)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point(15, 40)
$lblStatus.Size      = New-Object System.Drawing.Size(392, 18)
$lblStatus.Font      = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblStatus.ForeColor = if ($taskEnabled)   { [System.Drawing.Color]::DarkGreen }
                       elseif ($taskExists) { [System.Drawing.Color]::DarkRed }
                       else               { [System.Drawing.Color]::Gray }
$lblStatus.Text      = if (-not $taskExists) { "Scheduled task: not installed" }
                       elseif ($taskEnabled)  { "Scheduled task: ACTIVE (every 15 min)" }
                       else                   { "Scheduled task: DISABLED" }
$form.Controls.Add($lblStatus)

# Row 1: three equal buttons filling 392px with 10px gaps  (124px each)
$btnSetup          = New-Object System.Windows.Forms.Button
$btnSetup.Text     = if ($ready) { "Re-run Setup" } else { "Setup (First Time)" }
$btnSetup.Location = New-Object System.Drawing.Point(15, 75)
$btnSetup.Size     = New-Object System.Drawing.Size(124, 32)
$btnSetup.Add_Click({ $form.Tag = "setup"; $form.Close() })
$form.Controls.Add($btnSetup)

$btnDemo          = New-Object System.Windows.Forms.Button
$btnDemo.Text     = "Run Demo"
$btnDemo.Location = New-Object System.Drawing.Point(149, 75)
$btnDemo.Size     = New-Object System.Drawing.Size(124, 32)
$btnDemo.Enabled  = $ready
$btnDemo.Add_Click({
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptFile`" -Demo"
})
$form.Controls.Add($btnDemo)

$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = "Close"
$btnClose.Location = New-Object System.Drawing.Point(283, 75)
$btnClose.Size     = New-Object System.Drawing.Size(124, 32)
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

$sep             = New-Object System.Windows.Forms.Label
$sep.Location    = New-Object System.Drawing.Point(15, 125)
$sep.Size        = New-Object System.Drawing.Size(392, 1)
$sep.BorderStyle = "Fixed3D"
$form.Controls.Add($sep)

$lblProt          = New-Object System.Windows.Forms.Label
$lblProt.Location = New-Object System.Drawing.Point(15, 133)
$lblProt.Size     = New-Object System.Drawing.Size(392, 18)
$lblProt.Font     = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblProt.ForeColor = [System.Drawing.Color]::Gray
$lblProt.Text     = "Scheduling control (disable requires password):"
$form.Controls.Add($lblProt)

# Row 2: two equal buttons  (191px each, 10px gap)
$btnDisable          = New-Object System.Windows.Forms.Button
$btnDisable.Text     = "Disable Monitoring"
$btnDisable.Location = New-Object System.Drawing.Point(15, 157)
$btnDisable.Size     = New-Object System.Drawing.Size(191, 32)
$btnDisable.Enabled  = $taskEnabled
$btnDisable.ForeColor = [System.Drawing.Color]::DarkRed
$btnDisable.Add_Click({ $form.Tag = "disable"; $form.Close() })
$form.Controls.Add($btnDisable)

$btnEnable          = New-Object System.Windows.Forms.Button
$btnEnable.Text     = "Enable Monitoring"
$btnEnable.Location = New-Object System.Drawing.Point(216, 157)
$btnEnable.Size     = New-Object System.Drawing.Size(191, 32)
$btnEnable.Enabled  = ($taskExists -and -not $taskEnabled)
$btnEnable.ForeColor = [System.Drawing.Color]::DarkGreen
$btnEnable.Add_Click({ $form.Tag = "enable"; $form.Close() })
$form.Controls.Add($btnEnable)

$null = $form.ShowDialog()

# --- Actions ---
if ($form.Tag -eq "setup") {
    Invoke-Setup

} elseif ($form.Tag -eq "disable") {
    if (Show-PasswordPrompt) {
        Disable-ScheduledTask -TaskName "PortMonitor" -TaskPath "\Security\" | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            "Port Monitor scheduling has been DISABLED.`nBackground scans will no longer run automatically.",
            "Monitoring Disabled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

} elseif ($form.Tag -eq "enable") {
    Enable-ScheduledTask -TaskName "PortMonitor" -TaskPath "\Security\" | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        "Port Monitor scheduling has been ENABLED.`nBackground scans will resume every 15 minutes.",
        "Monitoring Enabled",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}
