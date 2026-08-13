namespace CodexDreamSkin.Manager;

internal static class WallpaperEngineReferenceCatalog
{
  private static readonly string WorkshopContentSuffix = Path.Combine(
    "steamapps", "workshop", "content", "431960");

  public static int AddImports(
    IList<WallpaperEngineReference> imports,
    IEnumerable<WallpaperEngineItem> items)
  {
    var added = 0;
    foreach (var item in items)
    {
      if (imports.Any(import => SameReference(import, item)))
      {
        continue;
      }
      imports.Add(new WallpaperEngineReference
      {
        WorkshopId = item.WorkshopId,
        WorkshopRoot = item.WorkshopRoot,
        RelativePath = item.RelativePath,
        Name = item.Name,
      });
      added++;
    }
    return added;
  }

  public static IReadOnlyList<WallpaperItem> ResolveAndPrune(
    IList<WallpaperEngineReference> imports,
    string? search,
    out bool changed)
  {
    changed = false;
    var normalizedSearch = search?.Trim();
    var resolved = new List<WallpaperItem>();
    for (var index = imports.Count - 1; index >= 0; index--)
    {
      if (!TryResolve(imports[index], out var item))
      {
        imports.RemoveAt(index);
        changed = true;
        continue;
      }
      if (string.IsNullOrWhiteSpace(normalizedSearch) ||
          item.Name.Contains(normalizedSearch, StringComparison.CurrentCultureIgnoreCase) ||
          item.Path.Contains(normalizedSearch, StringComparison.CurrentCultureIgnoreCase))
      {
        resolved.Add(item);
      }
    }
    return resolved
      .OrderByDescending(item => item.LastWriteTime)
      .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
      .ToArray();
  }

  public static string GetPreviewPath(WallpaperItem item)
  {
    if (item.Kind != WallpaperKind.Scene)
    {
      return item.Path;
    }
    try
    {
      var directory = Path.GetDirectoryName(item.Path);
      if (directory is null)
      {
        return item.Path;
      }
      var supported = new HashSet<string>(
        new[] { ".jpg", ".jpeg", ".png", ".webp", ".gif" },
        StringComparer.OrdinalIgnoreCase);
      var preview = Directory.EnumerateFiles(directory, "preview.*", SearchOption.TopDirectoryOnly)
        .FirstOrDefault(path => supported.Contains(Path.GetExtension(path)));
      return preview ?? item.Path;
    }
    catch (IOException)
    {
      return item.Path;
    }
    catch (UnauthorizedAccessException)
    {
      return item.Path;
    }
  }

  private static bool SameReference(WallpaperEngineReference import, WallpaperEngineItem item) =>
    import.WorkshopId.Equals(item.WorkshopId, StringComparison.Ordinal) &&
    import.WorkshopRoot.Equals(item.WorkshopRoot, StringComparison.OrdinalIgnoreCase) &&
    import.RelativePath.Equals(item.RelativePath, StringComparison.OrdinalIgnoreCase);

  private static bool TryResolve(
    WallpaperEngineReference import,
    out WallpaperItem item)
  {
    item = null!;
    try
    {
      if (!IsSafeReference(import))
      {
        return false;
      }
      var workshopRoot = Path.GetFullPath(import.WorkshopRoot).TrimEnd(Path.DirectorySeparatorChar);
      var workshopDirectory = Path.Combine(workshopRoot, import.WorkshopId);
      var mediaPath = Path.GetFullPath(Path.Combine(workshopDirectory, import.RelativePath));
      var isScene = Path.GetFileName(mediaPath).Equals("scene.pkg", StringComparison.OrdinalIgnoreCase);
      if (!IsInside(workshopRoot, workshopDirectory) || !IsInside(workshopDirectory, mediaPath) ||
          !File.Exists(mediaPath) || (File.GetAttributes(mediaPath) & FileAttributes.ReparsePoint) != 0 ||
          (!isScene &&
            (!WallpaperCatalog.IsSupported(mediaPath) ||
             WallpaperCatalog.GetKind(mediaPath) != WallpaperKind.Video)))
      {
        return false;
      }
      var name = IsSafeName(import.Name)
        ? import.Name.Trim()
        : Path.GetFileNameWithoutExtension(mediaPath);
      var info = new FileInfo(mediaPath);
      item = new WallpaperItem(
        info.FullName,
        name,
        info.Extension.ToUpperInvariant(),
        isScene ? WallpaperKind.Scene : WallpaperKind.Video,
        info.Length,
        info.LastWriteTime,
        WallpaperSource.WallpaperEngine,
        import);
      return true;
    }
    catch (IOException)
    {
      return false;
    }
    catch (UnauthorizedAccessException)
    {
      return false;
    }
  }

  private static bool IsSafeReference(WallpaperEngineReference import)
  {
    if (string.IsNullOrWhiteSpace(import.WorkshopRoot) || string.IsNullOrWhiteSpace(import.WorkshopId) ||
        string.IsNullOrWhiteSpace(import.RelativePath) || !Path.IsPathRooted(import.WorkshopRoot) ||
        Path.IsPathRooted(import.RelativePath) || !System.Text.RegularExpressions.Regex.IsMatch(import.WorkshopId, "^\\d{1,20}$"))
    {
      return false;
    }
    var normalizedRoot = Path.GetFullPath(import.WorkshopRoot).TrimEnd(Path.DirectorySeparatorChar);
    return normalizedRoot.EndsWith(WorkshopContentSuffix, StringComparison.OrdinalIgnoreCase);
  }

  private static bool IsSafeName(string? value) => !string.IsNullOrWhiteSpace(value) &&
    value.Trim().Length <= 120 && !value.Any(char.IsControl);

  private static bool IsInside(string root, string candidate)
  {
    var relative = Path.GetRelativePath(root, candidate);
    return !string.IsNullOrWhiteSpace(relative) && !Path.IsPathRooted(relative) &&
      !relative.Equals("..", StringComparison.Ordinal) &&
      !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal);
  }
}
