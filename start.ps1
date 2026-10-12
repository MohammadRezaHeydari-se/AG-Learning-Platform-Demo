<#
.SYNOPSIS
    One-command launcher for the AG Learning Platform Demo (Windows PowerShell).

.DESCRIPTION
    Walks through a numbered checklist of setup stages and shows a progress bar
    based on how many stages actually completed (never a fake timer):

        [1/9] [OK]      Docker CLI detected
        [2/9] [OK]      Docker Engine is running
        ...
        Setup steps completed  [####################]  100%

    Stages: Docker CLI, Docker Engine, Compose v2, existing container/image,
    port selection, image build (+ Python dependencies), container startup,
    Django migration/seeding readiness, HTTP readiness, then the final URL.

    Safety: read-only checks; the launcher never installs software, never deletes
    volumes/databases, preserves changed demo passwords and any running container,
    and never uses Invoke-Expression. Ctrl+C stops the launcher without removing
    anything. Works with Windows PowerShell 5.1+ and PowerShell 7+; it does not
    require WSL or Git Bash.

.PARAMETER SelfTest
    Runs internal logic checks and exits.

.PARAMETER NoColor
    Plain output without colour (NO_COLOR is also honoured).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\start.ps1

.EXAMPLE
    $env:HOST_PORT = 9000; powershell -ExecutionPolicy Bypass -File .\start.ps1
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$NoColor
)

$ErrorActionPreference = 'Stop'

# Resolve the directory of this script so `docker compose` finds compose.yaml.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Service = 'web'
$ContainerPort = 8000
$PortScanMax = 8050
$ReadinessTimeout = if ($env:READINESS_TIMEOUT) { [int]$env:READINESS_TIMEOUT } else { 90 }
$ReadinessInterval = 2
$DockerInstallUrl = 'https://docs.docker.com/get-docker/'
$ComposeInstallUrl = 'https://docs.docker.com/compose/install/'

$TotalSteps = 9
$BarWidth = 20
$ProgressLabel = 'Setup steps completed'
$EmDash = [char]0x2014

# Runtime state.
$script:Completed = 0
$script:TransientLen = 0
$script:BarActive = $false
$script:Interactive = -not [Console]::IsOutputRedirected
$script:UseColor = ($script:Interactive -and -not $NoColor -and -not $env:NO_COLOR)
$script:ContainerRunning = $false
$script:ImageExists = $false
$script:ReusedPort = $null
$script:ChosenPort = $null

function Write-Say {
    param([string]$Message)
    Clear-Transient
    Write-Host $Message
    if ($script:Interactive -and $script:BarActive) { Write-ProgressLine }
}

function Get-Percent {
    param([int]$Completed)
    if ($Completed -gt $TotalSteps) { $Completed = $TotalSteps }
    return [int][math]::Floor($Completed * 100 / $TotalSteps)
}

function Get-Bar {
    param([int]$Completed)
    if ($Completed -gt $TotalSteps) { $Completed = $TotalSteps }
    $filled = [int][math]::Floor($Completed * $BarWidth / $TotalSteps)
    $empty = $BarWidth - $filled
    $filledText = if ($filled -gt 0) { '#' * $filled } else { '' }
    $emptyText = if ($empty -gt 0) { '-' * $empty } else { '' }
    return $filledText + $emptyText
}

function Clear-Transient {
    if ($script:Interactive -and $script:TransientLen -gt 0) {
        $padding = ' ' * $script:TransientLen
        Write-Host ("`r" + $padding + "`r") -NoNewline
    }
    $script:TransientLen = 0
}

function Write-ProgressLine {
    $plain = "$ProgressLabel  [$(Get-Bar $script:Completed)]  $(Get-Percent $script:Completed)%"
    if ($script:Interactive) {
        Clear-Transient
        if ($script:UseColor) {
            Write-Host "`r$plain" -NoNewline -ForegroundColor DarkGray
        }
        else {
            Write-Host "`r$plain" -NoNewline
        }
        $script:TransientLen = $plain.Length
    }
    else {
        Write-Host $plain
    }
    $script:BarActive = $true
}

function Finalize-Progress {
    if ($script:Interactive -and $script:TransientLen -gt 0) { Write-Host '' }
    $script:TransientLen = 0
}

function Write-StepLine {
    param([int]$Number, [string]$Status, [string]$Message)
    Clear-Transient
    $tag = "[$Status]".PadRight(9)
    if ($script:UseColor) {
        $color = switch ($Status) {
            'OK' { 'Green' }
            'RUNNING' { 'Cyan' }
            'SKIP' { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'Gray' }
        }
        Write-Host ("[$Number/$TotalSteps]") -NoNewline -ForegroundColor DarkGray
        Write-Host " " -NoNewline
        Write-Host $tag -NoNewline -ForegroundColor $color
        Write-Host " $Message"
    }
    else {
        Write-Host ("[{0}/{1}] {2} {3}" -f $Number, $TotalSteps, $tag, $Message)
    }
}

function Begin-Step {
    param([int]$Number, [string]$Message)
    Write-StepLine -Number $Number -Status 'RUNNING' -Message $Message
}

function Finish-Step {
    param([int]$Number, [string]$Status, [string]$Message)
    Write-StepLine -Number $Number -Status $Status -Message $Message
    $script:Completed = $script:Completed + 1
    Write-ProgressLine
}

function Redact {
    param([string]$Text)
    return ($Text -replace '([A-Za-z0-9_]*(secret|password)[A-Za-z0-9_]*)[=:]\s*\S+', '$1=***')
}

function Show-SanitizedLogs {
    $ids = (& docker compose ps -aq $Service 2>$null)
    if (-not $ids) { return }
    Write-Host "`nRecent container logs (sanitized, last 50 lines):"
    $lines = (& docker compose logs --tail=50 $Service 2>&1) -join "`n"
    Write-Host ("  " + (Redact $lines))
}

function Invoke-DieStep {
    param([int]$Number, [string]$Name, [string]$Cause, [string]$Next)
    Write-StepLine -Number $Number -Status 'ERROR' -Message $Name
    Write-ProgressLine
    Finalize-Progress
    Write-Host ''
    if ($script:UseColor) {
        Write-Host 'Setup failed' -NoNewline -ForegroundColor Red
        Write-Host " at step $Number of $TotalSteps`: $Name"
    }
    else {
        Write-Host "Setup failed at step $Number of $TotalSteps`: $Name"
    }
    Write-Host ("Progress: {0}% ({1} of {2} setup steps completed)" -f (Get-Percent $script:Completed), $script:Completed, $TotalSteps)
    Write-Host "`nLikely cause:`n  $Cause"
    Write-Host "`nNext step:`n  $Next"
    Show-SanitizedLogs
    Write-Host "`nNo containers, volumes or demo data were removed."
    exit 1
}

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------
function Test-ValidPort {
    param([string]$Port)
    $number = 0
    if (-not [int]::TryParse($Port, [ref]$number)) { return $false }
    return ($number -ge 1 -and $number -le 65535)
}

function Test-PortInUse {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(500)) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Find-FreePort {
    param([int]$Start)
    for ($candidate = $Start; $candidate -le $PortScanMax; $candidate++) {
        if (-not (Test-PortInUse $candidate)) { return $candidate }
    }
    return $null
}

function Get-EnvFilePort {
    $envFile = Join-Path $ScriptDir '.env'
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*HOST_PORT\s*=\s*(.+?)\s*$') {
            $value = $matches[1].Trim(' ', '"', "'")
            if ($value) { return $value }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------
function Test-ImageExists {
    $img = (& docker compose config --images 2>$null | Select-Object -First 1)
    if (-not $img) { return $false }
    & docker image inspect $img *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-RunningPort {
    $line = (& docker compose port $Service $ContainerPort 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $line) { return $null }
    $port = ($line.Trim() -split ':')[-1]
    if (Test-ValidPort $port) { return [int]$port }
    return $null
}

function Wait-ForSeed {
    $elapsed = 0
    while ($elapsed -lt $ReadinessTimeout) {
        $logs = (& docker compose logs $Service 2>$null) -join "`n"
        if ($logs -match 'Demo data ready') { return $true }
        if ($elapsed -gt 0) {
            $state = (& docker compose ps -a --format '{{.State}}' $Service 2>$null) -join ''
            if ($state -match '^(exited|dead)$') { return $false }
        }
        Start-Sleep -Seconds $ReadinessInterval
        $elapsed += $ReadinessInterval
    }
    return $false
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
function Test-HttpReady {
    param([string]$Url)
    # Prefer the curl application (present on Windows 10+ and Linux/macOS).
    # -CommandType Application avoids the PowerShell 5.1 'curl' alias for
    # Invoke-WebRequest, which does not accept curl's arguments.
    $curl = Get-Command -Name 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curl) {
        & $curl.Source -fsS --max-time 5 $Url > $null 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Wait-ForHttp {
    param([string]$Url)
    $elapsed = 0
    while ($elapsed -lt $ReadinessTimeout) {
        if (Test-HttpReady $Url) { return $true }
        Start-Sleep -Seconds $ReadinessInterval
        $elapsed += $ReadinessInterval
    }
    return $false
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
function Invoke-StageDockerCli {
    Begin-Step 1 'Detecting the Docker CLI...'
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
        Invoke-DieStep 1 'Docker CLI detection' `
            'Docker is not installed on this machine (the docker command was not found).' `
            "Install Docker Desktop from $DockerInstallUrl, then open a new PowerShell window and run this launcher again."
    }
    Finish-Step 1 'OK' 'Docker CLI detected (already installed; this launcher never installs software).'
}

function Invoke-StageEngine {
    Begin-Step 2 'Checking that the Docker Engine is running...'
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-DieStep 2 'Docker Engine availability' `
            'Docker is installed but the Docker Engine is not running or not reachable (the daemon did not answer).' `
            'Start Docker Desktop, then run this launcher again.'
    }
    Finish-Step 2 'OK' 'Docker Engine is running.'
}

function Invoke-StageCompose {
    Begin-Step 3 'Detecting Docker Compose v2...'
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-DieStep 3 'Docker Compose v2 detection' `
            "Docker is installed, but the docker compose (Compose v2) plugin is not available." `
            "Install or enable the Compose v2 plugin: $ComposeInstallUrl"
    }
    Finish-Step 3 'OK' 'Docker Compose v2 is available.'
}

function Invoke-StageDetect {
    Begin-Step 4 'Checking for an existing project container or image...'
    $id = (& docker compose ps -q $Service 2>$null)
    if ($LASTEXITCODE -eq 0 -and $id) {
        $script:ContainerRunning = $true
        $script:ReusedPort = Get-RunningPort
        $short = ($id | Select-Object -First 1).ToString()
        if ($short.Length -gt 12) { $short = $short.Substring(0, 12) }
        Finish-Step 4 'OK' "Existing container detected (id $short...)."
        Write-Say 'Existing AG Learning Platform container detected.'
        Write-Say "Reusing existing container $EmDash no rebuild or dependency installation needed."
    }
    elseif (Test-ImageExists) {
        $script:ImageExists = $true
        Finish-Step 4 'OK' 'Existing image detected; Python dependencies are already installed inside it.'
    }
    else {
        Finish-Step 4 'OK' 'No existing image found; a fresh build is required on this first run.'
    }
}

function Invoke-StagePort {
    Begin-Step 5 'Selecting a local host port...'
    if ($script:ContainerRunning) {
        if ($script:ReusedPort) {
            $script:ChosenPort = $script:ReusedPort
            Finish-Step 5 'OK' "Using port $($script:ChosenPort) (published by the existing container)."
            return
        }
        Invoke-DieStep 5 'Port selection' `
            'An existing container is running but no published port could be detected.' `
            "Run 'docker compose port $Service $ContainerPort' to inspect it, or 'docker compose down' and start again."
    }
    if ($env:HOST_PORT) {
        if (-not (Test-ValidPort $env:HOST_PORT)) {
            Invoke-DieStep 5 'Port selection' `
                "HOST_PORT='$($env:HOST_PORT)' is not a valid TCP port (1-65535)." `
                'Set HOST_PORT to a number between 1 and 65535, for example HOST_PORT=8002.'
        }
        $candidate = [int]$env:HOST_PORT
        if (Test-PortInUse $candidate) {
            Invoke-DieStep 5 'Port selection' `
                "Port $candidate (your HOST_PORT) is already in use by another program." `
                'Choose a different port, for example HOST_PORT=8002.'
        }
        $script:ChosenPort = $candidate
        Finish-Step 5 'OK' "Using port $($script:ChosenPort) (from HOST_PORT in your environment)."
        return
    }
    $envPort = Get-EnvFilePort
    if ($envPort) {
        if (-not (Test-ValidPort $envPort)) {
            Invoke-DieStep 5 'Port selection' `
                "HOST_PORT in .env ('$envPort') is not a valid TCP port (1-65535)." `
                'Fix the HOST_PORT value in .env, or remove the line to use the default.'
        }
        $candidate = [int]$envPort
        if (Test-PortInUse $candidate) {
            Invoke-DieStep 5 'Port selection' `
                "Port $candidate (from HOST_PORT in .env) is already in use." `
                'Update HOST_PORT in .env to a free port, or remove the line.'
        }
        $script:ChosenPort = $candidate
        Finish-Step 5 'OK' "Using port $($script:ChosenPort) (from HOST_PORT in .env)."
        return
    }
    $free = Find-FreePort 8000
    if (-not $free) {
        Invoke-DieStep 5 'Port selection' `
            "No free port was found between 8000 and $PortScanMax." `
            'Stop some local services, or set HOST_PORT to a free port.'
    }
    $script:ChosenPort = $free
    if ($free -eq 8000) {
        Finish-Step 5 'OK' 'Using port 8000 (default; it is free).'
    }
    else {
        Finish-Step 5 'OK' "Using port $free (8000 was busy; the next free port was chosen)."
    }
}

function Invoke-StageBuild {
    if ($script:ContainerRunning) {
        Finish-Step 6 'SKIP' 'Skipped: reusing the running container (no rebuild).'
        return
    }
    if ($script:ImageExists) {
        Finish-Step 6 'SKIP' 'Skipped: image already built; Python dependencies are already inside it.'
        return
    }
    Begin-Step 6 'Building the image and installing Python dependencies...'
    Write-Say 'Python dependencies are installed inside the Docker image, not on your host OS.'
    Write-Say 'Streaming Docker build output below (the first build can take a minute)...'
    & docker compose build
    if ($LASTEXITCODE -ne 0) {
        Invoke-DieStep 6 'Image build and Python dependencies' `
            "The Docker image failed to build (a Docker build or pip install error)." `
            'Read the build output above, fix the Dockerfile or requirements.txt, then run this launcher again.'
    }
    Finish-Step 6 'OK' 'Image built; Python dependencies are installed inside the image.'
}

function Invoke-StageStart {
    if ($script:ContainerRunning) {
        Finish-Step 7 'SKIP' 'Skipped: the container is already running (reused).'
        return
    }
    Begin-Step 7 'Starting the container...'
    & docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Invoke-DieStep 7 'Container startup' `
            'Docker Compose could not start the container.' `
            'Review the output above and the logs below, fix the problem, then run this launcher again.'
    }
    Finish-Step 7 'OK' 'Container started.'
}

function Invoke-StageSeed {
    if ($script:ContainerRunning) {
        Finish-Step 8 'OK' 'Migrations and fictional demo data were preserved (existing container reused).'
        return
    }
    Begin-Step 8 'Waiting for Django migrations and fictional demo seeding...'
    if (-not (Wait-ForSeed)) {
        Invoke-DieStep 8 'Django migration and demo seeding' `
            "The container did not report 'Demo data ready' within ${ReadinessTimeout}s (migration or seeding may have failed)." `
            'Check the logs below, then run this launcher again.'
    }
    Finish-Step 8 'OK' 'Django migrations ran and fictional demo data is ready.'
}

function Invoke-StageHttp {
    Begin-Step 9 "Checking HTTP readiness at http://127.0.0.1:$($script:ChosenPort)/ ..."
    if (-not (Wait-ForHttp "http://127.0.0.1:$($script:ChosenPort)/")) {
        Invoke-DieStep 9 'HTTP readiness check' `
            "The service started but did not answer HTTP at http://127.0.0.1:$($script:ChosenPort)/ within ${ReadinessTimeout}s." `
            "The app may still be starting; wait and retry, or run 'docker compose logs $Service'."
    }
    Finish-Step 9 'OK' "HTTP health check passed at http://127.0.0.1:$($script:ChosenPort)/."
}

function Show-Success {
    Finalize-Progress
    Write-Host ''
    if ($script:UseColor) {
        Write-Host 'Your demo is running (local development only).' -ForegroundColor Green
    }
    else {
        Write-Host 'Your demo is running (local development only).'
    }
    Write-Host ''
    Write-Host "  Home:  http://127.0.0.1:$($script:ChosenPort)/"
    Write-Host "  Login: http://127.0.0.1:$($script:ChosenPort)/login/"
    Write-Host ''
    Write-Host '  Demo accounts (fictional):'
    Write-Host '    Admin:   demo_admin   / demo-admin-pass'
    Write-Host '    Teacher: demo_teacher / demo-teacher-pass'
    Write-Host '    Student: demo_student / demo-student-pass'
    Write-Host ''
    Write-Host '  Passwords are applied only when the demo accounts are first created.'
    Write-Host '  If you changed a password earlier, your new password is kept.'
    Write-Host ''
    Write-Host '  Stop the demo safely:  docker compose down'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
function Start-OrDetect {
    Write-Host 'AG Learning Platform Demo - setup'
    Write-Host 'Local development only. This launcher is non-destructive.'
    Write-Host ''
    Invoke-StageDockerCli
    Invoke-StageEngine
    Invoke-StageCompose
    Invoke-StageDetect
    Invoke-StagePort
    $env:HOST_PORT = "$($script:ChosenPort)"
    Invoke-StageBuild
    Invoke-StageStart
    Invoke-StageSeed
    Invoke-StageHttp
    Show-Success
}

# ---------------------------------------------------------------------------
# Self-test (pure logic; used by tests/launcher_test.sh)
# ---------------------------------------------------------------------------
function Invoke-SelfTest {
    $script:failures = 0

    function Assert-Equal {
        param([string]$Description, $Expected, $Actual)
        if ("$Expected" -ne "$Actual") {
            Write-Host "FAIL - $Description (expected $Expected got $Actual)"
            $script:failures++
        }
        else {
            Write-Host "ok   - $Description"
        }
    }

    function Assert-Valid {
        param([string]$Description, [string]$Port, [int]$WantValid)
        $got = if (Test-ValidPort $Port) { 0 } else { 1 }
        Assert-Equal $Description $WantValid $got
    }

    Assert-Valid 'valid port 1' '1' 0
    Assert-Valid 'valid port 8000' '8000' 0
    Assert-Valid 'valid port 65535' '65535' 0
    Assert-Valid 'invalid empty' '' 1
    Assert-Valid 'invalid zero' '0' 1
    Assert-Valid 'invalid text' 'abc' 1
    Assert-Valid 'invalid high' '70000' 1
    Assert-Valid 'invalid negative' '-1' 1
    Assert-Valid 'invalid injection' '80;rm -rf /' 1

    Assert-Equal 'percent at 0 steps' 0 (Get-Percent 0)
    Assert-Equal 'percent at 8/9 is not 100' 88 (Get-Percent 8)
    Assert-Equal 'percent reaches 100 only at 9/9' 100 (Get-Percent 9)
    Assert-Equal 'percent clamps above total' 100 (Get-Percent 42)
    Assert-Equal 'bar length at 0' $BarWidth (Get-Bar 0).Length
    Assert-Equal 'bar length at 9' $BarWidth (Get-Bar 9).Length
    Assert-Equal 'bar at 0 has no fill' $true ((Get-Bar 0) -notmatch '#')
    Assert-Equal 'bar at 9 is full' $true ((Get-Bar 9) -notmatch '-')

    $redacted = Redact 'DEMO_ADMIN_PASSWORD=demo-admin-pass DJANGO_SECRET_KEY=abc123'
    Assert-Equal 'redaction masks password' $true ($redacted -match 'PASSWORD=\*\*\*')
    Assert-Equal 'redaction masks secret key' $true ($redacted -match 'SECRET_KEY=\*\*\*')
    Assert-Equal 'redaction removes secret value' $false ($redacted -match 'demo-admin-pass')
    Assert-Equal 'redaction removes key value' $false ($redacted -match 'abc123')

    $free = Find-FreePort 8000
    if (Test-ValidPort "$free") {
        Write-Host "ok   - Find-FreePort returned $free"
    }
    else {
        Write-Host 'FAIL - Find-FreePort returned an invalid value'
        $script:failures++
    }

    if ($script:failures -eq 0) {
        Write-Host 'start.ps1 self-test passed.'
        exit 0
    }
    exit 1
}

if ($SelfTest) {
    Invoke-SelfTest
}

try {
    Start-OrDetect
}
finally {
    if ($script:TransientLen -gt 0) { Write-Host '' }
}
