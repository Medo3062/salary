$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'

if ([string]::IsNullOrWhiteSpace($env:SUPABASE_URL)) {
    throw 'Set SUPABASE_URL before building.'
}

$clientKey = if (-not [string]::IsNullOrWhiteSpace($env:SUPABASE_PUBLISHABLE_KEY)) {
    "--dart-define=SUPABASE_PUBLISHABLE_KEY=$env:SUPABASE_PUBLISHABLE_KEY"
} elseif (-not [string]::IsNullOrWhiteSpace($env:SUPABASE_ANON_KEY)) {
    "--dart-define=SUPABASE_ANON_KEY=$env:SUPABASE_ANON_KEY"
} else {
    throw 'Set SUPABASE_PUBLISHABLE_KEY or SUPABASE_ANON_KEY before building.'
}

Push-Location $projectRoot
try {
    & flutter build windows --release `
        '--dart-define=APP_ROLE=employee' `
        "--dart-define=SUPABASE_URL=$env:SUPABASE_URL" `
        $clientKey
    if ($LASTEXITCODE -ne 0) {
        throw 'Flutter failed to build the employee app.'
    }

    $sourceExecutable = Join-Path $buildDirectory 'employee_salary.exe'
    if (-not (Test-Path $sourceExecutable)) {
        throw "The Windows build output was not found: $sourceExecutable"
    }

    $destination = Join-Path $projectRoot 'dist\employee'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -Path (Join-Path $buildDirectory '*') `
        -Destination $destination -Recurse -Force
    Rename-Item -LiteralPath (Join-Path $destination 'employee_salary.exe') `
        -NewName 'employee-app.exe' -Force
}
finally {
    Pop-Location
}
