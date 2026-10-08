[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$NoElevate,
    [switch]$SkipEdgeRepair,
    [switch]$NoConfigLaunch,
    [switch]$SkipFeatureReprovision,
    [switch]$AllowOnlineServicing,
    [switch]$PlanOnly,
    [switch]$StageBootRepair,
    [switch]$NoRebootPrompt,
    [int]$LaunchWaitSeconds = 35
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$logDir = Join-Path $projectRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$backupDir = Join-Path $projectRoot 'backups'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDir "sandbox-repair-$stamp.log"
$probePath = Join-Path $projectRoot 'probe-sandbox.wsb'

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $logPath -Append | Out-Null
    Write-Host $line
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Log ("RUN {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    $output = & $FilePath @ArgumentList 2>&1
    foreach ($line in $output) {
        Write-Log ("  {0}" -f $line)
    }
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Command failed with exit code $exitCode`: $FilePath $($ArgumentList -join ' ')"
    }
    return $output
}

function Invoke-OnlineServicing {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int[]]$AllowedExitCodes = @(0)
    )

    if (-not $AllowOnlineServicing) {
        throw "Online DISM/servicing is disabled because this host crashed immediately after DISM feature queries. Re-run with -AllowOnlineServicing only after crash cause is resolved."
    }

    Invoke-External -FilePath dism.exe -ArgumentList $ArgumentList -AllowedExitCodes $AllowedExitCodes
}

function Get-FeatureState {
    param([string]$FeatureName)
    $result = Invoke-OnlineServicing -ArgumentList @('/Online', '/English', "/Get-FeatureInfo", "/FeatureName:$FeatureName")
    $stateLine = $result | Where-Object { $_ -match '^\s*State\s*:' } | Select-Object -First 1
    if (-not $stateLine) {
        return 'Unknown'
    }
    return (($stateLine -split ':', 2)[1]).Trim()
}

function Enable-FeatureIfNeeded {
    param([string]$FeatureName)
    $state = Get-FeatureState -FeatureName $FeatureName
    Write-Log "Feature $FeatureName state: $state"
    if ($state -eq 'Enabled') {
        return
    }
    if (-not (Test-Admin)) {
        throw "Feature $FeatureName is $state and needs elevation to enable."
    }
    Invoke-OnlineServicing -ArgumentList @('/Online', '/Enable-Feature', "/FeatureName:$FeatureName", '/All', '/NoRestart') -AllowedExitCodes @(0, 3010) | Out-Null
    Write-Log "Feature $FeatureName enable requested."
}

function Repair-Service {
    param(
        [string]$Name,
        [string]$StartupType = 'Automatic'
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Service $Name not present; skipping."
        return
    }

    if ($service.StartType -ne $StartupType) {
        if (-not (Test-Admin)) {
            throw "Service $Name startup is $($service.StartType) and needs elevation to set $StartupType."
        }
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Log "Service $Name startup set to $StartupType."
    }

    $service = Get-Service -Name $Name
    if ($service.Status -ne 'Running') {
        if (-not (Test-Admin)) {
            throw "Service $Name is $($service.Status) and needs elevation to start."
        }
        Start-Service -Name $Name -ErrorAction Stop
        Write-Log "Service $Name started."
    } else {
        Write-Log "Service $Name already running."
    }
}

function Reset-HostNetworkingIfNeeded {
    Repair-Service -Name hns -StartupType Automatic
    Repair-Service -Name vmcompute -StartupType Automatic
    Repair-Service -Name vmms -StartupType Automatic
}

function Assert-SandboxBinariesPresent {
    $sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExe)) {
        throw "WindowsSandbox.exe is missing at $sandboxExe"
    }
    Write-Log "WindowsSandbox.exe present: $sandboxExe"

    $package = Get-AppxPackage -Name MicrosoftWindows.WindowsSandbox -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $package) {
        Write-Log "MicrosoftWindows.WindowsSandbox AppX package is not registered for this user."
        return
    }

    Write-Log "Sandbox AppX package: $($package.PackageFullName)"
    Write-Log "Sandbox AppX install location: $($package.InstallLocation)"
    foreach ($relative in @('wsb.exe', 'WindowsSandboxServer.exe', 'WindowsSandboxRemoteSession.exe', 'AppxManifest.xml')) {
        $path = Join-Path $package.InstallLocation $relative
        Write-Log "$relative present: $(Test-Path -LiteralPath $path)"
    }
}

function Repair-SandboxAppxRegistration {
    $package = Get-AppxPackage -Name MicrosoftWindows.WindowsSandbox -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $package) {
        Write-Log "Sandbox AppX registration repair skipped; package not found."
        return
    }

    $manifest = Join-Path $package.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Log "Sandbox AppX manifest missing: $manifest"
        return
    }

    Write-Log "Re-registering Sandbox AppX manifest without DISM."
    Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
}

function Assert-NoCrashRiskyRepairNeeded {
    $badLayers = @(Get-IncompleteContainerLayers)
    $baseImageCount = Get-BaseImageCount
    if (($badLayers.Count -gt 0) -or ($baseImageCount -eq 0)) {
        foreach ($badLayer in $badLayers) {
            Write-Log "Incomplete layer still present: $($badLayer.FullName)"
        }
        Write-Log "Base image count is $baseImageCount."
        Write-Log "Crash-safe mode will not use online DISM or stop live container/HCS services on this host."
    }
}

function Test-BootCacheRepairNeeded {
    $badLayers = @(Get-IncompleteContainerLayers)
    $baseImageCount = Get-BaseImageCount
    return (($badLayers.Count -gt 0) -or ($baseImageCount -eq 0))
}

function Clear-PostRebootSelfRun {
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $value = (Get-ItemProperty -LiteralPath $runOncePath -Name 'WindowsSandboxRepairVerify' -ErrorAction SilentlyContinue).WindowsSandboxRepairVerify
    if (-not $value) {
        return
    }

    if (-not (Test-Admin)) {
        Write-Log "RunOnce cleanup needs elevation; current stale value remains: $value"
        return
    }

    Remove-ItemProperty -LiteralPath $runOncePath -Name 'WindowsSandboxRepairVerify' -ErrorAction Stop
    Write-Log "Removed stale RunOnce WindowsSandboxRepairVerify value."
}

function Get-BaseImageCount {
    $baseImageRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Containers\BaseImages'
    if (-not (Test-Path -LiteralPath $baseImageRoot)) {
        Write-Log "Base image root missing: $baseImageRoot"
        return 0
    }

    $items = @(Get-ChildItem -LiteralPath $baseImageRoot -Force -ErrorAction SilentlyContinue)
    Write-Log "Base image root: $baseImageRoot; child count=$($items.Count)"
    return $items.Count
}

function Assert-PathUnder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside expected parent. Path=$fullPath Parent=$fullParent"
    }
}

function Initialize-DelayedMoveApi {
    if ('SandboxRepair.NativeMethods' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
namespace SandboxRepair {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
    }
}
'@
}

function Register-DelayedMove {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedParent
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log "Delayed move skipped; source missing: $Source"
        return
    }

    Assert-PathUnder -Path $Source -Parent $ExpectedParent
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Initialize-DelayedMoveApi
    $MOVEFILE_DELAY_UNTIL_REBOOT = 0x4
    $ok = [SandboxRepair.NativeMethods]::MoveFileEx($Source, $Destination, $MOVEFILE_DELAY_UNTIL_REBOOT)
    if (-not $ok) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Failed to stage delayed move. Win32=$errorCode Source=$Source Destination=$Destination"
    }
    Write-Log "Staged boot move: $Source -> $Destination"
}

function Stage-BootCacheRepair {
    $containersRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Containers'
    $layersRoot = Join-Path $containersRoot 'Layers'
    $containerStoragesRoot = Join-Path $containersRoot 'ContainerStorages'
    $baseImagesRoot = Join-Path $containersRoot 'BaseImages'
    $badLayers = @(Get-IncompleteContainerLayers)
    $baseImageCount = Get-BaseImageCount

    if (($badLayers.Count -eq 0) -and ($baseImageCount -gt 0)) {
        Write-Log "No boot cache repair is needed."
        return $false
    }

    if (-not (Test-Admin)) {
        throw "Boot cache repair staging needs elevation."
    }

    $repairRoot = Join-Path $backupDir "boot-cache-repair-$stamp"
    New-Item -ItemType Directory -Force -Path $repairRoot | Out-Null
    $layerBackupRoot = Join-Path $repairRoot 'Layers'
    New-Item -ItemType Directory -Force -Path $layerBackupRoot | Out-Null

    foreach ($badLayer in $badLayers) {
        Register-DelayedMove -Source $badLayer.FullName -Destination (Join-Path $layerBackupRoot $badLayer.Name) -ExpectedParent $layersRoot
    }

    Register-DelayedMove -Source $containerStoragesRoot -Destination (Join-Path $repairRoot 'ContainerStorages') -ExpectedParent $containersRoot
    if ($baseImageCount -eq 0) {
        Register-DelayedMove -Source $baseImagesRoot -Destination (Join-Path $repairRoot 'BaseImages') -ExpectedParent $containersRoot
    }

    Write-Log "Boot cache repair staged. Restart Windows normally, then run this executable again without -StageBootRepair."
    return $true
}

function Get-IncompleteContainerLayers {
    $layersRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Containers\Layers'
    if (-not (Test-Path -LiteralPath $layersRoot)) {
        Write-Log "Container layers root missing: $layersRoot"
        return @()
    }

    $layers = @(Get-ChildItem -LiteralPath $layersRoot -Directory -Force -ErrorAction SilentlyContinue)
    $badLayers = @()
    foreach ($layer in $layers) {
        $filesPath = Join-Path $layer.FullName 'Files'
        $hasFiles = Test-Path -LiteralPath $filesPath
        Write-Log "Container layer $($layer.Name) HasFiles=$hasFiles"
        if (-not $hasFiles) {
            $badLayers += $layer
        }
    }
    return $badLayers
}

function Repair-ContainerLayerStoreIfNeeded {
    $badLayers = @(Get-IncompleteContainerLayers)
    $baseImageCount = Get-BaseImageCount

    if (($badLayers.Count -eq 0) -and ($baseImageCount -gt 0)) {
        Write-Log "Windows Containers layer store does not need cache rebuild."
        return
    }

    Repair-ContainerLayerStoreLive
}

function Ensure-BaseImagesMarker {
    param([string]$SourceLayerName = 'unknown')

    $baseImagesRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Containers\BaseImages'
    if (-not (Test-Path -LiteralPath $baseImagesRoot)) {
        New-Item -ItemType Directory -Force -Path $baseImagesRoot | Out-Null
        Write-Log "Created BaseImages root: $baseImagesRoot"
    }

    $items = @(Get-ChildItem -LiteralPath $baseImagesRoot -Force -ErrorAction SilentlyContinue)
    if ($items.Count -gt 0) {
        return
    }

    $placeholder = Join-Path $baseImagesRoot 'sandbox-cache-repaired-by-script.txt'
    Set-Content -LiteralPath $placeholder -Encoding ASCII -Value "Placeholder written by Windows Sandbox repair at $stamp. Layer repair source: $SourceLayerName"
    Write-Log "BaseImages was empty; wrote non-destructive marker: $placeholder"
}

function Invoke-RobocopyChecked {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExtraArguments = @('/E')
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Robocopy source missing: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @($Source, $Destination) + $ExtraArguments + @('/COPYALL', '/B', '/R:1', '/W:1', '/NP', '/NFL', '/NDL')
    Write-Log ("RUN robocopy.exe {0}" -f ($arguments -join ' '))
    $output = & robocopy.exe @arguments 2>&1
    foreach ($line in $output) {
        if ($line -match 'ERROR|FAILED|Total|Dirs|Files|Bytes|Times|Ended') {
            Write-Log ("  {0}" -f $line)
        }
    }
    $exitCode = $LASTEXITCODE
    Write-Log "robocopy exit code: $exitCode"
    if ($exitCode -ge 8) {
        throw "Robocopy failed with exit code $exitCode from $Source to $Destination"
    }
}

function Backup-PathLive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParent,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Backup skipped; path missing: $Path"
        return
    }

    Assert-PathUnder -Path $Path -Parent $ExpectedParent
    $name = Split-Path -Leaf $Path
    $destination = Join-Path $DestinationRoot $name
    Invoke-RobocopyChecked -Source $Path -Destination $destination -ExtraArguments @('/E')
    Write-Log "Backed up $Path to $destination"
}

function Repair-ContainerLayerStoreLive {
    if (-not (Test-Admin)) {
        throw "Live Windows Containers layer repair needs elevation."
    }

    $containersRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Containers'
    $layersRoot = Join-Path $containersRoot 'Layers'
    $baseImagesRoot = Join-Path $containersRoot 'BaseImages'
    $containerStoragesRoot = Join-Path $containersRoot 'ContainerStorages'
    $badLayers = @(Get-IncompleteContainerLayers)
    $goodLayers = @(Get-ChildItem -LiteralPath $layersRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Files') })

    if ($badLayers.Count -eq 0) {
        Write-Log "No incomplete layer found for live repair."
        return
    }
    if ($goodLayers.Count -eq 0) {
        throw "No intact Windows Containers layer with a Files directory is available as repair source."
    }

    $sourceLayer = $goodLayers | Sort-Object LastWriteTime | Select-Object -First 1
    $sourceFiles = Join-Path $sourceLayer.FullName 'Files'
    $repairRoot = Join-Path $backupDir "live-layer-repair-$stamp"
    New-Item -ItemType Directory -Force -Path $repairRoot | Out-Null

    Write-Log "Live layer repair source: $($sourceLayer.FullName)"
    Backup-PathLive -Path $baseImagesRoot -ExpectedParent $containersRoot -DestinationRoot $repairRoot
    Backup-PathLive -Path $containerStoragesRoot -ExpectedParent $containersRoot -DestinationRoot $repairRoot
    foreach ($badLayer in $badLayers) {
        Backup-PathLive -Path $badLayer.FullName -ExpectedParent $layersRoot -DestinationRoot (New-Item -ItemType Directory -Force -Path (Join-Path $repairRoot 'Layers') | Select-Object -ExpandProperty FullName)
        $destinationFiles = Join-Path $badLayer.FullName 'Files'
        Write-Log "Creating missing layer Files tree: $destinationFiles"
        Invoke-RobocopyChecked -Source $sourceFiles -Destination $destinationFiles -ExtraArguments @('/E', '/XF', 'migration.xml', 'pending.xml')
    }

    Ensure-BaseImagesMarker -SourceLayerName $sourceLayer.Name
}

function Repair-SandboxFeatureProvisioning {
    if ($SkipFeatureReprovision) {
        Write-Log "Sandbox feature reprovision skipped by caller."
        return
    }

    $baseImageCount = Get-BaseImageCount
    if ($baseImageCount -gt 0) {
        return
    }

    if (-not (Test-Admin)) {
        throw "Windows Sandbox base image cache is empty and needs elevation to reprovision."
    }

    Write-Log "Windows Sandbox base image cache is empty; reprovisioning Containers-DisposableClientVM."
    Invoke-OnlineServicing -ArgumentList @('/Online', '/Disable-Feature', '/FeatureName:Containers-DisposableClientVM', '/NoRestart') -AllowedExitCodes @(0, 3010) | Out-Null
    Invoke-OnlineServicing -ArgumentList @('/Online', '/Enable-Feature', '/FeatureName:Containers-DisposableClientVM', '/All', '/NoRestart') -AllowedExitCodes @(0, 3010) | Out-Null
    Enable-FeatureIfNeeded -FeatureName Containers-DisposableClientVM
}

function Repair-EdgeDependency {
    if ($SkipEdgeRepair) {
        Write-Log "Edge/WebView repair skipped by caller."
        return
    }

    $clientRoots = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\*',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\*'
    )
    $clients = @(Get-ItemProperty $clientRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.name -in @('Microsoft Edge', 'Microsoft Edge WebView2 Runtime') })

    foreach ($client in $clients) {
        if (-not $client.location -or -not $client.pv) {
            continue
        }
        $setupPath = Join-Path $client.location "$($client.pv)\Installer\setup.exe"
        if (-not (Test-Path -LiteralPath $setupPath)) {
            Write-Log "Dependency repair setup missing for $($client.name): $setupPath"
            continue
        }
        Write-Log "Repairing dependency $($client.name) $($client.pv)"
        Invoke-External -FilePath $setupPath -ArgumentList @('--repair', '--system-level', '--verbose-logging') -AllowedExitCodes @(0) | Out-Null
    }

    $edgeExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    $webViewRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application'
    $webViewVersions = @(Get-ChildItem -LiteralPath $webViewRoot -Directory -ErrorAction SilentlyContinue)
    Write-Log "Edge present: $(Test-Path -LiteralPath $edgeExe)"
    Write-Log "WebView2 version directories: $($webViewVersions.Count)"
}

function Write-ProbeConfig {
    $content = @'
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Default</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <ProtectedClient>Disable</ProtectedClient>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Enable</ClipboardRedirection>
  <MemoryInMB>4096</MemoryInMB>
</Configuration>
'@
    Set-Content -LiteralPath $probePath -Encoding ASCII -Value $content
    Write-Log "Probe config written: $probePath"
}

function Assert-HypervisorPresent {
    $system = Get-CimInstance Win32_ComputerSystem
    Write-Log "HypervisorPresent=$($system.HypervisorPresent)"
    if (-not $system.HypervisorPresent) {
        throw "Hypervisor is not present. Enable CPU virtualization/Windows hypervisor and reboot before Sandbox can launch."
    }
}

function Invoke-SelfElevated {
    if ((Test-Admin) -or $NoElevate) {
        return $false
    }

    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($NoLaunch) { $args += '-NoLaunch' }
    if ($NoConfigLaunch) { $args += '-NoConfigLaunch' }
    if ($SkipEdgeRepair) { $args += '-SkipEdgeRepair' }
    if ($SkipFeatureReprovision) { $args += '-SkipFeatureReprovision' }
    if ($AllowOnlineServicing) { $args += '-AllowOnlineServicing' }
    if ($PlanOnly) { $args += '-PlanOnly' }
    if ($StageBootRepair) { $args += '-StageBootRepair' }
    if ($NoRebootPrompt) { $args += '-NoRebootPrompt' }
    $args += "-LaunchWaitSeconds"
    $args += "$LaunchWaitSeconds"

    Write-Log "Relaunching elevated for repair permissions."
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait -PassThru
    Write-Log "Elevated child exit code: $($process.ExitCode)"
    exit $process.ExitCode
}

function Launch-And-VerifySandbox {
    $sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExe)) {
        throw "WindowsSandbox.exe was not found at $sandboxExe"
    }

    $startedAt = Get-Date
    $hcsBefore = @(& hcsdiag.exe list 2>$null)
    if ($NoConfigLaunch) {
        Write-Log "Launching $sandboxExe with no WSB config"
        $process = Start-Process -FilePath $sandboxExe -PassThru
    } else {
        Write-Log "Launching $sandboxExe $probePath"
        $process = Start-Process -FilePath $sandboxExe -ArgumentList "`"$probePath`"" -PassThru
    }
    Write-Log "Started WindowsSandbox PID=$($process.Id)"

    $deadline = (Get-Date).AddSeconds($LaunchWaitSeconds)
    do {
        Start-Sleep -Seconds 2
        $mainWindows = @(Get-Process -Name WindowsSandbox -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match 'Windows Sandbox' })
        if ($mainWindows.Count -gt 0) {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
            $root = [Windows.Automation.AutomationElement]::RootElement
            $dialogCondition = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::ClassNameProperty,
                '#32770'
            )
            $dialogs = $root.FindAll([Windows.Automation.TreeScope]::Children, $dialogCondition)
            foreach ($dialog in $dialogs) {
                if ($dialog.Current.Name -notlike '*Windows Sandbox*') {
                    continue
                }
                $descendants = $dialog.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
                foreach ($element in $descendants) {
                    $name = $element.Current.Name
                    if ($name -match 'failed to initialise|failed to initialize|0x80070002|cannot find the file') {
                        throw "Windows Sandbox opened a failure dialog: $name"
                    }
                }
            }
        }

        $client = Get-Process -Name WindowsSandboxClient -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
            Select-Object -First 1
        $hcsAfter = @(& hcsdiag.exe list 2>$null)
        $newHcs = @($hcsAfter | Where-Object { ($hcsBefore -notcontains $_) -and ($_ -notmatch 'WSL') })
        if ($client -or $newHcs.Count -gt 0) {
            if ($client) {
                Write-Log "Verified sandbox client process: PID=$($client.Id)"
            }
            if ($newHcs.Count -gt 0) {
                foreach ($line in $newHcs) {
                    Write-Log "Verified new HCS entry: $line"
                }
            }
            return
        }
    } while ((Get-Date) -lt $deadline)

    $recent = Get-Process -Name WindowsSandbox -ErrorAction SilentlyContinue | Select-Object Name,Id,StartTime,MainWindowTitle
    foreach ($item in $recent) {
        Write-Log ("Observed process: {0} {1} {2} {3}" -f $item.Name, $item.Id, $item.StartTime, $item.MainWindowTitle)
    }
    throw "Windows Sandbox did not expose a verified window within $LaunchWaitSeconds seconds."
}

try {
    Write-Log "Windows Sandbox repair started. Project=$projectRoot"
    Clear-PostRebootSelfRun
    Assert-HypervisorPresent
    Assert-SandboxBinariesPresent
    Assert-NoCrashRiskyRepairNeeded
    Write-ProbeConfig
    if ($StageBootRepair) {
        $repairWasStaged = Stage-BootCacheRepair
        if ($repairWasStaged) {
            Write-Log "Boot repair was staged because -StageBootRepair was explicitly requested. No reboot is started by this script."
        }
        Write-Log "SUCCESS"
        exit 0
    }
    if ($PlanOnly) {
        Write-Log "PlanOnly requested; repair and launch skipped."
        Write-Log "SUCCESS"
        exit 0
    }
    if ((Test-BootCacheRepairNeeded) -and (-not $AllowOnlineServicing)) {
        Write-Log "Container layer repair is needed before Sandbox launch can succeed."
        if (-not (Test-Admin)) {
            Invoke-SelfElevated | Out-Null
        }
        Repair-ContainerLayerStoreLive
        Ensure-BaseImagesMarker
    }
    try {
        if ($AllowOnlineServicing) {
            Enable-FeatureIfNeeded -FeatureName Containers-DisposableClientVM
            Enable-FeatureIfNeeded -FeatureName Microsoft-Hyper-V-All
            Enable-FeatureIfNeeded -FeatureName VirtualMachinePlatform
            Enable-FeatureIfNeeded -FeatureName HypervisorPlatform
            Enable-FeatureIfNeeded -FeatureName Containers
        } else {
            Write-Log "Online DISM/feature servicing skipped by default due observed host crash after DISM."
        }
        Reset-HostNetworkingIfNeeded
        Repair-EdgeDependency
        Repair-SandboxAppxRegistration
        if ($AllowOnlineServicing) {
            Repair-ContainerLayerStoreIfNeeded
            Repair-SandboxFeatureProvisioning
        }
    } catch {
        if ((-not (Test-Admin)) -and ($_.Exception.Message -match 'needs elevation')) {
            Invoke-SelfElevated | Out-Null
        }
        throw
    }
    if (-not $NoLaunch) {
        Launch-And-VerifySandbox
    }
    Write-Log "SUCCESS"
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    Write-Log "Log: $logPath"
    exit 1
}
