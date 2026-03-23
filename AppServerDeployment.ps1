<#
.SYNOPSIS
  Creates + deploys a simple Todo List ASP.NET Core Razor Pages app to IIS.
  Uses SQL Server on another server as the backend.

.NOTES
  - Installs IIS features.
  - Installs .NET Hosting Bundle (recommended for IIS hosting). [3](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/hosting-bundle?view=aspnetcore-10.0)[4](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0)
  - Uses dotnet-install.ps1 to install .NET SDK if missing. [5](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script)
  - Publishes and configures an IIS site (publish-to-IIS guidance). [1](https://learn.microsoft.com/en-us/aspnet/core/tutorials/publish-to-iis?view=aspnetcore-10.0)[2](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0)
#>

#Give the SQL script time to finish before this one runs
Start-Sleep -Seconds 600

# ----------------------------
# CONFIG (edit these)
# ----------------------------
$AppName         = "SimpleTodoPortal"
$Root            = "C:\Apps"
$AppPath         = Join-Path $Root $AppName
$PublishPath     = Join-Path $AppPath "publish"

$IISSiteName     = "SimpleTodoPortal"
$IISAppPoolName  = "SimpleTodoPortalPool"
$Port            = 80

# Remote SQL Server (Backend server)
$SqlServer       = "ArcTrainSQL"
$SqlDatabase     = "TodoDb"
$SqlUser         = "todouser"
$SqlPassword     = "ReplaceWithARealPassword!"

# .NET versions
$DotnetChannel   = "8.0"      # SDK channel
$HostingBundleWingetId = "Microsoft.DotNet.HostingBundle.8" # optional (if winget exists)

# ----------------------------
# Helpers
# ----------------------------
function Write-Section($text) {
  Write-Host ""
  Write-Host "==== $text ====" -ForegroundColor Cyan
}

# ----------------------------
# 1) Install IIS + tools
# ----------------------------
Write-Section "Installing IIS roles/features"
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools -IncludeManagementTools | Out-Null

# ----------------------------
# 2) Install .NET Hosting Bundle (recommended for IIS hosting)
#    Hosting Bundle includes runtime + ASP.NET Core Module for IIS. [3](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/hosting-bundle?view=aspnetcore-10.0)[4](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0)
# ----------------------------
Write-Section "Installing .NET Hosting Bundle (for IIS hosting)"
$winget = Get-Command winget -ErrorAction SilentlyContinue

if ($winget) {
  # Winget route (simple automation). (Package id shown by winget catalogs) [6](https://winget.ragerworks.com/package/Microsoft.DotNet.HostingBundle.8)
  winget install --id $HostingBundleWingetId -e --accept-package-agreements --accept-source-agreements
} else {
  Write-Warning "winget not found. Install the .NET Hosting Bundle manually from Microsoft guidance, then re-run this script."
  Write-Host "See: " -NoNewline
  Write-Host "https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/hosting-bundle" -ForegroundColor Yellow
  throw "Missing Hosting Bundle install path (winget not available)."
}

# ----------------------------
# 3) Ensure .NET SDK exists (needed to build/publish on this server)
#    Use dotnet-install.ps1 (official script) [5](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script)
# ----------------------------
Write-Section "Ensuring .NET SDK is installed (for build/publish)"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue

if (-not $dotnet) {
  $dotnetInstall = Join-Path $env:TEMP "dotnet-install.ps1"
  Invoke-WebRequest "https://dot.net/v1/dotnet-install.ps1" -OutFile $dotnetInstall
  Unblock-File $dotnetInstall

  # Install .NET SDK into Program Files location is not what the script does by default;
  # We install into a deterministic folder and add to PATH for current process.
  $InstallDir = "C:\dotnet"
  & $dotnetInstall -Channel $DotnetChannel -InstallDir $InstallDir -NoPath:$false
  $env:PATH = "$InstallDir;$env:PATH"
}

dotnet --info

# ----------------------------
# 4) Create Razor Pages app
# ----------------------------
Write-Section "Creating app folder + Razor Pages project"
New-Item -ItemType Directory -Path $AppPath -Force | Out-Null

# If rerunning, you may want to clean old content
if (Test-Path (Join-Path $AppPath "$AppName.csproj")) {
  Write-Warning "Project already exists. Skipping dotnet new."
} else {
  dotnet new webapp -n $AppName -o $AppPath
}

Push-Location $AppPath

# ----------------------------
# 5) Add EF Core SQL Server packages + dotnet-ef tool
# ----------------------------
Write-Section "Adding EF Core packages + installing dotnet-ef tool"
dotnet add package Microsoft.EntityFrameworkCore.SqlServer --version 8.0.0
dotnet add package Microsoft.EntityFrameworkCore.Design --version 8.0.0
dotnet add package Microsoft.EntityFrameworkCore.Tools --version 8.0.0

# Install EF tooling (common usage pattern shown in Microsoft Learn samples). [7](https://learn.microsoft.com/en-us/azure/app-service/tutorial-dotnetcore-sqldb-app)
dotnet tool install --global dotnet-ef
$env:PATH = "$env:PATH;$env:USERPROFILE\.dotnet\tools"

# ----------------------------
# 6) Write the Todo model + DbContext
# ----------------------------
Write-Section "Writing Todo model + DbContext + Razor Pages UI"

$ModelsDir = Join-Path $AppPath "Models"
$DataDir   = Join-Path $AppPath "Data"
$TodosDir  = Join-Path $AppPath "Pages\Todos"

New-Item -ItemType Directory -Path $ModelsDir,$DataDir,$TodosDir -Force | Out-Null

@"
using System;

namespace $AppName.Models;

public class TodoItem
{
    public int Id { get; set; }
    public string Title { get; set; } = string.Empty;
    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
}
"@ | Set-Content -Encoding UTF8 (Join-Path $ModelsDir "TodoItem.cs")

@"
using Microsoft.EntityFrameworkCore;
using $AppName.Models;

namespace $AppName.Data;

public class TodoDbContext : DbContext
{
    public TodoDbContext(DbContextOptions<TodoDbContext> options) : base(options) { }

    public DbSet<TodoItem> TodoItems => Set<TodoItem>();
}
"@ | Set-Content -Encoding UTF8 (Join-Path $DataDir "TodoDbContext.cs")

# ----------------------------
# 7) Configure Program.cs for EF Core + Razor Pages
# ----------------------------
$ProgramCs = Join-Path $AppPath "Program.cs"

$connectionString = "Server=$SqlServer;Database=$SqlDatabase;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"

@"
using Microsoft.EntityFrameworkCore;
using $AppName.Data;

var builder = WebApplication.CreateBuilder(args);

// Razor Pages
builder.Services.AddRazorPages();

// EF Core SQL Server
builder.Services.AddDbContext<TodoDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("TodoDb")));

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();

app.UseRouting();

app.MapRazorPages();

// Make / redirect to /Todos
app.MapGet("/", context =>
{
    context.Response.Redirect("/Todos");
    return Task.CompletedTask;
});

app.Run();
"@ | Set-Content -Encoding UTF8 $ProgramCs

# appsettings.json connection string
$appSettingsPath = Join-Path $AppPath "appsettings.json"
$appSettings = Get-Content $appSettingsPath -Raw | ConvertFrom-Json
if (-not $appSettings.ConnectionStrings) { $appSettings | Add-Member -MemberType NoteProperty -Name ConnectionStrings -Value (@{}) }
$appSettings.ConnectionStrings | Add-Member -MemberType NoteProperty -Name "TodoDb" -Value $connectionString -Force
$appSettings | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $appSettingsPath

# ----------------------------
# 8) Create Razor Pages: /Todos (Add + Delete)
# ----------------------------
@"
@page
@model $AppName.Pages.Todos.IndexModel
@{
    ViewData["Title"] = "To-Do List";
}

<h1 class="display-6 mb-3">To‑Do List</h1>

<div class="card mb-4">
  <div class="card-body">
    <form method="post" asp-page-handler="Add" class="row g-2">
      <div class="col-md-10">
        <input class="form-control" name="Title" placeholder="Add a new to-do item..." maxlength="200" required />
      </div>
      <div class="col-md-2 d-grid">
        <button class="btn btn-primary" type="submit">Add</button>
      </div>
    </form>
  </div>
</div>

@if (Model.Items.Count == 0)
{
    <p class="text-muted">No items yet.</p>
}
else
{
  <div class="list-group">
    @foreach (var item in Model.Items)
    {
      <div class="list-group-item d-flex justify-content-between align-items-center">
        <div>
          <strong>@item.Title</strong>
          <div class="text-muted small">Created: @item.CreatedUtc.ToString("u")</div>
        </div>
        <form method="post" asp-page-handler="Delete" class="ms-3">
          <input type="hidden" name="Id" value="@item.Id" />
          <button class="btn btn-outline-danger btn-sm" type="submit">Delete</button>
        </form>
      </div>
    }
  </div>
}
"@ | Set-Content -Encoding UTF8 (Join-Path $TodosDir "Index.cshtml")

@"
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;
using $AppName.Data;
using $AppName.Models;

namespace $AppName.Pages.Todos;

public class IndexModel : PageModel
{
    private readonly TodoDbContext _db;

    public IndexModel(TodoDbContext db) => _db = db;

    public List<TodoItem> Items { get; set; } = new();

    public async Task OnGetAsync()
    {
        Items = await _db.TodoItems
            .OrderByDescending(t => t.Id)
            .AsNoTracking()
            .ToListAsync();
    }

    public async Task<IActionResult> OnPostAddAsync([FromForm] string title)
    {
        if (string.IsNullOrWhiteSpace(title))
            return RedirectToPage();

        _db.TodoItems.Add(new TodoItem { Title = title.Trim() });
        await _db.SaveChangesAsync();
        return RedirectToPage();
    }

    public async Task<IActionResult> OnPostDeleteAsync([FromForm] int id)
    {
        var item = await _db.TodoItems.FindAsync(id);
        if (item != null)
        {
            _db.TodoItems.Remove(item);
            await _db.SaveChangesAsync();
        }
        return RedirectToPage();
    }
}
"@ | Set-Content -Encoding UTF8 (Join-Path $TodosDir "Index.cshtml.cs")

# Ensure Pages/_ViewImports has taghelpers (template usually does, but safe)
$ViewImportsPath = Join-Path $AppPath "Pages\_ViewImports.cshtml"
if (-not (Test-Path $ViewImportsPath)) {
@"
@using $AppName
@namespace $AppName.Pages
@addTagHelper *, Microsoft.AspNetCore.Mvc.TagHelpers
"@ | Set-Content -Encoding UTF8 $ViewImportsPath
}

# ----------------------------
# 9) EF Core migrations + create schema on remote SQL Server
# ----------------------------
Write-Section "Running EF migrations to create schema on remote SQL Server"
dotnet ef migrations add InitialCreate
dotnet ef database update

# ----------------------------
# 10) Publish
# ----------------------------
Write-Section "Publishing app"
dotnet publish -c Release -o $PublishPath

Pop-Location

# ----------------------------
# 11) Configure IIS site
# ----------------------------
Write-Section "Configuring IIS site + app pool"
Import-Module WebAdministration

if (-not (Test-Path "IIS:\AppPools\$IISAppPoolName")) {
  New-WebAppPool -Name $IISAppPoolName | Out-Null
}

# No managed runtime for ASP.NET Core (out-of-process module handles it)
Set-ItemProperty "IIS:\AppPools\$IISAppPoolName" -Name managedRuntimeVersion -Value ""
Set-ItemProperty "IIS:\AppPools\$IISAppPoolName" -Name processModel.identityType -Value ApplicationPoolIdentity

if (-not (Test-Path "IIS:\Sites\$IISSiteName")) {
  New-Website -Name $IISSiteName -Port $Port -PhysicalPath $PublishPath -ApplicationPool $IISAppPoolName | Out-Null
} else {
  Set-ItemProperty "IIS:\Sites\$IISSiteName" -Name physicalPath -Value $PublishPath
  Set-ItemProperty "IIS:\Sites\$IISSiteName" -Name applicationPool -Value $IISAppPoolName
}

iisreset | Out-Null

# ----------------------------
# 12) Stop Default Web Site and start SimpleTodoPortal
# ----------------------------
Write-Section "Stopping Default Web Site and starting $IISSiteName"
if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) {
  Stop-Website -Name "Default Web Site"
  Write-Host "Default Web Site stopped."
}
Start-Website -Name $IISSiteName
Write-Host "$IISSiteName started."

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "Browse: http://localhost:$Port/Todos" -ForegroundColor Green
