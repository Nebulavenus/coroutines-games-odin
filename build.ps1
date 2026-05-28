param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("build", "run", "test", "debug", "build_web", "run_web")]
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
    "build_web"
    {
        # Clean old files
        $build = "build"
        if (Test-Path $build)
        {
            # Preview what will be removed:
            # Get-ChildItem -LiteralPath $build -Force

            # Remove all files and folders inside build\
            Get-ChildItem -LiteralPath $build -Force |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
        } else
        {
            New-Item -ItemType Directory -Path $build | Out-Null
        }

        # Compile web build
        odin run E:\OdinLang\Odin\shared\karl2d\build_web\ -- src/ "-o:size"

        # Move everything from src/ folder to build/ folder
        $dest = "build"
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        # Move everything from any src/<bin|build> into top-level build\
        $dest = Join-Path (Get-Location) "build"
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        # Find all "src" directories, then for each move bin and build subfolders
        Get-ChildItem -Path . -Directory -Recurse -Force |
            Where-Object { $_.Name -ieq "src" } |
            ForEach-Object {
                foreach ($name in "bin","build")
                {
                    $folder = Join-Path $_.FullName $name
                    if (Test-Path $folder)
                    {
                        # If destination folder already exists, move contents to it (merge)
                        $targetFolder = Join-Path $dest $name
                        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null

                        Get-ChildItem -Path $folder -Force |
                            ForEach-Object {
                                $sourceItem = $_.FullName
                                $targetPath = Join-Path $targetFolder $_.Name

                                # If a file/folder with same name exists, add a numeric suffix to avoid overwrite
                                if (Test-Path $targetPath)
                                {
                                    $i = 1
                                    while (Test-Path ("{0}_{1}" -f $targetPath, $i))
                                    { $i++
                                    }
                                    $targetPath = "{0}_{1}" -f $targetPath, $i
                                }

                                Move-Item -LiteralPath $sourceItem -Destination $targetPath -Force
                            }

                            # Remove the empty original folder if it's now empty
                            if ((Get-ChildItem -Path $folder -Force | Measure-Object).Count -eq 0)
                            {
                                Remove-Item -Path $folder -Force -Recurse
                            }
                        }
                    }
                }
    }
    "run_web"
    {
        $workDir = Join-Path "build" "bin\web"
        if (-not (Test-Path $workDir))
        { Write-Error "Directory not found: $workDir"; break
        }
        Start-Process -FilePath "python" -ArgumentList "-m", "http.server" -WorkingDirectory $workDir
    }
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
