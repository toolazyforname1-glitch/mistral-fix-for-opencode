param(
  [string]$SourceDir = $PSScriptRoot,
  [string]$ApiKey = '',
  [switch]$Unattended,
  [switch]$DisableApiChange,
  [switch]$EnableBackground,
  [switch]$DisableSync
)

$ErrorActionPreference = 'Stop'
$script:AppName = 'VIBE MODE SETUP'
$script:AppVersion = '1.0.0'
$script:Rows = @()
$script:BarY = 0
$script:Interactive = $true
try {
  if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $script:Interactive = $false }
} catch {
  $script:Interactive = $false
}
$script:NoPrompt = $true
if (-not $Unattended -and $script:Interactive) { $script:NoPrompt = $false }

function Get-Width {
  $w = 100
  try { $w = [Console]::WindowWidth } catch {}
  if ($w -lt 64) { $w = 64 }
  if ($w -gt 104) { $w = 104 }
  return ($w - 1)
}

function Write-Color([string]$Text, [string]$Color = 'Gray') {
  Write-Host $Text -ForegroundColor $Color
}

function Clear-Screen {
  if (-not $script:Interactive) { return }
  try { Clear-Host } catch { }
}

function Show-Header([string]$Subtitle) {
  $w = Get-Width
  Write-Host ''
  Write-Color ('  ' + $script:AppName + '  v' + $script:AppVersion) 'Cyan'
  Write-Color ('  ' + $Subtitle) 'DarkGray'
  Write-Color ('  ' + ('-' * ($w - 4))) 'DarkGray'
  Write-Host ''
}

function Format-Bytes([long]$Value) {
  if ($Value -ge 1GB) { return ('{0:N1} GB' -f ($Value / 1GB)) }
  if ($Value -ge 1MB) { return ('{0:N1} MB' -f ($Value / 1MB)) }
  if ($Value -ge 1KB) { return ('{0:N0} KB' -f ($Value / 1KB)) }
  return "$Value B"
}

function Test-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Get-OpenCodePath {
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in @("$env:APPDATA\npm\opencode.exe", "$env:USERPROFILE\.bun\bin\opencode.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Get-ExeVersion([string]$Exe) {
  try {
    $out = & $Exe --version 2>&1 | Out-String
    return $out.Trim().Split("`n")[0].Trim()
  } catch {
    return $null
  }
}

function Read-Secret([string]$Prompt) {
  Write-Host ('  ' + $Prompt) -ForegroundColor Gray -NoNewline
  $sb = New-Object System.Text.StringBuilder
  while ($true) {
    $key = [Console]::ReadKey($true)
    if ($key.Key -eq 'Enter') { break }
    if ($key.Key -eq 'Backspace') {
      if ($sb.Length -gt 0) {
        [void]$sb.Remove($sb.Length - 1, 1)
        Write-Host "`b `b" -NoNewline
      }
      continue
    }
    if ($key.Key -eq 'Escape') { Write-Host ''; return $null }
    if ([char]::IsControl($key.KeyChar)) { continue }
    if ($sb.Length -ge 200) { continue }
    [void]$sb.Append($key.KeyChar)
    Write-Host '*' -NoNewline
  }
  Write-Host ''
  return $sb.ToString()
}

function Confirm-Default([string]$Prompt, [bool]$Default = $true) {
  $suffix = ' [Y/n] '
  if (-not $Default) { $suffix = ' [y/N] ' }
  Write-Host ('  ' + $Prompt + $suffix) -ForegroundColor Gray -NoNewline
  $key = [Console]::ReadKey($true)
  Write-Host ''
  if ($key.Key -eq 'Enter') { return $Default }
  if ($key.Key -eq 'Y') { return $true }
  if ($key.Key -eq 'N') { return $false }
  return $Default
}

function New-Row([string]$Name) {
  $script:Rows += [pscustomobject]@{ Name = $Name; Status = 'pending'; Detail = ''; Y = 0 }
  return ($script:Rows.Count - 1)
}

function Get-RowText($Row) {
  $mark = '[ ]'
  $color = 'DarkGray'
  switch ($Row.Status) {
    'run'  { $mark = '[..]'; $color = 'Yellow' }
    'ok'   { $mark = '[OK]'; $color = 'Green' }
    'warn' { $mark = '[!!]'; $color = 'Yellow' }
    'fail' { $mark = '[XX]'; $color = 'Red' }
    'skip' { $mark = '[--]'; $color = 'DarkGray' }
  }
  $name = $Row.Name
  $detail = $Row.Detail
  $text = '  ' + $mark + '  ' + $name
  if ($detail) { $text = $text + '  ' + $detail }
  $w = Get-Width
  if ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
  return @{ Text = $text; Color = $color }
}

function Draw-Progress([string]$Title) {
  Clear-Screen
  Show-Header $Title
  foreach ($row in $script:Rows) {
    $render = Get-RowText $row
    if ($script:Interactive) { $row.Y = [Console]::CursorTop }
    Write-Host $render.Text -ForegroundColor $render.Color
  }
  Write-Host ''
  if ($script:Interactive) {
    $script:BarY = [Console]::CursorTop
    Write-Host ''
  }
}

function Update-Row([int]$Index, [string]$Status, [string]$Detail = '') {
  $row = $script:Rows[$Index]
  $row.Status = $Status
  $row.Detail = $Detail
  $render = Get-RowText $row
  if (-not $script:Interactive) {
    if ($Status -in @('ok', 'warn', 'fail', 'skip')) {
      Write-Host $render.Text -ForegroundColor $render.Color
    }
    return
  }
  try {
    $pos = [Console]::CursorPosition
    [Console]::SetCursorPosition(0, $row.Y)
    Write-Host $render.Text.PadRight((Get-Width)) -ForegroundColor $render.Color -NoNewline
    [Console]::SetCursorPosition($pos.X, $pos.Y)
  } catch {
    Write-Host $render.Text -ForegroundColor $render.Color
  }
}

function Update-Bar([int]$Done, [int]$Total) {
  if (-not $script:Interactive) { return }
  if ($Total -le 0) { return }
  $w = 32
  $filled = [int](($Done / $Total) * $w)
  if ($filled -gt $w) { $filled = $w }
  $bar = ('#' * $filled) + ('-' * ($w - $filled))
  $text = '  [' + $bar + '] ' + $Done + '/' + $Total
  try {
    $pos = [Console]::CursorPosition
    [Console]::SetCursorPosition(0, $script:BarY)
    Write-Host $text.PadRight((Get-Width)) -ForegroundColor Cyan -NoNewline
    [Console]::SetCursorPosition($pos.X, $pos.Y)
  } catch { }
}

function Invoke-ProcessRow([int]$Index, [string]$File, [string[]]$Arguments) {
  $outLog = Join-Path $env:TEMP ('vibe-setup-out-' + [guid]::NewGuid().ToString('N') + '.log')
  $errLog = Join-Path $env:TEMP ('vibe-setup-err-' + [guid]::NewGuid().ToString('N') + '.log')
  $frames = @('|', '/', '-', '\')
  $i = 0
  try {
    $proc = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    while (-not $proc.HasExited) {
      Update-Row $Index 'run' ('working ' + $frames[$i % 4])
      Start-Sleep -Milliseconds 250
      $i++
    }
    $proc.WaitForExit()
    if ($proc.ExitCode -eq 0) {
      Update-Row $Index 'ok' ''
      return $true
    }
    $tail = @()
    if (Test-Path $errLog) { $tail += (Get-Content $errLog -Tail 2) }
    if (Test-Path $outLog) { $tail += (Get-Content $outLog -Tail 2) }
    $detail = ($tail | Where-Object { $_ } | Select-Object -Last 1)
    if ($detail) { $detail = $detail.Trim() }
    Update-Row $Index 'fail' ("exit " + $proc.ExitCode + ' ' + $detail)
    return $false
  } catch {
    Update-Row $Index 'fail' $_.Exception.Message
    return $false
  } finally {
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
  }
}

function Sync-ProcessPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @()
  foreach ($p in (($machine + ';' + $user).Split(';'))) {
    if ($p -and ($parts -notcontains $p)) { $parts += $p }
  }
  $env:Path = ($parts -join ';')
}
$script:ConfigDir = Join-Path $env:USERPROFILE '.config\opencode'
if ($env:XDG_CONFIG_HOME) { $script:ConfigDir = Join-Path $env:XDG_CONFIG_HOME 'opencode' }
$script:ConfigPath = Join-Path $script:ConfigDir 'opencode.json'
$script:StatePath = Join-Path $script:ConfigDir 'vibe-mode.json'
$script:KeyPath = Join-Path $script:ConfigDir 'secrets\mistral.key'
$script:LocalBin = Join-Path $env:USERPROFILE '.local\bin'

$script:ModelsJson = @'
{
  "deepseek-v4-1-flash-1017": {
    "name": "deepseek-v4-1-flash-1017",
    "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"], "temperature": true, "reasoning": { "supported": true, "effort": ["low", "high", "max"] } },
    "limit": { "context": 1048576, "output": 131072 }
  },
  "mistral-large-4": {
    "name": "Mistral Large 4",
    "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"], "temperature": true, "reasoning": { "supported": true, "effort": ["low", "medium", "high"] } },
    "limit": { "context": 1048576, "output": 131072 }
  },
  "mistral-medium-latest": {
    "name": "Mistral Medium 3.5",
    "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"], "temperature": true, "reasoning": { "supported": true, "effort": ["none", "high"] } },
    "limit": { "context": 262144, "output": 65536 }
  },
  "zai-glm-5-3": {
    "name": "GLM 5.3 (Mistral Hosted)",
    "capabilities": { "tools": true, "input": ["text"], "output": ["text"], "temperature": true, "reasoning": { "supported": true, "effort": ["low", "high", "max"] } },
    "limit": { "context": 1048576, "output": 131072 }
  },
  "zai-glm-5-3-flash": {
    "name": "GLM 5.3 Flash (Mistral Hosted)",
    "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"], "temperature": true, "reasoning": { "supported": true, "effort": ["low", "high", "max"] } },
    "limit": { "context": 1048576, "output": 131072 }
  },
  "zai-glm-5-3-flash-vibe-free": {
    "name": "GLM 5.3 Flash Free (Mistral Hosted)",
    "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"], "temperature": true, "reasoning": { "supported": true, "effort": ["low", "high", "max"] } },
    "limit": { "context": 262144, "output": 65536 }
  }
}
'@

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}

function Has-Prop($Object, [string]$Name) {
  if ($null -eq $Object) { return $false }
  return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-StoredKey {
  if (Test-Path $script:KeyPath) {
    try { return ([IO.File]::ReadAllText($script:KeyPath)).Trim() } catch { return $null }
  }
  return $null
}

function Find-VibePython {
  $candidates = @()
  if ($env:UV_TOOL_DIR) { $candidates += (Join-Path $env:UV_TOOL_DIR 'mistral-vibe\Scripts\python.exe') }
  if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'uv\tools\mistral-vibe\Scripts\python.exe') }
  if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'uv\tools\mistral-vibe\Scripts\python.exe') }
  if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'AppData\Roaming\uv\tools\mistral-vibe\Scripts\python.exe') }
  foreach ($path in $candidates) {
    if (Test-Path $path) { return $path }
  }
  return $null
}

function Save-ApiKey([string]$Key) {
  Ensure-Directory (Split-Path -Parent $script:KeyPath)
  [IO.File]::WriteAllText($script:KeyPath, $Key.Trim(), (New-Object System.Text.UTF8Encoding($false)))
}

function Set-VibeKeyring([string]$Key) {
  $python = Find-VibePython
  if (-not $python) { return $false }
  try {
    $Key | & $python -c "import keyring,sys; keyring.set_password('ai.mistral.vibe','MISTRAL_API_KEY',sys.stdin.read().strip())" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Add-VibePluginConfig {
  $created = $false
  if (-not (Test-Path $script:ConfigPath)) {
    $created = $true
    Ensure-Directory $script:ConfigDir
    [IO.File]::WriteAllText($script:ConfigPath, "{`n  `"`$schema`": `"https://opencode.ai/config.json`"`n}`n", (New-Object System.Text.UTF8Encoding($false)))
  }
  Copy-Item $script:ConfigPath ($script:ConfigPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force -ErrorAction SilentlyContinue
  $raw = [IO.File]::ReadAllText($script:ConfigPath)
  if (-not $raw.Trim()) { $raw = '{}' }
  $cfg = $raw | ConvertFrom-Json

  $plugins = @()
  if (Has-Prop $cfg 'plugins') { $plugins = @($cfg.plugins) }
  $hasPlugin = $false
  foreach ($p in $plugins) { if ($p -and (Has-Prop $p 'package') -and $p.package -eq './plugins/vibe-mode') { $hasPlugin = $true } }
  if (-not $hasPlugin) { $plugins += [pscustomobject]@{ package = './plugins/vibe-mode' } }
  $cfg | Add-Member -NotePropertyName plugins -NotePropertyValue $plugins -Force

  if (-not (Has-Prop $cfg 'providers')) {
    $cfg | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $models = $script:ModelsJson | ConvertFrom-Json
  if (-not (Has-Prop $cfg.providers 'mistral')) {
    $provider = [pscustomobject]@{
      name = 'Mistral'
      package = '@opencode/ai/providers/openai-compatible'
      settings = [pscustomobject]@{
        baseURL = 'https://api.mistral.ai/v1'
        apiKey = '{file:secrets/mistral.key}'
      }
      models = $models
    }
    $cfg.providers | Add-Member -NotePropertyName mistral -NotePropertyValue $provider -Force
  } else {
    $existing = $cfg.providers.mistral
    if (-not (Has-Prop $existing 'models') -or @($existing.models.PSObject.Properties).Count -eq 0) {
      $existing | Add-Member -NotePropertyName models -NotePropertyValue $models -Force
    }
    if (-not (Has-Prop $existing 'settings')) {
      $existing | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{ baseURL = 'https://api.mistral.ai/v1'; apiKey = '{file:secrets/mistral.key}' }) -Force
    }
  }

  $json = $cfg | ConvertTo-Json -Depth 100
  [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  if ($created) { return 'created' }
  return 'updated'
}

function Save-ModeState([bool]$ApiChange, [bool]$Background, [bool]$SyncKey) {
  Ensure-Directory $script:ConfigDir
  $state = [ordered]@{ apiChange = $ApiChange; background = $Background; syncKey = $SyncKey }
  [IO.File]::WriteAllText($script:StatePath, ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Show-Options($Items, [int]$Selected) {
  Clear-Screen
  Show-Header 'Choose what to install'
  Write-Color '  Environment' 'White'
  Write-Color ('    OpenCode V2   ' + $script:EnvOpenCode) 'Gray'
  Write-Color ('    Vibe          ' + $script:EnvVibe) 'Gray'
  Write-Color ('    uv            ' + $script:EnvUv) 'Gray'
  Write-Color ('    Config        ' + $script:ConfigDir) 'Gray'
  Write-Host ''
  Write-Color '  Options   up/down move, space toggles, enter installs' 'White'
  Write-Host ''
  for ($i = 0; $i -lt $Items.Count; $i++) {
    $item = $Items[$i]
    $cursor = '   '
    if ($i -eq $Selected) { $cursor = '  >' }
    $box = '[ ]'
    if ($item.On) { $box = '[x]' }
    $color = 'Gray'
    if ($i -eq $Selected) { $color = 'Cyan' }
    Write-Host ($cursor + ' ' + $box + ' ' + $item.Label) -ForegroundColor $color
    Write-Host ('       ' + $item.Desc) -ForegroundColor 'DarkGray'
  }
  Write-Host ''
  Write-Color '  q quits' 'DarkGray'
}
try { $Host.UI.RawUI.WindowTitle = 'Vibe Mode Setup' } catch {}

$ocPath = Get-OpenCodePath
$ocVersion = 'not found'
if ($ocPath) {
  $v = Get-ExeVersion $ocPath
  if ($v) { $ocVersion = $v }
}
$vibePath = Test-CommandPath 'vibe'
$vibeVersion = 'not found'
if ($vibePath) {
  $v = Get-ExeVersion $vibePath
  if ($v) { $vibeVersion = $v }
}
$uvPath = Test-CommandPath 'uv'
$uvVersion = 'not found'
if ($uvPath) {
  $v = Get-ExeVersion $uvPath
  if ($v) { $uvVersion = 'uv ' + $v }
}

$script:EnvOpenCode = $ocVersion
if ($ocPath) { $script:EnvOpenCode = $ocVersion + '  ' + $ocPath }
$script:EnvVibe = $vibeVersion
$script:EnvUv = $uvVersion
if ($uvPath) { $script:EnvUv = $uvVersion + '  ' + $uvPath }

$optApi = $true
$optBackground = $false
$optSync = $true
$optPrereq = $true

if (-not $script:NoPrompt) {
  $items = @(
    [pscustomobject]@{ Label = 'API change (build #1)'; Desc = 'Inject Vibe metadata into Mistral requests so they use the Vibe quota'; On = $true },
    [pscustomobject]@{ Label = 'Vibe background (build #2)'; Desc = 'Route Mistral traffic through the Vibe CLI; OpenCode executes the tool calls'; On = $false },
    [pscustomobject]@{ Label = 'Auto-sync API key to Vibe'; Desc = 'After /connect in OpenCode, copy the Mistral key into Vibe automatically'; On = $true },
    [pscustomobject]@{ Label = 'Install missing prerequisites'; Desc = 'Install uv, Vibe, Node.js and OpenCode V2 when they are not found'; On = $true }
  )

  $selected = 0
  while ($true) {
    Show-Options $items $selected
    $key = [Console]::ReadKey($true)
    if ($key.Key -eq 'UpArrow') { if ($selected -gt 0) { $selected-- } }
    elseif ($key.Key -eq 'DownArrow') { if ($selected -lt ($items.Count - 1)) { $selected++ } }
    elseif ($key.Key -eq 'Spacebar') { $items[$selected].On = -not $items[$selected].On }
    elseif ($key.Key -eq 'Enter') { break }
    elseif ($key.Key -eq 'Q') { exit 0 }
  }

  $optApi = [bool]$items[0].On
  $optBackground = [bool]$items[1].On
  $optSync = [bool]$items[2].On
  $optPrereq = [bool]$items[3].On
} else {
  $optApi = -not $DisableApiChange
  $optBackground = [bool]$EnableBackground
  $optSync = -not $DisableSync
  $optPrereq = $true
}

$stored = Get-StoredKey
$apiKey = $null
if ($ApiKey) { $apiKey = $ApiKey.Trim() }
elseif ($env:VIBE_SETUP_KEY) { $apiKey = $env:VIBE_SETUP_KEY.Trim() }

if (-not $apiKey -and -not $script:NoPrompt) {
  Clear-Screen
  Show-Header 'Mistral API key'
  if ($stored -and $stored.Length -ge 20) {
    Write-Color ('  Found an existing key: ' + $stored.Length + ' characters in ' + $script:KeyPath) 'Gray'
    Write-Host ''
    if (Confirm-Default 'Keep this key?' $true) {
      $apiKey = $stored
    }
  } else {
    Write-Color '  Vibe and OpenCode will share this Mistral API key.' 'Gray'
    Write-Color '  Create one at console.mistral.ai if you do not have it yet.' 'DarkGray'
    Write-Host ''
  }
  while (-not $apiKey) {
    $entered = Read-Secret 'Paste the Mistral API key (input hidden):'
    if ($null -eq $entered) { exit 0 }
    $entered = $entered.Trim()
    if ($entered.Length -lt 20) {
      Write-Color '  That looks too short, try again.' 'Red'
      continue
    }
    $apiKey = $entered
  }
}

if (-not $apiKey -and $stored -and $stored.Length -ge 20) { $apiKey = $stored }
if (-not $apiKey) {
  Write-Color '  No API key available. Pass -ApiKey or set VIBE_SETUP_KEY.' 'Red'
  exit 1
}

$rOpen = New-Row 'OpenCode V2'
$rNode = New-Row 'Node.js (bridge runtime)'
$rUv = New-Row 'uv package manager'
$rVibe = New-Row 'Mistral Vibe'
$rPath = New-Row 'PATH'
$rPlugin = New-Row 'vibe-mode plugin'
$rConfig = New-Row 'OpenCode config'
$rKey = New-Row 'Mistral API key'
$rSync = New-Row 'Vibe keyring'
$rState = New-Row 'Mode state'
$rCheck = New-Row 'Verification'
$total = $script:Rows.Count
Draw-Progress 'Installing'

if ($ocPath) {
  Update-Row $rOpen 'ok' $ocVersion
} elseif ($optPrereq -and (Test-CommandPath 'npm')) {
  $null = Invoke-ProcessRow $rOpen $env:ComSpec @('/c', 'npm', 'install', '-g', '@opencode/cli')
  $ocPath = Get-OpenCodePath
  if ($ocPath) { Update-Row $rOpen 'ok' (Get-ExeVersion $ocPath) } elseif ($script:Rows[$rOpen].Status -ne 'fail') { Update-Row $rOpen 'fail' 'not found after install' }
} else {
  Update-Row $rOpen 'warn' 'not found; install OpenCode V2 first'
}
Update-Bar 1 $total

$nodePath = Test-CommandPath 'node'
if ($nodePath) {
  Update-Row $rNode 'ok' (Get-ExeVersion $nodePath)
} elseif ($optPrereq -and (Test-CommandPath 'winget')) {
  $null = Invoke-ProcessRow $rNode 'winget.exe' @('install', '-e', '--id', 'OpenJS.NodeJS.LTS', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  Sync-ProcessPath
  $nodePath = Test-CommandPath 'node'
  if ($nodePath) { Update-Row $rNode 'ok' (Get-ExeVersion $nodePath) } elseif ($script:Rows[$rNode].Status -ne 'fail') { Update-Row $rNode 'fail' 'not found after install' }
} else {
  Update-Row $rNode 'warn' 'not found; background mode will not start'
}
Update-Bar 2 $total

if (-not $uvPath) {
  if ($optPrereq) {
    if (Test-CommandPath 'winget') {
      $null = Invoke-ProcessRow $rUv 'winget.exe' @('install', '-e', '--id', 'astral-sh.uv', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    } else {
      $null = Invoke-ProcessRow $rUv 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://astral.sh/uv/install.ps1 | iex')
    }
    Sync-ProcessPath
    $uvPath = Test-CommandPath 'uv'
    if ($uvPath) { Update-Row $rUv 'ok' (Get-ExeVersion $uvPath) } elseif ($script:Rows[$rUv].Status -ne 'fail') { Update-Row $rUv 'fail' 'not found after install' }
  } else {
    Update-Row $rUv 'warn' 'not found; skipped'
  }
} else {
  Update-Row $rUv 'ok' (Get-ExeVersion $uvPath)
}
Update-Bar 3 $total

if (-not $vibePath) {
  if ($uvPath -and $optPrereq) {
    $ok = Invoke-ProcessRow $rVibe $uvPath @('tool', 'install', '--force', '--python', 'cpython-3.14+gil', 'mistral-vibe')
    Sync-ProcessPath
    $vibePath = Test-CommandPath 'vibe'
    if ($vibePath) { Update-Row $rVibe 'ok' (Get-ExeVersion $vibePath) } elseif ($ok) { Update-Row $rVibe 'fail' 'installed but not on PATH' }
  } else {
    Update-Row $rVibe 'warn' 'not found; skipped'
  }
} else {
  Update-Row $rVibe 'ok' (Get-ExeVersion $vibePath)
}
Update-Bar 4 $total

try {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -notlike ('*' + $script:LocalBin + '*')) {
    $next = $userPath
    if ($next -and -not $next.EndsWith(';')) { $next = $next + ';' }
    [Environment]::SetEnvironmentVariable('Path', ($next + $script:LocalBin), 'User')
  }
  Sync-ProcessPath
  Update-Row $rPath 'ok' $script:LocalBin
} catch {
  Update-Row $rPath 'warn' $_.Exception.Message
}
Update-Bar 5 $total

$payload = Join-Path $SourceDir 'payload\vibe-mode'
$pluginDir = Join-Path $script:ConfigDir 'plugins\vibe-mode'
try {
  if (-not (Test-Path (Join-Path $payload 'index.js'))) { throw ('payload missing at ' + $payload) }
  Ensure-Directory $pluginDir
  Copy-Item (Join-Path $payload '*') $pluginDir -Recurse -Force
  Update-Row $rPlugin 'ok' $pluginDir
} catch {
  Update-Row $rPlugin 'fail' $_.Exception.Message
}
Update-Bar 6 $total

try {
  $result = Add-VibePluginConfig
  Update-Row $rConfig 'ok' $result
} catch {
  Update-Row $rConfig 'fail' $_.Exception.Message
}
Update-Bar 7 $total

try {
  Save-ApiKey $apiKey
  $mode = 'saved'
  if (Test-Path $script:KeyPath) { $mode = 'saved (' + ([IO.File]::ReadAllText($script:KeyPath)).Trim().Length + ' chars)' }
  Update-Row $rKey 'ok' $mode
} catch {
  Update-Row $rKey 'fail' $_.Exception.Message
}
Update-Bar 8 $total

if (Set-VibeKeyring $apiKey) {
  Update-Row $rSync 'ok' 'ai.mistral.vibe / MISTRAL_API_KEY'
} else {
  Update-Row $rSync 'warn' 'Vibe python not found; applied by plugin at runtime'
}
Update-Bar 9 $total

try {
  Save-ModeState $optApi $optBackground $optSync
  $summary = @()
  if ($optApi) { $summary += 'api=on' } else { $summary += 'api=off' }
  if ($optBackground) { $summary += 'bg=on' } else { $summary += 'bg=off' }
  if ($optSync) { $summary += 'sync=on' } else { $summary += 'sync=off' }
  Update-Row $rState 'ok' ($summary -join ' ')
} catch {
  Update-Row $rState 'fail' $_.Exception.Message
}
Update-Bar 10 $total

$problems = @()
if (-not (Test-Path (Join-Path $pluginDir 'index.js'))) { $problems += 'plugin' }
if (-not (Test-Path $script:ConfigPath)) { $problems += 'config' }
if (-not (Test-Path $script:KeyPath)) { $problems += 'key' }
if ($problems.Count -eq 0) {
  Update-Row $rCheck 'ok' 'all files present'
} else {
  Update-Row $rCheck 'fail' ('missing: ' + ($problems -join ', '))
}
Update-Bar 11 $total

Start-Sleep -Milliseconds 300
Clear-Screen
Show-Header 'Done'
Write-Color ('  API change          ' + $(if ($optApi) { 'ON' } else { 'OFF' })) 'White'
Write-Color ('  Vibe background     ' + $(if ($optBackground) { 'ON' } else { 'OFF' })) 'White'
Write-Color ('  Auto-sync key       ' + $(if ($optSync) { 'ON' } else { 'OFF' })) 'White'
Write-Color ('  API key             ' + $script:KeyPath) 'White'
Write-Color ('  Plugin              ' + $pluginDir) 'White'
Write-Host ''
Write-Color '  Restart the OpenCode TUI to load the sidebar block:' 'Gray'
Write-Color '    Mistral transport' 'DarkGray'
Write-Color '    [x] API change' 'DarkGray'
Write-Color '    [ ] vibe background' 'DarkGray'
Write-Host ''
Write-Color '  Then pick a mistral/* model. /connect -> mistral -> API keeps Vibe in sync.' 'Gray'
Write-Host ''
Write-Color '  Press any key to close.' 'DarkGray'
if (-not $script:NoPrompt) { $null = [Console]::ReadKey($true) }
exit 0


