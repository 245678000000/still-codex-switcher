param([ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$Root = Split-Path $PSScriptRoot -Parent
$Out = Join-Path $Root "dist/$Runtime"
Push-Location $Root
try {
    dotnet run --project Tests/Still.Tests.csproj -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
    dotnet publish Windows/Still.Windows.csproj -c Release -r $Runtime --self-contained true -p:RuntimeFrameworkVersion=8.0.32 -o $Out
    if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
    Copy-Item README.md (Join-Path $Out 'README.md')
    Copy-Item LICENSE (Join-Path $Out 'LICENSE.txt')
    Copy-Item scripts/self-test.cmd $Out
    Copy-Item scripts/demo.cmd $Out
    Copy-Item licenses $Out -Recurse -Force
    if ($Runtime -eq 'win-x64' -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        $p = Start-Process (Join-Path $Out 'StillCodexSwitcher.exe') -ArgumentList '--self-test','--test-output',('"' + (Join-Path $Out 'self-test-result.txt') + '"') -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw 'Windows native tests failed. Read self-test-result.txt.' }
    }
    Compress-Archive -Path "$Out/*" -DestinationPath (Join-Path $Root "dist/Codex-Account-Switcher-Windows-$Runtime.zip") -Force
    Write-Host "Built: $Out"
} finally { Pop-Location }
