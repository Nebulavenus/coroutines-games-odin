param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("build", "run", "test", "debug")]
    [string]$Action
)

$OutExe = "build/game.exe"
$Source = "src"
$ProjectFile = "coroutines.raddbg"

function Invoke-OdinBuild
{
    param($Source, $Output)

    Write-Host "Building $Output..." -ForegroundColor Cyan
    odin build $Source -out:$Output -debug -linker:radlink -show-timings
    return $LASTEXITCODE
}

function Invoke-OdinTest
{
    param($Source)

    Write-Host "Testing $Source..." -ForegroundColor Cyan
    odin test $Source -all-packages
}

$RaddbgPath = $env:RADDBG_PATH
if (-not $RaddbgPath -or -not (Test-Path $RaddbgPath))
{
    $RaddbgPath = "E:\OdinLang\raddbg\raddbg.exe"
}

switch ($Action)
{
    "debug"
    {
        if ((Invoke-OdinBuild $Source $OutExe) -eq 0)
        {
            if (Test-Path $RaddbgPath)
            {
                Write-Host "Launching RAD Debugger..." -ForegroundColor Green
                $raddbgArgs = @($OutExe, "--auto_run")
                if (Test-Path $ProjectFile)
                {
                    $raddbgArgs += "--project:$ProjectFile"
                }
                Start-Process -FilePath $RaddbgPath -ArgumentList $raddbgArgs
            } else
            {
                Write-Warning "RAD Debugger not found at $RaddbgPath. Running normally."
                & $OutExe
            }
        }
    }
    "build"
    {
        Invoke-OdinBuild $Source $OutExe
    }
    "run"
    {
        if ((Invoke-OdinBuild $Source $OutExe) -eq 0)
        {
            Write-Host "Running $OutExe..." -ForegroundColor Green
            & $OutExe
        }
    }
    "test"
    {
        Invoke-OdinTest $Source
    }
    default
    {
        Invoke-OdinBuild $Source $OutExe
    }
}
