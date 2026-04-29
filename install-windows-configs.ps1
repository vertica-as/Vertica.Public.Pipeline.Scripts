[CmdletBinding()]
param(
    [string]$GitHubRepository = 'vertica-as/Vertica.Public.Pipeline.Scripts',

    [string]$GitRef = 'main',

    [switch]$ForceRemoteTemplates,

    [switch]$KeepDownloadedTemplates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository-local template root and a consistent encoding for any files we write.
$localTemplatesRoot = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'templates' } else { $null }
$remoteTemplateManifestPath = 'template-files.txt'
$rawGitHubRoot = 'https://raw.githubusercontent.com'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Reads the full file exactly as-is so merge operations can preserve formatting.
function Read-AllText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    return [System.IO.File]::ReadAllText($FilePath)
}

# Creates the target directory tree before we write a config file.
function Ensure-ParentDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $parent = Split-Path -Parent -Path $FilePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

# Discovers every template file under templates/ so the script does not need a hardcoded list.
function Get-TemplateFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    return Get-ChildItem -Path $RootPath -File -Recurse | Sort-Object FullName
}

# Builds the raw GitHub URL for one repository-relative file path.
function Get-RemoteFileUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace('\', '/').TrimStart('/')
    return '{0}/{1}/{2}/{3}' -f $rawGitHubRoot, $Repository, $Ref, $normalizedPath
}

# Reads the list of template files that should be downloaded when the script runs standalone.
function Get-RemoteTemplatePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    $manifestUrl = Get-RemoteFileUrl -Repository $Repository -Ref $Ref -RelativePath $ManifestPath

    try {
        $manifestContent = (Invoke-WebRequest -Uri $manifestUrl).Content
    }
    catch {
        throw "Failed to download template manifest from $manifestUrl. $($_.Exception.Message)"
    }

    $templatePaths = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($manifestContent -split '\r?\n')) {
        $trimmedLine = $line.Trim()
        if (-not $trimmedLine -or $trimmedLine.StartsWith('#')) {
            continue
        }

        if (-not $trimmedLine.StartsWith('templates/')) {
            throw "Unsupported template manifest entry '$trimmedLine' in $manifestUrl"
        }

        $templatePaths.Add($trimmedLine)
    }

    if ($templatePaths.Count -eq 0) {
        throw "No template paths were found in $manifestUrl"
    }

    return $templatePaths
}

# Downloads the manifest-listed template files into a temporary folder so the existing
# merge logic can keep working with on-disk template files.
function Initialize-RemoteTemplates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    $cacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ssc-global-configs-' + [System.Guid]::NewGuid().ToString())
    $templatePaths = @(Get-RemoteTemplatePaths -Repository $Repository -Ref $Ref -ManifestPath $ManifestPath)

    foreach ($templatePath in $templatePaths) {
        $templateUrl = Get-RemoteFileUrl -Repository $Repository -Ref $Ref -RelativePath $templatePath
        $destinationPath = Join-Path $cacheRoot ($templatePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))

        try {
            $templateContent = (Invoke-WebRequest -Uri $templateUrl).Content
        }
        catch {
            throw "Failed to download template $templatePath from $templateUrl. $($_.Exception.Message)"
        }

        Ensure-ParentDirectory -FilePath $destinationPath
        [System.IO.File]::WriteAllText($destinationPath, $templateContent, $utf8NoBom)
    }

    return [pscustomobject]@{
        TemplatesRoot = Join-Path $cacheRoot 'templates'
        CacheRoot = $cacheRoot
    }
}

# Uses repository-local templates when available, otherwise falls back to downloading
# the templates from GitHub so the script can run as a standalone raw file.
function Resolve-TemplateSource {
    param(
        [Parameter()]
        [string]$LocalTemplatesRoot,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [switch]$ForceRemote
    )

    if (-not $ForceRemote -and $LocalTemplatesRoot -and (Test-Path -LiteralPath $LocalTemplatesRoot)) {
        return [pscustomobject]@{
            TemplatesRoot = $LocalTemplatesRoot
            CacheRoot = $null
            Source = 'local'
        }
    }

    $remoteTemplates = Initialize-RemoteTemplates -Repository $Repository -Ref $Ref -ManifestPath $ManifestPath
    return [pscustomobject]@{
        TemplatesRoot = $remoteTemplates.TemplatesRoot
        CacheRoot = $remoteTemplates.CacheRoot
        Source = 'github'
    }
}

# Pulls machine-readable path markers such as Windows-Path, Linux-Path, or macOS-Path.
function Get-TargetSpecs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Windows', 'Linux', 'macOS')]
        [string]$Platform
    )

    $marker = '{0}-Path:' -f $Platform
    $specs = @()

    foreach ($line in [System.IO.File]::ReadLines($TemplatePath)) {
        $trimmedLine = $line.Trim()

        if ($trimmedLine.StartsWith('#')) {
            $trimmedLine = $trimmedLine.Substring(1).Trim()
        }
        elseif ($trimmedLine.StartsWith(';')) {
            $trimmedLine = $trimmedLine.Substring(1).Trim()
        }

        if ($trimmedLine.StartsWith($marker, [System.StringComparison]::OrdinalIgnoreCase)) {
            $pathSpec = $trimmedLine.Substring($marker.Length).Trim()
            if (-not $pathSpec) {
                throw "Empty $marker marker found in $TemplatePath"
            }

            $specs += $pathSpec
        }
    }

    return $specs
}

# Expands environment variables and ~ style home-directory shortcuts into real paths.
function Expand-TargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathSpec
    )

    $expanded = [System.Environment]::ExpandEnvironmentVariables($PathSpec)

    if ($expanded.StartsWith('~/')) {
        return Join-Path $HOME $expanded.Substring(2)
    }

    if ($expanded.StartsWith('~\')) {
        return Join-Path $HOME $expanded.Substring(2)
    }

    if ($expanded -match '%[^%]+%') {
        return $null
    }

    return $expanded
}

# Chooses the merge strategy based on the template and destination file format.
# pnpm's legacy rc file is treated like an ini-style key=value config.
function Get-ConfigFormat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $templateName = [System.IO.Path]::GetFileName($TemplatePath)
    $destinationName = [System.IO.Path]::GetFileName($DestinationPath)
    $extension = [System.IO.Path]::GetExtension($TemplatePath).ToLowerInvariant()

    if ($templateName -ieq '.npmrc' -or $destinationName -ieq 'rc') {
        return 'ini'
    }

    if ($extension -eq '.yml' -or $extension -eq '.yaml') {
        return 'yaml'
    }

    if ($extension -eq '.toml') {
        return 'toml'
    }

    throw "Unsupported config format for $TemplatePath"
}

# Uses section + key as the identity for a managed setting so we can update only that setting.
function New-QualifiedKey {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    return ('{0}`n{1}' -f $Section.Trim(), $Key.Trim()).ToLowerInvariant()
}

# Parses one key=value line from ini-style files such as .npmrc and pnpm rc.
function Try-GetIniKey {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [ref]$Key
    )

    $trimmed = $Line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
        return $false
    }

    $separatorIndex = $Line.IndexOf('=')
    if ($separatorIndex -lt 1) {
        return $false
    }

    $candidateKey = $Line.Substring(0, $separatorIndex).Trim()
    if (-not $candidateKey) {
        return $false
    }

    $Key.Value = $candidateKey
    return $true
}

# Parses one top-level key: value line from YAML files.
# Nested YAML is ignored because the current templates only manage top-level settings.
function Try-GetYamlTopLevelKey {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [ref]$Key
    )

    $trimmed = $Line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
        return $false
    }

    if ($Line.Length -ne $Line.TrimStart().Length) {
        return $false
    }

    $separatorIndex = $Line.IndexOf(':')
    if ($separatorIndex -lt 1) {
        return $false
    }

    $candidateKey = $Line.Substring(0, $separatorIndex).Trim()
    if (-not $candidateKey) {
        return $false
    }

    $Key.Value = $candidateKey
    return $true
}

# Detects TOML section headers like [install] so sectioned settings can be merged safely.
function Try-GetTomlSectionName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [ref]$SectionName
    )

    $trimmed = $Line.Trim()
    if ($trimmed.Length -lt 3) {
        return $false
    }

    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return $false
    }

    $name = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if (-not $name) {
        return $false
    }

    $SectionName.Value = $name
    return $true
}

# Parses one TOML key = value line within the current section.
function Try-GetTomlKey {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [ref]$Key
    )

    $trimmed = $Line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
        return $false
    }

    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
        return $false
    }

    $separatorIndex = $Line.IndexOf('=')
    if ($separatorIndex -lt 1) {
        return $false
    }

    $candidateKey = $Line.Substring(0, $separatorIndex).Trim()
    if (-not $candidateKey) {
        return $false
    }

    $Key.Value = $candidateKey
    return $true
}

# Converts the pnpm YAML template lines into pnpm v10 rc key=value lines.
function Convert-YamlLineToRcLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    $separatorIndex = $Line.IndexOf(':')
    if ($separatorIndex -lt 1) {
        throw "Unsupported pnpm YAML line for rc conversion: $Line"
    }

    $key = $Line.Substring(0, $separatorIndex).Trim()
    $value = $Line.Substring($separatorIndex + 1).Trim()
    return '{0}={1}' -f $key, $value
}

# Extracts only the actual managed settings from a template file and normalizes them
# into a common shape for the merge logic.
function Get-TemplateEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $format = Get-ConfigFormat -TemplatePath $TemplatePath -DestinationPath $DestinationPath
    $templateName = [System.IO.Path]::GetFileName($TemplatePath)
    $destinationName = [System.IO.Path]::GetFileName($DestinationPath)
    $entries = New-Object System.Collections.Generic.List[object]

    switch ($format) {
        'ini' {
            foreach ($line in [System.IO.File]::ReadLines($TemplatePath)) {
                $key = $null

                if ($templateName -ieq 'config.yaml' -and $destinationName -ieq 'rc') {
                    if (-not (Try-GetYamlTopLevelKey -Line $line -Key ([ref]$key))) {
                        continue
                    }

                    $normalizedLine = Convert-YamlLineToRcLine -Line $line
                    $entries.Add([pscustomobject]@{
                        Section = ''
                        Key = $key
                        QualifiedKey = New-QualifiedKey -Section '' -Key $key
                        Line = $normalizedLine
                    })
                    continue
                }

                if (-not (Try-GetIniKey -Line $line -Key ([ref]$key))) {
                    continue
                }

                $entries.Add([pscustomobject]@{
                    Section = ''
                    Key = $key
                    QualifiedKey = New-QualifiedKey -Section '' -Key $key
                    Line = $line.Trim()
                })
            }
        }
        'yaml' {
            foreach ($line in [System.IO.File]::ReadLines($TemplatePath)) {
                $key = $null
                if (-not (Try-GetYamlTopLevelKey -Line $line -Key ([ref]$key))) {
                    continue
                }

                $entries.Add([pscustomobject]@{
                    Section = ''
                    Key = $key
                    QualifiedKey = New-QualifiedKey -Section '' -Key $key
                    Line = $line.Trim()
                })
            }
        }
        'toml' {
            $currentSection = ''

            foreach ($line in [System.IO.File]::ReadLines($TemplatePath)) {
                $sectionName = $null
                if (Try-GetTomlSectionName -Line $line -SectionName ([ref]$sectionName)) {
                    $currentSection = $sectionName
                    continue
                }

                $key = $null
                if (-not (Try-GetTomlKey -Line $line -Key ([ref]$key))) {
                    continue
                }

                $entries.Add([pscustomobject]@{
                    Section = $currentSection
                    Key = $key
                    QualifiedKey = New-QualifiedKey -Section $currentSection -Key $key
                    Line = $line.Trim()
                })
            }
        }
    }

    return $entries
}

# Creates a lookup table so existing settings can be replaced by exact managed entries.
function Get-EntryLookup {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    $lookup = @{}
    foreach ($entry in $Entries) {
        $lookup[$entry.QualifiedKey] = $entry
    }

    return $lookup
}

# Appends any managed flat settings that were not already present in the destination file.
function Add-MissingFlatEntries {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$OutputLines,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$SeenKeys
    )

    $missingLines = @()
    foreach ($entry in $Entries) {
        if (-not $SeenKeys.Contains($entry.QualifiedKey)) {
            $missingLines += $entry.Line
            $SeenKeys.Add($entry.QualifiedKey) | Out-Null
        }
    }

    if ($missingLines.Count -eq 0) {
        return
    }

    if ($OutputLines.Count -gt 0 -and $OutputLines[$OutputLines.Count - 1] -ne '') {
        $OutputLines.Add('')
    }

    foreach ($line in $missingLines) {
        $OutputLines.Add($line)
    }
}

# Merges ini-style configs by replacing only matching keys and leaving everything else alone.
function Merge-IniContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $entries = @(Get-TemplateEntries -TemplatePath $TemplatePath -DestinationPath $DestinationPath)
    $lookup = Get-EntryLookup -Entries $entries
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        $newLines = [System.Collections.Generic.List[string]]::new()
        Add-MissingFlatEntries -OutputLines $newLines -Entries $entries -SeenKeys $seenKeys
        return (($newLines -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
    }

    $outputLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ((Read-AllText -FilePath $DestinationPath) -split '\r?\n')) {
        $key = $null
        if (-not (Try-GetIniKey -Line $line -Key ([ref]$key))) {
            $outputLines.Add($line)
            continue
        }

        $qualifiedKey = New-QualifiedKey -Section '' -Key $key
        if (-not $lookup.ContainsKey($qualifiedKey)) {
            $outputLines.Add($line)
            continue
        }

        if (-not $seenKeys.Contains($qualifiedKey)) {
            $outputLines.Add($lookup[$qualifiedKey].Line)
            $seenKeys.Add($qualifiedKey) | Out-Null
        }
    }

    Add-MissingFlatEntries -OutputLines $outputLines -Entries $entries -SeenKeys $seenKeys
    return (($outputLines -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
}

# Merges YAML configs by replacing only matching top-level keys and preserving unrelated lines.
function Merge-YamlContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $entries = @(Get-TemplateEntries -TemplatePath $TemplatePath -DestinationPath $DestinationPath)
    $lookup = Get-EntryLookup -Entries $entries
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        $newLines = [System.Collections.Generic.List[string]]::new()
        Add-MissingFlatEntries -OutputLines $newLines -Entries $entries -SeenKeys $seenKeys
        return (($newLines -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
    }

    $outputLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ((Read-AllText -FilePath $DestinationPath) -split '\r?\n')) {
        $key = $null
        if (-not (Try-GetYamlTopLevelKey -Line $line -Key ([ref]$key))) {
            $outputLines.Add($line)
            continue
        }

        $qualifiedKey = New-QualifiedKey -Section '' -Key $key
        if (-not $lookup.ContainsKey($qualifiedKey)) {
            $outputLines.Add($line)
            continue
        }

        if (-not $seenKeys.Contains($qualifiedKey)) {
            $outputLines.Add($lookup[$qualifiedKey].Line)
            $seenKeys.Add($qualifiedKey) | Out-Null
        }
    }

    Add-MissingFlatEntries -OutputLines $outputLines -Entries $entries -SeenKeys $seenKeys
    return (($outputLines -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
}

# Adds any missing TOML settings for one section, optionally creating the section header first.
function Add-MissingTomlEntriesForSection {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$OutputLines,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$SeenKeys,

        [switch]$CreateSectionHeader
    )

    $sectionEntries = @($Entries | Where-Object { $_.Section -ceq $Section -and -not $SeenKeys.Contains($_.QualifiedKey) })
    if ($sectionEntries.Count -eq 0) {
        return
    }

    if ($CreateSectionHeader) {
        if ($OutputLines.Count -gt 0 -and $OutputLines[$OutputLines.Count - 1] -ne '') {
            $OutputLines.Add('')
        }

        $OutputLines.Add('[{0}]' -f $Section)
    }
    elseif ($OutputLines.Count -gt 0) {
        $lastLine = $OutputLines[$OutputLines.Count - 1].Trim()
        if ($lastLine -and -not ($lastLine.StartsWith('[') -and $lastLine.EndsWith(']'))) {
            # Keep section additions adjacent to the section body.
        }
    }

    foreach ($entry in $sectionEntries) {
        $OutputLines.Add($entry.Line)
        $SeenKeys.Add($entry.QualifiedKey) | Out-Null
    }
}

# Merges TOML configs by matching settings on section + key.
# This keeps unrelated sections and keys intact while still updating managed values.
function Merge-TomlContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $entries = @(Get-TemplateEntries -TemplatePath $TemplatePath -DestinationPath $DestinationPath)
    $lookup = Get-EntryLookup -Entries $entries
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $knownSections = @($entries | ForEach-Object { $_.Section } | Select-Object -Unique)

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        $newLines = [System.Collections.Generic.List[string]]::new()
        Add-MissingTomlEntriesForSection -OutputLines $newLines -Entries $entries -Section '' -SeenKeys $seenKeys

        foreach ($section in $knownSections) {
            if ($section -ceq '') {
                continue
            }

            Add-MissingTomlEntriesForSection -OutputLines $newLines -Entries $entries -Section $section -SeenKeys $seenKeys -CreateSectionHeader
        }

        return (($newLines -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
    }

    $outputLines = [System.Collections.Generic.List[string]]::new()
    $existingSections = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $currentSection = ''
    $sawAnySection = $false

    foreach ($line in ((Read-AllText -FilePath $DestinationPath) -split '\r?\n')) {
        $sectionName = $null
        if (Try-GetTomlSectionName -Line $line -SectionName ([ref]$sectionName)) {
            if (-not $sawAnySection) {
                Add-MissingTomlEntriesForSection -OutputLines $outputLines -Entries $entries -Section '' -SeenKeys $seenKeys
                $sawAnySection = $true
            }
            else {
                Add-MissingTomlEntriesForSection -OutputLines $outputLines -Entries $entries -Section $currentSection -SeenKeys $seenKeys
            }

            $currentSection = $sectionName
            $existingSections.Add($sectionName) | Out-Null
            $outputLines.Add($line)
            continue
        }

        $key = $null
        if (-not (Try-GetTomlKey -Line $line -Key ([ref]$key))) {
            $outputLines.Add($line)
            continue
        }

        $qualifiedKey = New-QualifiedKey -Section $currentSection -Key $key
        if (-not $lookup.ContainsKey($qualifiedKey)) {
            $outputLines.Add($line)
            continue
        }

        if (-not $seenKeys.Contains($qualifiedKey)) {
            $outputLines.Add($lookup[$qualifiedKey].Line)
            $seenKeys.Add($qualifiedKey) | Out-Null
        }
    }

    if ($sawAnySection) {
        Add-MissingTomlEntriesForSection -OutputLines $outputLines -Entries $entries -Section $currentSection -SeenKeys $seenKeys
    }
    else {
        Add-MissingTomlEntriesForSection -OutputLines $outputLines -Entries $entries -Section '' -SeenKeys $seenKeys
    }

    foreach ($section in $knownSections) {
        if ($section -ceq '' -or $existingSections.Contains($section)) {
            continue
        }

        Add-MissingTomlEntriesForSection -OutputLines $outputLines -Entries $entries -Section $section -SeenKeys $seenKeys -CreateSectionHeader
    }

    return (($outputLines -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
}

# Dispatches to the format-specific merge function.
function Merge-ConfigContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    switch (Get-ConfigFormat -TemplatePath $TemplatePath -DestinationPath $DestinationPath) {
        'ini' { return Merge-IniContent -TemplatePath $TemplatePath -DestinationPath $DestinationPath }
        'yaml' { return Merge-YamlContent -TemplatePath $TemplatePath -DestinationPath $DestinationPath }
        'toml' { return Merge-TomlContent -TemplatePath $TemplatePath -DestinationPath $DestinationPath }
        default { throw "Unsupported merge format for $TemplatePath" }
    }
}

# Writes the file only when the merged result differs from what is already on disk.
function Write-FileIfChanged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if (Test-Path -LiteralPath $FilePath) {
        $existing = Read-AllText -FilePath $FilePath
        if ($existing -ceq $Content) {
            return 'unchanged'
        }
    }

    Ensure-ParentDirectory -FilePath $FilePath
    [System.IO.File]::WriteAllText($FilePath, $Content, $utf8NoBom)
    return 'updated'
}

# Main flow:
# 1. Discover all template files.
# 2. Read each template's Windows-Path markers.
# 3. Merge only the managed settings into each destination config.
# 4. Write changes if needed and report any failures at the end.
$templateSource = $null

try {
    $templateSource = Resolve-TemplateSource -LocalTemplatesRoot $localTemplatesRoot -Repository $GitHubRepository -Ref $GitRef -ManifestPath $remoteTemplateManifestPath -ForceRemote:$ForceRemoteTemplates
    $templatesRoot = $templateSource.TemplatesRoot

    if ($templateSource.Source -eq 'github') {
        Write-Host ("Using templates downloaded from https://github.com/{0} at ref {1}" -f $GitHubRepository, $GitRef)
    }

    $templateFiles = @(Get-TemplateFiles -RootPath $templatesRoot)
    if ($templateFiles.Count -eq 0) {
        throw "No template files were found in $templatesRoot"
    }

    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($templateFile in $templateFiles) {
        $templatePath = $templateFile.FullName
        $templateName = Split-Path -Leaf $templateFile.DirectoryName
        $targetSpecs = @(Get-TargetSpecs -TemplatePath $templatePath -Platform 'Windows')

        if ($targetSpecs.Count -eq 0) {
            Write-Warning ("[{0}] No Windows-Path markers found in {1}" -f $templateName, $templatePath)
            continue
        }

        foreach ($targetSpec in $targetSpecs) {
            $destinationPath = Expand-TargetPath -PathSpec $targetSpec

            if (-not $destinationPath) {
                Write-Host ("[{0}] SKIPPED: unresolved path marker {1}" -f $templateName, $targetSpec)
                continue
            }

            try {
                $mergedContent = Merge-ConfigContent -TemplatePath $templatePath -DestinationPath $destinationPath
                $result = Write-FileIfChanged -FilePath $destinationPath -Content $mergedContent
                Write-Host ("[{0}] {1}: {2}" -f $templateName, $result.ToUpperInvariant(), $destinationPath)
            }
            catch {
                $failures.Add("[$templateName] $destinationPath - $($_.Exception.Message)")
                Write-Warning ("[{0}] FAILED: {1}`n{2}" -f $templateName, $destinationPath, $_.Exception.Message)
            }
        }
    }

    if ($failures.Count -gt 0) {
        $message = @(
            'One or more config files could not be written:'
            $failures
        ) -join [System.Environment]::NewLine

        throw $message
    }

    Write-Host 'All Windows config files are in sync with the templates.'
}
finally {
    if ($templateSource -and $templateSource.CacheRoot -and -not $KeepDownloadedTemplates) {
        Remove-Item -LiteralPath $templateSource.CacheRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
