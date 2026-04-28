# ============================================================================
# Important Variables
# ============================================================================
#$webDeployUrl = "https://download.microsoft.com/download/0/1/D/01DC28EA-638C-4A22-A57B-4CEF97755C6C/WebDeploy_amd64_en-US.msi"
$webDeployUrl = "https://github.com/Mr-MSFT/Training/raw/refs/heads/main/WebDeploy_amd64_en-US.msi"
$webDeployInstaller = "C:\Temp\WebDeploy_amd64_en-US.msi"
$exportedSiteUrl = "https://github.com/Mr-MSFT/Training/raw/refs/heads/main/Todo.zip"
$exportedSiteZipPath = "C:\Temp\exported-site.zip"
$siteName = "SimpleTodoPortal"
$sitePhysicalPath = "C:\inetpub\wwwroot\SimpleTodoPortal"
$sitePort = 80
$appPoolName = "SimpleTodoPortalPool"

# ============================================================================
# Script Execution
# ============================================================================

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null }
Start-Transcript -Path "C:\Temp\TodoConfigOutput.txt" -Force

# Install IIS and required features
$iisFeature = Get-WindowsFeature -Name Web-Server
if ($iisFeature.InstallState -ne 'Installed') {
    Write-Host "Installing IIS and required features..." -ForegroundColor Cyan

    Install-WindowsFeature -Name Web-Server `
        -IncludeManagementTools `
        -IncludeAllSubFeature

    Install-WindowsFeature -Name Web-Asp-Net45
    Install-WindowsFeature -Name Web-Net-Ext45

    Write-Host "IIS installation complete." -ForegroundColor Green
} else {
    Write-Host "IIS is already installed, skipping." -ForegroundColor Yellow
}

# Install ASP.NET Core Module V2 (version 8.0.0) via the .NET Hosting Bundle
$hostingBundleInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*ASP.NET Core*8.0*Hosting Bundle*" }
if (-not $hostingBundleInstalled) {
    Write-Host "Downloading .NET 8 Hosting Bundle..." -ForegroundColor Cyan
    $hostingBundleUrl = "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.26/dotnet-hosting-8.0.26-win.exe"
    $hostingBundleInstaller = "C:\Temp\dotnet-hosting-8.0.26-win.exe"
    Invoke-WebRequest -Uri $hostingBundleUrl -OutFile $hostingBundleInstaller -UseBasicParsing

    Write-Host "Installing .NET 8 Hosting Bundle..." -ForegroundColor Cyan
    Start-Process -FilePath $hostingBundleInstaller -ArgumentList "/install", "/quiet", "/norestart" -Wait -NoNewWindow

    Write-Host ".NET 8 Hosting Bundle installation complete." -ForegroundColor Green
} else {
    Write-Host ".NET 8 Hosting Bundle is already installed, skipping." -ForegroundColor Yellow
}

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
    Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value ''
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

Write-Host "Downloading exported IIS site package..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $exportedSiteUrl -OutFile $exportedSiteZipPath -UseBasicParsing
Write-Host "Download complete." -ForegroundColor Green

Write-Host "Importing IIS site from package..." -ForegroundColor Cyan
& "$env:ProgramFiles\IIS\Microsoft Web Deploy V3\msdeploy.exe" `
    -verb:sync `
    -source:package="$exportedSiteZipPath" `
    -dest:auto `
    -allowUntrusted

Write-Host "IIS site import complete." -ForegroundColor Green

# Restart IIS to apply the imported site
Write-Host "Restarting IIS..." -ForegroundColor Cyan
& iisreset /restart
Write-Host "IIS restarted." -ForegroundColor Green

# Create a desktop shortcut to the Todo app for all users
Write-Host "Creating desktop shortcut for all users..." -ForegroundColor Cyan
$shortcutPath = Join-Path $env:PUBLIC "Desktop\Shortcut to Todo Web App.url"
$shortcutContent = @"
[InternetShortcut]
URL=http://localhost/Todos
"@
Set-Content -Path $shortcutPath -Value $shortcutContent -Encoding ASCII
Write-Host "Desktop shortcut created at '$shortcutPath'." -ForegroundColor Green

Stop-Transcript
