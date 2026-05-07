# ============================================================================
# Important Variables
# ============================================================================
#$webDeployUrl = "https://download.microsoft.com/download/0/1/D/01DC28EA-638C-4A22-A57B-4CEF97755C6C/WebDeploy_amd64_en-US.msi"
$webDeployUrl = "https://github.com/Mr-MSFT/Training/raw/refs/heads/main/WebDeploy_amd64_en-US.msi"
$webDeployInstaller = "C:\Temp\WebDeploy_amd64_en-US.msi"

# URL to the BankingApp web application backup (Web Deploy package produced by BankApp-Deploy.ps1)
$backupDownloadUrl = "https://github.com/Mr-MSFT/Training/raw/refs/heads/main/BankingApp.zip"
$backupZipPath = "C:\Temp\BankingApp.zip"

$siteName = "BankPortal"
$sitePhysicalPath = "C:\inetpub\wwwroot\BankPortal"
$sitePort = 80
$appPoolName = "BankPortalPool"

# ============================================================================
# Script Execution
# ============================================================================

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null }
Start-Transcript -Path "C:\Temp\BankingConfigOutput.txt" -Force

# Install IIS and required features for ASP.NET MVC / .NET 4.x (Windows Server 2025)
$iisFeatures = @(
    'Web-Server',
    'Web-WebServer',
    'Web-Common-Http',
    'Web-Static-Content',
    'Web-Default-Doc',
    'Web-Http-Errors',
    'Web-App-Dev',
    'Web-Net-Ext45',
    'Web-Asp-Net45',
    'Web-ISAPI-Ext',
    'Web-ISAPI-Filter',
    'Web-Health',
    'Web-Http-Logging',
    'Web-Security',
    'Web-Windows-Auth',
    'Web-Mgmt-Tools',
    'Web-Mgmt-Console',
    'NET-Framework-45-ASPNET',
    'NET-WCF-HTTP-Activation45'
)

foreach ($feature in $iisFeatures) {
    $state = (Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue).InstallState
    if ($state -ne 'Installed') {
        Write-Host "Installing Windows feature: $feature" -ForegroundColor Cyan
        Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
    }
}
Write-Host "IIS and ASP.NET 4.x features installed." -ForegroundColor Green

# Reset IIS to apply the new module
Write-Host "Restarting IIS..." -ForegroundColor Cyan
& iisreset /restart
Write-Host "IIS restarted." -ForegroundColor Green

# Import WebAdministration module
Import-Module WebAdministration

# Remove Default Web Site
if (Test-Path "IIS:\Sites\Default Web Site") {
    Write-Host "Removing Default Web Site..." -ForegroundColor Cyan
    Remove-WebSite -Name "Default Web Site"
    Write-Host "Default Web Site removed." -ForegroundColor Green
} else {
    Write-Host "Default Web Site not found, skipping." -ForegroundColor Yellow
}

Write-Host "IIS configuration complete." -ForegroundColor Green


# Install Web Deploy
if (-not (Test-Path "$env:ProgramFiles\IIS\Microsoft Web Deploy V3\msdeploy.exe")) {
    Write-Host "Downloading Web Deploy..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $webDeployUrl -OutFile $webDeployInstaller -UseBasicParsing

    Write-Host "Installing Web Deploy..." -ForegroundColor Cyan
    Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i", $webDeployInstaller, "ADDLOCAL=ALL", "/quiet", "/norestart" `
        -Wait `
        -NoNewWindow
    Write-Host "Web Deploy installation complete." -ForegroundColor Green
} else {
    Write-Host "Web Deploy is already installed, skipping." -ForegroundColor Yellow
}

# Create IIS app pool and website if they do not already exist
if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
    Write-Host "Creating app pool '$appPoolName'..." -ForegroundColor Cyan
    New-WebAppPool -Name $appPoolName
    Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value 'v4.0'
    Write-Host "App pool created." -ForegroundColor Green
} else {
    Write-Host "App pool '$appPoolName' already exists, skipping." -ForegroundColor Yellow
}

if (-not (Test-Path "IIS:\Sites\$siteName")) {
    Write-Host "Creating IIS website '$siteName'..." -ForegroundColor Cyan
    if (-not (Test-Path $sitePhysicalPath)) {
        New-Item -ItemType Directory -Path $sitePhysicalPath -Force | Out-Null
    }
    New-Website -Name $siteName `
        -PhysicalPath $sitePhysicalPath `
        -Port $sitePort `
        -ApplicationPool $appPoolName `
        -Force
    Write-Host "IIS website '$siteName' created." -ForegroundColor Green
} else {
    Write-Host "IIS website '$siteName' already exists, skipping." -ForegroundColor Yellow
}

Write-Host "Downloading BankingApp web application backup..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $backupDownloadUrl -OutFile $backupZipPath -UseBasicParsing
Write-Host "Download complete." -ForegroundColor Green

Write-Host "Importing BankingApp site from backup package..." -ForegroundColor Cyan
& "$env:ProgramFiles\IIS\Microsoft Web Deploy V3\msdeploy.exe" `
    -verb:sync `
    -source:package="$backupZipPath" `
    -dest:auto `
    -allowUntrusted

Write-Host "IIS site import complete." -ForegroundColor Green

# Restart IIS to apply the imported site
Write-Host "Restarting IIS..." -ForegroundColor Cyan
& iisreset /restart
Write-Host "IIS restarted." -ForegroundColor Green

# Create a desktop shortcut to the Todo app for all users
Write-Host "Creating desktop shortcut for all users..." -ForegroundColor Cyan
$shortcutPath = Join-Path $env:PUBLIC "Desktop\Shortcut to Banking Web App.url"
$shortcutContent = @"
[InternetShortcut]
URL=http://localhost:$sitePort
"@
Set-Content -Path $shortcutPath -Value $shortcutContent -Encoding ASCII
Write-Host "Desktop shortcut created at '$shortcutPath'." -ForegroundColor Green

Stop-Transcript
