<#
Installs SQL Server 2025 Express (Engine only) as DEFAULT instance (MSSQLSERVER),
then enables TCP/IP + Named Pipes.

Key references:
- Setup parameters (/Q /ACTION /FEATURES /INSTANCENAME /IACCEPTSQLSERVERLICENSETERMS) are documented for SQL Setup.  (Microsoft Learn) 
- Enabling TCP and Named Pipes via PowerShell/SMO WMI is documented. (Microsoft Learn)
#>

$ErrorActionPreference = "Continue"  # Change to "Stop" for stricter error handling and easier debugging

# ============================
# Variables
# ============================
$SqlVersion        = "2025"
$DownloadUrl       = "https://go.microsoft.com/fwlink/?linkid=2216019"  # SQL Server 2025 Express (placeholder)
$WorkingDir        = "C:\Install\SQL${SqlVersion}Express"
$BootstrapExe      = "$WorkingDir\SQLEXPR.exe"
$ExtractedMedia    = "$WorkingDir\Media"
$InstanceName      = "SQLEXPRESS"
$SaPassword        = "P@ssw0rd!ChangeMe"
$SysAdminAccounts  = "BUILTIN\Administrators"
$LogDir            = "C:\Program Files\Microsoft SQL Server\Setup Bootstrap\Log"
$ExtractedFileName = "SQLEXPR_x64_ENU.exe"

Start-Transcript -Path "C:\Temp\TodoSQLConfigOutput.txt" -Force

# Optional: set a static TCP port after enabling TCP/IP
$SetStaticTcpPort  = $true
$TcpPort           = 1433

# -----------------------------
# Helpers
# -----------------------------
function Write-Section($msg) {
  Write-Host ""
  Write-Host "==== $msg ====" -ForegroundColor Cyan
}

function Test-IsAdmin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -----------------------------
# Pre-checks
# -----------------------------
if (-not (Test-IsAdmin)) {
  throw "Please run this script in an elevated (Administrator) PowerShell session."
}

# Use TLS 1.2+ for downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor `
                                              [Net.SecurityProtocolType]::Tls13


# ============================
# Download SQL Express
# ============================
$sqlInstalled = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
if ($sqlInstalled) {
    Write-Host "SQL Server Express is already installed, skipping download and installation." -ForegroundColor Yellow
} else {
  New-Item -ItemType Directory -Force -Path $WorkingDir | Out-Null
  New-Item -ItemType Directory -Force -Path $ExtractedMedia | Out-Null
    Invoke-WebRequest `
      -Uri $DownloadUrl `
      -OutFile $BootstrapExe

    # ============================
    # Extract installer
    # ============================
    Start-Process `
      -FilePath $BootstrapExe `
      -ArgumentList "/Q /ACTION=Download /MEDIATYPE=Core /MEDIAPATH=$ExtractedMedia" `
      -Wait

    # Locate setup.exe
    $SetupExe = Get-ChildItem -Path $ExtractedMedia -Recurse -Filter $ExtractedFileName | Select-Object -First 1

    # ============================
    # Install SQL Server Express
    # ============================
    $Args = @(
        "/Q",
        "/ACTION=Install",
        "/FEATURES=SQL",
        "/INSTANCENAME=$InstanceName",
        "/SECURITYMODE=SQL",
        "/SAPWD=$SaPassword",
        "/SQLSYSADMINACCOUNTS=$SysAdminAccounts",
        "/TCPENABLED=1",
        "/SQLSVCSTARTUPTYPE=Automatic",
        "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS",
        "/IACCEPTSQLSERVERLICENSETERMS"
    ) -join " "

    Start-Process `
      -FilePath $SetupExe.FullName `
      -ArgumentList $Args `
      -Wait `
      -NoNewWindow

    Write-Host "SQL Server Express installation complete."
    Write-Host "Logs available at: $LogDir"
}


# -----------------------------
# 2) Enable TCP/IP and Named Pipes (per Microsoft documentation)
# -----------------------------
Write-Section "Enabling TCP/IP and Named Pipes via SMO WMI"
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
  Write-Host "Installing SqlServer PowerShell module..."
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
  Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers
}
Import-Module SqlServer -ErrorAction Stop

try {
  $computer = (Get-Item env:\COMPUTERNAME).Value
  $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $computer

  # Enable TCP/IP
  $tcpUri = "ManagedComputer[@Name='$computer']/ServerInstance[@Name='$InstanceName']/ServerProtocol[@Name='Tcp']"
  $tcp = $wmi.GetSmoObject($tcpUri)
  $tcp.IsEnabled = $true
  $tcp.Alter()

  # Enable Named Pipes
  $npUri = "ManagedComputer[@Name='$computer']/ServerInstance[@Name='$InstanceName']/ServerProtocol[@Name='Np']"
  $np = $wmi.GetSmoObject($npUri)
  $np.IsEnabled = $true
  $np.Alter()

  if ($SetStaticTcpPort) {
    Write-Section "Setting static TCP port $TcpPort on all IPs (optional)"
    foreach ($ip in $tcp.IPAddresses) {
      foreach ($prop in $ip.IPAddressProperties) {
        if ($prop.Name -eq "TcpDynamicPorts") { $prop.Value = "" }
        if ($prop.Name -eq "TcpPort")         { $prop.Value = "$TcpPort" }
        if ($prop.Name -eq "Enabled")         { $prop.Value = $true }
      }
    }
    $tcp.Alter()
  }
}
catch {
  throw "Failed enabling protocols via SMO/WMI. Error: $($_.Exception.Message)"
}

# -----------------------------
# Ensure Mixed Mode Authentication (SQL Server + Windows)
# -----------------------------
Write-Section "Ensuring SQL Server is configured for Mixed Mode authentication"
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQLServer"
if (Test-Path $regPath) {
  $currentMode = (Get-ItemProperty -Path $regPath -Name LoginMode -ErrorAction SilentlyContinue).LoginMode
  if ($currentMode -ne 2) {
    Set-ItemProperty -Path $regPath -Name LoginMode -Value 2
    Write-Host "Mixed Mode authentication enabled (LoginMode set to 2)."
  } else {
    Write-Host "Mixed Mode authentication is already enabled."
  }
} else {
  Write-Warning "Registry path not found. Verify SQL Server instance name and version."
}

# -----------------------------
# Restart SQL service to apply protocol and auth changes
# -----------------------------
Write-Section "Restarting SQL Server service to apply changes"
Restart-Service -Name 'MSSQL$SQLEXPRESS' -Force

# -----------------------------
# 3) Open Windows Firewall for SQL Server connections
# -----------------------------
Write-Section "Opening Windows Firewall for SQL Server"
New-NetFirewallRule -DisplayName "SQL Server (TCP $TcpPort)" `
  -Direction Inbound -Protocol TCP -LocalPort $TcpPort `
  -Action Allow -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "SQL Server Browser (UDP 1434)" `
  -Direction Inbound -Protocol UDP -LocalPort 1434 `
  -Action Allow -Profile Any -ErrorAction SilentlyContinue
Write-Host "Firewall rules created for TCP port $TcpPort and UDP port 1434."


Write-Section "Done"
Write-Host "SQL Server 2025 Express installed as DEFAULT instance ($InstanceName) and TCP/IP + Named Pipes enabled."
Write-Host "Tip: Connect remotely using: tcp:<ServerName>,$TcpPort (if you enabled static port)."

# -----------------------------
# 4) Restore TodoDb from backup
# -----------------------------
Write-Section "Restoring TodoDb database from backup"
$backupUrl     = "https://sqlmiget.blob.core.windows.net/randf/TodoDb.bak?sp=r&st=2026-04-18T23:02:36Z&se=2026-04-26T07:17:36Z&spr=https&sv=2025-11-05&sr=b&sig=%2FvvIvRf%2FeyQpTGGzzO6F9iRg3zwZyO7RmksD%2B4va8P0%3D"
$backupBakPath = Join-Path $WorkingDir "TodoDb.bak"

Write-Host "Downloading backup file..."
Invoke-WebRequest -Uri $backupUrl -OutFile $backupBakPath -UseBasicParsing

Write-Host "Restoring database from '$backupBakPath'..."

$dataDir = "C:\Program Files\Microsoft SQL Server\MSSQL17.SQLEXPRESS\MSSQL\DATA"

$relocateData = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile("TodoDb",      "$dataDir\TodoDb.mdf")
$relocateLog  = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile("TodoDb_log",  "$dataDir\TodoDb_log.ldf")

Restore-SqlDatabase `
    -ServerInstance "." `
    -Database "TodoDb" `
    -BackupFile $backupBakPath `
    -RelocateFile @($relocateData, $relocateLog) `
    -ReplaceDatabase `
    -TrustServerCertificate

Write-Host "Database 'TodoDb' restored successfully."


# -----------------------------
# 5) Run SQL configuration (database, login, user)
# -----------------------------
Write-Section "Running SQL configuration (database, login, user)"
$sqlCommands = @(
"CREATE LOGIN todouser WITH PASSWORD = 'ReplaceWithARealPassword!';",
"USE TodoDb; ALTER ROLE db_owner ADD MEMBER todouser;", 
"use TodoDb; alter user todouser with login = todouser;"
)

try {
  foreach ($cmd in $sqlCommands) {
    Invoke-Sqlcmd -Query $cmd -ServerInstance "." -TrustServerCertificate
  }
  Write-Host "SQL configuration applied successfully."
}
catch {
  throw "Failed to apply SQL configuration. Error: $($_.Exception.Message)"
}


Stop-Transcript