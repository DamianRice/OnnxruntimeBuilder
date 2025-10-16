<#
.SYNOPSIS build onnxruntime for windows by benjaminwan
.DESCRIPTION
This is a powershell script for building onnxruntime in windows.
Put this script to onnxruntime root path, and then run .\build-onnxruntime-win.ps1
Attentions:
  1) Set ExecutionPolicy before run this script: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  2) Setup Developer PowerShell via Launch-VsDevShell.ps1
  3) onnxruntime v1.18 only supports VS2022 (v143)
#>

param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('x64', 'x86', 'arm64', 'arm64ec')]
    [string] $VsArch = "x64",

    [Parameter(Mandatory = $false)]
    [ValidateSet('v140', 'v141', 'v142', 'v143')]
    [string] $VsVer = 'v143',

    [Parameter(Mandatory = $false)]
    [ValidateSet('mt', 'md')]
    [string] $VsCRT = 'mt',

    [Parameter(Mandatory = $false)]
    [switch] $BuildJava = $false,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Release', 'Debug', 'MinSizeRel', 'RelWithDebInfo')]
    [string] $BuildType = 'Debug'
)

function GetFileName {
    param ([string]$filePath)
    return [System.IO.Path]::GetFileName($filePath)
}

function CheckLibexeExists {
    return $null -ne (Get-Command lib.exe -ErrorAction SilentlyContinue)
}

function GetLibsList {
    $InFile = "onnxruntime.dir\$BuildType\onnxruntime.tlog\link.read.1.tlog"
    $OutFile = "install-static\libs_list.txt"

    if (!(Test-Path $InFile)) {
        Write-Warning "TLOG file not found: $InFile. Skipping static lib collection."
        return
    }

    $data = Get-Content $InFile -ErrorAction Stop | ForEach-Object { $_.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) }
    $filtered = $data | Where-Object { $_ -like "*$BuildType\*.lib" -and (Test-Path $_) }

    if ($filtered) {
        $filtered | Out-File -Encoding ascii $OutFile
    } else {
        Set-Content -Path $OutFile -Value ""
    }
}

function CollectLibs {
    if (!(Test-Path "install")) {
        Write-Error "install directory not found!"
        exit 1
    }

    # Clean test binaries
    Get-ChildItem -Path "install" -Include "*test*.exe" -Recurse | Remove-Item -Force

    # Flatten include
    if (Test-Path "install\include\onnxruntime") {
        Copy-Item -Path "install\include\onnxruntime\*" -Destination "install\include" -Recurse -Force
        Remove-Item -Path "install\include\onnxruntime" -Recurse -Force
    }

    # Create static install dir
    $StaticDir = "install-static"
    if (Test-Path $StaticDir) { Remove-Item $StaticDir -Recurse -Force }
    New-Item -ItemType Directory -Path "$StaticDir\lib" | Out-Null
    Copy-Item -Path "install\include" -Destination "$StaticDir\" -Recurse

    # Generate lib list
    GetLibsList

    $LibexeExists = CheckLibexeExists
    $LibListFile = "$StaticDir\libs_list.txt"
    $LibOutput = "$StaticDir\lib\onnxruntime.lib"

    if (Test-Path $LibListFile -and (Get-Item $LibListFile).Length -gt 0) {
        if ($LibexeExists) {
            # Use lib.exe to merge
            $libs = Get-Content $LibListFile
            & lib.exe /OUT:$LibOutput /MACHINE:$($VsArch.ToUpper()) $libs
            $libName = "onnxruntime.lib"
        } else {
            # Copy individual libs
            $libs = Get-Content $LibListFile
            foreach ($lib in $libs) {
                if (Test-Path $lib) {
                    Copy-Item $lib "$StaticDir\lib\"
                }
            }
            $libName = ($libs | ForEach-Object { GetFileName $_ }) -join ';'
        }
    } else {
        $libName = ""
    }

    # Write CMake config
    $CmakeContent = @"
set(OnnxRuntime_INCLUDE_DIRS `\${CMAKE_CURRENT_LIST_DIR}/include`)
include_directories(\${OnnxRuntime_INCLUDE_DIRS})
link_directories(\${CMAKE_CURRENT_LIST_DIR}/lib)
set(OnnxRuntime_LIBS $libName)
"@
    Set-Content -Path "$StaticDir\OnnxRuntimeConfig.cmake" -Value $CmakeContent
}

# === Main ===
Clear-Host
Write-Host "Params: VsArch=$VsArch VsVer=$VsVer VsCRT=$VsCRT BuildJava=$BuildJava BuildType=$BuildType"

# Arch flags
$VsArchFlag = switch ($VsArch) {
    'x86'      { '--x86' }
    'arm64'    { '--arm64' }
    'arm64ec'  { '--arm64ec' }
    default    { '' }
}

$ArmFlag = if ($VsArch -in @('arm64', 'arm64ec')) { '--buildasx' } else { '' }

# VS version
$VsFlag = if ($VsVer -eq 'v143') { 'Visual Studio 17 2022' } else { 'Visual Studio 16 2019' }

# CRT
$StaticCrtFlag = if ($VsCRT -eq 'mt') { '--enable_msvc_static_runtime' } else { '' }

# Java
$JavaFlag = if ($BuildJava) { '--build_java' } else { '' }

$OutPutPath = "build-$VsArch-$VsVer-$VsCRT"

# Build via ONNX Runtime's build.py
python $PSScriptRoot\tools\ci_build\build.py `
    $VsArchFlag `
    $ArmFlag `
    $JavaFlag `
    --build_shared_lib `
    --build_dir "$PSScriptRoot\$OutPutPath" `
    --config $BuildType `
    --parallel `
    --skip_tests `
    --compile_no_warning_as_error `
    --cmake_generator "$VsFlag" `
    $StaticCrtFlag `
    --cmake_extra_defines CMAKE_INSTALL_PREFIX=./install onnxruntime_BUILD_UNIT_TESTS=OFF

# Install and collect
Push-Location $OutPutPath

# Important: specify --config for multi-config generators
cmake --install . --config $BuildType

if (!(Test-Path "install")) {
    Write-Error "CMake install failed!"
    exit 1
}

CollectLibs

Pop-Location

Write-Host "✅ Build and install completed."