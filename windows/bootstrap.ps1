<#
.SYNOPSIS
  Sets up a Windows machine to match the Linux/macOS Ansible setup.

.DESCRIPTION
  Installs apps with winget, removes preinstalled apps, turns on dark mode,
  installs Claude Code and mise (+ uv), and can optionally install WSL so the
  Ansible playbook can set up a Linux shell too. Safe to re-run: anything
  already installed or already removed is skipped.

  Run from a normal (non-admin) PowerShell window:
    powershell -ExecutionPolicy Bypass -File windows\bootstrap.ps1
  winget asks for elevation per app when it needs it.

.PARAMETER WithWsl
  Also install WSL with Fedora (needs a reboot the first time).

.PARAMETER GitUserName
  Optional git user.name.

.PARAMETER GitUserEmail
  Optional git user.email.

.PARAMETER CheckOnly
  Only check that every winget package ID exists; installs nothing.
#>
[CmdletBinding()]
param(
    [switch]$WithWsl,
    [string]$GitUserName = '',
    [string]$GitUserEmail = '',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

# Keep these in step with vars/apps.yml.
$WingetPackages = @(
    # Apps
    'Google.Chrome'
    'Spotify.Spotify'
    'VideoLAN.VLC'
    'Microsoft.VisualStudioCode'
    'JetBrains.Toolbox'            # install IntelliJ from Toolbox with one click
    'Docker.DockerDesktop'
    'RedHat.Podman'
    'NoMachine.NoMachine'          # server + client
    'Anthropic.Claude'
    'Google.GoogleDrive'
    'Microsoft.WindowsTerminal'    # Ghostty has no Windows build yet
    # CLI tools
    'Git.Git'
    'GitHub.cli'
    'vim.vim'
    'junegunn.fzf'
    'sharkdp.bat'
    'aristocratos.btop4win'
    'eza-community.eza'
    'dandavison.delta'
    'jdx.mise'
    'DEVCOM.JetBrainsMonoNerdFont'
)

# Preinstalled Store apps to remove, matching what's removed on Fedora/macOS.
$AppxRemove = @(
    'Clipchamp.Clipchamp'
    'Microsoft.BingNews'
    'Microsoft.BingWeather'               # GNOME Weather
    'Microsoft.WindowsMaps'               # GNOME Maps
    'Microsoft.People'                    # GNOME Contacts
    'Microsoft.GetHelp'                   # Help
    'Microsoft.Getstarted'                # Tips, like GNOME Tour
    'Microsoft.ZuneMusic'                 # Media Player (VLC instead)
    'Microsoft.ZuneVideo'                 # Movies & TV
    'Microsoft.MicrosoftOfficeHub'        # Office/Microsoft 365 launcher
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.Todos'
)

$MiseGlobalTools = @('uv')
$WslDistro = 'FedoraLinux-42'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Skip([string]$Message) { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Test-WingetInstalled([string]$Id) {
    winget list --id $Id --exact --accept-source-agreements --disable-interactivity *> $null
    return $LASTEXITCODE -eq 0
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user;$env:USERPROFILE\.local\bin"
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store and re-run.'
}

if ($CheckOnly) {
    Write-Step 'Checking winget package IDs'
    $missing = @()
    foreach ($id in $WingetPackages) {
        winget show --id $id --exact --accept-source-agreements --disable-interactivity *> $null
        if ($LASTEXITCODE -eq 0) { Write-Skip "ok      $id" } else { Write-Warn "missing $id"; $missing += $id }
    }
    if ($missing.Count -gt 0) { throw "Unknown winget IDs: $($missing -join ', ')" }
    return
}

# --- Apps -------------------------------------------------------------------
Write-Step 'Installing apps with winget'
$failed = @()
foreach ($id in $WingetPackages) {
    if (Test-WingetInstalled $id) { Write-Skip "already installed: $id"; continue }
    Write-Host "    installing $id"
    winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { Write-Warn "failed: $id (exit $LASTEXITCODE)"; $failed += $id }
}
Update-SessionPath

# --- Removals ----------------------------------------------------------------
Write-Step 'Removing preinstalled apps'
foreach ($name in $AppxRemove) {
    $pkgs = Get-AppxPackage -Name $name
    if (-not $pkgs) { Write-Skip "not installed: $name"; continue }
    foreach ($pkg in $pkgs) {
        Write-Host "    removing $($pkg.Name)"
        try { $pkg | Remove-AppxPackage } catch { Write-Warn "couldn't remove $name`: $_" }
    }
}

# --- Dark mode ---------------------------------------------------------------
Write-Step 'Turning on dark mode'
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
foreach ($value in 'AppsUseLightTheme', 'SystemUsesLightTheme') {
    if ((Get-ItemProperty -Path $personalize -Name $value -ErrorAction SilentlyContinue).$value -ne 0) {
        Set-ItemProperty -Path $personalize -Name $value -Value 0 -Type DWord
        Write-Host "    set $value = 0"
    } else { Write-Skip "$value already 0" }
}

# --- Claude Code -------------------------------------------------------------
Write-Step 'Installing Claude Code'
if (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") {
    Write-Skip 'already installed'
} else {
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    Update-SessionPath
}

# --- mise + uv -----------------------------------------------------------------
Write-Step 'Installing global tools with mise'
if (Get-Command mise -ErrorAction SilentlyContinue) {
    foreach ($tool in $MiseGlobalTools) {
        mise which $tool *> $null
        if ($LASTEXITCODE -eq 0) { Write-Skip "already installed: $tool"; continue }
        mise use -g "$tool@latest"
    }
    if ((mise settings get python.uv_venv_auto 2>$null) -ne 'true') {
        mise settings set python.uv_venv_auto true
    }
} else {
    Write-Warn 'mise not on PATH yet; open a new terminal and re-run to install uv.'
}

# --- Git and SSH ---------------------------------------------------------------
Write-Step 'Configuring git'
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitConfig = [ordered]@{
        'init.defaultBranch'                        = 'main'
        'pull.rebase'                               = 'true'
        'push.autoSetupRemote'                      = 'true'
        'fetch.prune'                               = 'true'
        'merge.conflictstyle'                       = 'zdiff3'
        'core.autocrlf'                             = 'input'
        'credential.https://github.com.helper'      = '!gh auth git-credential'
        'credential.https://gist.github.com.helper' = '!gh auth git-credential'
        'core.pager'                                = 'delta'
        'interactive.diffFilter'                    = 'delta --color-only'
        'delta.navigate'                            = 'true'
        'delta.line-numbers'                        = 'true'
        'delta.dark'                                = 'true'
    }
    if ($GitUserName) { $gitConfig['user.name'] = $GitUserName }
    if ($GitUserEmail) { $gitConfig['user.email'] = $GitUserEmail }
    foreach ($key in $gitConfig.Keys) {
        if ((git config --global --get $key) -ne $gitConfig[$key]) {
            git config --global --replace-all $key $gitConfig[$key]
            Write-Host "    set $key"
        }
    }
}

$sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
if (Test-Path $sshKey) {
    Write-Skip 'SSH key already exists'
} else {
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
    # A string ArgumentList is passed as-is, so -N "" (no passphrase) survives
    # both Windows PowerShell and PowerShell 7 argument quoting.
    Start-Process ssh-keygen -NoNewWindow -Wait -ArgumentList "-q -t ed25519 -N `"`" -C $env:USERNAME@$env:COMPUTERNAME -f `"$sshKey`""
    Write-Host "    created $sshKey.pub (add it to GitHub with: gh ssh-key add $sshKey.pub)"
}

# --- WSL ---------------------------------------------------------------------
if ($WithWsl) {
    Write-Step "Installing WSL with $WslDistro"
    $distros = (wsl --list --quiet 2>$null) -replace "`0", ''
    if ($distros -contains $WslDistro) {
        Write-Skip 'already installed'
    } else {
        wsl --install -d $WslDistro
        Write-Warn 'Reboot if asked, open Fedora from the Start menu, then run ./bootstrap.sh from this repo inside it.'
    }
}

# --- Summary -----------------------------------------------------------------
Write-Step 'Done'
if ($failed.Count -gt 0) {
    Write-Warn "These apps failed to install; re-run to retry: $($failed -join ', ')"
    exit 1
}
Write-Host 'Open a new terminal so PATH changes take effect.'
