# Export a character's learned BuffMe data to JSON for inspection/promotion into SpellDB.lua.
#
# Usage: .\Export-BuffMeDB.ps1 -CharacterName Leaves
#        .\Export-BuffMeDB.ps1 -CharacterName Leaves -OutFile C:\path\to\leaves.json

param(
    [Parameter(Mandatory = $true)][string]$CharacterName,
    [string]$OutFile
)

# Character data lives in the account-level SavedVariables file under BuffMeDB.chars[name]
# (see BuffMe_InitDB's migration in spells.lua) — NOT the per-character SavedVariablesPerCharacter
# file, which is only a stale mirror of the old BuffMeCharDB global (doesn't reliably flush on
# Ascension; see feedback-savedvariables-percharacter memory).
$AccountPath = "D:\games\Ascension Launcher\resources\client\WTF\Account\TODDIMER@GMAIL.COM"

$svPath = Join-Path $AccountPath "SavedVariables\BuffMe.lua"
if (-not (Test-Path $svPath)) {
    throw "Account-level SavedVariables not found: $svPath"
}

if (-not $OutFile) {
    $OutFile = Join-Path $PSScriptRoot "$CharacterName.json"
}

$exporter = Join-Path $PSScriptRoot "ExportSavedVariables.lua"
lua $exporter $svPath $CharacterName $OutFile
