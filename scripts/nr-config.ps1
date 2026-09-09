<#
.SYNOPSIS
  dlss5-anywhere - set up, tune, switch and launch DLSS Neural Rendering inside Lossless Scaling.

.DESCRIPTION
  The ReShade overlay cannot be opened while ReShade lives inside LosslessScaling.exe (key presses
  go to the game, not to LS), so everything is done on disk, in ReShade.ini. This script touches
  only the places below and leaves every other line alone:
    [ADDON]  DisabledAddons           - turn the "RenoDX DLSS" add-on on or off
    [RENODX-DLSS]                     - keys a non-DLSS host needs (RequireDlss, both hook keys: always written), colour/UI handling
    [RENODX-DLSS-preset1]             - the image parameters (model, passes, intensity, the add-on's own resolution scale, ...)
    [OVERLAY]  ShowFPS, ShowFrameTime  - ReShade's own FPS counter (-Fps), for diagnosis
  and, when the NR Cost Scaler is installed, keys in nvngx_dlssnr.ini:
    [DLSSNR_Proxy] EnableProxy, ResolutionScale, EnableAnamorphic, ResolutionScaleX/Y, EnableAlternatingFrames
                                      - Cost Scaler on/off, resolution, anamorphic X/Y, alternating frames
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
  0.75 is the author's recommended sweet spot (about 40 % faster neural pass). Uniform: turns anamorphic off.

.PARAMETER CostScaleX
  Anamorphic Cost Scaler: horizontal scale, 0.25 to 1.00. Setting X or Y turns EnableAnamorphic on.
  The Cost Scaler's own presets: Widescreen 0.65/0.85, Ultra-Perf 0.50/0.75, Quality 0.80/0.90.

.PARAMETER CostScaleY
  Anamorphic Cost Scaler: vertical scale, 0.25 to 1.00.

.PARAMETER Alternating
  on / off. Cost Scaler "Alternating Frames": runs NR on every other frame and reuses the result in between.
  More FPS, but the tool itself warns about uneven (sawtooth) frame pacing; judge camera motion by eye.

.PARAMETER Scale
  The add-on's own resampling (DirectNeuralRenderingProcessingScale), in percent of width and height: 100 = off,
  75 = NR runs on a 75 % frame and the correction is applied back at full resolution (RGB residual). Same idea
  as the Cost Scaler, built into the add-on since 2026-09-09. Use one of the two; the script warns when both are on.

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
  No parameters: shows the current setup, asks on/off, AI model, passes, Cost Scaler, FPS counter, offers the advanced
  settings, writes (the keys LS always needs included), offers to start LS.
.EXAMPLE
  .\nr-config.ps1 -Launch
  Just start LS the right way. Nothing is asked; the keys LS always needs are checked on the way.
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

  # [RENODX-DLSS]   (the hook keys are not parameters: the script always writes the values LS needs, see $Required)
  [int]$Scale,               # DirectNeuralRenderingProcessingScale  add-on's own resampling, percent (100 = off)
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
  [double]$CostScale,        # ResolutionScale (uniform; also turns EnableAnamorphic off)
  [ValidateRange(0.25, 1.0)]
  [double]$CostScaleX,       # ResolutionScaleX (anamorphic; turns EnableAnamorphic on)
  [ValidateRange(0.25, 1.0)]
  [double]$CostScaleY,       # ResolutionScaleY
  [ValidateSet('on', 'off')]
  [string]$Alternating,      # EnableAlternatingFrames 1 / 0

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
# Keys that have exactly one right value in LS, written on every run, never asked:
#   RequireDlss 0  - the add-on agrees to run in a host without native DLSS
#   HookPoint 1    - "auto", read by add-on builds before 2026-09-09
#   HookMethod 2   - "present", read by add-on builds from 2026-09-09 (each build ignores the other's key)
$Required = [ordered]@{
  'DirectNeuralRenderingRequireDlss' = '0'
  'DirectNeuralRenderingHookPoint'   = '1'
  'DirectNeuralRenderingHookMethod'  = '2'
}
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
  Scale          = @($PresetSection, 'DirectNeuralRenderingProcessingScale')
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
$Basic     = @('Model', 'PassCount')    # asked always in interactive mode, after on/off; the rest under "Advanced"
$IntParams = @('PassCount', 'AutoMask', 'Scale', 'UiCorrection', 'Encoding', 'WhiteNits', 'WhiteOverride')
# Every question reads "<Label> - <what it does> (<values>) [<current>]". Plain words; parameter names stay in -Show.
$Label = @{
  Model = 'AI Model'; PassCount = 'Passes'; Scale = 'Add-on resolution scale'
  Intensity = 'Intensity'; AutoMask = 'Character mask'; GlobalTone = 'Global tone'; LocalTone = 'Local tone'
  LocalStructure = 'Structure'; SkinStructure = 'Skin structure'; UiCorrection = 'UI correction'; Encoding = 'Colour encoding'
  WhiteNits = 'Diffuse white'; WhiteOverride = 'White override'
}
$Hint = @{
  Model          = ' - the neural model, C is the newest (A/B/C)'
  PassCount      = ' - how many times the model runs on each frame, every pass costs the same FPS again (1-10, 1 = default)'
  Scale          = ' - the add-on''s own version of the Cost Scaler, keep 100 while the Cost Scaler is on (percent, 100 = off)'
  Intensity      = ' - overall strength of the effect (0-1)'
  AutoMask       = ' - detect characters so their skin gets its own strength (on/off)'
  GlobalTone     = ' - brightness and contrast changes over the whole frame (0-1)'
  LocalTone      = ' - contrast changes in small areas (0-1)'
  LocalStructure = ' - added surface detail (0-1)'
  SkinStructure  = ' - added detail on detected characters (0-1)'
  UiCorrection   = ' - keep menus and HUD readable, auto decides from the source (auto, or a number to force it)'
  Encoding       = ' - how colours are read, leave auto unless the source is HDR (auto, or a number)'
  WhiteNits      = ' - brightness of white for HDR sources, only used with White override = custom (nits)'
  WhiteOverride  = ' - use the automatic white level, or the nits above (auto/custom)'
}
# Numeric switches shown with their meaning, "0 (auto)", and accepted by name when typed. Names come from the add-on's
# overlay (Hook Method: Off/Auto/..., UI Correction: Auto/Off/On, Diffuse White: automatic or a custom nits value).
$ValueNames = @{
  Encoding      = @{ 0 = 'auto' }
  UiCorrection  = @{ 0 = 'auto' }
  WhiteOverride = @{ 0 = 'auto'; 1 = 'custom' }
  AutoMask      = @{ 0 = 'off'; 1 = 'on' }
}
$ModelNames = @('A', 'B', 'C')   # DirectNeuralRenderingStyle 0 / 1 / 2
# RHI never creates these keys. Written when the key is absent: Enter in the prompts, or any non-interactive run.
# (The hook keys are handled by $Required above.)
$Suggested = [ordered]@{ Model = 'C'; PassCount = 1; Scale = 100 }

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
function Get-ProxyDouble([string]$key) {
  $v = Get-IniValue $ProxySection $key $proxyLines
  $d = 0.0
  if ($v -and [double]::TryParse($v, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
  return $null
}
function Test-CostScalerAnamorphic { return ((Get-IniValue $ProxySection 'EnableAnamorphic' $proxyLines) -eq '1') }
function Test-CostScalerAlternating { return ((Get-IniValue $ProxySection 'EnableAlternatingFrames' $proxyLines) -eq '1') }
function Show-CostScaleState {
  # "0.75" or "0.65 x 0.85 (anamorphic)", plus ", alternating frames ON"
  $s = if (Test-CostScalerAnamorphic) {
    $x = Get-ProxyDouble 'ResolutionScaleX'; $y = Get-ProxyDouble 'ResolutionScaleY'
    "{0} x {1} (anamorphic)" -f $(if ($null -eq $x) { '?' } else { Format-Scale $x }), $(if ($null -eq $y) { '?' } else { Format-Scale $y })
  } else {
    $u = Get-CostScale
    if ($null -eq $u) { '(missing)' } else { Format-Scale $u }
  }
  if (Test-CostScalerAlternating) { $s += ', alternating frames ON' }
  return $s
}

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
function Show-Named([string]$p, $v) {
  # "1 (auto)" for switches listed in $ValueNames, plain value otherwise
  if ($null -eq $v) { return '(missing)' }
  if ($p -eq 'Model') { return Show-Model $v }
  $n = 0
  if ($ValueNames.Contains($p) -and [int]::TryParse([string]$v, [ref]$n) -and $ValueNames[$p].Contains($n)) { return "$v ($($ValueNames[$p][$n]))" }
  return [string]$v
}
function Convert-NamedInput([string]$p, [string]$s) {
  # "auto" / "off" / "on" / "custom" -> number for switches in $ValueNames, or $null when not a known name
  if (-not $ValueNames.Contains($p)) { return $null }
  foreach ($k in $ValueNames[$p].Keys) { if ($ValueNames[$p][$k] -eq $s.Trim().ToLowerInvariant()) { return [int]$k } }
  return $null
}
function Show-Param([string]$p) {
  $sec, $key = $Tunable[$p]; $cur = Get-IniValue $sec $key
  if ($null -eq $cur -and $Suggested.Contains($p)) { return "(missing, will be set to $(Show-Named $p $Suggested[$p]))" }
  return Show-Named $p $cur
}
function Show-Short([string]$p, $v) {
  # For prompts and the summary: the word alone ("present", "C"), the number when it has no name, "(missing)" when absent
  if ($null -eq $v) { return '(missing)' }
  if ($p -eq 'Model') { $n = 0; if ([int]::TryParse([string]$v, [ref]$n) -and $n -ge 0 -and $n -lt $ModelNames.Count) { return $ModelNames[$n] } }
  $n = 0
  if ($ValueNames.Contains($p) -and [int]::TryParse([string]$v, [ref]$n) -and $ValueNames[$p].Contains($n)) { return $ValueNames[$p][$n] }
  return [string]$v
}
function Get-ParamValue([string]$p) { $sec, $key = $Tunable[$p]; return (Get-IniValue $sec $key) }

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

## RHI's "Auto-configure ReShade for FrameGen" installs ReShade as Reshade64.asi behind an ASI loader (winmm.dll). In LS that
## loader only fires when LS loads winmm.dll, which happens at exit, so ReShade is never there when you press Scale
## (seen 2026-09-09: ReShade.log "loaded from ...\Reshade64.asi", initialised two seconds before LS closed, no swapchain).
function Test-AsiLoaderMode {
  return (Test-Path (Join-Path $LsPath 'Reshade64.asi')) -or (Test-Path (Join-Path $LsPath 'ReShade64.asi'))
}
function Warn-AsiLoaderMode {
  if (Test-AsiLoaderMode) {
    Write-Warning "ReShade is installed as Reshade64.asi (ASI loader). In LS it loads too late and NR never runs. In RHI: gear next to Remove -> ShortFuse Settings -> 'Auto-configure ReShade for FrameGen' Off -> Save -> Reinstall, then run this again."
  }
}

## Four lines anyone can read. Shown before the questions and at the top of -Show.
function Show-Summary {
  Warn-AsiLoaderMode
  $nr = if (Test-AddonEnabled) { 'on ' } else { 'OFF' }
  $passes = Show-Short 'PassCount' (Get-ParamValue 'PassCount')
  $passWord = if ($passes -eq '1') { 'pass' } else { 'passes' }
  $scale = Get-ParamValue 'Scale'
  $scaleTxt = if ($scale -and $scale -ne '100') { "  ·  add-on scale $scale %" } else { '' }
  Write-Host ("  Neural rendering   {0}  ·  AI Model {1}  ·  {2} {3}  ·  Intensity {4}{5}" -f $nr,
    (Show-Short 'Model' (Get-ParamValue 'Model')), $passes, $passWord, (Show-Short 'Intensity' (Get-ParamValue 'Intensity')), $scaleTxt)
  if (Test-CostScalerInstalled) {
    $cs = if (Test-CostScalerOn) { 'on ' } else { 'off' }
    Write-Host ("  Cost Scaler        {0}  ·  {1}" -f $cs, (Show-CostScaleState))
  } else {
    Write-Host '  Cost Scaler        not installed (optional, for FPS: RHI -> Neural Rendering -> NR Cost Scaler)'
  }
  Write-Host ("  FPS counter        {0}" -f $(if (Test-FpsShown) { 'on' } else { 'off' }))
  Write-Host ("  Online model check {0}" -f $(if (Test-OtaOn) { 'on   (the driver asks NVIDIA for models when Scale starts; on a slow network that is a long wait: -Ota off)' } else { 'off' }))
}

## Every key the script knows, with its parameter. Debugging view, -Show only.
function Show-Current {
  Show-Summary
  Write-Host ''
  Write-Host "Keys in $IniPath"
  Write-Host "[$MainSection]"
  $byKey = @{}; foreach ($p in $Tunable.Keys) { $byKey[$Tunable[$p][1]] = $p }
  $mainKeys = Get-SectionKeys $MainSection 'DirectNeuralRendering'
  foreach ($k in $Required.Keys) { if (-not $mainKeys.Contains($k)) { $mainKeys[$k] = $null } }
  foreach ($k in $mainKeys.Keys) {
    $cur = $mainKeys[$k]
    $tag = ''
    $shown = Show-Value $cur
    if ($Required.Contains($k)) { $tag = if ($cur -eq $Required[$k]) { '   (required for LS)' } else { "   <- LS needs $($Required[$k])" } }
    elseif ($byKey.ContainsKey($k)) { $tag = "   (-$($byKey[$k]))"; $shown = Show-Param $byKey[$k] }
    Write-Host ("  {0,-45} = {1}{2}" -f $k, $shown, $tag)
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
  $onlyOta = (-not $Launch) -and (-not $On) -and (-not $Off) -and (-not $Fps) -and (-not $CostScaler) -and (-not $Alternating) -and
             (-not $PSBoundParameters.ContainsKey('CostScale')) -and (-not $PSBoundParameters.ContainsKey('CostScaleX')) -and
             (-not $PSBoundParameters.ContainsKey('CostScaleY')) -and ($requested.Count -eq 0)
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
$wantCostScaleX = $null
if ($PSBoundParameters.ContainsKey('CostScaleX')) { $wantCostScaleX = [double]$CostScaleX }
$wantCostScaleY = $null
if ($PSBoundParameters.ContainsKey('CostScaleY')) { $wantCostScaleY = [double]$CostScaleY }
$wantAlternating = $null
if ($Alternating) { $wantAlternating = ($Alternating -eq 'on') }

function Read-Param([string]$p) {
  # asks once for one parameter; stores into $requested; Enter keeps the current value,
  # or takes the suggested one when the key is not in the ini yet
  $sec, $key = $Tunable[$p]
  $useSuggested = ($null -eq (Get-IniValue $sec $key)) -and $Suggested.Contains($p)
  $shown = if ($useSuggested) { "$(Show-Short $p $Suggested[$p]), suggested" } else { Show-Short $p (Get-IniValue $sec $key) }
  $label = if ($Label.Contains($p)) { $Label[$p] } else { $p }
  while ($true) {
    $in = Read-Host ("  {0}{1} [{2}]" -f $label, $Hint[$p], $shown)
    if ([string]::IsNullOrWhiteSpace($in)) {
      if ($useSuggested) { $script:requested[$p] = $Suggested[$p] }
      return
    }
    $in = $in.Trim().Replace(',', '.')
    if ($p -eq 'Model') {
      $m = Convert-ModelInput $in
      if ($null -ne $m) { $script:requested[$p] = $ModelNames[$m]; return }
      Write-Host '    Type A, B or C.'; continue
    }
    if ($p -in $IntParams) {
      $named = Convert-NamedInput $p $in
      if ($null -ne $named) { $script:requested[$p] = $named; return }
      $tmp = 0
      if ([int]::TryParse($in, [ref]$tmp)) { $script:requested[$p] = $tmp; return }
      if ($ValueNames.Contains($p)) { Write-Host ("    Type {0}, or a number." -f (($ValueNames[$p].Values | Sort-Object) -join ' or ')); continue }
    } else {
      $tmp = 0.0
      if ([double]::TryParse($in, [Globalization.NumberStyles]::Float, $Inv, [ref]$tmp)) { $script:requested[$p] = $tmp; return }
    }
    Write-Host '    Type a number, with a dot for decimals (0.7).'
  }
}

## on/off question in the same shape as the others: "<Label> - <what it does> (on/off) [<current>]".
## Returns $true / $false, or $null for Enter.
function Read-Switch([string]$label, [string]$explain, [bool]$current) {
  while ($true) {
    $a = Read-Host ("  {0} - {1} (on/off) [{2}]" -f $label, $explain, $(if ($current) { 'on' } else { 'off' }))
    if ([string]::IsNullOrWhiteSpace($a)) { return $null }
    if ($a -match '^(?i)on$')  { return $true }
    if ($a -match '^(?i)off$') { return $false }
    Write-Host '    Type on or off.'
  }
}

if ($Interactive) {
  Assert-LsClosed
  Write-Host 'Current setup'
  Show-Summary
  Write-Host ''
  Write-Host 'Enter keeps the value in brackets. The settings LS always needs are written for you.'
  $wantEnabled = Read-Switch 'Neural rendering' 'the DLSS 5 effect itself' (Test-AddonEnabled)
  foreach ($p in $Basic) { Read-Param $p }
  if (Test-CostScalerInstalled) {
    $wantCostScaler = Read-Switch 'Cost Scaler' 'runs the model at a lower resolution for more FPS' (Test-CostScalerOn)
    while ($true) {
      $a = Read-Host ("  Cost Scaler resolution - lower = more FPS, softer image; two numbers = width height (0.25-1, or 0.65 0.85) [{0}]" -f ((Show-CostScaleState) -replace ', alternating frames ON', ''))
      if ([string]::IsNullOrWhiteSpace($a)) { break }
      $parts = @($a.Trim().Replace(',', '.') -split '[\s/x]+' | Where-Object { $_ })
      $nums = @()
      foreach ($q in $parts) { $tmp = 0.0; if ([double]::TryParse($q, [Globalization.NumberStyles]::Float, $Inv, [ref]$tmp) -and $tmp -ge 0.25 -and $tmp -le 1.0) { $nums += $tmp } }
      if ($nums.Count -eq 1 -and $parts.Count -eq 1) { $wantCostScale = $nums[0]; break }
      if ($nums.Count -eq 2 -and $parts.Count -eq 2) { $wantCostScaleX = $nums[0]; $wantCostScaleY = $nums[1]; break }
      Write-Host '    Type one number (0.75) or two (0.65 0.85), each between 0.25 and 1.'
    }
  }
  $wantFps = Read-Switch 'FPS counter' 'ReShade''s counter in the corner of the LS output' (Test-FpsShown)
  $adv = Read-Host '  Advanced settings - fine-tuning and HDR, the defaults are fine (y/N)'
  if ($adv -match '^(?i)y') {
    if (Test-CostScalerInstalled) {
      $wantAlternating = Read-Switch 'Alternating frames' 'Cost Scaler runs the model on every other frame, more FPS but uneven motion' (Test-CostScalerAlternating)
    }
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
  if ($cur -ne $new) { Set-IniValue $sec $key $new; $changes += "[$sec] ${key}: $(Show-Named $p $cur) -> $(Show-Named $p $new)" }
}

$proxyChanges = @()
function Set-ProxyValue([string]$key, [string]$new) {
  $cur = Get-IniValue $ProxySection $key $proxyLines
  if ($cur -ne $new) { Set-IniValue $ProxySection $key $new $proxyLines; $script:proxyChanges += "[$ProxySection] ${key}: $(Show-Value $cur) -> $new" }
}
$touchProxy = ($null -ne $wantCostScaler) -or ($null -ne $wantCostScale) -or ($null -ne $wantCostScaleX) -or ($null -ne $wantCostScaleY) -or ($null -ne $wantAlternating)
if ($touchProxy) {
  if (-not (Test-CostScalerInstalled)) {
    Write-Warning "Cost Scaler is not installed. Turn it on in RHI (Neural Rendering -> NR Cost Scaler), then run this again."
  } else {
    if ($null -ne $wantCostScaler) { Set-ProxyValue 'EnableProxy' $(if ($wantCostScaler) { '1' } else { '0' }) }
    if ($null -ne $wantCostScale) {
      Set-ProxyValue 'ResolutionScale' (Format-Scale $wantCostScale)
      Set-ProxyValue 'EnableAnamorphic' '0'   # a uniform scale only takes effect with anamorphic off
    }
    if ($null -ne $wantCostScaleX -or $null -ne $wantCostScaleY) {
      if ($null -ne $wantCostScaleX) { Set-ProxyValue 'ResolutionScaleX' (Format-Scale $wantCostScaleX) }
      if ($null -ne $wantCostScaleY) { Set-ProxyValue 'ResolutionScaleY' (Format-Scale $wantCostScaleY) }
      Set-ProxyValue 'EnableAnamorphic' '1'
    }
    if ($null -ne $wantAlternating) { Set-ProxyValue 'EnableAlternatingFrames' $(if ($wantAlternating) { '1' } else { '0' }) }
  }
}

# Two resamplers, one image: the Cost Scaler proxy and the add-on's own ProcessingScale do the same job.
$finalCsOn = if ($null -ne $wantCostScaler) { $wantCostScaler } else { (Test-CostScalerInstalled) -and (Test-CostScalerOn) }
$finalScale = if ($requested.Contains('Scale')) { [string]$requested['Scale'] } else { Get-IniValue $PresetSection 'DirectNeuralRenderingProcessingScale' }
if ($finalCsOn -and $finalScale -and $finalScale -ne '100') {
  Write-Warning "Cost Scaler and the add-on's own resolution scale ($finalScale %) are both on, so the image is scaled twice. Turn one off: -CostScaler off, or -Scale 100."
}

if ($changes.Count -eq 0 -and $proxyChanges.Count -eq 0) {
  Write-Host 'Nothing to change.'
}
if ($changes.Count -gt 0) {
  [IO.File]::WriteAllLines($IniPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Saved to ReShade.ini:"
  $changes | ForEach-Object { Write-Host "  $_" }
}
if ($proxyChanges.Count -gt 0) {
  $porig = "$ProxyIniPath.orig"
  if (-not (Test-Path $porig)) { Copy-Item $ProxyIniPath $porig; Write-Host "Original kept at: $porig" }
  [IO.File]::WriteAllLines($ProxyIniPath, $proxyLines, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Saved to $ProxyIniName (Cost Scaler):"
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
  $a = Read-Host 'Start Lossless Scaling now? (Y/n)'
  if ([string]::IsNullOrWhiteSpace($a) -or $a -match '^[yY]') { Start-LS } else { Write-Host 'Start Lossless Scaling again to apply.' }
} else {
  Write-Host 'Start Lossless Scaling again to apply (or pass -Launch).'
}
