#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs SQL Server 2022 Developer, configures the BankPortalDb database, and
    deploys the BankPortal ASP.NET MVC 5 web application to IIS.

.DESCRIPTION
    Phase 1 - SQL Server Developer 2022:
      Downloads and installs SQL Server Developer as the MSSQLSERVER default instance,
      enables TCP/IP and Named Pipes, sets Mixed Mode authentication, restores the
      BankPortalDb database from a backup, and creates the application SQL login
      with sysadmin permissions.

    Phase 2 - BankPortal Application Deployment:
      Scaffolds the ASP.NET MVC 5 / .NET 4.6.2 BankPortal project, restores NuGet
      packages, builds with MSBuild, and deploys to IIS.

.PARAMETER SaPassword
    SA account password set during SQL Server Express installation.

.PARAMETER SysAdminAccounts
    Windows account(s) granted sysadmin during SQL Server Express setup.

.PARAMETER SetStaticTcpPort
    When true, configures SQL Server to listen on a fixed TCP port.

.PARAMETER TcpPort
    Static TCP port number for SQL Server (default 1433).

.PARAMETER ProjectPath
    Directory where the BankPortal project source will be created.

.PARAMETER DeployPath
    IIS physical path for the deployed application.

.PARAMETER SqlServer
    SQL Server instance name used by the application (default: localhost).

.PARAMETER SqlDatabase
    Name of the database to restore and use.

.PARAMETER SqlUser
    SQL login name created for the application.

.PARAMETER SqlPassword
    Password for the SQL login.

.PARAMETER AppPoolName
    IIS application pool name.

.PARAMETER SiteName
    IIS website name.

.PARAMETER Port
    HTTP port for the IIS site.

.PARAMETER SkipSQLInstall
    Skip Phase 1 (SQL Server Express installation and database configuration).

.PARAMETER SkipIIS
    Skip IIS site configuration (build and copy files only).

.PARAMETER SkipDatabase
    Skip BankDb schema initialisation step in Phase 2.

.PARAMETER SkipPrerequisites
    Skip Windows feature and tooling prerequisite installation in Phase 2.
#>
param(
    # SQL Server Express install
    [string]$SaPassword       = "P@ssw0rd!ChangeMe",
    [string]$SysAdminAccounts = "BUILTIN\Administrators",
    [bool]  $SetStaticTcpPort = $true,
    [int]   $TcpPort          = 1433,

    # Application deployment
    [string]$ProjectPath = "C:\BankPortal",
    [string]$DeployPath  = "C:\inetpub\wwwroot\BankPortal",
    [string]$SqlServer   = "localhost",
    [string]$SqlDatabase = "BankPortalDb",
    [string]$SqlUser     = "fakeuser",
    [string]$SqlPassword = "f@keP@ssword!",
    [string]$AppPoolName = "BankPortalPool",
    [string]$SiteName    = "BankPortal",
    [int]   $Port        = 8080,

    # Skip switches
    [switch]$SkipSQLInstall,
    [switch]$SkipIIS,
    [switch]$SkipDatabase,
    [switch]$SkipPrerequisites
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK      { param([string]$Msg) Write-Host "    [OK] $Msg"  -ForegroundColor Green }
function Write-Section { param([string]$Msg) Write-Host ""; Write-Host "==== $Msg ====" -ForegroundColor Cyan }

# ======================================================================
# SQL. SQL Server 2022 Developer — Install and Configure
# ======================================================================
if (-not $SkipSQLInstall) {
    $savedEAP          = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $SqlVersion        = "2022"
    $DownloadUrl       = "https://go.microsoft.com/fwlink/p/?linkid=2215158&clcid=0x409"
    $WorkingDir        = "C:\Install\SQL${SqlVersion}Dev"
    $BootstrapExe      = "$WorkingDir\SQL2022-SSEI-Dev.exe"
    $ExtractedMedia    = "$WorkingDir\Media"
    $InstanceName      = "MSSQLSERVER"
    $LogDir            = "C:\Program Files\Microsoft SQL Server\Setup Bootstrap\Log"
    $IsoFileName       = "SQLServer2022-x64-ENU-Dev.iso"

    New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null
    Start-Transcript -Path "C:\Temp\BankingSQLConfigOutput.txt" -Force

    # -- Download and install SQL Server 2022 Developer ------------------
    Write-Section "SQL Server $SqlVersion Developer - Download and Install"
    $sqlInstalled = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if ($sqlInstalled) {
        Write-Host "SQL Server Developer is already installed, skipping." -ForegroundColor Yellow
    } else {
        New-Item -ItemType Directory -Force -Path $WorkingDir     | Out-Null
        New-Item -ItemType Directory -Force -Path $ExtractedMedia | Out-Null

        Invoke-WebRequest -Uri $DownloadUrl -OutFile $BootstrapExe

        Start-Process -FilePath $BootstrapExe `
            -ArgumentList "/Q /ACTION=Download /MEDIATYPE=ISO /MEDIAPATH=$ExtractedMedia" `
            -Wait

        $IsoPath     = "$ExtractedMedia\$IsoFileName"
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru
        $driveLetter = ($mountResult | Get-Volume).DriveLetter
        $SetupExePath = "${driveLetter}:\setup.exe"

        $sqlInstallArgs = @(
            "/Q",
            "/ACTION=Install",
            "/FEATURES=SQLENGINE",
            "/INSTANCENAME=$InstanceName",
            "/SECURITYMODE=SQL",
            "/SAPWD=$SaPassword",
            "/SQLSYSADMINACCOUNTS=$SysAdminAccounts",
            "/TCPENABLED=1",
            "/SQLSVCSTARTUPTYPE=Automatic",
            "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS",
            "/IACCEPTSQLSERVERLICENSETERMS"
        ) -join " "

        try {
            Start-Process -FilePath $SetupExePath -ArgumentList $sqlInstallArgs -Wait -NoNewWindow
            Write-Host "SQL Server 2022 Developer installation complete. Logs: $LogDir"
        } finally {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }
    }

    # -- Enable TCP/IP and Named Pipes ------------------------------------
    Write-Section "Enabling TCP/IP and Named Pipes via SMO WMI"
    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        Write-Host "Installing SqlServer PowerShell module..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
        Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers
    }
    Import-Module SqlServer -ErrorAction Stop

    try {
        $computer = (Get-Item env:\COMPUTERNAME).Value
        $wmi      = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $computer

        $tcpUri = "ManagedComputer[@Name='$computer']/ServerInstance[@Name='$InstanceName']/ServerProtocol[@Name='Tcp']"
        $tcp    = $wmi.GetSmoObject($tcpUri)
        $tcp.IsEnabled = $true
        $tcp.Alter()

        $npUri = "ManagedComputer[@Name='$computer']/ServerInstance[@Name='$InstanceName']/ServerProtocol[@Name='Np']"
        $np    = $wmi.GetSmoObject($npUri)
        $np.IsEnabled = $true
        $np.Alter()

        if ($SetStaticTcpPort) {
            Write-Section "Setting static TCP port $TcpPort on all IPs"
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

    # -- Mixed Mode authentication ----------------------------------------
    Write-Section "Ensuring Mixed Mode authentication (SQL + Windows)"
    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer"
    if (Test-Path $regPath) {
        $currentMode = (Get-ItemProperty -Path $regPath -Name LoginMode -ErrorAction SilentlyContinue).LoginMode
        if ($currentMode -ne 2) {
            Set-ItemProperty -Path $regPath -Name LoginMode -Value 2
            Write-Host "Mixed Mode authentication enabled (LoginMode = 2)."
        } else {
            Write-Host "Mixed Mode authentication already enabled."
        }
    } else {
        Write-Warning "Registry path not found - verify SQL Server instance name and version."
    }

    # -- Restart service --------------------------------------------------
    Write-Section "Restarting SQL Server service to apply changes"
    Restart-Service -Name 'MSSQLSERVER' -Force
    
# -- Create SQL login with sysadmin permissions ----------------------
    Write-Section "Creating SQL login '$SqlUser' with sysadmin permissions"
    $sqlSetupScript = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($SqlUser)')
BEGIN
    CREATE LOGIN [$($SqlUser)] WITH PASSWORD = N'$($SqlPassword)',
        CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    PRINT 'Login created.';
END
ELSE
BEGIN
    ALTER LOGIN [$($SqlUser)] WITH PASSWORD = N'$($SqlPassword)',
        CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    PRINT 'Login already exists; password updated.';
END

IF IS_SRVROLEMEMBER('sysadmin', N'$($SqlUser)') = 0
BEGIN
    ALTER SERVER ROLE sysadmin ADD MEMBER [$($SqlUser)];
    PRINT 'sysadmin role granted.';
END
ELSE
BEGIN
    PRINT 'Login is already a member of sysadmin.';
END
"@
    try {
        Invoke-Sqlcmd -Query $sqlSetupScript -ServerInstance "." -TrustServerCertificate
        Write-Host "SQL login '$SqlUser' configured with sysadmin permissions."
    }
    catch {
        throw "Failed to configure SQL login '$SqlUser'. Error: $($_.Exception.Message)"
    }

  
    $ErrorActionPreference = $savedEAP
}

# ======================================================================
# 0. Windows Server 2025 Prerequisites
# ======================================================================
if (-not $SkipPrerequisites) {
    Write-Step "Installing prerequisites (Windows Server 2025)"

    # --- IIS + ASP.NET features ----------------------------------------
    $iisFeatures = @(
        'Web-Server',          # IIS base
        'Web-WebServer',
        'Web-Common-Http',
        'Web-Static-Content',
        'Web-Default-Doc',
        'Web-Http-Errors',
        'Web-App-Dev',
        'Web-Net-Ext45',       # .NET Extensibility 4.x
        'Web-Asp-Net45',       # ASP.NET 4.x
        'Web-ISAPI-Ext',
        'Web-ISAPI-Filter',
        'Web-Health',
        'Web-Http-Logging',
        'Web-Security',
        'Web-Windows-Auth',
        'Web-Mgmt-Tools',
        'Web-Mgmt-Console',
        'Web-Scripting-Tools', # IIS Management Scripts and Tools
        'Web-Mgmt-Service',    # IIS Management Service (required for Delegation UI)
        'NET-Framework-45-ASPNET',
        'NET-WCF-HTTP-Activation45'
    )
    foreach ($feature in $iisFeatures) {
        $state = (Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue).InstallState
        if ($state -ne 'Installed') {
            Write-Host "    Installing Windows feature: $feature" -ForegroundColor Gray
            Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-OK "IIS and ASP.NET Windows features installed"

    # --- Web Deploy 4.0 (all components) --------------------------------
    $wdRegKey    = 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\MSDeploy\4'
    $wdInstalled = Test-Path $wdRegKey
    if (-not $wdInstalled) {
        Write-Host "    Downloading Web Deploy 4.0..." -ForegroundColor Gray
        $wdInstaller = "$env:TEMP\WebDeploy_amd64_en-US.msi"
        $wdLogPath   = "C:\Temp\WebDeploy-Install.log"
        Invoke-WebRequest `
            -Uri 'https://github.com/Mr-MSFT/Training/raw/refs/heads/main/WebDeploy_amd64_en-US.msi' `
            -OutFile $wdInstaller -UseBasicParsing
        Write-Host "    Installing Web Deploy 4.0 (all components)..." -ForegroundColor Gray
        $wdArgs = @(
            "/i",   $wdInstaller,
            "/qn",
            "/norestart",
            "ADDLOCAL=ALL",
            "/l*v", $wdLogPath
        )
        $wdProc = Start-Process -FilePath "msiexec.exe" -ArgumentList $wdArgs -Wait -PassThru
        Remove-Item $wdInstaller -Force -ErrorAction SilentlyContinue
        if ($wdProc.ExitCode -notin @(0, 3010)) {
            Write-Warning "Web Deploy installer exited with code $($wdProc.ExitCode). See log: $wdLogPath"
        } else {
            Write-OK "Web Deploy 4.0 installed (log: $wdLogPath)"
            if ($wdProc.ExitCode -eq 3010) {
                Write-Warning "A reboot is required to complete the Web Deploy installation."
            }
        }
    } else {
        Write-OK "Web Deploy 4.0 already present"
    }

    # --- Visual C++ 2015-2022 Redistributable (x64) ---------------------
    # Microsoft.Data.SqlClient.SNI.x64.dll is a native DLL that links against
    # the VC++ runtime.  Without it the SNI DLL fails to load (0x8007007E).
    $vcRegKey = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    $vcInstalled = (Test-Path $vcRegKey) -and
                   ([int](Get-ItemProperty $vcRegKey -ErrorAction SilentlyContinue).Installed -eq 1)
    if (-not $vcInstalled) {
        Write-Host "    Downloading Visual C++ 2022 Redistributable (x64)..." -ForegroundColor Gray
        $vcRedist = "$env:TEMP\vc_redist.x64.exe"
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' `
                          -OutFile $vcRedist -UseBasicParsing
        Start-Process $vcRedist -ArgumentList '/quiet', '/norestart' -Wait | Out-Null
        Remove-Item $vcRedist -Force -ErrorAction SilentlyContinue
        Write-OK "Visual C++ 2022 Redistributable (x64) installed"
    } else {
        Write-OK "Visual C++ 2022 Redistributable already present"
    }

    # --- Visual Studio Build Tools 2022 --------------------------------
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $buildToolsPresent = (Test-Path $vswhere) -and `
        (& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null)

    if (-not $buildToolsPresent) {
        Write-Host "    Downloading Visual Studio Build Tools 2022..." -ForegroundColor Gray
        $btInstaller = "$env:TEMP\vs_buildtools.exe"
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' `
                          -OutFile $btInstaller -UseBasicParsing

        Write-Host "    Installing Build Tools (this may take several minutes)..." -ForegroundColor Gray
        $btArgs = @(
            '--quiet', '--wait', '--norestart',
            '--add', 'Microsoft.VisualStudio.Workload.WebBuildTools',   # ASP.NET + web
            '--add', 'Microsoft.Net.Component.4.6.2.TargetingPack',
            '--add', 'Microsoft.Net.Component.4.8.TargetingPack',
            '--includeRecommended'
        )
        $proc = Start-Process -FilePath $btInstaller -ArgumentList $btArgs -Wait -PassThru
        Remove-Item $btInstaller -Force -ErrorAction SilentlyContinue
        if ($proc.ExitCode -notin @(0, 3010)) {
            throw "Build Tools installer exited with code $($proc.ExitCode)."
        }
        Write-OK "Visual Studio Build Tools 2022 installed"
        if ($proc.ExitCode -eq 3010) {
            Write-Warning "A reboot is required to complete Build Tools installation. Reboot then re-run this script."
            exit 3010
        }
    } else {
        Write-OK "Visual Studio Build Tools already present"
    }

    # --- SqlServer PowerShell module -----------------------------------
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Host "    Installing SqlServer PowerShell module..." -ForegroundColor Gray
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
        Import-Module SqlServer -ErrorAction Stop
        Write-OK "SqlServer module installed"
    } else {
        Write-OK "Invoke-Sqlcmd already available"
    }
}

# ======================================================================
# 1. Locate MSBuild
# ======================================================================
Write-Step "Locating build tools"

$msbuildCandidates = @(
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools\MSBuild\15.0\Bin\MSBuild.exe"
)

$msbuild = $msbuildCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $msbuild) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($vsPath) { $msbuild = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe" }
    }
}

if (-not $msbuild -or -not (Test-Path $msbuild)) {
    # Refresh vswhere path after potential Build Tools install above
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null
        if ($vsPath) { $msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe' }
    }
    if (-not $msbuild -or -not (Test-Path $msbuild)) {
        throw "MSBuild not found. Re-run the script without -SkipPrerequisites to install Build Tools automatically."
    }
}
Write-OK "MSBuild: $msbuild"

# NuGet CLI
$nugetExe = Join-Path $ProjectPath "nuget.exe"
New-Item -ItemType Directory -Force -Path $ProjectPath | Out-Null
if (-not (Test-Path $nugetExe)) {
    Write-Step "Downloading NuGet CLI"
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" `
                      -OutFile $nugetExe -UseBasicParsing
}
Write-OK "NuGet: $nugetExe"

# ======================================================================
# 2. Scaffold project files
# ======================================================================
Write-Step "Creating project structure at $ProjectPath"

@("App_Start","Controllers","Models",
  "Views\Shared","Views\Home","Views\Accounts","Views\Transactions",
  "Content","Scripts") | ForEach-Object {
    New-Item -ItemType Directory -Force -Path "$ProjectPath\$_" | Out-Null
}

# --- packages.config --------------------------------------------------
@'
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="bootstrap"                    version="3.4.1"   targetFramework="net462" />
  <package id="jQuery"                       version="3.6.4"   targetFramework="net462" />
  <package id="Microsoft.AspNet.Mvc"         version="5.2.9"   targetFramework="net462" />
  <package id="Microsoft.AspNet.Razor"       version="3.2.9"   targetFramework="net462" />
  <package id="Microsoft.AspNet.WebPages"    version="3.2.9"   targetFramework="net462" />
  <package id="Microsoft.Data.SqlClient"     version="5.2.0"   targetFramework="net462" />
  <package id="Microsoft.Web.Infrastructure" version="1.0.0.0" targetFramework="net462" />
</packages>
'@ | Set-Content "$ProjectPath\packages.config" -Encoding UTF8

# --- Web.config -------------------------------------------------------
@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <connectionStrings>
    <add name="BankPortalDb"
         connectionString="Data Source=$SqlServer;Initial Catalog=$SqlDatabase;User ID=$SqlUser;Password=$SqlPassword;MultipleActiveResultSets=True;TrustServerCertificate=True"
         providerName="Microsoft.Data.SqlClient" />
  </connectionStrings>
  <appSettings>
    <add key="webpages:Version"              value="3.0.0.0" />
    <add key="webpages:Enabled"              value="false" />
    <add key="ClientValidationEnabled"       value="true" />
    <add key="UnobtrusiveJavaScriptEnabled"  value="true" />
  </appSettings>
  <system.web>
    <compilation debug="false" targetFramework="4.6.2" />
    <httpRuntime targetFramework="4.6.2" />
    <customErrors mode="Off" />
  </system.web>
  <system.webServer>
    <httpErrors errorMode="Detailed" />
  </system.webServer>
  <system.data>
    <DbProviderFactories>
      <remove invariant="Microsoft.Data.SqlClient" />
      <add name="Microsoft Data SqlClient Data Provider"
           invariant="Microsoft.Data.SqlClient"
           description=".NET Framework Data Provider for Microsoft SQL Server"
           type="Microsoft.Data.SqlClient.SqlClientFactory, Microsoft.Data.SqlClient" />
    </DbProviderFactories>
  </system.data>
  <runtime>
    <assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">
    </assemblyBinding>
  </runtime>
</configuration>
"@ | Set-Content "$ProjectPath\Web.config" -Encoding UTF8

# --- Global.asax ------------------------------------------------------
@'
<%@ Application Codebehind="Global.asax.cs" Inherits="BankPortal.MvcApplication" Language="C#" %>
'@ | Set-Content "$ProjectPath\Global.asax" -Encoding UTF8

# --- Global.asax.cs ---------------------------------------------------
@'
using System.Web.Mvc;
using System.Web.Routing;
using BankPortal.Models;

namespace BankPortal
{
    public class MvcApplication : System.Web.HttpApplication
    {
        protected void Application_Start()
        {
            AreaRegistration.RegisterAllAreas();
            FilterConfig.RegisterGlobalFilters(GlobalFilters.Filters);
            RouteConfig.RegisterRoutes(RouteTable.Routes);
            try { BankDb.EnsureCreated(); }
            catch (System.Exception ex)
            {
                // Log but do not crash startup - the app can still serve pages.
                // Database errors will surface per-request rather than killing the app pool.
                System.Diagnostics.Trace.TraceError("BankDb.EnsureCreated failed: {0}", ex);
            }
        }
    }
}
'@ | Set-Content "$ProjectPath\Global.asax.cs" -Encoding UTF8

# --- App_Start\RouteConfig.cs -----------------------------------------
@'
using System.Web.Mvc;
using System.Web.Routing;

namespace BankPortal
{
    public class RouteConfig
    {
        public static void RegisterRoutes(RouteCollection routes)
        {
            routes.IgnoreRoute("{resource}.axd/{*pathInfo}");
            routes.MapRoute(
                name: "Default",
                url: "{controller}/{action}/{id}",
                defaults: new { controller = "Home", action = "Index", id = UrlParameter.Optional }
            );
        }
    }
}
'@ | Set-Content "$ProjectPath\App_Start\RouteConfig.cs" -Encoding UTF8

# --- App_Start\FilterConfig.cs ----------------------------------------
@'
using System.Web.Mvc;

namespace BankPortal
{
    public class FilterConfig
    {
        public static void RegisterGlobalFilters(GlobalFilterCollection filters)
        {
            filters.Add(new HandleErrorAttribute());
        }
    }
}
'@ | Set-Content "$ProjectPath\App_Start\FilterConfig.cs" -Encoding UTF8

# --- Models\Account.cs ------------------------------------------------
@'
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;

namespace BankPortal.Models
{
    public enum AccountType { Checking, Savings, MoneyMarket, CertificateOfDeposit }

    public class Account
    {
        public int AccountId { get; set; }

        [Required, StringLength(20), Display(Name = "Account Number")]
        public string AccountNumber { get; set; }

        [Required, StringLength(100), Display(Name = "Customer Name")]
        public string CustomerName { get; set; }

        [Display(Name = "Account Type")]
        public AccountType AccountType { get; set; }

        [DataType(DataType.Currency), Display(Name = "Balance")]
        public decimal Balance { get; set; }

        [Display(Name = "Opened")]
        public DateTime OpenedDate { get; set; }

        public bool IsActive { get; set; }

        public List<Transaction> Transactions { get; set; }
    }
}
'@ | Set-Content "$ProjectPath\Models\Account.cs" -Encoding UTF8

# --- Models\Transaction.cs --------------------------------------------
@'
using System;
using System.ComponentModel.DataAnnotations;

namespace BankPortal.Models
{
    public enum TransactionType { Debit, Credit }

    public class Transaction
    {
        public int TransactionId { get; set; }

        public int AccountId { get; set; }

        [Display(Name = "Date")]
        public DateTime TransactionDate { get; set; }

        [Required, StringLength(200)]
        public string Description { get; set; }

        [DataType(DataType.Currency)]
        public decimal Amount { get; set; }

        [Display(Name = "Type")]
        public TransactionType TransactionType { get; set; }

        [DataType(DataType.Currency), Display(Name = "Running Balance")]
        public decimal RunningBalance { get; set; }

        [StringLength(50), Display(Name = "Reference #")]
        public string ReferenceNumber { get; set; }

        public Account Account { get; set; }
    }
}
'@ | Set-Content "$ProjectPath\Models\Transaction.cs" -Encoding UTF8

# --- Models\TransferViewModel.cs --------------------------------------
@'
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Web.Mvc;

namespace BankPortal.Models
{
    public class TransferViewModel
    {
        [Required, Display(Name = "From Account")]
        public int FromAccountId { get; set; }

        [Required, Display(Name = "To Account")]
        public int ToAccountId { get; set; }

        [Required, DataType(DataType.Currency), Display(Name = "Amount")]
        [Range(0.01, double.MaxValue, ErrorMessage = "Amount must be greater than zero.")]
        public decimal Amount { get; set; }

        [StringLength(200)]
        public string Description { get; set; }

        public IEnumerable<SelectListItem> Accounts { get; set; }
    }
}
'@ | Set-Content "$ProjectPath\Models\TransferViewModel.cs" -Encoding UTF8

# --- Models\BankDbContext.cs ------------------------------------------
@'
using System;
using System.Collections.Generic;
using System.Configuration;
using Microsoft.Data.SqlClient;

namespace BankPortal.Models
{
    public sealed class BankDb : IDisposable
    {
        private readonly SqlConnection _cn;

        public BankDb()
        {
            _cn = new SqlConnection(
                ConfigurationManager.ConnectionStrings["BankPortalDb"].ConnectionString);
            _cn.Open();
        }

        // ── Schema + Seed ──────────────────────────────────────────────
        public static void EnsureCreated()
        {
            using (var db = new BankDb())
            {
                db.ExecNonQuery(
                    "IF NOT EXISTS (SELECT 1 FROM sysobjects WHERE name='Accounts' AND xtype='U') " +
                    "CREATE TABLE Accounts (" +
                    "  AccountId INT IDENTITY PRIMARY KEY," +
                    "  AccountNumber NVARCHAR(20)  NOT NULL," +
                    "  CustomerName  NVARCHAR(100) NOT NULL," +
                    "  AccountType   INT           NOT NULL," +
                    "  Balance       DECIMAL(18,2) NOT NULL," +
                    "  OpenedDate    DATETIME2     NOT NULL," +
                    "  IsActive      BIT           NOT NULL DEFAULT 1)");

                db.ExecNonQuery(
                    "IF NOT EXISTS (SELECT 1 FROM sysobjects WHERE name='Transactions' AND xtype='U') " +
                    "CREATE TABLE [Transactions] (" +
                    "  TransactionId   INT IDENTITY PRIMARY KEY," +
                    "  AccountId       INT           NOT NULL REFERENCES Accounts(AccountId)," +
                    "  TransactionDate DATETIME2     NOT NULL," +
                    "  Description     NVARCHAR(200) NOT NULL," +
                    "  Amount          DECIMAL(18,2) NOT NULL," +
                    "  TransactionType INT           NOT NULL," +
                    "  RunningBalance  DECIMAL(18,2) NOT NULL," +
                    "  ReferenceNumber NVARCHAR(50))");

                int count;
                using (var cmd = new SqlCommand("SELECT COUNT(*) FROM Accounts", db._cn))
                    count = (int)cmd.ExecuteScalar();
                if (count == 0) db.Seed();
            }
        }

        private void Seed()
        {
            ExecNonQuery(
                "INSERT INTO Accounts (AccountNumber,CustomerName,AccountType,Balance,OpenedDate,IsActive) VALUES" +
                " ('CHK-100001','Alice Johnson', 0,  4250.00, '2019-03-15', 1)," +
                " ('SAV-200001','Alice Johnson', 1, 18500.75, '2019-03-15', 1)," +
                " ('CHK-100002','Robert Smith',  0,  1830.40, '2020-07-22', 1)," +
                " ('MM-300001', 'Robert Smith',  2, 52000.00, '2021-01-05', 1)," +
                " ('CD-400001', 'Clara Williams',3, 25000.00, '2022-06-01', 1)");

            ExecNonQuery(
                "INSERT INTO [Transactions] (AccountId,TransactionDate,Description,Amount,TransactionType,RunningBalance,ReferenceNumber) VALUES" +
                " (1,'2024-12-01','Payroll Deposit',       3200.00,1, 7450.00,'PAY-001')," +
                " (1,'2024-12-05','Mortgage Payment',      1200.00,0, 6250.00,'MTG-001')," +
                " (1,'2024-12-12','Grocery Store',           85.40,0, 6164.60,'POS-112')," +
                " (1,'2024-12-15','Electric Bill',          140.00,0, 6024.60,'UTL-001')," +
                " (2,'2024-11-01','Transfer from Checking', 500.00,1,18500.75,'TRF-001')," +
                " (3,'2024-12-01','Payroll Deposit',       2800.00,1, 4630.40,'PAY-002')");
        }

        // ── Dashboard stats ────────────────────────────────────────────
        public int GetActiveAccountCount()
        {
            using (var cmd = new SqlCommand("SELECT COUNT(*) FROM Accounts WHERE IsActive=1", _cn))
                return (int)cmd.ExecuteScalar();
        }

        public decimal GetTotalDeposits()
        {
            using (var cmd = new SqlCommand(
                "SELECT ISNULL(SUM(Balance),0) FROM Accounts WHERE IsActive=1", _cn))
                return (decimal)cmd.ExecuteScalar();
        }

        public int GetRecentTransactionCount(DateTime since)
        {
            using (var cmd = new SqlCommand(
                "SELECT COUNT(*) FROM [Transactions] WHERE TransactionDate>=@since", _cn))
            {
                cmd.Parameters.AddWithValue("@since", since);
                return (int)cmd.ExecuteScalar();
            }
        }

        // ── Accounts ───────────────────────────────────────────────────
        public List<Account> GetActiveAccounts()
        {
            var list = new List<Account>();
            using (var cmd = new SqlCommand(
                "SELECT AccountId,AccountNumber,CustomerName,AccountType,Balance,OpenedDate,IsActive " +
                "FROM Accounts WHERE IsActive=1 ORDER BY CustomerName", _cn))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) list.Add(MapAccount(r));
            return list;
        }

        public Account GetAccountWithTransactions(int id)
        {
            Account account = null;
            using (var cmd = new SqlCommand(
                "SELECT AccountId,AccountNumber,CustomerName,AccountType,Balance,OpenedDate,IsActive " +
                "FROM Accounts WHERE AccountId=@id", _cn))
            {
                cmd.Parameters.AddWithValue("@id", id);
                using (var r = cmd.ExecuteReader())
                    if (r.Read()) account = MapAccount(r);
            }
            if (account == null) return null;
            using (var cmd = new SqlCommand(
                "SELECT TransactionId,AccountId,TransactionDate,Description,Amount," +
                "TransactionType,RunningBalance,ReferenceNumber " +
                "FROM [Transactions] WHERE AccountId=@id ORDER BY TransactionDate DESC", _cn))
            {
                cmd.Parameters.AddWithValue("@id", id);
                using (var r = cmd.ExecuteReader())
                    while (r.Read()) account.Transactions.Add(MapTransaction(r));
            }
            return account;
        }

        // ── Transactions ───────────────────────────────────────────────
        public List<Transaction> GetRecentTransactions(int top = 100)
        {
            var list = new List<Transaction>();
            using (var cmd = new SqlCommand(
                "SELECT TOP " + top + " t.TransactionId,t.AccountId,t.TransactionDate,t.Description," +
                "t.Amount,t.TransactionType,t.RunningBalance,t.ReferenceNumber,a.AccountNumber " +
                "FROM [Transactions] t JOIN Accounts a ON t.AccountId=a.AccountId " +
                "ORDER BY t.TransactionDate DESC", _cn))
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())
                {
                    var tx = MapTransaction(r);
                    tx.Account = new Account { AccountNumber = r.GetString(8) };
                    list.Add(tx);
                }
            }
            return list;
        }

        // ── Transfer ───────────────────────────────────────────────────
        public string Transfer(int fromId, int toId, decimal amount, string description)
        {
            using (var tran = _cn.BeginTransaction())
            {
                decimal fromBal, toBal;
                string  fromAcctNo, toAcctNo;

                using (var cmd = new SqlCommand(
                    "SELECT Balance,AccountNumber FROM Accounts WITH (UPDLOCK) WHERE AccountId=@id",
                    _cn, tran))
                {
                    cmd.Parameters.AddWithValue("@id", fromId);
                    using (var r = cmd.ExecuteReader())
                    {
                        if (!r.Read()) throw new InvalidOperationException("Source account not found.");
                        fromBal    = r.GetDecimal(0);
                        fromAcctNo = r.GetString(1);
                    }
                }

                if (fromBal < amount)
                {
                    tran.Rollback();
                    throw new InvalidOperationException("Insufficient funds.");
                }

                using (var cmd = new SqlCommand(
                    "SELECT Balance,AccountNumber FROM Accounts WITH (UPDLOCK) WHERE AccountId=@id",
                    _cn, tran))
                {
                    cmd.Parameters.AddWithValue("@id", toId);
                    using (var r = cmd.ExecuteReader())
                    {
                        if (!r.Read()) throw new InvalidOperationException("Destination account not found.");
                        toBal    = r.GetDecimal(0);
                        toAcctNo = r.GetString(1);
                    }
                }

                fromBal -= amount;
                toBal   += amount;

                using (var cmd = new SqlCommand(
                    "UPDATE Accounts SET Balance=@bal WHERE AccountId=@id", _cn, tran))
                {
                    cmd.Parameters.AddWithValue("@bal", fromBal);
                    cmd.Parameters.AddWithValue("@id",  fromId);
                    cmd.ExecuteNonQuery();
                }
                using (var cmd = new SqlCommand(
                    "UPDATE Accounts SET Balance=@bal WHERE AccountId=@id", _cn, tran))
                {
                    cmd.Parameters.AddWithValue("@bal", toBal);
                    cmd.Parameters.AddWithValue("@id",  toId);
                    cmd.ExecuteNonQuery();
                }

                var refNo = "TRF-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss");
                var desc  = string.IsNullOrWhiteSpace(description) ? "Account Transfer" : description;
                const string ins =
                    "INSERT INTO [Transactions] (AccountId,TransactionDate,Description,Amount," +
                    "TransactionType,RunningBalance,ReferenceNumber) " +
                    "VALUES (@aid,@dt,@desc,@amt,@type,@bal,@ref)";

                using (var cmd = new SqlCommand(ins, _cn, tran))
                {
                    cmd.Parameters.AddWithValue("@aid",  fromId);
                    cmd.Parameters.AddWithValue("@dt",   DateTime.UtcNow);
                    cmd.Parameters.AddWithValue("@desc", desc + " to " + toAcctNo);
                    cmd.Parameters.AddWithValue("@amt",  amount);
                    cmd.Parameters.AddWithValue("@type", (int)TransactionType.Debit);
                    cmd.Parameters.AddWithValue("@bal",  fromBal);
                    cmd.Parameters.AddWithValue("@ref",  refNo);
                    cmd.ExecuteNonQuery();
                }
                using (var cmd = new SqlCommand(ins, _cn, tran))
                {
                    cmd.Parameters.AddWithValue("@aid",  toId);
                    cmd.Parameters.AddWithValue("@dt",   DateTime.UtcNow);
                    cmd.Parameters.AddWithValue("@desc", desc + " from " + fromAcctNo);
                    cmd.Parameters.AddWithValue("@amt",  amount);
                    cmd.Parameters.AddWithValue("@type", (int)TransactionType.Credit);
                    cmd.Parameters.AddWithValue("@bal",  toBal);
                    cmd.Parameters.AddWithValue("@ref",  refNo);
                    cmd.ExecuteNonQuery();
                }

                tran.Commit();
                return refNo;
            }
        }

        // ── SelectListItems ────────────────────────────────────────────
        public List<System.Web.Mvc.SelectListItem> GetAccountSelectList()
        {
            var list = new List<System.Web.Mvc.SelectListItem>();
            using (var cmd = new SqlCommand(
                "SELECT AccountId,AccountNumber,CustomerName FROM Accounts WHERE IsActive=1 ORDER BY CustomerName",
                _cn))
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    list.Add(new System.Web.Mvc.SelectListItem
                    {
                        Value = r.GetInt32(0).ToString(),
                        Text  = r.GetString(1) + " - " + r.GetString(2)
                    });
            return list;
        }

        // ── Mappers ────────────────────────────────────────────────────
        private static Account MapAccount(SqlDataReader r) => new Account
        {
            AccountId     = r.GetInt32(0),
            AccountNumber = r.GetString(1),
            CustomerName  = r.GetString(2),
            AccountType   = (AccountType)r.GetInt32(3),
            Balance       = r.GetDecimal(4),
            OpenedDate    = r.GetDateTime(5),
            IsActive      = r.GetBoolean(6),
            Transactions  = new List<Transaction>()
        };

        private static Transaction MapTransaction(SqlDataReader r) => new Transaction
        {
            TransactionId   = r.GetInt32(0),
            AccountId       = r.GetInt32(1),
            TransactionDate = r.GetDateTime(2),
            Description     = r.GetString(3),
            Amount          = r.GetDecimal(4),
            TransactionType = (TransactionType)r.GetInt32(5),
            RunningBalance  = r.GetDecimal(6),
            ReferenceNumber = r.IsDBNull(7) ? null : r.GetString(7)
        };

        private void ExecNonQuery(string sql)
        {
            using (var cmd = new SqlCommand(sql, _cn))
                cmd.ExecuteNonQuery();
        }

        public void Dispose() => _cn?.Dispose();
    }
}
'@ | Set-Content "$ProjectPath\Models\BankDbContext.cs" -Encoding UTF8

# --- Controllers\HomeController.cs ------------------------------------
@'
using System;
using System.Web.Mvc;
using BankPortal.Models;

namespace BankPortal.Controllers
{
    public class HomeController : Controller
    {
        public ActionResult Index()
        {
            using (var db = new BankDb())
            {
                ViewBag.TotalAccounts = db.GetActiveAccountCount();
                ViewBag.TotalDeposits = db.GetTotalDeposits();
                ViewBag.RecentTxCount = db.GetRecentTransactionCount(DateTime.Today.AddDays(-30));
            }
            return View();
        }
    }
}
'@ | Set-Content "$ProjectPath\Controllers\HomeController.cs" -Encoding UTF8

# --- Controllers\AccountsController.cs --------------------------------
@'
using System.Web.Mvc;
using BankPortal.Models;

namespace BankPortal.Controllers
{
    public class AccountsController : Controller
    {
        public ActionResult Index()
        {
            using (var db = new BankDb())
                return View(db.GetActiveAccounts());
        }

        public ActionResult Details(int id)
        {
            using (var db = new BankDb())
            {
                var account = db.GetAccountWithTransactions(id);
                if (account == null) return HttpNotFound();
                return View(account);
            }
        }
    }
}
'@ | Set-Content "$ProjectPath\Controllers\AccountsController.cs" -Encoding UTF8

# --- Controllers\TransactionsController.cs ----------------------------
@'
using System;
using System.Web.Mvc;
using BankPortal.Models;

namespace BankPortal.Controllers
{
    public class TransactionsController : Controller
    {
        public ActionResult Index()
        {
            using (var db = new BankDb())
                return View(db.GetRecentTransactions());
        }

        [HttpGet]
        public ActionResult Transfer()
        {
            using (var db = new BankDb())
                return View(new TransferViewModel { Accounts = db.GetAccountSelectList() });
        }

        [HttpPost, ValidateAntiForgeryToken]
        public ActionResult Transfer(TransferViewModel model)
        {
            if (model.FromAccountId == model.ToAccountId)
                ModelState.AddModelError(string.Empty, "Source and destination accounts must differ.");

            if (!ModelState.IsValid)
            {
                using (var db = new BankDb())
                    model.Accounts = db.GetAccountSelectList();
                return View(model);
            }

            try
            {
                string refNo;
                using (var db = new BankDb())
                    refNo = db.Transfer(model.FromAccountId, model.ToAccountId, model.Amount, model.Description);
                TempData["Success"] = string.Format("Successfully transferred {0:C}. Reference: {1}", model.Amount, refNo);
                return RedirectToAction("Index");
            }
            catch (InvalidOperationException ex)
            {
                ModelState.AddModelError(
                    ex.Message.Contains("funds") ? "Amount" : string.Empty, ex.Message);
                using (var db = new BankDb())
                    model.Accounts = db.GetAccountSelectList();
                return View(model);
            }
        }
    }
}
'@ | Set-Content "$ProjectPath\Controllers\TransactionsController.cs" -Encoding UTF8

# --- Views\Shared\_Layout.cshtml --------------------------------------
@'
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>@ViewBag.Title - First National Bank</title>
    <link href="~/Content/bootstrap.min.css" rel="stylesheet" />
    <style>
        body        { background-color: #f5f5f5; }
        .navbar     { background-color: #003366; border: none; border-radius: 0; }
        .navbar-brand, .navbar-nav > li > a { color: #fff !important; }
        .navbar-nav > li > a:hover          { background-color: #004d99 !important; }
        .page-header                        { border-bottom: 2px solid #003366; color: #003366; }
        .badge-credit { color: #155724; background-color: #d4edda; padding: 2px 7px; border-radius: 3px; font-weight: bold; }
        .badge-debit  { color: #721c24; background-color: #f8d7da; padding: 2px 7px; border-radius: 3px; font-weight: bold; }
        .stat-panel   { text-align: center; padding: 20px; }
        .stat-panel h2 { font-size: 2.5em; margin: 0; }
    </style>
</head>
<body>
    <nav class="navbar navbar-static-top" role="navigation">
        <div class="container">
            <div class="navbar-header">
                <button type="button" class="navbar-toggle" data-toggle="collapse" data-target=".navbar-collapse">
                    <span class="icon-bar"></span><span class="icon-bar"></span><span class="icon-bar"></span>
                </button>
                <a class="navbar-brand" href="/">&#127981; First National Bank</a>
            </div>
            <div class="navbar-collapse collapse">
                <ul class="nav navbar-nav">
                    <li>@Html.ActionLink("Dashboard",    "Index",    "Home")</li>
                    <li>@Html.ActionLink("Accounts",     "Index",    "Accounts")</li>
                    <li>@Html.ActionLink("Transactions",  "Index",   "Transactions")</li>
                    <li>@Html.ActionLink("Transfer",     "Transfer", "Transactions")</li>
                </ul>
            </div>
        </div>
    </nav>
    <div class="container" style="margin-top: 24px">
        @RenderBody()
    </div>
    <footer class="text-center text-muted" style="margin-top: 40px; padding: 20px; border-top: 1px solid #ddd;">
        &copy; @DateTime.Now.Year First National Bank &mdash; Internal Use Only
    </footer>
    <script src="~/Scripts/jquery-3.6.4.min.js"></script>
    <script src="~/Scripts/bootstrap.min.js"></script>
</body>
</html>
'@ | Set-Content "$ProjectPath\Views\Shared\_Layout.cshtml" -Encoding UTF8

# --- Views\_ViewStart.cshtml ------------------------------------------
@'
@{
    Layout = "~/Views/Shared/_Layout.cshtml";
}
'@ | Set-Content "$ProjectPath\Views\_ViewStart.cshtml" -Encoding UTF8

# --- Views\Web.config -------------------------------------------------
@'
<?xml version="1.0"?>
<configuration>
  <configSections>
    <sectionGroup name="system.web.webPages.razor"
                  type="System.Web.WebPages.Razor.Configuration.RazorWebSectionGroup, System.Web.WebPages.Razor, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31BF3856AD364E35">
      <section name="host"  type="System.Web.WebPages.Razor.Configuration.HostSection, System.Web.WebPages.Razor, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31BF3856AD364E35" requirePermission="false" />
      <section name="pages" type="System.Web.WebPages.Razor.Configuration.RazorPagesSection, System.Web.WebPages.Razor, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31BF3856AD364E35" requirePermission="false" />
    </sectionGroup>
  </configSections>
  <system.web.webPages.razor>
    <host factoryType="System.Web.Mvc.MvcWebRazorHostFactory, System.Web.Mvc, Version=5.2.9.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" />
    <pages pageBaseType="System.Web.Mvc.WebViewPage">
      <namespaces>
        <add namespace="System.Web.Mvc" />
        <add namespace="System.Web.Mvc.Ajax" />
        <add namespace="System.Web.Mvc.Html" />
        <add namespace="System.Web.Routing" />
        <add namespace="BankPortal.Models" />
      </namespaces>
    </pages>
  </system.web.webPages.razor>
  <appSettings>
    <add key="webpages:Enabled" value="false" />
  </appSettings>
  <system.webServer>
    <handlers>
      <remove name="BlockViewHandler"/>
      <add name="BlockViewHandler" path="*" verb="*" preCondition="integratedMode" type="System.Web.HttpNotFoundHandler" />
    </handlers>
  </system.webServer>
</configuration>
'@ | Set-Content "$ProjectPath\Views\Web.config" -Encoding UTF8

# --- Views\Home\Index.cshtml ------------------------------------------
@'
@{
    ViewBag.Title = "Dashboard";
}
<div class="page-header"><h2>Dashboard</h2></div>
<div class="row" style="margin-top: 20px">
    <div class="col-md-4">
        <div class="panel panel-primary">
            <div class="panel-heading"><h3 class="panel-title">Active Accounts</h3></div>
            <div class="panel-body stat-panel"><h2>@ViewBag.TotalAccounts</h2></div>
        </div>
    </div>
    <div class="col-md-4">
        <div class="panel panel-success">
            <div class="panel-heading"><h3 class="panel-title">Total Deposits on Account</h3></div>
            <div class="panel-body stat-panel"><h2>@string.Format("{0:C}", ViewBag.TotalDeposits)</h2></div>
        </div>
    </div>
    <div class="col-md-4">
        <div class="panel panel-info">
            <div class="panel-heading"><h3 class="panel-title">Transactions (Last 30 Days)</h3></div>
            <div class="panel-body stat-panel"><h2>@ViewBag.RecentTxCount</h2></div>
        </div>
    </div>
</div>
<div class="row" style="margin-top: 10px">
    <div class="col-md-6">
        <a href="/Accounts"             class="btn btn-primary btn-block btn-lg">View All Accounts</a>
    </div>
    <div class="col-md-6">
        <a href="/Transactions/Transfer" class="btn btn-success btn-block btn-lg">Make a Transfer</a>
    </div>
</div>
'@ | Set-Content "$ProjectPath\Views\Home\Index.cshtml" -Encoding UTF8

# --- Views\Accounts\Index.cshtml --------------------------------------
@'
@model IEnumerable<BankPortal.Models.Account>
@{
    ViewBag.Title = "Accounts";
}
<div class="page-header"><h2>All Accounts</h2></div>
<table class="table table-striped table-hover">
    <thead>
        <tr>
            <th>Account #</th>
            <th>Customer</th>
            <th>Type</th>
            <th class="text-right">Balance</th>
            <th>Opened</th>
            <th></th>
        </tr>
    </thead>
    <tbody>
        @foreach (var a in Model) {
        <tr>
            <td><strong>@a.AccountNumber</strong></td>
            <td>@a.CustomerName</td>
            <td>@a.AccountType</td>
            <td class="text-right">@a.Balance.ToString("C")</td>
            <td>@a.OpenedDate.ToString("MMM d, yyyy")</td>
            <td>@Html.ActionLink("Details", "Details", new { id = a.AccountId }, new { @class = "btn btn-xs btn-default" })</td>
        </tr>
        }
    </tbody>
</table>
'@ | Set-Content "$ProjectPath\Views\Accounts\Index.cshtml" -Encoding UTF8

# --- Views\Accounts\Details.cshtml ------------------------------------
@'
@model BankPortal.Models.Account
@{
    ViewBag.Title = "Account Details";
}
<div class="page-header">
    <h2>@Model.AccountNumber <small>@Model.CustomerName</small></h2>
</div>
<div class="row">
    <div class="col-md-4">
        <dl class="dl-horizontal">
            <dt>Type</dt>    <dd>@Model.AccountType</dd>
            <dt>Balance</dt> <dd><strong>@Model.Balance.ToString("C")</strong></dd>
            <dt>Opened</dt>  <dd>@Model.OpenedDate.ToString("MMM d, yyyy")</dd>
            <dt>Status</dt>  <dd>@(Model.IsActive ? "Active" : "Closed")</dd>
        </dl>
    </div>
</div>
<h4>Transaction History</h4>
<table class="table table-condensed table-striped">
    <thead>
        <tr>
            <th>Date</th>
            <th>Description</th>
            <th>Reference #</th>
            <th class="text-right">Amount</th>
            <th class="text-right">Running Balance</th>
        </tr>
    </thead>
    <tbody>
        @foreach (var t in Model.Transactions) {
        <tr>
            <td>@t.TransactionDate.ToString("MM/dd/yyyy")</td>
            <td>@t.Description</td>
            <td><code>@t.ReferenceNumber</code></td>
            <td class="text-right">
                @if (t.TransactionType == BankPortal.Models.TransactionType.Credit) {
                    <span class="badge-credit">+@t.Amount.ToString("C")</span>
                } else {
                    <span class="badge-debit">-@t.Amount.ToString("C")</span>
                }
            </td>
            <td class="text-right">@t.RunningBalance.ToString("C")</td>
        </tr>
        }
    </tbody>
</table>
@Html.ActionLink("Back to Accounts", "Index", null, new { @class = "btn btn-default" })
'@ | Set-Content "$ProjectPath\Views\Accounts\Details.cshtml" -Encoding UTF8

# --- Views\Transactions\Index.cshtml ----------------------------------
@'
@model IEnumerable<BankPortal.Models.Transaction>
@{
    ViewBag.Title = "Transactions";
}
<div class="page-header"><h2>Recent Transactions <small>last 100</small></h2></div>
@if (TempData["Success"] != null) {
    <div class="alert alert-success alert-dismissible">
        <button type="button" class="close" data-dismiss="alert">&times;</button>
        @TempData["Success"]
    </div>
}
<table class="table table-striped table-condensed">
    <thead>
        <tr>
            <th>Date &amp; Time</th>
            <th>Account</th>
            <th>Description</th>
            <th>Reference #</th>
            <th class="text-right">Amount</th>
        </tr>
    </thead>
    <tbody>
        @foreach (var t in Model) {
        <tr>
            <td>@t.TransactionDate.ToString("MM/dd/yyyy HH:mm")</td>
            <td>@(t.Account != null ? t.Account.AccountNumber : "")</td>
            <td>@t.Description</td>
            <td><code>@t.ReferenceNumber</code></td>
            <td class="text-right">
                @if (t.TransactionType == BankPortal.Models.TransactionType.Credit) {
                    <span class="badge-credit">+@t.Amount.ToString("C")</span>
                } else {
                    <span class="badge-debit">-@t.Amount.ToString("C")</span>
                }
            </td>
        </tr>
        }
    </tbody>
</table>
'@ | Set-Content "$ProjectPath\Views\Transactions\Index.cshtml" -Encoding UTF8

# --- Views\Transactions\Transfer.cshtml -------------------------------
@'
@model BankPortal.Models.TransferViewModel
@{
    ViewBag.Title = "Transfer Funds";
}
<div class="page-header"><h2>Transfer Funds</h2></div>
<div class="row">
    <div class="col-md-6">
        @using (Html.BeginForm()) {
            @Html.AntiForgeryToken()
            @Html.ValidationSummary(false, null, new { @class = "alert alert-danger" })
            <div class="form-group">
                @Html.LabelFor(m => m.FromAccountId)
                @Html.DropDownListFor(m => m.FromAccountId, Model.Accounts, "-- Select source account --", new { @class = "form-control" })
                @Html.ValidationMessageFor(m => m.FromAccountId, null, new { @class = "text-danger" })
            </div>
            <div class="form-group">
                @Html.LabelFor(m => m.ToAccountId)
                @Html.DropDownListFor(m => m.ToAccountId, Model.Accounts, "-- Select destination account --", new { @class = "form-control" })
                @Html.ValidationMessageFor(m => m.ToAccountId, null, new { @class = "text-danger" })
            </div>
            <div class="form-group">
                @Html.LabelFor(m => m.Amount)
                <div class="input-group">
                    <span class="input-group-addon">$</span>
                    @Html.TextBoxFor(m => m.Amount, new { @class = "form-control", placeholder = "0.00" })
                </div>
                @Html.ValidationMessageFor(m => m.Amount, null, new { @class = "text-danger" })
            </div>
            <div class="form-group">
                @Html.LabelFor(m => m.Description)
                @Html.TextBoxFor(m => m.Description, new { @class = "form-control", placeholder = "Optional memo" })
            </div>
            <button type="submit" class="btn btn-success">Transfer Funds</button>
            @Html.ActionLink("Cancel", "Index", null, new { @class = "btn btn-default" })
        }
    </div>
</div>
'@ | Set-Content "$ProjectPath\Views\Transactions\Transfer.cshtml" -Encoding UTF8

# ======================================================================
# 3. Create .csproj
# ======================================================================
Write-Step "Creating project file (BankPortal.csproj)"
@'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="14.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props"
          Condition="Exists('$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props')" />
  <PropertyGroup>
    <Configuration Condition=" '$(Configuration)' == '' ">Release</Configuration>
    <Platform Condition=" '$(Platform)' == '' ">AnyCPU</Platform>
    <ProjectGuid>{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}</ProjectGuid>
    <ProjectTypeGuids>{349c5851-65df-11da-9384-00065b846f21};{fae04ec0-301f-11d3-bf4b-00c04f79efbc}</ProjectTypeGuids>
    <OutputType>Library</OutputType>
    <RootNamespace>BankPortal</RootNamespace>
    <AssemblyName>BankPortal</AssemblyName>
    <TargetFrameworkVersion>v4.6.2</TargetFrameworkVersion>
    <MvcBuildViews>false</MvcBuildViews>
    <NuGetPackageImportStamp></NuGetPackageImportStamp>
  </PropertyGroup>
  <PropertyGroup Condition=" '$(Configuration)|$(Platform)' == 'Release|AnyCPU' ">
    <DebugType>pdbonly</DebugType>
    <Optimize>true</Optimize>
    <OutputPath>bin\</OutputPath>
    <ErrorReport>prompt</ErrorReport>
    <WarningLevel>4</WarningLevel>
  </PropertyGroup>
  <ItemGroup>
    <Reference Include="Microsoft.CSharp" />
    <Reference Include="System" />
    <Reference Include="System.Data" />
    <Reference Include="System.Web" />
    <Reference Include="System.Web.Abstractions" />
    <Reference Include="System.Web.ApplicationServices" />
    <Reference Include="System.Web.Extensions" />
    <Reference Include="System.Web.Routing" />
    <Reference Include="System.Xml" />
    <Reference Include="System.ComponentModel.DataAnnotations" />
    <Reference Include="System.Configuration" />
    <Reference Include="Microsoft.Data.SqlClient">
      <HintPath>packages\Microsoft.Data.SqlClient.5.2.0\lib\net462\Microsoft.Data.SqlClient.dll</HintPath>
    </Reference>
    <Reference Include="System.Web.Mvc, Version=5.2.9.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35">
      <HintPath>packages\Microsoft.AspNet.Mvc.5.2.9\lib\net45\System.Web.Mvc.dll</HintPath>
    </Reference>
    <Reference Include="System.Web.WebPages, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35">
      <HintPath>packages\Microsoft.AspNet.WebPages.3.2.9\lib\net45\System.Web.WebPages.dll</HintPath>
    </Reference>
    <Reference Include="System.Web.WebPages.Razor, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35">
      <HintPath>packages\Microsoft.AspNet.Razor.3.2.9\lib\net45\System.Web.WebPages.Razor.dll</HintPath>
    </Reference>
    <Reference Include="System.Web.Helpers, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35">
      <HintPath>packages\Microsoft.AspNet.WebPages.3.2.9\lib\net45\System.Web.Helpers.dll</HintPath>
    </Reference>
    <Reference Include="System.Web.Razor, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35">
      <HintPath>packages\Microsoft.AspNet.Razor.3.2.9\lib\net45\System.Web.Razor.dll</HintPath>
    </Reference>
    <Reference Include="System.Web.Infrastructure">
      <HintPath>packages\Microsoft.Web.Infrastructure.1.0.0.0\lib\net40\Microsoft.Web.Infrastructure.dll</HintPath>
    </Reference>
  </ItemGroup>
  <ItemGroup>
    <Compile Include="App_Start\FilterConfig.cs" />
    <Compile Include="App_Start\RouteConfig.cs" />
    <Compile Include="Controllers\AccountsController.cs" />
    <Compile Include="Controllers\HomeController.cs" />
    <Compile Include="Controllers\TransactionsController.cs" />
    <Compile Include="Global.asax.cs" />
    <Compile Include="Models\Account.cs" />
    <Compile Include="Models\BankDbContext.cs" />
    <Compile Include="Models\Transaction.cs" />
    <Compile Include="Models\TransferViewModel.cs" />
  </ItemGroup>
  <ItemGroup>
    <Content Include="Global.asax" />
    <Content Include="packages.config" />
    <Content Include="Web.config" />
    <Content Include="Views\**\*.cshtml" />
    <Content Include="Views\Web.config" />
    <Content Include="Content\**" />
    <Content Include="Scripts\**" />
  </ItemGroup>
  <Import Project="$(MSBuildBinPath)\Microsoft.CSharp.targets" />
</Project>
'@ | Set-Content "$ProjectPath\BankPortal.csproj" -Encoding UTF8
Write-OK "BankPortal.csproj created"

# ======================================================================
# 4. NuGet — configure source and install packages
# ======================================================================
Write-Step "Configuring NuGet source"

# Ensure nuget.org is registered (fresh servers have no sources config)
$nugetSources = & $nugetExe sources list 2>&1
if ($nugetSources -notmatch 'nuget\.org') {
    & $nugetExe sources add -Name 'nuget.org' `
        -Source 'https://api.nuget.org/v3/index.json' `
        -NonInteractive | Out-Null
    Write-OK "nuget.org source added"
} else {
    Write-OK "nuget.org source already configured"
}

# Enable nuget.org if it exists but is disabled
& $nugetExe sources enable -Name 'nuget.org' -NonInteractive 2>$null | Out-Null

Write-Step "Installing NuGet packages"
$packagesDir = "$ProjectPath\packages"
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

# Each entry: @(id, version)
# The four System.* entries are transitive dependencies of Microsoft.Data.SqlClient
# pinned here so their exact assembly versions are known and match the binding redirects.
$packages = @(
    @('bootstrap',                              '3.4.1'),
    @('jQuery',                                 '3.6.4'),
    @('Microsoft.AspNet.Mvc',                   '5.2.9'),
    @('Microsoft.AspNet.Razor',                 '3.2.9'),
    @('Microsoft.AspNet.WebPages',              '3.2.9'),
    @('Microsoft.Data.SqlClient',               '5.2.0'),
    @('Microsoft.Web.Infrastructure',           '1.0.0.0'),
    @('Microsoft.Bcl.AsyncInterfaces',          '6.0.0'),
    @('System.Buffers',                         '4.5.1'),
    @('System.Diagnostics.DiagnosticSource',    '6.0.0'),
    @('System.Memory',                          '4.5.5'),
    @('System.Runtime.CompilerServices.Unsafe', '6.0.0'),
    @('System.Text.Encodings.Web',              '6.0.0'),
    @('System.Text.Json',                       '6.0.0'),
    @('System.Threading.Tasks.Extensions',      '4.5.4')
)

foreach ($pkg in $packages) {
    $id      = $pkg[0]
    $version = $pkg[1]
    $pkgDir  = Join-Path $packagesDir "$id.$version"
    if (Test-Path $pkgDir) {
        Write-OK "$id $version (already present)"
        continue
    }
    Write-Host "    Installing $id $version..." -ForegroundColor Gray
    & $nugetExe install $id `
        -Version $version `
        -OutputDirectory $packagesDir `
        -Source 'https://api.nuget.org/v3/index.json' `
        -NonInteractive `
        -NoCache
    if ($LASTEXITCODE -ne 0) { throw "Failed to install NuGet package: $id $version" }
    Write-OK "$id $version installed"
}

Write-OK "All NuGet packages installed"

# ======================================================================
# 5. Copy static assets from NuGet packages
# ======================================================================
Write-Step "Copying static assets (Bootstrap, jQuery)"

$bootstrapCss = Get-ChildItem "$ProjectPath\packages\bootstrap.*" -Recurse -Filter "bootstrap.min.css" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bootstrapCss) { Copy-Item $bootstrapCss.FullName "$ProjectPath\Content\bootstrap.min.css" -Force; Write-OK "bootstrap.min.css" }
else { Write-Warning "bootstrap.min.css not found in packages; layout may be unstyled." }

$bootstrapJs = Get-ChildItem "$ProjectPath\packages\bootstrap.*" -Recurse -Filter "bootstrap.min.js" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bootstrapJs) { Copy-Item $bootstrapJs.FullName "$ProjectPath\Scripts\bootstrap.min.js" -Force; Write-OK "bootstrap.min.js" }

$jqueryJs = Get-ChildItem "$ProjectPath\packages\jQuery.*" -Recurse -Filter "jquery-*.min.js" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($jqueryJs) { Copy-Item $jqueryJs.FullName "$ProjectPath\Scripts\jquery-3.6.4.min.js" -Force; Write-OK "jquery.min.js" }

# ======================================================================
# 6. Build then manually deploy to IIS folder
# ======================================================================
Write-Step "Building BankPortal"
New-Item -ItemType Directory -Force -Path $DeployPath | Out-Null

& $msbuild "$ProjectPath\BankPortal.csproj" `
    /p:Configuration=Release `
    /nologo /verbosity:minimal

if ($LASTEXITCODE -ne 0) { throw "MSBuild build failed with exit code $LASTEXITCODE." }
Write-OK "Build succeeded"

Write-Step "Copying application files to $DeployPath"

# bin\ — compiled assemblies and dependencies
$binDst = "$DeployPath\bin"
New-Item -ItemType Directory -Force -Path $binDst | Out-Null
Copy-Item "$ProjectPath\bin\*" $binDst -Recurse -Force
Write-OK "bin\ (project output)"

# Copy NuGet package DLLs — Microsoft.CSharp.targets does not always
# copy all HintPath references for Library projects; web framework
# assemblies (System.Web.WebPages.Razor, System.Web.Mvc, etc.) must
# be present in bin\ for IIS to load them at runtime.
# netstandard2.0 is required for Azure SDK assemblies (Azure.Identity, Azure.Core,
# Microsoft.Identity.Client, etc.) that are transitive deps of Microsoft.Data.SqlClient.
$tfmPreference = @('net462', 'net461', 'net45', 'net40', 'netstandard2.0')
Get-ChildItem "$ProjectPath\packages" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($tfm in $tfmPreference) {
        $libPath = Join-Path $_.FullName "lib\$tfm"
        if (Test-Path $libPath) {
            Get-ChildItem $libPath -Filter "*.dll" | ForEach-Object {
                $src = $_.FullName
                $dst = "$binDst\$($_.Name)"
                if (Test-Path $dst) {
                    # Never overwrite a newer DLL with an older one — multiple packages
                    # can ship the same assembly (e.g. System.Memory, System.Buffers)
                    # and the last writer wins without this guard.
                    try {
                        $srcVer = [System.Version]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($src).FileVersion)
                        $dstVer = [System.Version]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($dst).FileVersion)
                        if ($srcVer -gt $dstVer) { Copy-Item $src $dst -Force }
                    } catch { <# unparseable version — keep existing #> }
                } else {
                    Copy-Item $src $dst -Force
                }
            }
            break
        }
    }
}
Write-OK "bin\ (NuGet package assemblies)"

# Force-copy the pinned shared runtime assemblies LAST so they always win
# over any older copies that the general loop may have placed first.
$pinnedAsms = @(
    @{ Pkg = "Microsoft.Bcl.AsyncInterfaces.6.0.0";          Dll = 'Microsoft.Bcl.AsyncInterfaces.dll' },
    @{ Pkg = "System.Buffers.4.5.1";                         Dll = 'System.Buffers.dll' },
    @{ Pkg = "System.Memory.4.5.5";                          Dll = 'System.Memory.dll' },
    @{ Pkg = "System.Runtime.CompilerServices.Unsafe.6.0.0"; Dll = 'System.Runtime.CompilerServices.Unsafe.dll' },
    @{ Pkg = "System.Text.Encodings.Web.6.0.0";              Dll = 'System.Text.Encodings.Web.dll' },
    @{ Pkg = "System.Text.Json.6.0.0";                       Dll = 'System.Text.Json.dll' },
    @{ Pkg = "System.Threading.Tasks.Extensions.4.5.4";      Dll = 'System.Threading.Tasks.Extensions.dll' }
)
foreach ($asm in $pinnedAsms) {
    foreach ($tfm in $tfmPreference) {
        $src = "$packagesDir\$($asm.Pkg)\lib\$tfm\$($asm.Dll)"
        if (Test-Path $src) {
            Copy-Item $src "$binDst\$($asm.Dll)" -Force
            Write-OK "Pinned $($asm.Dll) ($($asm.Pkg))"
            break
        }
    }
}

# Copy native SNI DLLs — search recursively so the location inside the package
# does not need to be hard-coded (it can vary across Microsoft.Data.SqlClient versions).
foreach ($sniFilter in @('Microsoft.Data.SqlClient.SNI.x64.dll', 'Microsoft.Data.SqlClient.SNI.x86.dll')) {
    $sniFile = Get-ChildItem "$packagesDir" -Recurse -Filter $sniFilter -ErrorAction SilentlyContinue |
               Select-Object -First 1
    if ($sniFile) {
        Copy-Item $sniFile.FullName "$binDst\$($sniFile.Name)" -Force
        Write-OK "Copied $($sniFile.Name) from $($sniFile.DirectoryName)"
    } else {
        Write-Warning "$sniFilter not found in packages - SQL connections may fail"
    }
}
Write-OK "bin\ (native runtime DLLs)"

# Views\
$null = robocopy "$ProjectPath\Views"   "$DeployPath\Views"   /E /NJH /NJS /NFL /NDL
Write-OK "Views\"

# Content\
$null = robocopy "$ProjectPath\Content" "$DeployPath\Content" /E /NJH /NJS /NFL /NDL
Write-OK "Content\"

# Scripts\
$null = robocopy "$ProjectPath\Scripts" "$DeployPath\Scripts" /E /NJH /NJS /NFL /NDL
Write-OK "Scripts\"

# Root files
Copy-Item "$ProjectPath\Web.config"  $DeployPath -Force
Copy-Item "$ProjectPath\Global.asax" $DeployPath -Force
Write-OK "Web.config, Global.asax"

# ── Dynamic binding redirects ─────────────────────────────────────────────────
# Read the actual assembly version from each DLL in bin\ and generate matching
# binding redirects. Hard-coding versions fails when NuGet's transitive resolution
# installs a newer package than the static value — the redirect newVersion must
# equal exactly what is on disk.
$redirectMap = [ordered]@{
    'System.Runtime.CompilerServices.Unsafe'          = 'b03f5f7f11d50a3a'
    'System.Memory'                                   = 'cc7b13ffcd2ddd51'
    'System.Buffers'                                  = 'cc7b13ffcd2ddd51'
    'System.Threading.Tasks.Extensions'               = 'cc7b13ffcd2ddd51'
    'System.Diagnostics.DiagnosticSource'             = 'cc7b13ffcd2ddd51'
    'Microsoft.Bcl.AsyncInterfaces'                   = 'cc7b13ffcd2ddd51'
    'System.Text.Encodings.Web'                       = 'cc7b13ffcd2ddd51'
    'System.Text.Json'                                = 'cc7b13ffcd2ddd51'
    'Microsoft.IdentityModel.Abstractions'            = '31bf3856ad364e35'
    'Microsoft.IdentityModel.Logging'                 = '31bf3856ad364e35'
    'Microsoft.IdentityModel.Tokens'                  = '31bf3856ad364e35'
    'Microsoft.IdentityModel.JsonWebTokens'           = '31bf3856ad364e35'
    'Microsoft.IdentityModel.Protocols'               = '31bf3856ad364e35'
    'Microsoft.IdentityModel.Protocols.OpenIdConnect' = '31bf3856ad364e35'
}
$dynRedirects = ''
foreach ($asmName in $redirectMap.Keys) {
    $dll = "$binDst\$asmName.dll"
    if (Test-Path $dll) {
        try {
            $ver = [System.Reflection.AssemblyName]::GetAssemblyName($dll).Version.ToString()
            $dynRedirects += "`n      <dependentAssembly>`n"
            $dynRedirects += "        <assemblyIdentity name=`"$asmName`" publicKeyToken=`"$($redirectMap[$asmName])`" culture=`"neutral`" />`n"
            $dynRedirects += "        <bindingRedirect oldVersion=`"0.0.0.0-$ver`" newVersion=`"$ver`" />`n"
            $dynRedirects += "      </dependentAssembly>"
        } catch { Write-Warning "Could not read assembly version for $asmName.dll: $_" }
    }
}
$wcPath = "$DeployPath\Web.config"
(Get-Content $wcPath -Raw).Replace('</assemblyBinding>', "$dynRedirects`n    </assemblyBinding>") |
    Set-Content $wcPath -Encoding UTF8
Write-OK "Dynamic binding redirects written to Web.config"

Write-OK "Deployed to $DeployPath"

# ======================================================================
# 7. SQL Database
# ======================================================================
if (-not $SkipDatabase) {
    Write-Step "Creating SQL database '$SqlDatabase' on '$SqlServer'"
    $createDbSql = @"
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'$SqlDatabase')
BEGIN
    CREATE DATABASE [$SqlDatabase];
    PRINT 'Database created.';
END
ELSE
    PRINT 'Database already exists - skipping.';
"@
    try {
        if ($SqlUser -and $SqlPassword) {
            Invoke-Sqlcmd -ServerInstance $SqlServer -Query $createDbSql -TrustServerCertificate `
                          -Username $SqlUser -Password $SqlPassword `
                          -ErrorAction Stop
        } else {
            Invoke-Sqlcmd -ServerInstance $SqlServer -Query $createDbSql -TrustServerCertificate `
                           -ErrorAction Stop
        }
        Write-OK "Database ready. Entity Framework will create schema on first request."
    } catch {
        Write-Warning "Could not create database automatically: $_"
        Write-Warning "Create the database manually, then browse the site to trigger EF initializer."
    }
}

# ======================================================================
# 8. IIS configuration
# ======================================================================
if (-not $SkipIIS) {
    Write-Step "Configuring IIS"
    Import-Module WebAdministration -ErrorAction Stop

    # Application Pool
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        New-WebAppPool -Name $AppPoolName | Out-Null
        Write-OK "App pool '$AppPoolName' created"
    }
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" managedRuntimeVersion "v4.0"
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" managedPipelineMode    "Integrated"
    Write-OK "App pool configured: .NET v4.0 / Integrated pipeline"

    # Website
    $existingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    if (-not $existingSite) {
        New-Website -Name $SiteName -Port $Port -PhysicalPath $DeployPath `
                    -ApplicationPool $AppPoolName | Out-Null
        Write-OK "IIS site '$SiteName' created on port $Port"
    } else {
        Set-ItemProperty "IIS:\Sites\$SiteName" physicalPath $DeployPath
        Set-ItemProperty "IIS:\Sites\$SiteName" applicationPool $AppPoolName
        Write-OK "IIS site '$SiteName' updated"
    }
    Start-Website -Name $SiteName -ErrorAction SilentlyContinue
}

# ======================================================================
# Desktop shortcut — all users
# ======================================================================
Write-Step "Creating desktop shortcut for all users"
try {
    $siteUrl      = "http://localhost:$Port"
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "BankPortal.url"
    $wsh          = New-Object -ComObject WScript.Shell
    $shortcut     = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $siteUrl
    $shortcut.Save()
    Write-OK "Shortcut created: $shortcutPath -> $siteUrl"
}
catch {
    Write-Warning "Could not create desktop shortcut: $_"
}

# ======================================================================
# Done
# ======================================================================
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  BankPortal deployed successfully!"              -ForegroundColor Green
Write-Host "  URL  : http://localhost:$Port"                  -ForegroundColor Green
Write-Host "  DB   : $SqlServer \ $SqlDatabase"               -ForegroundColor Green
Write-Host "  Path : $DeployPath"                             -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""

# ======================================================================
# Generate C:\Temp\BackUpSQLDB.ps1
# ======================================================================
Write-Step "Creating C:\Temp\BackUpSQLDB.ps1"
New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null

$backupScript = @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Backs up the BankPortalDb SQL Server database to C:\Temp\BankPortalDb.bak.
#>

$BackupPath = "C:\Temp\BankPortalDb.bak"
$Database   = "BankPortalDb"
$Instance   = "localhost"   # SQL Server 2022 Developer — default instance (MSSQLSERVER)

# Ensure SqlServer module is available
if (-not (Get-Command Backup-SqlDatabase -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
}
Import-Module SqlServer -ErrorAction Stop

New-Item -ItemType Directory -Force -Path (Split-Path $BackupPath) | Out-Null

if (Test-Path $BackupPath) {
    Remove-Item $BackupPath -Force
    Write-Host "Existing backup removed: $BackupPath" -ForegroundColor Yellow
}

Write-Host "Starting backup of '$Database' to '$BackupPath'..." -ForegroundColor Cyan

Backup-SqlDatabase `
    -ServerInstance     $Instance `
    -Database           $Database `
    -BackupFile         $BackupPath `
    -Initialize `
    -CompressionOption  On `
    -TrustServerCertificate

Write-Host "Backup complete: $BackupPath" -ForegroundColor Green
'@

Set-Content -Path "C:\Temp\BackUpSQLDB.ps1" -Value $backupScript -Encoding UTF8
Write-OK "C:\Temp\BackUpSQLDB.ps1 created"

# ======================================================================
# Install App Service Migration Assistant
# ======================================================================
Write-Step "Installing App Service Migration Assistant"
try {
    $msaInstallerUrl  = "https://appmigration.microsoft.com/api/download/windowspreview/AppServiceMigrationAssistant.msi"
    $msaInstallerPath = "$env:TEMP\AppServiceMigrationAssistant.msi"
    $msaLogPath       = "C:\Temp\AppServiceMigrationAssistant-Install.log"

    Write-Host "    Downloading App Service Migration Assistant..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $msaInstallerUrl -OutFile $msaInstallerPath -UseBasicParsing

    Write-Host "    Running installer (this may take a moment)..." -ForegroundColor Gray
    $msiArgs = @(
        "/i",   $msaInstallerPath,
        "/qn",
        "/norestart",
        "/l*v", $msaLogPath
    )
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -notin @(0, 3010)) {
        throw "msiexec exited with code $($proc.ExitCode). See log: $msaLogPath"
    }
    Remove-Item $msaInstallerPath -Force -ErrorAction SilentlyContinue
    Write-OK "App Service Migration Assistant installed (log: $msaLogPath)"
    if ($proc.ExitCode -eq 3010) {
        Write-Warning "A reboot is required to complete the App Service Migration Assistant installation."
    }
}
catch {
    Write-Warning "Could not install App Service Migration Assistant: $_"
}

  Stop-Transcript 