<#
.SYNOPSIS
  Development driver for factorio-broadcast: sets up a throwaway server instance,
  runs it headless with RCON + Lua UDP enabled, and drives it without a human.

.EXAMPLE
  .\scripts\dev.ps1 setup                 # one-time: junction the mod, copy a save
  .\scripts\dev.ps1 start
  .\scripts\dev.ps1 rcon "/silent-command rcon.print(game.tick)"
  .\scripts\dev.ps1 restart               # after editing mod\control.lua
  .\scripts\dev.ps1 stop
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'start', 'stop', 'restart', 'status', 'rcon', 'logs', 'errors')]
  [string]$Command = 'status',

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $PSScriptRoot
$Dev        = Join-Path $Root 'dev'
$ModsDir    = Join-Path $Dev 'mods'
$SaveFile   = Join-Path $Dev 'dev.zip'
$Settings   = Join-Path $Dev 'server-settings.json'
$PidFile    = Join-Path $Dev 'server.pid'
$StdoutLog  = Join-Path $Dev 'server-stdout.log'
$ConsoleLog = Join-Path $Dev 'server-console.log'

# Adjust if Factorio moves. Steam install; there is no Windows headless build,
# so the normal binary is used - it prints "Running in headless mode" for --start-server.
$Exe = 'F:\SteamLibrary\steamapps\common\Factorio\bin\x64\factorio.exe'

# 34199 is taken by the Factorio client when it is running, so the dev server
# uses its own ports throughout.
$GamePort     = 34198
$LuaUdpPort   = 34200
$RconPort     = 27015
$RconPassword = 'devpass'
$SidecarPort  = 41234

function Get-ServerProcess {
  if (-not (Test-Path $PidFile)) { return $null }
  $serverPid = (Get-Content $PidFile -Raw).Trim()
  if (-not $serverPid) { return $null }
  try { return Get-Process -Id ([int]$serverPid) -ErrorAction Stop } catch { return $null }
}

function Invoke-Setup {
  New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null

  $link = Join-Path $ModsDir 'factorio-broadcast'
  if (-not (Test-Path $link)) {
    # A junction means an edit to mod\control.lua is live on the next server
    # start - no copy step, no packaging.
    New-Item -ItemType Junction -Path $link -Target (Join-Path $Root 'mod') | Out-Null
    Write-Output "junction: $link -> $(Join-Path $Root 'mod')"
  }

  $modList = Join-Path $ModsDir 'mod-list.json'
  if (-not (Test-Path $modList)) {
    @'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": true },
    { "name": "quality", "enabled": true },
    { "name": "space-age", "enabled": true },
    { "name": "factorio-broadcast", "enabled": true }
  ]
}
'@ | Set-Content -Path $modList -Encoding utf8
    Write-Output "wrote $modList"
  }

  if (-not (Test-Path $Settings)) {
    @'
{
  "name": "factorio-broadcast-dev",
  "description": "local dev server",
  "tags": [],
  "max_players": 4,
  "visibility": { "public": false, "lan": true },
  "username": "",
  "password": "",
  "token": "",
  "game_password": "",
  "require_user_verification": false,
  "max_upload_in_kilobytes_per_second": 0,
  "max_upload_slots": 5,
  "minimum_latency_in_ticks": 0,
  "ignore_player_limit_for_returning_players": false,
  "allow_commands": "true",
  "autosave_interval": 0,
  "autosave_slots": 2,
  "afk_autokick_interval": 0,
  "auto_pause": false,
  "only_admins_can_pause_the_game": true,
  "autosave_only_on_server": true,
  "non_blocking_saving": true
}
'@ | Set-Content -Path $Settings -Encoding utf8
    Write-Output "wrote $Settings"
  }

  if (-not (Test-Path $SaveFile)) {
    # A real save with a running factory, so the statistics are never all zero.
    # Matched by glob: the filename has non-ASCII characters that do not survive
    # PowerShell 5.1 reading this script as ANSI.
    $source = Get-ChildItem -Path (Join-Path $env:APPDATA 'Factorio\saves') -Filter '10x *.zip' |
      Select-Object -First 1 -ExpandProperty FullName
    if ($source) {
      Copy-Item -LiteralPath $source -Destination $SaveFile
      Write-Output "copied save: $source"
    } else {
      & $Exe --create $SaveFile --map-gen-seed 1234 | Out-Null
      Write-Output "created empty save (source save not found): $SaveFile"
    }
  }

  Write-Output 'setup complete'
}

function Invoke-Start {
  $existing = Get-ServerProcess
  if ($existing) { Write-Output "already running (pid $($existing.Id))"; return }

  if (-not (Test-Path $SaveFile)) { throw 'no save; run: .\scripts\dev.ps1 setup' }

  $serverArgs = @(
    '--start-server', $SaveFile,
    '--server-settings', $Settings,
    '--mod-directory', $ModsDir,
    '--rcon-bind', "127.0.0.1:$RconPort",
    '--rcon-password', $RconPassword,
    '--enable-lua-udp', $LuaUdpPort,
    '--port', $GamePort,
    '--console-log', $ConsoleLog
  )

  $proc = Start-Process -FilePath $Exe -ArgumentList $serverArgs -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog -RedirectStandardError (Join-Path $Dev 'server-stderr.log')
  $proc.Id | Set-Content -Path $PidFile -Encoding ascii
  Write-Output "started pid=$($proc.Id)  rcon=127.0.0.1:$RconPort  lua-udp=$LuaUdpPort  game=$GamePort"
}

function Invoke-Stop {
  $proc = Get-ServerProcess
  if (-not $proc) { Write-Output 'not running'; return }
  # /quit over RCON saves and shuts down cleanly; killing the process loses ticks.
  try { node (Join-Path $PSScriptRoot 'rcon.js') 127.0.0.1 $RconPort $RconPassword '/quit' | Out-Null } catch { }
  try { $proc.WaitForExit(15000) | Out-Null } catch { }
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  Remove-Item $PidFile -ErrorAction SilentlyContinue
  Write-Output 'stopped'
}

function Invoke-Status {
  $proc = Get-ServerProcess
  if ($proc) {
    Write-Output "server: running (pid $($proc.Id), $([int]($proc.WorkingSet64/1MB)) MB)"
  } else {
    Write-Output 'server: stopped'
  }
  if (Test-Path $StdoutLog) {
    $ready = Select-String -Path $StdoutLog -Pattern 'Starting RCON interface|Hosting game' | Select-Object -Last 2
    $ready | ForEach-Object { Write-Output "  $($_.Line.Trim())" }
  }
}

function Invoke-Errors {
  if (-not (Test-Path $StdoutLog)) { Write-Output 'no log yet'; return }
  # This is what an agent greps after a restart to know whether the mod loaded.
  $hits = Select-String -Path $StdoutLog -Pattern 'Error|error while running|failed|Warning: ' |
    Where-Object { $_.Line -notmatch 'Warning: .*deprecated' } |
    Select-Object -Last 20
  if ($hits) { $hits | ForEach-Object { Write-Output $_.Line.Trim() } } else { Write-Output 'no errors' }
}

switch ($Command) {
  'setup'   { Invoke-Setup }
  'start'   { Invoke-Start }
  'stop'    { Invoke-Stop }
  'restart' { Invoke-Stop; Invoke-Start }
  'status'  { Invoke-Status }
  'errors'  { Invoke-Errors }
  'logs'    { if (Test-Path $StdoutLog) { Get-Content $StdoutLog -Tail 40 } else { Write-Output 'no log yet' } }
  'rcon'    {
    if (-not $Rest) { throw 'usage: .\scripts\dev.ps1 rcon "<command>"' }
    node (Join-Path $PSScriptRoot 'rcon.js') 127.0.0.1 $RconPort $RconPassword ($Rest -join ' ')
  }
}
