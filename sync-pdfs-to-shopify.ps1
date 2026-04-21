$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvPath = Join-Path $Root ".env"
$ManifestPath = Join-Path $Root "shopify-pdf-sync-manifest.json"
$StatePath = Join-Path $Root "shopify-pdf-sync-state.json"
$TempRoot = Join-Path $Root ".tmp\shopify-pdf-sync"
$script:LocalPdfIndex = @{}

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

function Get-EnvInt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$DefaultValue
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Convert-ToHashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    $table = @{}
    if ($null -eq $InputObject) {
        return $table
    }

    if ($InputObject -is [hashtable]) {
        foreach ($key in $InputObject.Keys) {
            $table[$key] = $InputObject[$key]
        }
        return $table
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }

    return $table
}

function New-State {
    return @{
        synced_at = $null
        shopify_store_domain = $env:SHOPIFY_STORE_DOMAIN
        vector_store_id = $env:OPENAI_VECTOR_STORE_ID
        next_after = $null
        completed_ids = @()
        failed = @()
        files = @()
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return (New-State)
    }

    $raw = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $state = New-State
    $state.synced_at = $raw.synced_at
    $state.shopify_store_domain = $raw.shopify_store_domain
    $state.vector_store_id = $raw.vector_store_id
    $state.next_after = $raw.next_after
    $state.completed_ids = @($raw.completed_ids)
    $state.failed = @($raw.failed)
    $state.files = @($raw.files)
    return $state
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $State.synced_at = (Get-Date).ToString("o")
    $State.shopify_store_domain = $env:SHOPIFY_STORE_DOMAIN
    $State.vector_store_id = $env:OPENAI_VECTOR_STORE_ID
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $StatePath -Encoding utf8
}

function Save-Manifest {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $manifest = [PSCustomObject]@{
        synced_at = (Get-Date).ToString("o")
        vector_store_id = $env:OPENAI_VECTOR_STORE_ID
        shopify_store_domain = $env:SHOPIFY_STORE_DOMAIN
        synced_count = @($State.files).Count
        failed_count = @($State.failed).Count
        next_after = $State.next_after
        files = @($State.files)
        failed = @($State.failed)
    }

    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $maxAttempts = Get-EnvInt -Name "SYNC_RETRY_ATTEMPTS" -DefaultValue 5
    $baseDelaySeconds = Get-EnvInt -Name "SYNC_RETRY_DELAY_SECONDS" -DefaultValue 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                throw
            }

            $delay = [Math]::Min(60, $baseDelaySeconds * [Math]::Pow(2, $attempt - 1))
            $message = $_.Exception.Message
            Write-Warning "$Label failed on attempt $attempt/$maxAttempts. Retrying in $delay seconds. $message"
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-OpenAiJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Method = "GET",
        [object]$Body,
        [string]$Label = "OpenAI request"
    )

    $headers = @{
        Authorization = "Bearer $env:OPENAI_API_KEY"
    }

    return Invoke-WithRetry -Label $Label -ScriptBlock {
        if ($null -ne $Body) {
            Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 12)
        }
        else {
            Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
        }
    }
}

function Invoke-ShopifyGraphQL {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,
        [hashtable]$Variables = @{},
        [string]$Label = "Shopify GraphQL request"
    )

    $headers = @{
        "X-Shopify-Access-Token" = $env:SHOPIFY_ADMIN_ACCESS_TOKEN
    }
    $uri = "https://$($env:SHOPIFY_STORE_DOMAIN)/admin/api/$($env:SHOPIFY_API_VERSION)/graphql.json"
    $payload = @{
        query = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 12

    $response = Invoke-WithRetry -Label $Label -ScriptBlock {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -ContentType "application/json" -Body $payload
    }

    if ($response.errors) {
        $message = ($response.errors | ConvertTo-Json -Depth 12)
        throw "Shopify GraphQL error: $message"
    }

    return $response.data
}

function Get-VectorStoreFilePage {
    param(
        [string]$After
    )

    $uri = "https://api.openai.com/v1/vector_stores/$($env:OPENAI_VECTOR_STORE_ID)/files?limit=100"
    if ($After) {
        $uri = "$uri&after=$([uri]::EscapeDataString($After))"
    }

    return Invoke-OpenAiJson -Uri $uri -Label "List vector store files"
}

function Get-OpenAiFileMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileId
    )

    return Invoke-OpenAiJson -Uri "https://api.openai.com/v1/files/$FileId" -Label "Fetch OpenAI file metadata for $FileId"
}

function Save-OpenAiFileContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileId,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $headers = @{
        Authorization = "Bearer $env:OPENAI_API_KEY"
    }

    Invoke-WithRetry -Label "Download OpenAI file content for $FileId" -ScriptBlock {
        Invoke-WebRequest -Uri "https://api.openai.com/v1/files/$FileId/content" -Headers $headers -OutFile $DestinationPath | Out-Null
    }
}

function Build-LocalPdfIndex {
    param(
        [string]$SourceRoot
    )

    $script:LocalPdfIndex = @{}
    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or -not (Test-Path -LiteralPath $SourceRoot)) {
        return
    }

    Write-Host "Indexing local PDFs from $SourceRoot"
    Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if (-not $script:LocalPdfIndex.ContainsKey($key)) {
            $script:LocalPdfIndex[$key] = $_.FullName
        }
    }
}

function Resolve-LocalPdfPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    $key = $Filename.ToLowerInvariant()
    if ($script:LocalPdfIndex.ContainsKey($key)) {
        return $script:LocalPdfIndex[$key]
    }

    return $null
}

function Save-PdfContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileId,
        [Parameter(Mandatory = $true)]
        [string]$Filename,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $localPath = Resolve-LocalPdfPath -Filename $Filename
    if ($localPath) {
        Copy-Item -LiteralPath $localPath -Destination $DestinationPath -Force
        return "local"
    }

    Save-OpenAiFileContent -FileId $FileId -DestinationPath $DestinationPath
    return "openai"
}

function Get-StagedUploadTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename,
        [Parameter(Mandatory = $true)]
        [string]$MimeType,
        [Parameter(Mandatory = $true)]
        [long]$FileSize
    )

    $query = @'
mutation stagedUploadsCreate($input: [StagedUploadInput!]!) {
  stagedUploadsCreate(input: $input) {
    stagedTargets {
      url
      resourceUrl
      parameters {
        name
        value
      }
    }
    userErrors {
      field
      message
    }
  }
}
'@

    $data = Invoke-ShopifyGraphQL -Query $query -Variables @{
        input = @(
            @{
                filename = $Filename
                mimeType = $MimeType
                resource = "FILE"
                httpMethod = "POST"
                fileSize = [string]$FileSize
            }
        )
    } -Label "Create Shopify staged upload for $Filename"

    if (@($data.stagedUploadsCreate.userErrors).Count -gt 0) {
        $message = ($data.stagedUploadsCreate.userErrors | ConvertTo-Json -Depth 12)
        throw "Shopify staged upload failed: $message"
    }

    return $data.stagedUploadsCreate.stagedTargets[0]
}

function New-MultipartFormBody {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Fields
    )

    $boundary = "----CodexBoundary$([guid]::NewGuid().ToString('N'))"
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)

    foreach ($field in $Fields) {
        $writer.Write("--$boundary`r`n")
        if ($field.Type -eq "file") {
            $writer.Write("Content-Disposition: form-data; name=`"$($field.Name)`"; filename=`"$($field.FileName)`"`r`n")
            $writer.Write("Content-Type: $($field.ContentType)`r`n`r`n")
            $writer.Flush()
            $bytes = [System.IO.File]::ReadAllBytes($field.Path)
            $stream.Write($bytes, 0, $bytes.Length)
            $writer.Write("`r`n")
        }
        else {
            $writer.Write("Content-Disposition: form-data; name=`"$($field.Name)`"`r`n`r`n")
            $writer.Write("$($field.Value)`r`n")
        }
        $writer.Flush()
    }

    $writer.Write("--$boundary--`r`n")
    $writer.Flush()
    $stream.Position = 0

    return @{
        Boundary = $boundary
        Bytes = $stream.ToArray()
    }
}

function Send-StagedUploadFile {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $true)]
        [string]$MimeType
    )

    $fields = @()
    foreach ($parameter in $Target.parameters) {
        $fields += @{
            Type = "value"
            Name = $parameter.name
            Value = $parameter.value
        }
    }
    $fields += @{
        Type = "file"
        Name = "file"
        Path = $Path
        FileName = $FileName
        ContentType = $MimeType
    }

    $multipart = New-MultipartFormBody -Fields $fields
    Invoke-WithRetry -Label "Upload staged Shopify file for $FileName" -ScriptBlock {
        Invoke-WebRequest -Uri $Target.url -Method POST -ContentType "multipart/form-data; boundary=$($multipart.Boundary)" -Body $multipart.Bytes | Out-Null
    }
}

function Create-ShopifyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceUrl,
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    $query = @'
mutation fileCreate($files: [FileCreateInput!]!) {
  fileCreate(files: $files) {
    files {
      __typename
      ... on GenericFile {
        id
        fileStatus
        url
      }
      ... on MediaImage {
        id
        fileStatus
        image {
          url
        }
      }
    }
    userErrors {
      field
      message
    }
  }
}
'@

    $data = Invoke-ShopifyGraphQL -Query $query -Variables @{
        files = @(
            @{
                originalSource = $ResourceUrl
                filename = $Filename
                contentType = "FILE"
                duplicateResolutionMode = "REPLACE"
            }
        )
    } -Label "Create Shopify file for $Filename"

    if (@($data.fileCreate.userErrors).Count -gt 0) {
        $message = ($data.fileCreate.userErrors | ConvertTo-Json -Depth 12)
        throw "Shopify fileCreate failed: $message"
    }

    return $data.fileCreate.files[0]
}

function Get-ShopifyFileStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileGid
    )

    $query = @'
query fileNode($id: ID!) {
  node(id: $id) {
    __typename
    ... on GenericFile {
      id
      fileStatus
      url
    }
  }
}
'@

    $data = Invoke-ShopifyGraphQL -Query $query -Variables @{ id = $FileGid } -Label "Fetch Shopify file status for $FileGid"
    return $data.node
}

function Wait-ForShopifyFileReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileGid
    )

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $node = Get-ShopifyFileStatus -FileGid $FileGid
        if (-not $node) {
            throw "Shopify file $FileGid was not found after creation."
        }

        if ($node.fileStatus -eq "READY" -and $node.url) {
            return $node
        }

        if ($node.fileStatus -eq "FAILED") {
            throw "Shopify file $FileGid failed to process."
        }

        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for Shopify file $FileGid to become ready."
}

function Update-VectorStoreFileAttributes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Attributes
    )

    return Invoke-OpenAiJson -Uri "https://api.openai.com/v1/vector_stores/$($env:OPENAI_VECTOR_STORE_ID)/files/$FileId" -Method POST -Body @{
        attributes = $Attributes
    } -Label "Update vector store metadata for $FileId"
}

function Add-CompletedRecord {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record
    )

    $completed = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($State.completed_ids)) {
        [void]$completed.Add([string]$item)
    }
    if (-not $completed.Contains($Record.file_id)) {
        [void]$completed.Add($Record.file_id)
    }
    $State.completed_ids = $completed.ToArray()

    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($State.files)) {
        [void]$files.Add($item)
    }
    [void]$files.Add($Record)
    $State.files = $files.ToArray()
}

function Add-FailedRecord {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record
    )

    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($State.failed)) {
        [void]$failed.Add($item)
    }
    [void]$failed.Add($Record)
    $State.failed = $failed.ToArray()
}

function Sync-PdfEntry {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Entry,
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $tempPath = Join-Path $TempRoot $Entry.filename

    try {
        $fileSource = Save-PdfContent -FileId $Entry.file_id -Filename $Entry.filename -DestinationPath $tempPath

        $target = Get-StagedUploadTarget -Filename $Entry.filename -MimeType "application/pdf" -FileSize $Entry.bytes
        Send-StagedUploadFile -Target $target -Path $tempPath -FileName $Entry.filename -MimeType "application/pdf"

        $createdFile = Create-ShopifyFile -ResourceUrl $target.resourceUrl -Filename $Entry.filename
        $readyFile = Wait-ForShopifyFileReady -FileGid $createdFile.id

        $updatedAttributes = @{}
        foreach ($key in $Entry.attributes.Keys) {
            $updatedAttributes[$key] = $Entry.attributes[$key]
        }
        $updatedAttributes["source_url"] = $readyFile.url
        $updatedAttributes["shopify_cdn_url"] = $readyFile.url
        $updatedAttributes["shopify_file_gid"] = $readyFile.id

        Update-VectorStoreFileAttributes -FileId $Entry.file_id -Attributes $updatedAttributes | Out-Null

        Add-CompletedRecord -State $State -Record ([PSCustomObject]@{
            file_id = $Entry.file_id
            filename = $Entry.filename
            shopify_file_gid = $readyFile.id
            source_url = $readyFile.url
            file_source = $fileSource
        })
        Save-State -State $State
        Save-Manifest -State $State
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

Load-DotEnv -Path $EnvPath

$required = @(
    "OPENAI_API_KEY",
    "OPENAI_VECTOR_STORE_ID",
    "SHOPIFY_STORE_DOMAIN",
    "SHOPIFY_ADMIN_ACCESS_TOKEN"
)

$missing = $required | Where-Object { -not (Get-Item "Env:$_" -ErrorAction SilentlyContinue) }
if ($missing.Count -gt 0) {
    throw "Missing required environment variables: $($missing -join ', ')"
}

if (-not $env:SHOPIFY_API_VERSION) {
    $env:SHOPIFY_API_VERSION = "2026-04"
}

if (-not $env:LOCAL_PDF_SOURCE_ROOT) {
    $env:LOCAL_PDF_SOURCE_ROOT = "G:\My Drive\Traderservice downloads"
}

$batchSize = Get-EnvInt -Name "SYNC_BATCH_SIZE" -DefaultValue 25
$maxFiles = Get-EnvInt -Name "SYNC_MAX_FILES" -DefaultValue 0

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
Build-LocalPdfIndex -SourceRoot $env:LOCAL_PDF_SOURCE_ROOT

$state = Load-State
$processedThisRun = 0
$after = $state.next_after
$completedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($id in @($state.completed_ids)) {
    [void]$completedSet.Add([string]$id)
}

while ($true) {
    if ($batchSize -gt 0 -and $processedThisRun -ge $batchSize) {
        break
    }

    if ($maxFiles -gt 0 -and @($state.files).Count -ge $maxFiles) {
        break
    }

    $page = Get-VectorStoreFilePage -After $after
    $items = @($page.data)
    if ($items.Count -eq 0) {
        $state.next_after = $null
        Save-State -State $state
        Save-Manifest -State $state
        break
    }

    foreach ($vectorStoreFile in $items) {
        $after = $vectorStoreFile.id
        $state.next_after = $after

        if ($batchSize -gt 0 -and $processedThisRun -ge $batchSize) {
            break
        }

        if ($maxFiles -gt 0 -and @($state.files).Count -ge $maxFiles) {
            break
        }

        if ($completedSet.Contains($vectorStoreFile.id)) {
            continue
        }

        $meta = Get-OpenAiFileMeta -FileId $vectorStoreFile.id
        if (-not $meta.filename -or -not $meta.filename.ToLowerInvariant().EndsWith(".pdf")) {
            continue
        }

        $attributes = Convert-ToHashtable $vectorStoreFile.attributes
        if ($attributes.ContainsKey("source_url") -and -not [string]::IsNullOrWhiteSpace([string]$attributes["source_url"])) {
            continue
        }

        $entry = [PSCustomObject]@{
            file_id = $vectorStoreFile.id
            filename = $meta.filename
            bytes = [long]$meta.bytes
            attributes = $attributes
        }

        Write-Host "Syncing $($entry.filename) ($($entry.file_id))"

        try {
            Sync-PdfEntry -Entry $entry -State $state
            [void]$completedSet.Add($entry.file_id)
            $processedThisRun++
        }
        catch {
            Add-FailedRecord -State $state -Record ([PSCustomObject]@{
                file_id = $entry.file_id
                filename = $entry.filename
                error = $_.Exception.Message
                failed_at = (Get-Date).ToString("o")
            })
            Save-State -State $state
            Save-Manifest -State $state
            throw
        }
    }

    Save-State -State $state
    Save-Manifest -State $state

    if ($batchSize -gt 0 -and $processedThisRun -ge $batchSize) {
        break
    }

    if (-not $page.has_more) {
        $state.next_after = $null
        Save-State -State $state
        Save-Manifest -State $state
        break
    }
}

$summary = [PSCustomObject]@{
    synced_this_run = $processedThisRun
    total_synced = @($state.files).Count
    total_failed = @($state.failed).Count
    next_after = $state.next_after
    manifest_path = $ManifestPath
    state_path = $StatePath
}

$summary | ConvertTo-Json -Depth 12
