using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;

internal static class Program
{
    private const string DefaultGitHubRepository = "vertica-as/Vertica.Public.Pipeline.Scripts";
    private const string DefaultGitRef = "main";
    private const string RemoteTemplateManifestPath = "template-files.txt";
    private const string RawGitHubRoot = "https://raw.githubusercontent.com";
    private static readonly HttpClient HttpClient = new();
    private static readonly UTF8Encoding Utf8NoBom = new(false);
    private static readonly Regex UnresolvedWindowsEnvironmentVariablePattern = new("%[^%]+%", RegexOptions.Compiled);
    private static readonly SearchOption RecursiveSearch = SearchOption.AllDirectories;

    private static async Task<int> Main(string[] args)
    {
        Options options;

        try
        {
            options = ParseArgs(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            PrintUsage();
            return 1;
        }

        if (options.ShowHelp)
        {
            PrintUsage();
            return 0;
        }

        var platform = GetCurrentPlatform();
        if (platform != SyncPlatform.Windows)
        {
            Console.Error.WriteLine("Current implementation only syncs Windows targets.");
            return 1;
        }

        TemplateSource? templateSource = null;

        try
        {
            templateSource = await ResolveTemplateSourceAsync(options).ConfigureAwait(false);

            if (string.Equals(templateSource.Source, "github", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"Using templates downloaded from https://github.com/{options.GitHubRepository} at ref {options.GitRef}");
            }

            var templateFiles = GetTemplateFiles(templateSource.TemplatesRoot);
            if (templateFiles.Count == 0)
            {
                throw new InvalidOperationException($"No template files were found in {templateSource.TemplatesRoot}");
            }

            var failures = new List<string>();

            foreach (var templatePath in templateFiles)
            {
                var templateName = Path.GetFileName(Path.GetDirectoryName(templatePath)) ?? Path.GetFileName(templatePath);
                var targetSpecs = GetTargetSpecs(templatePath, platform);

                if (targetSpecs.Count == 0)
                {
                    Console.Error.WriteLine($"[{templateName}] No {GetPlatformMarker(platform)} markers found in {templatePath}");
                    continue;
                }

                foreach (var targetSpec in targetSpecs)
                {
                    var destinationPath = ExpandTargetPath(targetSpec, platform);
                    if (destinationPath is null)
                    {
                        if (options.Verbose)
                        {
                            Console.WriteLine($"[{templateName}] Skipping unresolved path marker {targetSpec}");
                        }

                        continue;
                    }

                    try
                    {
                        var mergedContent = MergeConfigContent(templatePath, destinationPath);
                        var result = WriteFileIfChanged(destinationPath, mergedContent);
                        Console.WriteLine($"[{templateName}] {result.ToUpperInvariant()}: {destinationPath}");
                    }
                    catch (Exception ex)
                    {
                        failures.Add($"[{templateName}] {destinationPath} - {ex.Message}");
                        Console.Error.WriteLine($"[{templateName}] FAILED: {destinationPath}{Environment.NewLine}{ex.Message}");
                    }
                }
            }

            if (failures.Count > 0)
            {
                throw new InvalidOperationException(string.Join(
                    Environment.NewLine,
                    new[] { "One or more config files could not be written:" }.Concat(failures)));
            }

            Console.WriteLine("All Windows config files are in sync with the templates.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
        finally
        {
            if (templateSource?.CacheRoot is not null && !options.KeepDownloadedTemplates)
            {
                try
                {
                    Directory.Delete(templateSource.CacheRoot, recursive: true);
                }
                catch
                {
                }
            }
        }
    }

    private static Options ParseArgs(IReadOnlyList<string> args)
    {
        var options = new Options();

        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];

            switch (arg)
            {
                case "-h":
                case "--help":
                    options.ShowHelp = true;
                    break;
                case "--verbose":
                    options.Verbose = true;
                    break;
                case "--force-remote-templates":
                    options.ForceRemoteTemplates = true;
                    break;
                case "--keep-downloaded-templates":
                    options.KeepDownloadedTemplates = true;
                    break;
                case "--github-repository":
                    options.GitHubRepository = ReadRequiredValue(args, ref i, arg);
                    break;
                case "--git-ref":
                    options.GitRef = ReadRequiredValue(args, ref i, arg);
                    break;
                default:
                    throw new ArgumentException($"Unknown argument '{arg}'.");
            }
        }

        return options;
    }

    private static string ReadRequiredValue(IReadOnlyList<string> args, ref int index, string argumentName)
    {
        if (index + 1 >= args.Count)
        {
            throw new ArgumentException($"Missing value for {argumentName}.");
        }

        index++;
        return args[index];
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Usage: SscGlobalConfigs [options]");
        Console.WriteLine();
        Console.WriteLine("Options:");
        Console.WriteLine("  --github-repository <owner/repo>   GitHub repository for standalone template downloads.");
        Console.WriteLine("  --git-ref <ref>                    Git reference for standalone template downloads.");
        Console.WriteLine("  --force-remote-templates           Download templates from GitHub even when local templates exist.");
        Console.WriteLine("  --keep-downloaded-templates        Keep downloaded template cache on disk.");
        Console.WriteLine("  --verbose                          Show skipped unresolved Windows path markers.");
        Console.WriteLine("  -h, --help                         Show this help text.");
    }

    private static SyncPlatform GetCurrentPlatform()
    {
        if (OperatingSystem.IsWindows())
        {
            return SyncPlatform.Windows;
        }

        if (OperatingSystem.IsLinux())
        {
            return SyncPlatform.Linux;
        }

        if (OperatingSystem.IsMacOS())
        {
            return SyncPlatform.MacOs;
        }

        throw new PlatformNotSupportedException("Unsupported operating system.");
    }

    private static string GetPlatformMarker(SyncPlatform platform) => platform switch
    {
        SyncPlatform.Windows => "Windows-Path",
        SyncPlatform.Linux => "Linux-Path",
        SyncPlatform.MacOs => "macOS-Path",
        _ => throw new InvalidOperationException("Unsupported platform marker.")
    };

    private static async Task<TemplateSource> ResolveTemplateSourceAsync(Options options)
    {
        var localTemplatesRoot = Path.Combine(AppContext.BaseDirectory, "templates");

        if (!options.ForceRemoteTemplates && Directory.Exists(localTemplatesRoot))
        {
            return new TemplateSource(localTemplatesRoot, null, "local");
        }

        return await InitializeRemoteTemplatesAsync(options.GitHubRepository, options.GitRef, RemoteTemplateManifestPath).ConfigureAwait(false);
    }

    private static IReadOnlyList<string> GetTemplateFiles(string rootPath)
    {
        return Directory
            .EnumerateFiles(rootPath, "*", RecursiveSearch)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string GetRemoteFileUrl(string repository, string gitRef, string relativePath)
    {
        var normalizedPath = relativePath.Replace('\\', '/').TrimStart('/');
        return $"{RawGitHubRoot}/{repository}/{gitRef}/{normalizedPath}";
    }

    private static async Task<IReadOnlyList<string>> GetRemoteTemplatePathsAsync(string repository, string gitRef, string manifestPath)
    {
        var manifestUrl = GetRemoteFileUrl(repository, gitRef, manifestPath);
        string manifestContent;

        try
        {
            manifestContent = await DownloadStringAsync(manifestUrl).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Failed to download template manifest from {manifestUrl}. {ex.Message}");
        }

        var templatePaths = new List<string>();

        foreach (var line in SplitLines(manifestContent))
        {
            var trimmedLine = line.Trim();
            if (trimmedLine.Length == 0 || trimmedLine.StartsWith('#'))
            {
                continue;
            }

            if (!trimmedLine.StartsWith("templates/", StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Unsupported template manifest entry '{trimmedLine}' in {manifestUrl}");
            }

            templatePaths.Add(trimmedLine);
        }

        if (templatePaths.Count == 0)
        {
            throw new InvalidOperationException($"No template paths were found in {manifestUrl}");
        }

        return templatePaths;
    }

    private static async Task<TemplateSource> InitializeRemoteTemplatesAsync(string repository, string gitRef, string manifestPath)
    {
        var cacheRoot = Path.Combine(Path.GetTempPath(), "ssc-global-configs-" + Guid.NewGuid().ToString());
        var templatePaths = await GetRemoteTemplatePathsAsync(repository, gitRef, manifestPath).ConfigureAwait(false);

        foreach (var templatePath in templatePaths)
        {
            var templateUrl = GetRemoteFileUrl(repository, gitRef, templatePath);
            var destinationPath = Path.Combine(cacheRoot, templatePath.Replace('/', Path.DirectorySeparatorChar));

            try
            {
                var templateContent = await DownloadStringAsync(templateUrl).ConfigureAwait(false);
                EnsureParentDirectory(destinationPath);
                File.WriteAllText(destinationPath, templateContent, Utf8NoBom);
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"Failed to download template {templatePath} from {templateUrl}. {ex.Message}");
            }
        }

        return new TemplateSource(Path.Combine(cacheRoot, "templates"), cacheRoot, "github");
    }

    private static async Task<string> DownloadStringAsync(string url)
    {
        using var response = await HttpClient.GetAsync(url).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
    }

    private static IReadOnlyList<string> GetTargetSpecs(string templatePath, SyncPlatform platform)
    {
        var marker = GetPlatformMarker(platform) + ":";
        var specs = new List<string>();

        foreach (var line in File.ReadLines(templatePath))
        {
            var trimmedLine = line.Trim();

            if (trimmedLine.StartsWith('#'))
            {
                trimmedLine = trimmedLine[1..].Trim();
            }
            else if (trimmedLine.StartsWith(';'))
            {
                trimmedLine = trimmedLine[1..].Trim();
            }

            if (!trimmedLine.StartsWith(marker, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var pathSpec = trimmedLine[marker.Length..].Trim();
            if (pathSpec.Length == 0)
            {
                throw new InvalidOperationException($"Empty {marker} marker found in {templatePath}");
            }

            specs.Add(pathSpec);
        }

        return specs;
    }

    private static string? ExpandTargetPath(string pathSpec, SyncPlatform platform)
    {
        var expanded = Environment.ExpandEnvironmentVariables(pathSpec);

        if (expanded.StartsWith("~/", StringComparison.Ordinal) || expanded.StartsWith("~\\", StringComparison.Ordinal))
        {
            var homeDirectory = GetHomeDirectory();
            if (string.IsNullOrWhiteSpace(homeDirectory))
            {
                return expanded;
            }

            return Path.Combine(homeDirectory, expanded[2..]);
        }

        if (platform == SyncPlatform.Windows && UnresolvedWindowsEnvironmentVariablePattern.IsMatch(expanded))
        {
            return null;
        }

        return expanded;
    }

    private static string GetHomeDirectory()
    {
        return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private static ConfigFormat GetConfigFormat(string templatePath, string destinationPath)
    {
        var templateName = Path.GetFileName(templatePath);
        var destinationName = Path.GetFileName(destinationPath);
        var extension = Path.GetExtension(templatePath).ToLowerInvariant();

        if (string.Equals(templateName, ".npmrc", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(destinationName, "rc", StringComparison.OrdinalIgnoreCase))
        {
            return ConfigFormat.Ini;
        }

        if (extension is ".yml" or ".yaml")
        {
            return ConfigFormat.Yaml;
        }

        if (extension == ".toml")
        {
            return ConfigFormat.Toml;
        }

        throw new InvalidOperationException($"Unsupported config format for {templatePath}");
    }

    private static string NewQualifiedKey(string section, string key)
    {
        return $"{section.Trim()}\n{key.Trim()}".ToLowerInvariant();
    }

    private static bool TryGetIniKey(string line, out string key)
    {
        key = string.Empty;

        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed.StartsWith('#') || trimmed.StartsWith(';'))
        {
            return false;
        }

        var separatorIndex = line.IndexOf('=');
        if (separatorIndex < 1)
        {
            return false;
        }

        var candidateKey = line[..separatorIndex].Trim();
        if (candidateKey.Length == 0)
        {
            return false;
        }

        key = candidateKey;
        return true;
    }

    private static bool TryGetYamlTopLevelKey(string line, out string key)
    {
        key = string.Empty;

        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed.StartsWith('#'))
        {
            return false;
        }

        if (line.Length != line.TrimStart().Length)
        {
            return false;
        }

        var separatorIndex = line.IndexOf(':');
        if (separatorIndex < 1)
        {
            return false;
        }

        var candidateKey = line[..separatorIndex].Trim();
        if (candidateKey.Length == 0)
        {
            return false;
        }

        key = candidateKey;
        return true;
    }

    private static bool TryGetTomlSectionName(string line, out string sectionName)
    {
        sectionName = string.Empty;

        var trimmed = line.Trim();
        if (trimmed.Length < 3)
        {
            return false;
        }

        if (!trimmed.StartsWith('[') || !trimmed.EndsWith(']'))
        {
            return false;
        }

        var candidateName = trimmed[1..^1].Trim();
        if (candidateName.Length == 0)
        {
            return false;
        }

        sectionName = candidateName;
        return true;
    }

    private static bool TryGetTomlKey(string line, out string key)
    {
        key = string.Empty;

        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed.StartsWith('#'))
        {
            return false;
        }

        if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
        {
            return false;
        }

        var separatorIndex = line.IndexOf('=');
        if (separatorIndex < 1)
        {
            return false;
        }

        var candidateKey = line[..separatorIndex].Trim();
        if (candidateKey.Length == 0)
        {
            return false;
        }

        key = candidateKey;
        return true;
    }

    private static string ConvertYamlLineToRcLine(string line)
    {
        var separatorIndex = line.IndexOf(':');
        if (separatorIndex < 1)
        {
            throw new InvalidOperationException($"Unsupported pnpm YAML line for rc conversion: {line}");
        }

        var key = line[..separatorIndex].Trim();
        var value = line[(separatorIndex + 1)..].Trim();
        return $"{key}={value}";
    }

    private static IReadOnlyList<TemplateEntry> GetTemplateEntries(string templatePath, string destinationPath)
    {
        var format = GetConfigFormat(templatePath, destinationPath);
        var templateName = Path.GetFileName(templatePath);
        var destinationName = Path.GetFileName(destinationPath);
        var entries = new List<TemplateEntry>();

        switch (format)
        {
            case ConfigFormat.Ini:
                foreach (var line in File.ReadLines(templatePath))
                {
                    if (string.Equals(templateName, "config.yaml", StringComparison.OrdinalIgnoreCase) &&
                        string.Equals(destinationName, "rc", StringComparison.OrdinalIgnoreCase))
                    {
                        if (!TryGetYamlTopLevelKey(line, out var yamlKey))
                        {
                            continue;
                        }

                        var normalizedLine = ConvertYamlLineToRcLine(line);
                        entries.Add(new TemplateEntry(string.Empty, yamlKey, NewQualifiedKey(string.Empty, yamlKey), normalizedLine));
                        continue;
                    }

                    if (!TryGetIniKey(line, out var iniKey))
                    {
                        continue;
                    }

                    entries.Add(new TemplateEntry(string.Empty, iniKey, NewQualifiedKey(string.Empty, iniKey), line.Trim()));
                }
                break;
            case ConfigFormat.Yaml:
                foreach (var line in File.ReadLines(templatePath))
                {
                    if (!TryGetYamlTopLevelKey(line, out var yamlKey))
                    {
                        continue;
                    }

                    entries.Add(new TemplateEntry(string.Empty, yamlKey, NewQualifiedKey(string.Empty, yamlKey), line.Trim()));
                }
                break;
            case ConfigFormat.Toml:
                var currentSection = string.Empty;

                foreach (var line in File.ReadLines(templatePath))
                {
                    if (TryGetTomlSectionName(line, out var sectionName))
                    {
                        currentSection = sectionName;
                        continue;
                    }

                    if (!TryGetTomlKey(line, out var tomlKey))
                    {
                        continue;
                    }

                    entries.Add(new TemplateEntry(currentSection, tomlKey, NewQualifiedKey(currentSection, tomlKey), line.Trim()));
                }
                break;
            default:
                throw new InvalidOperationException($"Unsupported merge format for {templatePath}");
        }

        return entries;
    }

    private static Dictionary<string, TemplateEntry> GetEntryLookup(IEnumerable<TemplateEntry> entries)
    {
        var lookup = new Dictionary<string, TemplateEntry>(StringComparer.OrdinalIgnoreCase);

        foreach (var entry in entries)
        {
            lookup[entry.QualifiedKey] = entry;
        }

        return lookup;
    }

    private static void AddMissingFlatEntries(List<string> outputLines, IReadOnlyList<TemplateEntry> entries, HashSet<string> seenKeys)
    {
        var missingLines = new List<string>();

        foreach (var entry in entries)
        {
            if (seenKeys.Contains(entry.QualifiedKey))
            {
                continue;
            }

            missingLines.Add(entry.Line);
            seenKeys.Add(entry.QualifiedKey);
        }

        if (missingLines.Count == 0)
        {
            return;
        }

        if (outputLines.Count > 0 && outputLines[^1] != string.Empty)
        {
            outputLines.Add(string.Empty);
        }

        outputLines.AddRange(missingLines);
    }

    private static string MergeIniContent(string templatePath, string destinationPath)
    {
        var entries = GetTemplateEntries(templatePath, destinationPath);
        var lookup = GetEntryLookup(entries);
        var seenKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        if (!File.Exists(destinationPath))
        {
            var newLines = new List<string>();
            AddMissingFlatEntries(newLines, entries, seenKeys);
            return JoinOutputLines(newLines);
        }

        var outputLines = new List<string>();

        foreach (var line in SplitLines(ReadAllText(destinationPath)))
        {
            if (!TryGetIniKey(line, out var key))
            {
                outputLines.Add(line);
                continue;
            }

            var qualifiedKey = NewQualifiedKey(string.Empty, key);
            if (!lookup.TryGetValue(qualifiedKey, out var entry))
            {
                outputLines.Add(line);
                continue;
            }

            if (seenKeys.Add(qualifiedKey))
            {
                outputLines.Add(entry.Line);
            }
        }

        AddMissingFlatEntries(outputLines, entries, seenKeys);
        return JoinOutputLines(outputLines);
    }

    private static string MergeYamlContent(string templatePath, string destinationPath)
    {
        var entries = GetTemplateEntries(templatePath, destinationPath);
        var lookup = GetEntryLookup(entries);
        var seenKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        if (!File.Exists(destinationPath))
        {
            var newLines = new List<string>();
            AddMissingFlatEntries(newLines, entries, seenKeys);
            return JoinOutputLines(newLines);
        }

        var outputLines = new List<string>();

        foreach (var line in SplitLines(ReadAllText(destinationPath)))
        {
            if (!TryGetYamlTopLevelKey(line, out var key))
            {
                outputLines.Add(line);
                continue;
            }

            var qualifiedKey = NewQualifiedKey(string.Empty, key);
            if (!lookup.TryGetValue(qualifiedKey, out var entry))
            {
                outputLines.Add(line);
                continue;
            }

            if (seenKeys.Add(qualifiedKey))
            {
                outputLines.Add(entry.Line);
            }
        }

        AddMissingFlatEntries(outputLines, entries, seenKeys);
        return JoinOutputLines(outputLines);
    }

    private static void AddMissingTomlEntriesForSection(List<string> outputLines, IReadOnlyList<TemplateEntry> entries, string section, HashSet<string> seenKeys, bool createSectionHeader = false)
    {
        var sectionEntries = entries
            .Where(entry => string.Equals(entry.Section, section, StringComparison.Ordinal) && !seenKeys.Contains(entry.QualifiedKey))
            .ToArray();

        if (sectionEntries.Length == 0)
        {
            return;
        }

        if (createSectionHeader)
        {
            if (outputLines.Count > 0 && outputLines[^1] != string.Empty)
            {
                outputLines.Add(string.Empty);
            }

            outputLines.Add($"[{section}]");
        }

        foreach (var entry in sectionEntries)
        {
            outputLines.Add(entry.Line);
            seenKeys.Add(entry.QualifiedKey);
        }
    }

    private static string MergeTomlContent(string templatePath, string destinationPath)
    {
        var entries = GetTemplateEntries(templatePath, destinationPath);
        var lookup = GetEntryLookup(entries);
        var seenKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var knownSections = GetOrderedSections(entries);

        if (!File.Exists(destinationPath))
        {
            var newLines = new List<string>();
            AddMissingTomlEntriesForSection(newLines, entries, string.Empty, seenKeys);

            foreach (var section in knownSections)
            {
                if (section.Length == 0)
                {
                    continue;
                }

                AddMissingTomlEntriesForSection(newLines, entries, section, seenKeys, createSectionHeader: true);
            }

            return JoinOutputLines(newLines);
        }

        var outputLines = new List<string>();
        var existingSections = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var currentSection = string.Empty;
        var sawAnySection = false;

        foreach (var line in SplitLines(ReadAllText(destinationPath)))
        {
            if (TryGetTomlSectionName(line, out var sectionName))
            {
                if (!sawAnySection)
                {
                    AddMissingTomlEntriesForSection(outputLines, entries, string.Empty, seenKeys);
                    sawAnySection = true;
                }
                else
                {
                    AddMissingTomlEntriesForSection(outputLines, entries, currentSection, seenKeys);
                }

                currentSection = sectionName;
                existingSections.Add(sectionName);
                outputLines.Add(line);
                continue;
            }

            if (!TryGetTomlKey(line, out var key))
            {
                outputLines.Add(line);
                continue;
            }

            var qualifiedKey = NewQualifiedKey(currentSection, key);
            if (!lookup.TryGetValue(qualifiedKey, out var entry))
            {
                outputLines.Add(line);
                continue;
            }

            if (seenKeys.Add(qualifiedKey))
            {
                outputLines.Add(entry.Line);
            }
        }

        if (sawAnySection)
        {
            AddMissingTomlEntriesForSection(outputLines, entries, currentSection, seenKeys);
        }
        else
        {
            AddMissingTomlEntriesForSection(outputLines, entries, string.Empty, seenKeys);
        }

        foreach (var section in knownSections)
        {
            if (section.Length == 0 || existingSections.Contains(section))
            {
                continue;
            }

            AddMissingTomlEntriesForSection(outputLines, entries, section, seenKeys, createSectionHeader: true);
        }

        return JoinOutputLines(outputLines);
    }

    private static IReadOnlyList<string> GetOrderedSections(IEnumerable<TemplateEntry> entries)
    {
        var orderedSections = new List<string>();
        var seenSections = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var entry in entries)
        {
            if (seenSections.Add(entry.Section))
            {
                orderedSections.Add(entry.Section);
            }
        }

        return orderedSections;
    }

    private static string MergeConfigContent(string templatePath, string destinationPath)
    {
        return GetConfigFormat(templatePath, destinationPath) switch
        {
            ConfigFormat.Ini => MergeIniContent(templatePath, destinationPath),
            ConfigFormat.Yaml => MergeYamlContent(templatePath, destinationPath),
            ConfigFormat.Toml => MergeTomlContent(templatePath, destinationPath),
            _ => throw new InvalidOperationException($"Unsupported merge format for {templatePath}")
        };
    }

    private static string WriteFileIfChanged(string filePath, string content)
    {
        if (File.Exists(filePath))
        {
            var existing = ReadAllText(filePath);
            if (string.Equals(existing, content, StringComparison.Ordinal))
            {
                return "unchanged";
            }
        }

        EnsureParentDirectory(filePath);
        File.WriteAllText(filePath, content, Utf8NoBom);
        return "updated";
    }

    private static void EnsureParentDirectory(string filePath)
    {
        var parent = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrWhiteSpace(parent) && !Directory.Exists(parent))
        {
            Directory.CreateDirectory(parent);
        }
    }

    private static string ReadAllText(string filePath)
    {
        return File.ReadAllText(filePath);
    }

    private static string[] SplitLines(string content)
    {
        return Regex.Split(content, "\\r?\\n");
    }

    private static string JoinOutputLines(IEnumerable<string> lines)
    {
        return string.Join(Environment.NewLine, lines).TrimEnd() + Environment.NewLine;
    }

    private sealed class Options
    {
        public string GitHubRepository { get; set; } = DefaultGitHubRepository;
        public string GitRef { get; set; } = DefaultGitRef;
        public bool ForceRemoteTemplates { get; set; }
        public bool KeepDownloadedTemplates { get; set; }
        public bool Verbose { get; set; }
        public bool ShowHelp { get; set; }
    }

    private sealed record TemplateSource(string TemplatesRoot, string? CacheRoot, string Source);

    private sealed record TemplateEntry(string Section, string Key, string QualifiedKey, string Line);

    private enum SyncPlatform
    {
        Windows,
        Linux,
        MacOs
    }

    private enum ConfigFormat
    {
        Ini,
        Yaml,
        Toml
    }
}
