$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvPath = Join-Path $Root ".env"
$ManifestPath = Join-Path $Root "public-pdf-upload-manifest.json"

function Load-DotEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -notmatch '=') {
            return
        }

        $parts = $_ -split '=', 2
        $key = $parts[0].Trim()
        $value = $parts[1].Trim().Trim("'`"")

        if ($key -and -not (Test-Path "Env:$key")) {
            Set-Item -Path "Env:$key" -Value $value
        }
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $maxAttempts = 5
    $baseDelaySeconds = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                throw
            }

            $delay = [Math]::Min(60, $baseDelaySeconds * [Math]::Pow(2, $attempt - 1))
            Write-Warning "$Label failed on attempt $attempt/$maxAttempts. Retrying in $delay seconds. $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-OpenAiJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $headers = @{
        Authorization = "Bearer $env:OPENAI_API_KEY"
    }

    return Invoke-WithRetry -Label "OpenAI request" -ScriptBlock {
        Invoke-RestMethod -Uri $Uri -Method GET -Headers $headers
    }
}

function Get-VectorStoreFiles {
    $items = @()
    $after = $null

    do {
        $uri = "https://api.openai.com/v1/vector_stores/$($env:OPENAI_VECTOR_STORE_ID)/files?limit=100"
        if ($after) {
            $uri = "$uri&after=$([uri]::EscapeDataString($after))"
        }

        $response = Invoke-OpenAiJson -Uri $uri
        $batch = @($response.data)
        $items += $batch

        if ($response.has_more -and $batch.Count -gt 0) {
            $after = $batch[-1].id
        }
        else {
            $after = $null
        }
    } while ($after)

    return $items
}

function Get-OpenAiFileMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileId
    )

    return Invoke-OpenAiJson -Uri "https://api.openai.com/v1/files/$FileId"
}

function Build-LocalPdfIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    $index = @{}
    Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if (-not $index.ContainsKey($key)) {
            $index[$key] = $_.FullName
        }
    }
    return $index
}

Load-DotEnv -Path $EnvPath

if (-not $env:LOCAL_PDF_SOURCE_ROOT) {
    $env:LOCAL_PDF_SOURCE_ROOT = "G:\My Drive\Traderservice downloads"
}

if (-not (Test-Path -LiteralPath $env:LOCAL_PDF_SOURCE_ROOT)) {
    throw "LOCAL_PDF_SOURCE_ROOT does not exist: $($env:LOCAL_PDF_SOURCE_ROOT)"
}

$localIndex = Build-LocalPdfIndex -SourceRoot $env:LOCAL_PDF_SOURCE_ROOT
$vectorStoreFiles = Get-VectorStoreFiles

$manifestFiles = [System.Collections.Generic.List[object]]::new()
$seenFilenames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$matchedCount = 0
$missingCount = 0

foreach ($vectorStoreFile in $vectorStoreFiles) {
    $meta = Get-OpenAiFileMeta -FileId $vectorStoreFile.id
    if (-not $meta.filename -or -not $meta.filename.ToLowerInvariant().EndsWith(".pdf")) {
        continue
    }

    if (-not $seenFilenames.Add($meta.filename)) {
        continue
    }

    $localPath = $null
    if ($localIndex.ContainsKey($meta.filename.ToLowerInvariant())) {
        $localPath = $localIndex[$meta.filename.ToLowerInvariant()]
        $matchedCount++
    }
    else {
        $missingCount++
    }

    $manifestFiles.Add([PSCustomObject]@{
        filename = $meta.filename
        local_path = $localPath
        found_locally = [bool]$localPath
    }) | Out-Null
}

$manifest = [PSCustomObject]@{
    vector_store_id = $env:OPENAI_VECTOR_STORE_ID
    local_pdf_source_root = $env:LOCAL_PDF_SOURCE_ROOT
    unique_pdf_filenames = $manifestFiles.Count
    matched_locally = $matchedCount
    missing_locally = $missingCount
    files = $manifestFiles
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
$manifest | ConvertTo-Json -Depth 8
