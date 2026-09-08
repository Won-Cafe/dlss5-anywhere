<#
.SYNOPSIS
  dlss5-anywhere - set up, tune, switch and launch DLSS Neural Rendering inside Lossless Scaling.

.DESCRIPTION
  The ReShade overlay cannot be opened while ReShade lives inside LosslessScaling.exe (key presses
  go to the game, not to LS), so everything is done on disk, in ReShade.ini. This script touches
  only the places below and leaves every other line alone:
    [ADDON]  DisabledAddons           - turn the "RenoDX DLSS" add-on on or off
    [RENODX-DLSS]                     - keys a non-DLSS host needs, hook point, colour/UI handling
    [RENODX-DLSS-preset1]             - the image parameters (model, intensity, ...)
    [OVERLAY]  ShowFPS, ShowFrameTime  - ReShade's own FPS counter (-Fps), for diagnosis
  and, when the NR Cost Scaler is installed, two keys in nvngx_dlssnr.ini:
    [DLSSNR_Proxy] EnableProxy, ResolutionScale  - Cost Scaler on/off and internal resolution (-CostScaler, -CostScale)
  and one machine-wide registry value, only when asked with -Ota:
    HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore\EnableOTA  - NGX over-the-air model check (needs admin, UAC prompt)

  Close Lossless Scaling first: ReShade rewrites ReShade.ini when the process exits, so edits made
  while LS is running get overwritten.

.PARAMETER LsPath
  Lossless Scaling folder. Leave empty to auto-detect through Steam.

.PARAMETER Show
  Print current values only, write nothing.

.PARAMETER On
  Enable the RenoDX DLSS add-on (remove it from ReShade's DisabledAddons).

.PARAMETER Off
  Disable the RenoDX DLSS add-on (add it to ReShade's DisabledAddons). ReShade itself stays;
  nothing is neural-rendered until -On. Cheapest way to A/B.

.PARAMETER Model
  Neural rendering model: A, B or C (stored as DirectNeuralRenderingStyle 0, 1, 2).

.PARAMETER Fps
  on / off. Shows ReShade's own FPS and frame-time counter in the corner of the LS output. ReShade
  counts its Present calls, so this number tells you where the add-on sits relative to LSFG: equal
  to the LS output FPS means once per presented frame (after frame generation); equal to the LS
  input FPS means once per captured frame (before it). Independent of the add-on being on or off.

.PARAMETER CostScaler
  on / off. NR Cost Scaler (the toggle under Neural Rendering in RHI): runs the NR model at a lower
  internal resolution and rebuilds the output, to gain FPS. Stored in nvngx_dlssnr.ini, not ReShade.ini.

.PARAMETER CostScale
  Internal resolution scale for the Cost Scaler, 0.25 to 1.00. Lower = more FPS, less detail.
  0.75 is the author's recommended sweet spot (about 40 % faster neural pass).

.PARAMETER Ota
  on / off. NGX "over the air" check: when a DLSS feature is created, the NVIDIA driver asks
  ngx.download.nvidia.com for newer models before continuing. On a slow connection that turns the
  first NR frame after pressing Scale into a fixed wait of a minute or more. off writes EnableOTA=0
  under HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore (NVIDIA's documented switch), on removes
  the value again. Machine-wide, affects every DLSS game, needs admin: a UAC prompt appears. LS does
  not need to be closed for this one; the driver reads the value the next time Scale starts.

.PARAMETER Launch
  Start Lossless Scaling through Steam with WPF hardware acceleration turned off for the lifetime of
  LS (see notes near the bottom of the script), then restore the key when LS exits. Alone, it asks
  nothing: use it as your daily "open LS" command. In interactive mode this is asked instead.

.EXAMPLE
  .\nr-config.ps1
  No parameters: asks on/off, model, pass count, hook point, Cost Scaler, FPS counter, offers the advanced keys, writes, offers to start LS.
.EXAMPLE
  .\nr-config.ps1 -Launch
  Just start LS the right way. Nothing is asked; the required key is checked on the way.
.EXAMPLE
  .\nr-config.ps1 -Off -Launch
  Start LS with neural rendering off, for a before/after comparison.
.EXAMPLE
  .\nr-config.ps1 -Model C -Intensity 0.7 -Launch
  With parameters: writes directly, no questions, then starts LS.
.EXAMPLE
  .\nr-config.ps1 -Ota off
  Stop the driver's online model check so Scale starts in seconds instead of minutes. Asks for admin.
#>
[CmdletBinding()]
param(
  [string]$LsPath,
  [switch]$Show,
  [switch]$On,
  [switch]$Off,
  [switch]$Launch,

  # [RENODX-DLSS-preset1]
  [ValidatePattern('^(?i)[abc012]$')]
  [string]$Model,            # DirectNeuralRenderingStyle            A / B / C  (known-good setup: C)
  [double]$Intensity,        # DirectNeuralRenderingIntensity        (known-good setup: 1; start at 0.6-0.7)
  [int]$PassCount,           # DirectNeuralRenderingPassCount
  [int]$AutoMask,            # DirectNeuralRenderingAutoMask         (0 / 1)
  [double]$GlobalTone,       # DirectNeuralRenderingGlobalToneStrength
  [double]$LocalTone,        # DirectNeuralRenderingLocalToneStrength
  [double]$LocalStructure,   # DirectNeuralRenderingLocalStructureStrength
  [double]$SkinStructure,    # DirectNeuralRenderingSkinStructureStrength

  # [RENODX-DLSS]
  [int]$HookPoint,           # DirectNeuralRenderingHookPoint        (known-good setup for LS: 1)
  [int]$UiCorrection,        # DirectNeuralRenderingUiCorrectionMode
  [int]$Encoding,            # DirectNeuralRenderingEncoding
  [int]$WhiteNits,           # DirectNeuralRenderingDiffuseWhiteNits
  [int]$WhiteOverride,       # DirectNeuralRenderingDiffuseWhiteOverride (0 / 1)

  # [OVERLAY] (ReShade itself, not the add-on)
  [ValidateSet('on', 'off')]
  [string]$Fps,              # ShowFPS + ShowFrameTime

  # nvngx_dlssnr.ini [DLSSNR_Proxy] (NR Cost Scaler, installed through RHI)
  [ValidateSet('on', 'off')]
  [string]$CostScaler,       # EnableProxy 1 / 0
  [ValidateRange(0.25, 1.0)]
  [double]$CostScale,        # ResolutionScale

  # HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore (NVIDIA driver, machine-wide, admin)
  [ValidateSet('on', 'off')]
  [string]$Ota               # EnableOTA absent (on) / 0 (off)
)

$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

if ($On -and $Off) { throw 'Pass either -On or -Off, not both.' }

# ---- what this script is allowed to touch --------------------------------------------------------

$AddonName = 'RenoDX DLSS'     # as registered in ReShade.log: Registered add-on "RenoDX DLSS"

# Required for LS (a host without native DLSS). Value taken from a working ReShade.ini, 2026-09-06.
$Required = [ordered]@{ 'DirectNeuralRenderingRequireDlss' = '0' }
$MainSection = 'RENODX-DLSS'
$PresetSection = 'RENODX-DLSS-preset1'
$OverlaySection = 'OVERLAY'
$FpsKeys = @('ShowFPS', 'ShowFrameTime')   # ReShade's built-in counter, toggled together by -Fps
$ProxyIniName = 'nvngx_dlssnr.ini'         # written by RHI's "NR Cost Scaler" toggle; absent = not installed
$ProxySection = 'DLSSNR_Proxy'

# parameter name -> (section, ini key). Order = order of the interactive prompts.
$Tunable = [ordered]@{
  Model          = @($PresetSection, 'DirectNeuralRenderingStyle')
  PassCount      = @($PresetSection, 'DirectNeuralRenderingPassCount')
  HookPoint      = @($MainSection,   'DirectNeuralRenderingHookPoint')
  Intensity      = @($PresetSection, 'DirectNeuralRenderingIntensity')
  AutoMask       = @($PresetSection, 'DirectNeuralRenderingAutoMask')
  GlobalTone     = @($PresetSection, 'DirectNeuralRenderingGlobalToneStrength')
  LocalTone      = @($PresetSection, 'DirectNeuralRenderingLocalToneStrength')
  LocalStructure = @($PresetSection, 'DirectNeuralRenderingLocalStructureStrength')
  SkinStructure  = @($PresetSection, 'DirectNeuralRenderingSkinStructureStrength')
  UiCorrection   = @($MainSection,   'DirectNeuralRenderingUiCorrectionMode')
  Encoding       = @($MainSection,   'DirectNeuralRenderingEncoding')
  WhiteNits      = @($MainSection,   'DirectNeuralRenderingDiffuseWhiteNits')
  WhiteOverride  = @($MainSection,   'DirectNeuralRenderingDiffuseWhiteOverride')
}
$Basic     = @('Model', 'PassCount', 'HookPoint')    # asked always in interactive mode, after on/off
$IntParams = @('PassCount', 'AutoMask', 'HookPoint', 'UiCorrection', 'Encoding', 'WhiteNits', 'WhiteOverride')
$Hint = @{
  Model         = ' (A / B / C)'
  AutoMask      = ' (0 / 1)'
  PassCount     = ' (integer)'
  HookPoint     = ' (1 = known-good for LS)'
  WhiteOverride = ' (0 / 1)'
}
$ModelNames = @('A', 'B', 'C')   # DirectNeuralRenderingStyle 0 / 1 / 2
# RHI never creates these keys. Missing HookPoint = the add-on has nothing to hook, so LS scales without NR.
# Written when the key is absent: Enter in the prompts, or any non-interactive run.
$Suggested = [ordered]@{ Model = 'C'; PassCount = 1; HookPoint = 1 }

# ---- locate Lossless Scaling --------------------------------------------------------------------

function Find-LsPath {
  $steam = $null
  try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
  if (-not $steam) { return $null }
  $steam = $steam -replace '/', '\'
  $roots = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path $vdf) {
    $m = Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches
    foreach ($x in $m.Matches) { $roots += ($x.Groups[1].Value -replace '\\\\', '\') }
  }
  foreach ($r in ($roots | Select-Object -Unique)) {
    $p = Join-Path $r 'steamapps\common\Lossless Scaling'
    if (Test-Path (Join-Path $p 'LosslessScaling.exe')) { return $p }
  }
  return $null
}

$requested = [ordered]@{}
foreach ($p in $Tunable.Keys) {
  if ($PSBoundParameters.ContainsKey($p)) { $requested[$p] = $PSBoundParameters[$p] }
}
$Interactive = (-not $Show) -and (-not $Launch) -and (-not $On) -and (-not $Off) -and (-not $Fps) -and (-not $Ota) -and
               (-not $CostScaler) -and (-not $PSBoundParameters.ContainsKey('CostScale')) -and ($requested.Count -eq 0)

if (-not $LsPath) { $LsPath = Find-LsPath }
if (-not $LsPath -or -not (Test-Path (Join-Path $LsPath 'LosslessScaling.exe'))) {
  if ($Interactive) {
    $LsPath = (Read-Host 'Could not find Lossless Scaling. Paste the LS folder path').Trim('"', ' ')
  }
  if (-not $LsPath -or -not (Test-Path (Join-Path $LsPath 'LosslessScaling.exe'))) {
    throw "LosslessScaling.exe not found. Pass -LsPath 'path\to\Lossless Scaling'."
  }
}
$IniPath = Join-Path $LsPath 'ReShade.ini'
if (-not (Test-Path $IniPath)) {
  throw "No ReShade.ini in '$LsPath'. ReShade is not installed into LS yet (step 1), or LS has not been started since."
}

# ---- read / write the ini, keep every unrelated line as-is ---------------------------------------

$lines = [System.Collections.Generic.List[string]]([IO.File]::ReadAllLines($IniPath))

# nvngx_dlssnr.ini exists only when RHI's "NR Cost Scaler" toggle is on. Same helpers, other file.
$ProxyIniPath = Join-Path $LsPath $ProxyIniName
$proxyLines = $null
if (Test-Path $ProxyIniPath) { $proxyLines = [System.Collections.Generic.List[string]]([IO.File]::ReadAllLines($ProxyIniPath)) }

# All helpers work on a line list; $L defaults to ReShade.ini, pass $proxyLines for nvngx_dlssnr.ini.

function Get-SectionRange([string]$section, $L = $lines) {
  # returns [start, end): start = header line, end = next header line or line count
  $start = -1
  for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -match '^\s*\[(.+?)\]\s*$') {
      if ($start -ge 0) { return @($start, $i) }
      if ($Matches[1] -eq $section) { $start = $i }
    }
  }
  if ($start -ge 0) { return @($start, $L.Count) }
  return $null
}

function Get-IniValue([string]$section, [string]$key, $L = $lines) {
  $r = Get-SectionRange $section $L
  if (-not $r) { return $null }
  for ($i = $r[0] + 1; $i -lt $r[1]; $i++) {
    if ($L[$i] -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
  }
  return $null
}

function Set-IniValue([string]$section, [string]$key, [string]$value, $L = $lines) {
  $r = Get-SectionRange $section $L
  if (-not $r) {
    if ($L.Count -gt 0 -and $L[$L.Count - 1].Trim() -ne '') { $L.Add('') }
    $L.Add("[$section]"); $L.Add("$key=$value")
    return
  }
  for ($i = $r[0] + 1; $i -lt $r[1]; $i++) {
    if ($L[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $L[$i] = "$key=$value"; return }
  }
  # key missing: insert at the end of the section, before the blank line that separates sections
  $ins = $r[1]
  while ($ins -gt $r[0] + 1 -and $L[$ins - 1].Trim() -eq '') { $ins-- }
  $L.Insert($ins, "$key=$value")
}

function Get-SectionKeys([string]$section, [string]$prefix, $L = $lines) {
  $out = [ordered]@{}
  $r = Get-SectionRange $section $L
  if (-not $r) { return $out }
  for ($i = $r[0] + 1; $i -lt $r[1]; $i++) {
    if ($L[$i] -match "^\s*($([regex]::Escape($prefix))\w*)\s*=\s*(.*)$") { $out[$Matches[1]] = $Matches[2].Trim() }
  }
  return $out
}

# --- NR Cost Scaler through nvngx_dlssnr.ini [DLSSNR_Proxy] EnableProxy / ResolutionScale ---

function Test-CostScalerInstalled { return ($null -ne $proxyLines) }
function Test-CostScalerOn { return ((Get-IniValue $ProxySection 'EnableProxy' $proxyLines) -eq '1') }
function Get-CostScale {
  $v = Get-IniValue $ProxySection 'ResolutionScale' $proxyLines
  $d = 0.0
  if ($v -and [double]::TryParse($v, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
  return $null
}
function Format-Scale([double]$v) { return $v.ToString('0.00', $Inv) }

# --- add-on on/off through [ADDON] DisabledAddons (comma-separated add-on names) ---

function Get-DisabledAddons {
  $v = Get-IniValue 'ADDON' 'DisabledAddons'
  if ([string]::IsNullOrWhiteSpace($v)) { return @() }
  return @($v.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Test-AddonEnabled { return -not ((Get-DisabledAddons) -contains $AddonName) }
function Set-AddonEnabled([bool]$enabled) {
  $list = @(Get-DisabledAddons | Where-Object { $_ -ne $AddonName })
  if (-not $enabled) { $list += $AddonName }
  Set-IniValue 'ADDON' 'DisabledAddons' ($list -join ',')
}

# --- ReShade FPS counter through [OVERLAY] ShowFPS / ShowFrameTime ---

function Test-FpsShown { return ((Get-IniValue $OverlaySection 'ShowFPS') -eq '1') }
function Set-FpsShown([bool]$shown) {
  foreach ($k in $FpsKeys) { Set-IniValue $OverlaySection $k $(if ($shown) { '1' } else { '0' }) }
}

# --- value formatting ---

function Format-Num($v) {
  if ($v -is [double]) { return $v.ToString('0.###', $Inv) }
  return [string]$v
}
function Show-Value($v) { if ($null -eq $v) { '(missing)' } else { $v } }
function Show-Model($v) {
  if ($null -eq $v) { return '(missing)' }
  $n = 0
  if ([int]::TryParse($v, [ref]$n) -and $n -ge 0 -and $n -lt $ModelNames.Count) { return "$v (Model $($ModelNames[$n]))" }
  return "$v (unknown model)"
}
function Convert-ModelInput([string]$s) {
  # A/B/C or 0/1/2 -> ini value 0/1/2, or $null if not valid
  $s = $s.Trim().ToUpperInvariant()
  $i = [array]::IndexOf($ModelNames, $s)
  if ($i -ge 0) { return $i }
  $n = 0
  if ([int]::TryParse($s, [ref]$n) -and $n -ge 0 -and $n -lt $ModelNames.Count) { return $n }
  return $null
}
function Show-Param([string]$p) {
  $sec, $key = $Tunable[$p]; $cur = Get-IniValue $sec $key
  if ($null -eq $cur -and $Suggested.Contains($p)) { return "(missing, will be set to $($Suggested[$p]))" }
  if ($p -eq 'Model') { return Show-Model $cur }
  return Show-Value $cur
}

# --- NGX over-the-air model check: HKLM\...\NGXCore\EnableOTA (absent or 1 = on, 0 = off) ---

$OtaKey = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore'
$OtaName = 'EnableOTA'
function Get-OtaValue { try { return (Get-ItemProperty -Path $OtaKey -Name $OtaName -ErrorAction Stop).$OtaName } catch { return $null } }
function Test-OtaOn { return ((Get-OtaValue) -ne 0) }
function Test-IsAdmin {
  return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Set-OtaOn([bool]$on) {
  # Runs as-is when already admin, otherwise in an elevated child (UAC prompt), then re-reads the value.
  $cmd = if ($on) { "Remove-ItemProperty -Path '$OtaKey' -Name '$OtaName' -ErrorAction SilentlyContinue" }
         else     { "if (-not (Test-Path '$OtaKey')) { New-Item -Path '$OtaKey' -Force | Out-Null }; Set-ItemProperty -Path '$OtaKey' -Name '$OtaName' -Value 0 -Type DWord" }
  if (Test-IsAdmin) {
    Invoke-Expression $cmd
  } else {
    Write-Host 'Changing EnableOTA needs admin rights: confirm the UAC prompt.'
    $psExe = (Get-Process -Id $PID).Path
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try {
      Start-Process -FilePath $psExe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
    } catch { throw "UAC prompt was declined or failed: $($_.Exception.Message)" }
  }
  if ((Test-OtaOn) -ne $on) { throw "EnableOTA still reads $(Show-Value (Get-OtaValue)); the registry write did not take." }
}

# ---- current state -------------------------------------------------------------------------------

function Show-Current {
  Write-Host "ReShade.ini: $IniPath"
  $state = if (Test-AddonEnabled) { 'ON' } else { "OFF  (listed in [ADDON] DisabledAddons)" }
  Write-Host ("Neural rendering add-on `"$AddonName`": $state")
  $fpsState = if (Test-FpsShown) { 'ON' } else { 'off' }
  Write-Host ("ReShade FPS counter [$OverlaySection] ShowFPS/ShowFrameTime: $fpsState   (-Fps on|off)")
  if (Test-CostScalerInstalled) {
    $csState = if (Test-CostScalerOn) { 'ON' } else { 'off' }
    $csScale = Get-CostScale
    $csShown = if ($null -eq $csScale) { '(missing)' } else { Format-Scale $csScale }
    Write-Host ("NR Cost Scaler [$ProxyIniName]: $csState, internal resolution $csShown   (-CostScaler on|off, -CostScale 0.25-1.00)   for FPS: lower = faster, less detail")
  } else {
    Write-Host "NR Cost Scaler: not installed (no $ProxyIniName). Optional, for FPS: turn it on in RHI under Neural Rendering."
  }
  $otaState = if (Test-OtaOn) { 'on  (driver checks ngx.download.nvidia.com when Scale starts; slow network = long wait)' } else { 'off' }
  Write-Host ("NGX online model check [HKLM NGXCore] EnableOTA: $otaState   (-Ota on|off, admin)")
  Write-Host ''
  Write-Host "[$MainSection]"
  $byKey = @{}; foreach ($p in $Tunable.Keys) { $byKey[$Tunable[$p][1]] = $p }
  $mainKeys = Get-SectionKeys $MainSection 'DirectNeuralRendering'
  foreach ($k in $Required.Keys) { if (-not $mainKeys.Contains($k)) { $mainKeys[$k] = $null } }
  foreach ($k in $mainKeys.Keys) {
    $cur = $mainKeys[$k]
    $tag = ''
    if ($Required.Contains($k)) { $tag = if ($cur -eq $Required[$k]) { '   (required for LS)' } else { "   <- LS needs $($Required[$k])" } }
    elseif ($byKey.ContainsKey($k)) { $tag = "   (-$($byKey[$k]))" }
    Write-Host ("  {0,-45} = {1}{2}" -f $k, (Show-Value $cur), $tag)
  }
  Write-Host "[$PresetSection]"
  foreach ($p in $Tunable.Keys) {
    $sec, $key = $Tunable[$p]
    if ($sec -ne $PresetSection) { continue }
    Write-Host ("  {0,-45} = {1}   (-{2})" -f $key, (Show-Param $p), $p)
  }
}

if ($Show) { Show-Current; return }

# ---- NGX OTA (registry, machine-wide) - handled first: does not need LS closed -------------------

if ($Ota) {
  $wantOta = ($Ota -eq 'on')
  if ($wantOta -eq (Test-OtaOn)) {
    Write-Host "NGX online model check already $Ota."
  } else {
    Set-OtaOn $wantOta
    Write-Host "NGX online model check: $(if ($wantOta) { 'off -> on (EnableOTA removed)' } else { 'on -> off (EnableOTA=0)' }). Takes effect the next time Scale starts."
  }
  $onlyOta = (-not $Launch) -and (-not $On) -and (-not $Off) -and (-not $Fps) -and (-not $CostScaler) -and
             (-not $PSBoundParameters.ContainsKey('CostScale')) -and ($requested.Count -eq 0)
  if ($onlyOta) { return }
}

function Assert-LsClosed {
  if (Get-Process -Name 'LosslessScaling' -ErrorAction SilentlyContinue) {
    throw 'Lossless Scaling is running. Close it first: ReShade rewrites ReShade.ini on exit and would overwrite this change.'
  }
}

# ---- interactive prompts when no parameters were given -------------------------------------------

$wantEnabled = $null
if ($On) { $wantEnabled = $true } elseif ($Off) { $wantEnabled = $false }
$wantFps = $null
if ($Fps) { $wantFps = ($Fps -eq 'on') }
$wantCostScaler = $null
if ($CostScaler) { $wantCostScaler = ($CostScaler -eq 'on') }
$wantCostScale = $null
if ($PSBoundParameters.ContainsKey('CostScale')) { $wantCostScale = [double]$CostScale }

function Read-Param([string]$p) {
  # asks once for one parameter; stores into $requested; Enter keeps the current value,
  # or takes the suggested one when the key is not in the ini yet
  $sec, $key = $Tunable[$p]
  $useSuggested = ($null -eq (Get-IniValue $sec $key)) -and $Suggested.Contains($p)
  $shown = if ($useSuggested) { "$($Suggested[$p]), suggested" } else { Show-Param $p }
  while ($true) {
    $in = Read-Host ("  {0}{1} [{2}]" -f $p, $Hint[$p], $shown)
    if ([string]::IsNullOrWhiteSpace($in)) {
      if ($useSuggested) { $script:requested[$p] = $Suggested[$p] }
      return
    }
    $in = $in.Trim().Replace(',', '.')
    if ($p -eq 'Model') {
      $m = Convert-ModelInput $in
      if ($null -ne $m) { $script:requested[$p] = $ModelNames[$m]; return }
      Write-Host '    A, B or C'; continue
    }
    if ($p -in $IntParams) {
      $tmp = 0
      if ([int]::TryParse($in, [ref]$tmp)) { $script:requested[$p] = $tmp; return }
    } else {
      $tmp = 0.0
      if ([double]::TryParse($in, [Globalization.NumberStyles]::Float, $Inv, [ref]$tmp)) { $script:requested[$p] = $tmp; return }
    }
    Write-Host '    not a number, try again'
  }
}

if ($Interactive) {
  Assert-LsClosed
  Show-Current
  Write-Host ''
  Write-Host 'Type a new value, or press Enter to take the one in brackets (current, or suggested when the key is missing). Decimals use a dot (0.7).'
  $curState = if (Test-AddonEnabled) { 'on' } else { 'off' }
  while ($true) {
    $a = Read-Host ("  Neural rendering (on / off) [{0}]" -f $curState)
    if ([string]::IsNullOrWhiteSpace($a)) { break }
    if ($a -match '^(?i)on$')  { $wantEnabled = $true;  break }
    if ($a -match '^(?i)off$') { $wantEnabled = $false; break }
    Write-Host '    on or off'
  }
  foreach ($p in $Basic) { Read-Param $p }
  if (Test-CostScalerInstalled) {
    Write-Host '  NR Cost Scaler, for FPS: runs the NR model at a lower internal resolution, then rebuilds the output.'
    $curCs = if (Test-CostScalerOn) { 'on' } else { 'off' }
    while ($true) {
      $a = Read-Host ("  Cost Scaler (on / off) [{0}]" -f $curCs)
      if ([string]::IsNullOrWhiteSpace($a)) { break }
      if ($a -match '^(?i)on$')  { $wantCostScaler = $true;  break }
      if ($a -match '^(?i)off$') { $wantCostScaler = $false; break }
      Write-Host '    on or off'
    }
    $curScale = Get-CostScale
    $curScaleShown = if ($null -eq $curScale) { '(missing)' } else { Format-Scale $curScale }
    while ($true) {
      $a = Read-Host ("  Cost Scaler internal resolution, 0.25-1.00, lower = more FPS [{0}]" -f $curScaleShown)
      if ([string]::IsNullOrWhiteSpace($a)) { break }
      $tmp = 0.0
      if ([double]::TryParse($a.Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, $Inv, [ref]$tmp) -and $tmp -ge 0.25 -and $tmp -le 1.0) { $wantCostScale = $tmp; break }
      Write-Host '    a number from 0.25 to 1.00, e.g. 0.75'
    }
  }
  $curFps = if (Test-FpsShown) { 'on' } else { 'off' }
  while ($true) {
    $a = Read-Host ("  ReShade FPS counter on the LS output (on / off) [{0}]" -f $curFps)
    if ([string]::IsNullOrWhiteSpace($a)) { break }
    if ($a -match '^(?i)on$')  { $wantFps = $true;  break }
    if ($a -match '^(?i)off$') { $wantFps = $false; break }
    Write-Host '    on or off'
  }
  $adv = Read-Host '  Advanced keys (intensity, masks, tone, structure, colour...)? [y/N]'
  if ($adv -match '^(?i)y') {
    foreach ($p in $Tunable.Keys) { if ($p -notin $Basic) { Read-Param $p } }
  }
}

# ---- write ---------------------------------------------------------------------------------------

Assert-LsClosed

$orig = "$IniPath.orig"
if (-not (Test-Path $orig)) {
  Copy-Item $IniPath $orig
  Write-Host "Original kept at: $orig"
}

$changes = @()

if ($null -ne $wantEnabled -and $wantEnabled -ne (Test-AddonEnabled)) {
  Set-AddonEnabled $wantEnabled
  $changes += "[ADDON] `"$AddonName`": $(if ($wantEnabled) { 'OFF -> ON' } else { 'ON -> OFF' })"
}

if ($null -ne $wantFps -and $wantFps -ne (Test-FpsShown)) {
  Set-FpsShown $wantFps
  $changes += "[$OverlaySection] $($FpsKeys -join '/'): $(if ($wantFps) { 'off -> ON' } else { 'ON -> off' })"
}

foreach ($k in $Required.Keys) {
  $cur = Get-IniValue $MainSection $k
  if ($cur -ne $Required[$k]) {
    Set-IniValue $MainSection $k $Required[$k]
    $changes += "[$MainSection] ${k}: $(Show-Value $cur) -> $($Required[$k])"
  }
}

# Fill in the suggested value for keys that are still absent (also on parameter-only runs such as -On -Launch).
foreach ($p in $Suggested.Keys) {
  if ($requested.Contains($p)) { continue }
  $sec, $key = $Tunable[$p]
  if ($null -eq (Get-IniValue $sec $key)) { $requested[$p] = $Suggested[$p] }
}

foreach ($p in $requested.Keys) {
  $sec, $key = $Tunable[$p]; $cur = Get-IniValue $sec $key
  if ($p -eq 'Model') {
    $m = Convert-ModelInput ([string]$requested[$p])
    if ($null -eq $m) { throw "Model must be A, B or C (got '$($requested[$p])')." }
    $new = "$m"
    if ($cur -ne $new) { Set-IniValue $sec $key $new; $changes += "[$sec] ${key}: $(Show-Model $cur) -> $(Show-Model $new)" }
    continue
  }
  $new = Format-Num $requested[$p]
  if ($cur -ne $new) { Set-IniValue $sec $key $new; $changes += "[$sec] ${key}: $(Show-Value $cur) -> $new" }
}

$proxyChanges = @()
if ($null -ne $wantCostScaler -or $null -ne $wantCostScale) {
  if (-not (Test-CostScalerInstalled)) {
    Write-Warning "NR Cost Scaler is not installed (no $ProxyIniName in the LS folder). Turn it on in RHI under Neural Rendering, then run this again."
  } else {
    if ($null -ne $wantCostScaler -and $wantCostScaler -ne (Test-CostScalerOn)) {
      Set-IniValue $ProxySection 'EnableProxy' $(if ($wantCostScaler) { '1' } else { '0' }) $proxyLines
      $proxyChanges += "[$ProxySection] EnableProxy: $(if ($wantCostScaler) { 'off -> ON' } else { 'ON -> off' })"
    }
    if ($null -ne $wantCostScale) {
      $cur = Get-IniValue $ProxySection 'ResolutionScale' $proxyLines
      $new = Format-Scale $wantCostScale
      if ($cur -ne $new) { Set-IniValue $ProxySection 'ResolutionScale' $new $proxyLines; $proxyChanges += "[$ProxySection] ResolutionScale: $(Show-Value $cur) -> $new" }
    }
  }
}

if ($changes.Count -eq 0 -and $proxyChanges.Count -eq 0) {
  Write-Host 'Nothing to change: values already match.'
}
if ($changes.Count -gt 0) {
  [IO.File]::WriteAllLines($IniPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Wrote $($changes.Count) change(s) to $IniPath"
  $changes | ForEach-Object { Write-Host "  $_" }
}
if ($proxyChanges.Count -gt 0) {
  $porig = "$ProxyIniPath.orig"
  if (-not (Test-Path $porig)) { Copy-Item $ProxyIniPath $porig; Write-Host "Original kept at: $porig" }
  [IO.File]::WriteAllLines($ProxyIniPath, $proxyLines, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Wrote $($proxyChanges.Count) change(s) to $ProxyIniPath"
  $proxyChanges | ForEach-Object { Write-Host "  $_" }
}

# ---- start LS with WPF hardware acceleration off for its lifetime --------------------------------
# LS's own UI is WPF. With ReShade inside LosslessScaling.exe, the settings window would be
# neural-rendered too (GPU busy while LS sits idle). WPF reads
# HKCU\SOFTWARE\Microsoft\Avalon.Graphics\DisableHWAcceleration once at app start and Windows has no
# per-app variant of that key, so: set it to 1, start LS, wait for LS to exit, restore the previous
# value (or delete the key if there was none). The watcher runs in a hidden child process, so this
# window can be closed. LS is started through Steam (steam://rungameid/993090) so Steam's ownership
# check and settings apply. Any other WPF app started while LS is running also sees the key.
# The watcher also leaves a marker value next to the key while it runs. If the watcher dies before
# restoring (terminal closed, reboot), the next launch reads the marker instead of the stale key.
# The watcher polls Get-Process instead of calling Wait-Process: Steam-launched LS denies the
# SYNCHRONIZE right, so Wait-Process returns immediately and the key would be restored too early.

$SteamAppId = 993090

$WatcherScript = @'
$key = 'HKCU:\SOFTWARE\Microsoft\Avalon.Graphics'; $name = 'DisableHWAcceleration'
$mark = 'DisableHWAcceleration_dlss5anywhere_prev'   # what the key was before we touched it; exists only while a watcher is live
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
$prev = $null
try { $prev = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch {}
# A marker left behind means an earlier watcher set the key and never restored it (terminal closed,
# machine rebooted). Trust the marker over the current value, otherwise the stale 1 would be "restored" forever.
$m = $null
try { $m = (Get-ItemProperty -Path $key -Name $mark -ErrorAction Stop).$mark } catch {}
if ($null -ne $m) { $prev = if ("$m" -eq 'none') { $null } else { [int]$m } }
Set-ItemProperty -Path $key -Name $mark -Value $(if ($null -eq $prev) { 'none' } else { "$prev" }) -Type String
Set-ItemProperty -Path $key -Name $name -Value 1 -Type DWord
Start-Process 'steam://rungameid/__APPID__'
# Wait for LS to appear (Steam may show a dialog first), then wait for it to be gone. Wait-Process is
# not used: on a Steam-launched LS it fails at once with "Access is denied" (no SYNCHRONIZE right),
# which would restore the key while LS is still starting. Get-Process only needs query rights.
# LS exiting and coming back within a few seconds (Steam relaunch) counts as one session.
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline -and -not (Get-Process -Name '__PROC__' -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500 }
$gone = 0
while ($gone -lt 10) {
  Start-Sleep -Seconds 1
  if (Get-Process -Name '__PROC__' -ErrorAction SilentlyContinue) { $gone = 0 } else { $gone++ }
}
if ($null -eq $prev) { Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue } else { Set-ItemProperty -Path $key -Name $name -Value $prev -Type DWord }
Remove-ItemProperty -Path $key -Name $mark -ErrorAction SilentlyContinue
'@

function Start-LS {
  # Key already 1 with no marker: either the user set it on purpose, or an older version of this
  # watcher died before restoring. We cannot tell which, so say so once instead of guessing.
  $k = 'HKCU:\SOFTWARE\Microsoft\Avalon.Graphics'
  $cur = $null; $mk = $null
  try { $cur = (Get-ItemProperty -Path $k -Name 'DisableHWAcceleration' -ErrorAction Stop).DisableHWAcceleration } catch {}
  try { $mk = (Get-ItemProperty -Path $k -Name 'DisableHWAcceleration_dlss5anywhere_prev' -ErrorAction Stop).DisableHWAcceleration_dlss5anywhere_prev } catch {}
  if ($cur -eq 1 -and $null -eq $mk) {
    Write-Host "Note: DisableHWAcceleration is already 1 before launch. If you did not set that yourself, it is left over from an earlier run; after closing LS run:"
    Write-Host "  Remove-ItemProperty '$k' -Name DisableHWAcceleration"
  }
  $psExe = (Get-Process -Id $PID).Path
  $body = $WatcherScript.Replace('__APPID__', "$SteamAppId").Replace('__PROC__', 'LosslessScaling')
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
  Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
  Write-Host 'Starting Lossless Scaling through Steam. WPF hardware acceleration is off while LS runs and restored when it exits.'
}

if ($Launch) {
  Start-LS
} elseif ($Interactive) {
  Write-Host ''
  $a = Read-Host 'Start Lossless Scaling now? [Y/n]'
  if ([string]::IsNullOrWhiteSpace($a) -or $a -match '^[yY]') { Start-LS } else { Write-Host 'Start Lossless Scaling again to apply.' }
} else {
  Write-Host 'Start Lossless Scaling again to apply (or pass -Launch).'
}
