param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("build", "run")]
    [string]$Action
)

function Invoke-OdinBuild
{
    param($Source, $Output)

    Write-Host "Building $Output..." -ForegroundColor Cyan
    odin build $Source -out:$Output -linker:radlink -show-timings
}

switch ($Action)
{
    "build"
    {
        Invoke-OdinBuild "src" "build/game.exe"
    }
    "run"
    {
        $Target = "build/game.exe"
        $Src = "src"

        Invoke-OdinBuild $Src $Target

        if (Test-Path $Target)
        {
            Write-Host "Running $Target..." -ForegroundColor Green
            if ($LASTEXITCODE -eq 0)
            { & $Target
            }
        } else
        {
            Write-Error "Build failed, cannot run."
        }
    }
    default
    {
        Invoke-OdinBuild "src" "build/game.exe"
    }
}
