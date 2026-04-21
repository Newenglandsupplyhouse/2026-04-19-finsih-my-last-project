$nodePath = "C:\Users\jason\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"

if (-not (Test-Path $nodePath)) {
  Write-Error "Bundled Node runtime not found at $nodePath"
  exit 1
}

if (-not $env:PORT) {
  $env:PORT = "3010"
}

& $nodePath "C:\Users\jason\Documents\Codex\2026-04-19-finsih-my-last-project\server.js"
