$workspace = "C:\Users\jason\Documents\Codex\2026-04-19-finsih-my-last-project"
$statePath = Join-Path $workspace "live-processes.json"

if (-not (Test-Path $statePath)) {
  Write-Error "No running live state file found at $statePath"
  exit 1
}

try {
  $state = Get-Content -Path $statePath | ConvertFrom-Json
} catch {
  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
  Write-Output "Removed unreadable live state file."
  exit 0
}

$stoppedAny = $false
foreach ($processId in @($state.serverPid, $state.tunnelPid)) {
  if (-not $processId) {
    continue
  }

  try {
    Stop-Process -Id $processId -ErrorAction Stop
    $stoppedAny = $true
  } catch {
    # Ignore already-exited processes so cleanup stays idempotent.
  }
}

Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue

if ($stoppedAny) {
  Write-Output "Stopped bridge server and tunnel."
} else {
  Write-Output "Removed stale live state file."
}
