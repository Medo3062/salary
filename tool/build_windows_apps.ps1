$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'

Push-Location $projectRoot
try {
    foreach ($role in @('employee', 'manager')) {
        & flutter build windows --release "--dart-define=APP_ROLE=$role"
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter failed to build the $role app."
        }

        $sourceExecutable = Join-Path $buildDirectory 'employee_salary.exe'
        if (-not (Test-Path $sourceExecutable)) {
            throw "The Windows build output was not found: $sourceExecutable"
        }

        $destination = Join-Path $projectRoot "dist\$role"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -Path (Join-Path $buildDirectory '*') `
            -Destination $destination -Recurse -Force

        $appName = if ($role -eq 'employee') { 'employee-app.exe' } else { 'manager-app.exe' }
        Rename-Item -LiteralPath (Join-Path $destination 'employee_salary.exe') `
            -NewName $appName -Force
    }
}
finally {
    Pop-Location
}
