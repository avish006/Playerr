# Reads Windows' media session (what Spotify web/desktop publishes) and prints JSON lines.
# Reads commands from stdin: toggle | next | prev | seek <ms> | repeat-all | repeat-one
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$null = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType=WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type, $timeoutMs = -1) {
  $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  if (-not $t.Wait($timeoutMs)) { throw 'Windows media request timed out' }
  $t.Result
}
$mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

function Test-SpotifyDesktop($session) {
  return $null -ne $session -and $session.SourceAppUserModelId -match '^Spotify(?:$|\.exe$|AB\.SpotifyMusic_)'
}

function Pick-Session {
  $all = @($mgr.GetSessions())
  $current = $mgr.GetCurrentSession()
  $spotify = @($all | Where-Object { Test-SpotifyDesktop $_ })
  $playingSpotify = $spotify | Where-Object { $_.GetPlaybackInfo().PlaybackStatus -eq 'Playing' } | Select-Object -First 1
  if ($playingSpotify) { return $playingSpotify }
  if ($current -and $current.GetPlaybackInfo().PlaybackStatus -eq 'Playing') { return $current }
  $playing = $all | Where-Object { $_.GetPlaybackInfo().PlaybackStatus -eq 'Playing' } | Select-Object -First 1
  if ($playing) { return $playing }
  if ($spotify.Count) { return $spotify[0] }
  return $current
}
. (Join-Path $PSScriptRoot 'spotify-repeat.ps1')

function Read-NativeRepeatMode($info) {
  if ($info.Controls.IsRepeatEnabled) {
    switch ($info.AutoRepeatMode) {
      'None' { 'off' }
      'Track' { 'one' }
      'List' { 'all' }
    }
  }
}

function Read-RepeatMode($session, $info, $title) {
  if (Test-SpotifyDesktop $session) {
    $nativeMode = Read-NativeRepeatMode $info
    if ($nativeMode) { return $nativeMode }
  }
  $control = Get-SpotifyRepeat $session $title
  if ($control) {
    try { $script:repeatLabels[$control.Element.Current.Name] }
    catch { $script:repeatRoot = $null }
  }
}

function Toggle-Repeat($session, $mode) {
  if (Test-SpotifyDesktop $session) {
    $current = Read-NativeRepeatMode ($session.GetPlaybackInfo())
    if ($current) {
      $target = switch ($mode) {
        'all' { [Windows.Media.MediaPlaybackAutoRepeatMode]::List }
        'one' { [Windows.Media.MediaPlaybackAutoRepeatMode]::Track }
      }
      if ($current -eq $mode) { $target = [Windows.Media.MediaPlaybackAutoRepeatMode]::None }
      if (Await ($session.TryChangeAutoRepeatModeAsync($target)) ([bool])) { return }
    }
  }
  if (Get-RepeatPlayer $session) {
    $props = Await ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    Set-SpotifyRepeat $session $props.Title $mode
  }
}

$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
# The thumbnail stream comes back as a bare System.__ComObject that PowerShell's binder won't pass to
# AsStreamForRead / DataReader, so call them through reflection (the CLR does the interface cast itself).
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))
$seen = @{}
function Log-Once($e, $label) {
  $m = $e.Exception.Message
  if ($e.Exception.InnerException) { $m = $e.Exception.InnerException.Message }
  $m = "art: $label failed: $m"
  if (-not $seen.ContainsKey($m)) { $seen[$m] = 1; [Console]::Error.WriteLine($m) }
}
function Read-Thumb($props) {
  $stream = Await ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType]) 1800
  $bytes = $null
  $net = $null
  $memory = $null
  try {
    $net = $asStreamForRead.Invoke($null, @($stream))
    if ($net.CanSeek -and $net.Length -gt 16777216) { return $null }
    $memory = New-Object System.IO.MemoryStream
    $net.CopyTo($memory)
    $bytes = $memory.ToArray()
  } catch { Log-Once $_ 'AsStreamForRead' }
  finally {
    if ($memory) { $memory.Dispose() }
    if ($net) { $net.Dispose() }
  }

  if (-not $bytes -or $bytes.Length -eq 0) {
    # Reopen the thumbnail because a failed read may have moved or closed its stream.
    $stream = Await ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType]) 1800
    $reader = $null
    try {
      $size = [Windows.Storage.Streams.IRandomAccessStream].GetProperty('Size').GetValue($stream)
      if ($size -lt 4 -or $size -gt 16777216) { return $null }
      $reader = [Activator]::CreateInstance([Windows.Storage.Streams.DataReader], @($stream))
      $loaded = Await ($reader.LoadAsync([uint32]$size)) ([uint32]) 1800
      if ($loaded -ne $size) { return $null }
      $bytes = New-Object byte[] $loaded
      $reader.ReadBytes($bytes)
    } catch { Log-Once $_ 'DataReader' }
    finally { if ($reader) { $reader.Dispose() } }
  }
  if (-not $bytes -or $bytes.Length -lt 4) { return $null }
  $mime = switch -Regex ([BitConverter]::ToString($bytes, 0, [Math]::Min(12, $bytes.Length))) {
    '^FF-D8-FF' { 'image/jpeg'; break }
    '^89-50-4E-47' { 'image/png'; break }
    '^52-49-46-46-(?:[0-9A-F]{2}-){4}57-45-42-50' { 'image/webp'; break }
    '^47-49-46-38' { 'image/gif'; break }
    '^42-4D' { 'image/bmp'; break }
  }
  if ($mime) { return "data:$mime;base64," + [Convert]::ToBase64String($bytes) }
}
function Get-Art($props) {
  try {
    if ($null -eq $props.Thumbnail) { return $null }   # browser hasn't attached the cover yet
    return Read-Thumb $props
  } catch { Log-Once $_ 'thumbnail'; return $null }
}

function New-ArtworkState {
  return @{
    Key = $null; Art = $null; LastGoodArt = $null; LastGoodAlbum = $null
    NextProbe = [DateTime]::MinValue; TrackSince = [DateTime]::MinValue
  }
}

function Update-Artwork($state, $props, $source, $now) {
  $keyParts = @($source, $props.Title, $props.Artist, $props.AlbumTitle, $props.TrackNumber)
  $key = ConvertTo-Json -InputObject $keyParts -Compress
  $album = if ($props.AlbumTitle) { "$source/$($props.AlbumTitle)" }
  if ($state.Key -cne $key) {
    $state.Key = $key
    $state.Art = $null
    $state.NextProbe = $now
    $state.TrackSince = $now
  }
  if ($now -ge $state.NextProbe) {
    $candidate = Get-Art $props
    $settling = ($now - $state.TrackSince).TotalSeconds -lt 2
    # Some sessions publish the next title while still returning the last track's thumbnail.
    $oldCover = $candidate -and $candidate -ceq $state.LastGoodArt -and
      $album -cne $state.LastGoodAlbum -and (($album -and $state.LastGoodAlbum) -or $settling)
    if ($candidate -and -not $oldCover -and $candidate -cne $state.Art) {
      $state.Art = $candidate
      $state.LastGoodArt = $candidate
      $state.LastGoodAlbum = $album
    }
    $delay = if ($settling) { 450 } elseif ($state.Art) { 4000 } else { 1800 }
    $state.NextProbe = $now.AddMilliseconds($delay)
  }
}

$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput())
$read = $stdin.ReadLineAsync()
$artwork = New-ArtworkState
$sentTrack = $null; $sentArt = $null
$tick = 0
while ($true) {
  try {
    $s = Pick-Session
    $force = $false
    if ($read.IsCompleted) {
      $line = $read.Result
      if ($null -eq $line) { break }            # parent closed stdin -> exit
      $read = $stdin.ReadLineAsync()
      if ($s -and $line) {
        $c = $line.Trim().Split(' ')
        switch ($c[0]) {
          'repeat-all' { Toggle-Repeat $s 'all' }
          'repeat-one' { Toggle-Repeat $s 'one' }
          'toggle' {
            if (-not (Await ($s.TryTogglePlayPauseAsync()) ([bool]))) {
              $info = $s.GetPlaybackInfo()
              if ($info.PlaybackStatus -eq 'Playing' -and $info.Controls.IsPauseEnabled) {
                $null = Await ($s.TryPauseAsync()) ([bool])
              } elseif ($info.PlaybackStatus -ne 'Playing' -and $info.Controls.IsPlayEnabled) {
                $null = Await ($s.TryPlayAsync()) ([bool])
              }
            }
          }
          'next'   { $null = Await ($s.TrySkipNextAsync()) ([bool]) }
          'prev'   { $null = Await ($s.TrySkipPreviousAsync()) ([bool]) }
          'seek'   { $null = Await ($s.TryChangePlaybackPositionAsync([long]([double]$c[1] * 10000))) ([bool]) }
        }
        Start-Sleep -Milliseconds 150
        $force = $true
      }
    }
    if ($force -or ($tick % 4 -eq 0)) {
      if (-not $s) {
        if ($null -ne $artwork.Key) { $artwork = New-ArtworkState }
        $sentTrack = $null
        $sentArt = $null
        [Console]::Out.WriteLine('{"none":true}')
      } else {
        $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        if (-not $props) { Start-Sleep -Milliseconds 120; $tick++; continue }
        Update-Artwork $artwork $props $s.SourceAppUserModelId ([DateTime]::UtcNow)
        $tl = $s.GetTimelineProperties()
        $info = $s.GetPlaybackInfo()
        $playing = ($info.PlaybackStatus -eq 'Playing')
        $dur = $tl.EndTime.TotalMilliseconds - $tl.StartTime.TotalMilliseconds
        $pos = $tl.Position.TotalMilliseconds
        if ($playing) {
          $el = ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalMilliseconds
          if ($el -gt 0 -and $el -lt 3600000) { $pos += $el }
        }
        if ($pos -gt $dur) { $pos = $dur }
        if ($pos -lt 0) { $pos = 0 }
        $out = [ordered]@{ title = $props.Title; artist = $props.Artist; album = $props.AlbumTitle
                           trackKey = $artwork.Key
                           repeat = Read-RepeatMode $s $info $props.Title
                           playing = $playing; pos = [math]::Round($pos); dur = [math]::Round($dur) }
        if ($artwork.Key -cne $sentTrack -or $artwork.Art -cne $sentArt) { $out['art'] = $artwork.Art }
        [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress))
        $sentTrack = $artwork.Key
        $sentArt = $artwork.Art
      }
    }
  } catch { [Console]::Error.WriteLine($_.Exception.Message) }
  $tick++
  Start-Sleep -Milliseconds 120
}
