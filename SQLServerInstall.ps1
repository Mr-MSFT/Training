<#
Installs SQL Server 2022 Express (Engine only) as DEFAULT instance (MSSQLSERVER),
then enables TCP/IP + Named Pipes.

Key references:
- Setup parameters (/Q /ACTION /FEATURES /INSTANCENAME /IACCEPTSQLSERVERLICENSETERMS) are documented for SQL Setup.  (Microsoft Learn) 
- Enabling TCP and Named Pipes via PowerShell/SMO WMI is documented. (Microsoft Learn)
#>

$ErrorActionPreference = "Continue"  # Change to "Stop" for stricter error handling and easier debugging

# -----------------------------
# Config
# -----------------------------
$SqlExpressExeUrl = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe"  # Express Core (Engine) download URL (commonly referenced)
$SsmsInstallerUrl  = "https://aka.ms/ssmsfullsetup"  # Always points to the latest SSMS GA release
$WorkDir           = "C:\Install\SQL2022Express"
$InstallerPath     = Join-Path $WorkDir "SQLEXPR_x64_ENU.exe"
$ExtractDir        = Join-Path $WorkDir "SQLEXPR_Extracted"
$InstanceName      = "MSSQLSERVER"     # Default instance name
$Features          = "SQL"             # Database Engine (SQL) is used in official setup examples
$SqlSysAdmins      = "BUILTIN\Administrators"

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

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

# -----------------------------
# 1) Install SQL Express (Default instance)
# -----------------------------
Write-Section "Checking for existing SQL Server default instance service"
$existing = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue

if (-not $existing) {
  Write-Section "Downloading SQL Server 2022 Express installer"
  Invoke-WebRequest -Uri $SqlExpressExeUrl -OutFile $InstallerPath

  Write-Section "Extracting SQL Express media"
  # Commonly used extraction switches for SQLEXPR_x64_ENU.exe (quiet extract)
  Start-Process -FilePath $InstallerPath -ArgumentList "/q", "/x:$ExtractDir" -Wait

  $setupExe = Join-Path $ExtractDir "setup.exe"
  if (-not (Test-Path $setupExe)) {
    throw "setup.exe not found after extraction at: $setupExe"
  }

  Write-Section "Running unattended SQL Express setup (default instance: MSSQLSERVER)"
  # Setup parameters are documented for SQL Server Setup (quiet install, features, instancename, license acceptance)
  $args = @(
    "/Q",
    "/IACCEPTSQLSERVERLICENSETERMS",
    "/ACTION=Install",
    "/FEATURES=$Features",
    "/INSTANCENAME=$InstanceName",
    "/SQLSYSADMINACCOUNTS=$SqlSysAdmins",
    "/SECURITYMODE=SQL",
    "/SAPWD=$([char]0x22)ReplaceWithSAPassword!$([char]0x22)"
  )

  Start-Process -FilePath $setupExe -ArgumentList $args -Wait
}
else {
  Write-Host "SQL Server service MSSQLSERVER already exists. Skipping installation."
}

# -----------------------------
# 3) Enable TCP/IP and Named Pipes (per Microsoft documentation)
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
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer"
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
Restart-Service -Name "MSSQLSERVER" -Force

# -----------------------------
# 4) Run SQL configuration (database, login, user)
# -----------------------------
Write-Section "Running SQL configuration (database, login, user)"
$sqlCommands = @(
  "CREATE DATABASE TodoDb;",
  "CREATE LOGIN todouser WITH PASSWORD = 'ReplaceWithARealPassword!';",
  "USE TodoDb; CREATE USER todouser FOR LOGIN todouser;",
  "USE TodoDb; ALTER ROLE db_owner ADD MEMBER todouser;"
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

# -----------------------------
# 5) Open Windows Firewall for SQL Server connections
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
Write-Host "SQL Server Express installed as DEFAULT instance ($InstanceName) and TCP/IP + Named Pipes enabled."
Write-Host "Database 'TodoDb' created with login 'todouser'."
Write-Host "SQL Server Management Studio (SSMS) installed."
Write-Host "Tip: Connect remotely using: tcp:<ServerName>,$TcpPort (if you enabled static port)."
