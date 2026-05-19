$ErrorActionPreference = "Continue"

while ($true) {
  try {
    Write-Host "[watchdog] starting bot backend..."
    Set-Location "$PSScriptRoot\backend"
    cargo run
  }
  catch {
    Write-Host "[watchdog] bot crashed: $($_.Exception.Message)"
  }

  Write-Host "[watchdog] restarting in 2 seconds..."
  Start-Sleep -Seconds 2
}
