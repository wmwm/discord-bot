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

Write-Host "`n🔎 Checking if Gemfile.lock is in sync with Gemfile..."
$lockCheck = bundle check 2>&1
if ($lockCheck -like "*install the missing gems*") {
    Write-Host "⚠️  Gemfile.lock is out of sync. Running bundle install..."
    bundle install
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Gemfile.lock updated."
        git add Gemfile.lock
        Write-Host "✅ Gemfile.lock staged for commit."
    } else {
        Write-Host "❌ bundle install failed."
        exit 1
    }
} else {
    Write-Host "✅ Gemfile.lock is in sync."
}

Write-Host "`n🚀 Setup complete."
