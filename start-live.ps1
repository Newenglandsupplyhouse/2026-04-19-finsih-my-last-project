$workspace = "C:\Users\jason\Documents\Codex\2026-04-19-finsih-my-last-project"
$nodePath = "C:\Users\jason\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
$serverScript = Join-Path $workspace "server.js"
$cloudflaredPath = Join-Path $workspace "cloudflared.exe"
$serverLog = Join-Path $workspace "server.log"
$serverErrorLog = Join-Path $workspace "server-error.log"
$tunnelLog = Join-Path $workspace "tunnel.log"
$tunnelErrorLog = Join-Path $workspace "tunnel-error.log"
$statePath = Join-Path $workspace "live-processes.json"
$port = 3010
$healthUrl = "http://127.0.0.1:$port/health"

function Test-BridgeHealth {
  param(
    [string]$Url
  )

  try {
    $response = Invoke-RestMethod -Uri $Url
    return $response.ok -eq $true
  } catch {
    return $false
  }
}

function Get-RunningState {
  param(
    [string]$Path
  )

  if (-not (Test-Path $Path)) {
    return $null
  }

  try {
    return Get-Content -Path $Path | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Get-WorkspaceProcess {
  param(
    [string]$ProcessName,
    [string]$ExpectedPath
  )

  return Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $ExpectedPath } |
    Select-Object -First 1
}

if (-not (Test-Path $nodePath)) {
  Write-Error "Bundled Node runtime not found at $nodePath"
  exit 1
}

if (-not (Test-Path $cloudflaredPath)) {
  Write-Error "cloudflared.exe not found at $cloudflaredPath"
  exit 1
}

$existingState = Get-RunningState -Path $statePath
$bridgeIsHealthy = Test-BridgeHealth -Url $healthUrl
$server = $null
$serverPid = $null

if ($bridgeIsHealthy) {
  if ($existingState -and $existingState.serverPid) {
    $serverPid = $existingState.serverPid
  }
  Write-Output "Reusing existing bridge on port $port."
} else {
  foreach ($path in @($serverLog, $serverErrorLog, $tunnelLog, $tunnelErrorLog)) {
    if (Test-Path $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  $server = Start-Process -FilePath $nodePath `
    -ArgumentList $serverScript `
    -WorkingDirectory $workspace `
    -RedirectStandardOutput $serverLog `
    -RedirectStandardError $serverErrorLog `
    -PassThru

  Start-Sleep -Seconds 2

  if (-not (Test-BridgeHealth -Url $healthUrl)) {
    Stop-Process -Id $server.Id -ErrorAction SilentlyContinue
    Write-Error "Bridge server did not start successfully. Check $serverErrorLog"
    exit 1
  }

  $serverPid = $server.Id
  Write-Output "Started bridge server on port $port."
}

$existingTunnel = $null
if ($existingState -and $existingState.tunnelPid) {
  try {
    $existingTunnel = Get-Process -Id $existingState.tunnelPid -ErrorAction Stop
  } catch {
    $existingTunnel = $null
  }
}

if (-not $existingTunnel) {
  $existingTunnel = Get-WorkspaceProcess -ProcessName "cloudflared" -ExpectedPath $cloudflaredPath
}

if ($existingTunnel -and $existingState -and $existingState.publicUrl) {
  @{
    serverPid = $serverPid
    tunnelPid = $existingTunnel.Id
    publicUrl = $existingState.publicUrl
  } | ConvertTo-Json | Set-Content -Path $statePath

  Write-Output "Existing tunnel is still running."
  Write-Output "Public URL: $($existingState.publicUrl)"
  Write-Output "Chatbase endpoint: $($existingState.publicUrl)/chatbase/vector-search"
  exit 0
}

foreach ($path in @($tunnelLog, $tunnelErrorLog)) {
  if (Test-Path $path) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
}

$tunnel = Start-Process -FilePath $cloudflaredPath `
  -ArgumentList @("tunnel", "--url", "http://127.0.0.1:$port", "--no-autoupdate") `
  -WorkingDirectory $workspace `
  -RedirectStandardOutput $tunnelLog `
  -RedirectStandardError $tunnelErrorLog `
  -PassThru

$publicUrl = $null
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 1

  $logPaths = @($tunnelLog, $tunnelErrorLog) | Where-Object { Test-Path $_ }
  if ($logPaths.Count -gt 0) {
    $match = Select-String -Path $logPaths -Pattern "https://[-a-z0-9]+\.trycloudflare\.com" -AllMatches | Select-Object -Last 1
    if ($match) {
      $publicUrl = $match.Matches[-1].Value
      break
    }
  }
}

if (-not $publicUrl) {
  Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue
  if ($server) {
    Stop-Process -Id $server.Id -ErrorAction SilentlyContinue
  }
  Write-Error "Tunnel URL was not detected. Check $tunnelErrorLog"
  exit 1
}

@{
  serverPid = $serverPid
  tunnelPid = $tunnel.Id
  publicUrl = $publicUrl
} | ConvertTo-Json | Set-Content -Path $statePath

Write-Output "Bridge server is live."
Write-Output "Public URL: $publicUrl"
Write-Output "Chatbase endpoint: $publicUrl/chatbase/vector-search"
Write-Output "Server log: $serverLog"
Write-Output "Server error log: $serverErrorLog"
Write-Output "Tunnel log: $tunnelLog"
Write-Output "Tunnel error log: $tunnelErrorLog"
