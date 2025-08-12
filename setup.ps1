Write-Host "`n🔍 Checking for Gemfile..."
if (-Not (Test-Path ".\Gemfile")) {
    Write-Host "❌ No Gemfile found. Exiting."
    exit 1
}

Write-Host "`n📦 Running bundle install..."
try {
    bundle install
    Write-Host "✅ Dependencies installed."
} catch {
    Write-Host "❌ Bundle install failed."
    exit 1
}

Write-Host "`n🧹 Cleaning up optional clutter..."
$pathsToClean = @(".bundle", "vendor", "Gemfile.lock")
foreach ($path in $pathsToClean) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "🗑️ Removed $path"
    }
}

Write-Host "`n🚀 Setup complete."
