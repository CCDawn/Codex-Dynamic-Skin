using System.IO;
using System.Reflection;
using System.Security.Cryptography;

namespace CodexDreamSkin.Manager;

internal sealed class RuntimeProvisioner
{
  private const string ResourcePrefix = "DreamSkin.";
  private static readonly IReadOnlyDictionary<string, string> ResourceMap =
    new Dictionary<string, string>(StringComparer.Ordinal)
    {
      ["Engine.assets.dream-reference.jpg"] = @"payload\assets\dream-reference.jpg",
      ["Engine.assets.dream-skin.css"] = @"payload\assets\dream-skin.css",
      ["Engine.assets.renderer-inject.js"] = @"payload\assets\renderer-inject.js",
      ["Engine.assets.safe-css-validator.mjs"] = @"payload\assets\safe-css-validator.mjs",
      ["Engine.assets.selectors.json"] = @"payload\assets\selectors.json",
      ["Engine.assets.theme-package-validator.mjs"] = @"payload\assets\theme-package-validator.mjs",
      ["Engine.assets.theme-preferences.mjs"] = @"payload\assets\theme-preferences.mjs",
      ["Engine.assets.theme.json"] = @"payload\assets\theme.json",
      ["Engine.assets.theme-manager.DreamSkin.ThemeManager.exe"] = @"payload\assets\theme-manager\DreamSkin.ThemeManager.exe",
      ["Engine.scripts.common-windows.ps1"] = @"payload\scripts\common-windows.ps1",
      ["Engine.scripts.config-utf8.ps1"] = @"payload\scripts\config-utf8.ps1",
      ["Engine.scripts.image-metadata.mjs"] = @"payload\scripts\image-metadata.mjs",
      ["Engine.scripts.injector.mjs"] = @"payload\scripts\injector.mjs",
      ["Engine.scripts.install-dream-skin.ps1"] = @"payload\scripts\install-dream-skin.ps1",
      ["Engine.scripts.localization-windows.ps1"] = @"payload\scripts\localization-windows.ps1",
      ["Engine.scripts.manager-command.ps1"] = @"payload\scripts\manager-command.ps1",
      ["Engine.scripts.restore-dream-skin.ps1"] = @"payload\scripts\restore-dream-skin.ps1",
      ["Engine.scripts.start-dream-skin.ps1"] = @"payload\scripts\start-dream-skin.ps1",
      ["Engine.scripts.theme-windows.ps1"] = @"payload\scripts\theme-windows.ps1",
      ["Engine.scripts.tray-dream-skin.ps1"] = @"payload\scripts\tray-dream-skin.ps1",
      ["Engine.scripts.verify-dream-skin.ps1"] = @"payload\scripts\verify-dream-skin.ps1",
      ["Runtime.node.exe"] = @"node\node.exe",
      ["Runtime.NODE-LICENSE.txt"] = @"node\NODE-LICENSE.txt",
    };

  private readonly Assembly _assembly = Assembly.GetExecutingAssembly();

  public RuntimeProvisioner()
  {
    StateRoot = Path.Combine(
      Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
      "CodexDreamSkin");
    var version = _assembly.GetName().Version?.ToString(3) ?? "1.0.0";
    RuntimeRoot = Path.Combine(StateRoot, "manager-runtime", version);
    PayloadRoot = Path.Combine(RuntimeRoot, "payload");
    ScriptsRoot = Path.Combine(PayloadRoot, "scripts");
    NodePath = Path.Combine(RuntimeRoot, "node", "node.exe");
  }

  public string StateRoot { get; }
  public string RuntimeRoot { get; }
  public string PayloadRoot { get; }
  public string ScriptsRoot { get; }
  public string NodePath { get; }
  public string StartScript => Path.Combine(ScriptsRoot, "start-dream-skin.ps1");
  public string RestoreScript => Path.Combine(ScriptsRoot, "restore-dream-skin.ps1");
  public string ManagerCommandScript => Path.Combine(ScriptsRoot, "manager-command.ps1");

  public void EnsureExtracted()
  {
    EnsureSafeDirectory(StateRoot, StateRoot);
    EnsureSafeDirectory(Path.Combine(StateRoot, "manager-runtime"), StateRoot);
    EnsureSafeDirectory(RuntimeRoot, StateRoot);

    foreach (var entry in ResourceMap)
    {
      var destination = Path.Combine(RuntimeRoot, entry.Value);
      ExtractAtomically(ResourcePrefix + entry.Key, destination);
    }

    ValidateExtractedPayload();
  }

  public void ValidateExtractedPayload()
  {
    foreach (var relativePath in ResourceMap.Values)
    {
      var path = Path.Combine(RuntimeRoot, relativePath);
      if (!File.Exists(path) || new FileInfo(path).Length == 0)
      {
        throw new InvalidOperationException($"嵌入运行时文件缺失：{relativePath}");
      }
    }
  }

  private void ExtractAtomically(string resourceName, string destination)
  {
    using var resource = _assembly.GetManifestResourceStream(resourceName)
      ?? throw new InvalidOperationException($"EXE 缺少嵌入资源：{resourceName}");

    var directory = Path.GetDirectoryName(destination)
      ?? throw new InvalidOperationException("嵌入资源目标目录无效。");
    EnsureSafeDirectory(directory, StateRoot);

    if (File.Exists(destination) && StreamsMatch(resource, destination))
    {
      return;
    }

    resource.Position = 0;
    var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      using (var output = new FileStream(
        temporary,
        FileMode.CreateNew,
        FileAccess.Write,
        FileShare.None,
        1024 * 1024,
        FileOptions.WriteThrough))
      {
        resource.CopyTo(output);
        output.Flush(true);
      }

      File.Move(temporary, destination, true);
    }
    finally
    {
      if (File.Exists(temporary))
      {
        File.Delete(temporary);
      }
    }
  }

  private static bool StreamsMatch(Stream resource, string destination)
  {
    if (!resource.CanSeek)
    {
      return false;
    }

    var info = new FileInfo(destination);
    if (resource.Length != info.Length)
    {
      return false;
    }

    using var resourceHash = SHA256.Create();
    var expected = resourceHash.ComputeHash(resource);
    resource.Position = 0;
    using var file = File.OpenRead(destination);
    var actual = SHA256.HashData(file);
    return CryptographicOperations.FixedTimeEquals(expected, actual);
  }

  private static void EnsureSafeDirectory(string path, string root)
  {
    var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
    var fullPath = Path.GetFullPath(path);
    if (!fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) &&
        !fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
    {
      throw new InvalidOperationException($"运行时目录越过受管根目录：{fullPath}");
    }

    var current = fullPath;
    while (!string.IsNullOrEmpty(current))
    {
      if (Directory.Exists(current))
      {
        var attributes = File.GetAttributes(current);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
          throw new InvalidOperationException($"运行时目录包含重解析点：{current}");
        }
      }

      if (current.Equals(fullRoot, StringComparison.OrdinalIgnoreCase))
      {
        break;
      }

      current = Path.GetDirectoryName(current) ?? string.Empty;
    }

    Directory.CreateDirectory(fullPath);
  }
}
