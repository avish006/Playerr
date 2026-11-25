# Spotify exposes its repeat control through Windows accessibility.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$script:repeatLabels = @{
  'Enable repeat' = 'off'
  'Enable repeat one' = 'all'
  'Enable repeat once' = 'all'
  'Disable repeat' = 'one'
}
$script:repeatRoot = $null
$script:lastRepeatSearch = [DateTime]::MinValue
$script:lastRepeatTrack = $null
$script:lastRepeatPlayer = $null

function Get-RepeatPlayer($session) {
  if (Test-SpotifyDesktop $session) { return 'spotify' }
  switch -Regex ($session.SourceAppUserModelId) {
    '^Brave' { 'brave'; break }
    '^(Google)?Chrome' { 'chrome'; break }
    '^(MSEdge|Microsoft\.MicrosoftEdge)' { 'msedge'; break }
    '^Firefox' { 'firefox'; break }
  }
}

function Test-SpotifyDocument($document) {
  $address = $null
  if (-not $document.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$address)) { return $false }
  $url = $null
  return [Uri]::TryCreate($address.Current.Value, [UriKind]::Absolute, [ref]$url) -and
    $url.Scheme -eq 'https' -and $url.Host -eq 'open.spotify.com'
}

function Get-RepeatControl($document) {
  $names = [Windows.Automation.Condition[]]@(
    foreach ($label in $script:repeatLabels.Keys) {
      [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $label)
    }
  )
  $condition = [Windows.Automation.OrCondition]::new($names)
  foreach ($control in $document.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
    if (-not $control.Current.IsEnabled -or $control.Current.IsOffscreen) { continue }
    $pattern = $null
    if ($control.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
      return @{ Element = $control; Pattern = $pattern; UsesToggle = $true }
    }
    if ($control.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
      return @{ Element = $control; Pattern = $pattern; UsesToggle = $false }
    }
  }
}

function Find-SpotifyRepeatRoot($player, $title) {
  $processes = @(Get-Process -Name $player -ErrorAction SilentlyContinue | Where-Object MainWindowHandle)
  if (-not $processes.Count) { return }
  $type = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Document)
  $fallback = @()
  foreach ($entry in $processes) {
    $belongsToBrowser = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $entry.Id)
    foreach ($window in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $belongsToBrowser)) {
      if ($window.Current.IsOffscreen) { continue }
      $roots = if ($player -eq 'spotify') { @($window) }
        else { $window.FindAll([Windows.Automation.TreeScope]::Descendants, $type) }
      foreach ($root in $roots) {
        if ($root.Current.IsOffscreen) { continue }
        if ($player -ne 'spotify' -and -not (Test-SpotifyDocument $root)) { continue }
        if (-not (Get-RepeatControl $root)) { continue }
        if ($title -and $root.Current.Name.IndexOf($title, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $root }
        $fallback += $root
      }
    }
  }
  if ($fallback.Count -eq 1) { $fallback[0] }
}

function Get-SpotifyRepeat($session, $title) {
  $player = Get-RepeatPlayer $session
  if (-not $player) { return }
  if ($title -ne $script:lastRepeatTrack -or $player -ne $script:lastRepeatPlayer) {
    $script:repeatRoot = $null
    $script:lastRepeatSearch = [DateTime]::MinValue
    $script:lastRepeatTrack = $title
    $script:lastRepeatPlayer = $player
  }
  try {
    if ($script:repeatRoot -and ($player -eq 'spotify' -or (Test-SpotifyDocument $script:repeatRoot))) {
      $control = Get-RepeatControl $script:repeatRoot
      if ($control) { return $control }
    }
    $script:repeatRoot = $null
    if (([DateTime]::UtcNow - $script:lastRepeatSearch).TotalSeconds -lt 1.5) { return }
    $script:lastRepeatSearch = [DateTime]::UtcNow
    $script:repeatRoot = Find-SpotifyRepeatRoot $player $title
    if ($script:repeatRoot) { Get-RepeatControl $script:repeatRoot }
  } catch {
    # Window or tab may disappear while Windows is returning its controls.
    $script:repeatRoot = $null
  }
}

function Set-SpotifyRepeat($session, $title, $mode) {
  $control = Get-SpotifyRepeat $session $title
  if (-not $control) { return }
  $current = $script:repeatLabels[$control.Element.Current.Name]
  if (-not $current) { return }
  $target = if ($mode -eq $current) { 'off' } else { $mode }

  for ($step = 0; $step -lt 2 -and $current -ne $target; $step++) {
    try {
      if ($control.UsesToggle) { $control.Pattern.Toggle() }
      else { $control.Pattern.Invoke() }
    } catch {
      $script:repeatRoot = $null
      return
    }
    $previous = $current
    $deadline = [DateTime]::UtcNow.AddSeconds(1)
    do {
      Start-Sleep -Milliseconds 90
      $control = Get-SpotifyRepeat $session $title
      if ($control) { $current = $script:repeatLabels[$control.Element.Current.Name] }
    } while ($current -and $current -eq $previous -and [DateTime]::UtcNow -lt $deadline)
    if (-not $control -or -not $current -or $current -eq $previous) { return }
  }
}
