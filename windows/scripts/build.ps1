param([ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$Root = Split-Path $PSScriptRoot -Parent
$Out = Join-Path $Root "dist/$Runtime"
Push-Location $Root
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "dist") | Out-Null
    dotnet run --project Tests/Still.Tests.csproj -c Release | Tee-Object -FilePath (Join-Path $Root "dist/core-tests.txt")
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
    dotnet publish Windows/Still.Windows.csproj -c Release -r $Runtime --self-contained true -p:RuntimeFrameworkVersion=8.0.32 -o $Out
    if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
    Copy-Item README.md (Join-Path $Out 'README.md')
    Copy-Item LICENSE (Join-Path $Out 'LICENSE.txt')
    Copy-Item docs/token-statistics.md (Join-Path $Out 'Token-Statistics.md')
    Copy-Item scripts/self-test.cmd $Out
    Copy-Item scripts/demo.cmd $Out
    Copy-Item licenses $Out -Recurse -Force
    if ($Runtime -eq 'win-x64' -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        $p = Start-Process (Join-Path $Out 'StillCodexSwitcher.exe') -ArgumentList '--self-test','--test-output',('"' + (Join-Path $Out 'self-test-result.txt') + '"') -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw 'Windows native tests failed. Read self-test-result.txt.' }
    }
    $exe = Join-Path $Out 'StillCodexSwitcher.exe'
    $version = (Get-Item $exe).VersionInfo
    if ($version.ProductVersion -notlike '1.2.0-preview.1*') { throw 'Unexpected executable version' }
    @{ fileVersion = $version.FileVersion; productVersion = $version.ProductVersion; sha256 = (Get-FileHash $exe -Algorithm SHA256).Hash } | ConvertTo-Json | Set-Content (Join-Path $Root 'dist/executable-check.json')
    Compress-Archive -Path "$Out/*" -DestinationPath (Join-Path $Root "dist/Codex-Account-Switcher-Windows-$($Runtime.Substring(4)).zip") -Force
    Write-Host "Built: $Out"
} finally { Pop-Location }
