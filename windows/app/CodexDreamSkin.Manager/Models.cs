using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexDreamSkin.Manager;

internal enum WallpaperKind
{
  Image,
  Video,
  Scene,
}

internal enum WallpaperSource
{
  Library,
  WallpaperEngine,
}

internal sealed class WallpaperEngineReference
{
  public string WorkshopId { get; set; } = string.Empty;
  public string WorkshopRoot { get; set; } = string.Empty;
  public string RelativePath { get; set; } = string.Empty;
  public string Name { get; set; } = string.Empty;
}

internal sealed record WallpaperItem(
  string Path,
  string Name,
  string Extension,
  WallpaperKind Kind,
  long Length,
  DateTime LastWriteTime,
  WallpaperSource Source = WallpaperSource.Library,
  WallpaperEngineReference? WallpaperEngineReference = null)
{
  public string TypeLabel => Kind switch
  {
    WallpaperKind.Video => "动态壁纸",
    WallpaperKind.Scene => "场景壁纸",
    _ => "静态壁纸",
  };
  public string SourceLabel => Source == WallpaperSource.WallpaperEngine
    ? $"Wallpaper Engine · {TypeLabel}"
    : TypeLabel;
  public string SizeLabel => Length >= 1024L * 1024L
    ? $"{Length / 1024d / 1024d:0.#} MB"
    : $"{Math.Max(1, Length / 1024d):0} KB";
}

internal sealed record SavedTheme(string Id, string Name, WallpaperKind Kind)
{
  public string TypeLabel => Kind switch
  {
    WallpaperKind.Video => "动态壁纸",
    WallpaperKind.Scene => "场景壁纸",
    _ => "静态壁纸",
  };

  public override string ToString() => $"{Name} · {TypeLabel}";
}

internal sealed record WallpaperEngineItem(
  string WorkshopId,
  string Name,
  string WorkshopRoot,
  string ProjectDirectory,
  string RelativePath,
  string MediaPath,
  WallpaperKind Kind,
  long Length)
{
  public string TypeLabel => Kind switch
  {
    WallpaperKind.Video => "动态壁纸",
    WallpaperKind.Scene => "场景壁纸",
    _ => "静态壁纸",
  };

  public string SizeLabel => Length >= 1024L * 1024L
    ? $"{Length / 1024d / 1024d:0.#} MB"
    : $"{Math.Max(1, Length / 1024d):0} KB";

  public override string ToString() => $"{Name} · {TypeLabel} · {SizeLabel}";
}

internal sealed record DreamSkinStatus(
  bool WatcherRunning,
  bool CodexRunning,
  bool Paused,
  string? ActiveTheme,
  string? MediaPath,
  WallpaperKind? MediaKind,
  int RevealPercent)
{
  public string Summary => Paused
    ? CodexRunning
      ? "Codex 已打开 · 壁纸已暂停"
      : "Codex 未打开 · 壁纸已暂停"
    : WatcherRunning
      ? CodexRunning
        ? "Codex 已连接 · 壁纸运行中"
        : "Codex 未打开 · 壁纸服务运行中"
      : CodexRunning
        ? "Codex 已打开 · 壁纸未启动"
        : "Codex 未打开 · 壁纸未启动";

  public string CurrentWallpaperLabel => !string.IsNullOrWhiteSpace(ActiveTheme)
    ? ActiveTheme
    : !string.IsNullOrWhiteSpace(MediaPath)
      ? Path.GetFileNameWithoutExtension(MediaPath)
      : "未设置";
}

internal sealed class AppSettings
{
  public string LibraryPath { get; set; } = SettingsStore.DefaultLibraryPath;
  public bool StartWithWindows { get; set; }
  public List<WallpaperEngineReference> WallpaperEngineImports { get; set; } = new();
}

internal sealed class SettingsStore
{
  private static readonly JsonSerializerOptions JsonOptions = new()
  {
    WriteIndented = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
  };

  public static string DefaultLibraryPath => Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
    "Codex壁纸库");

  public SettingsStore()
  {
    SettingsPath = Path.Combine(
      Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
      "CodexDreamSkin",
      "manager-settings.json");
  }

  public string SettingsPath { get; }

  public AppSettings Load()
  {
    try
    {
      if (!File.Exists(SettingsPath))
      {
        return new AppSettings();
      }

      var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions)
        ?? new AppSettings();
      if (string.IsNullOrWhiteSpace(settings.LibraryPath))
      {
        settings.LibraryPath = DefaultLibraryPath;
      }
      settings.WallpaperEngineImports ??= new List<WallpaperEngineReference>();
      return settings;
    }
    catch
    {
      return new AppSettings();
    }
  }

  public void Save(AppSettings settings)
  {
    var directory = Path.GetDirectoryName(SettingsPath)!;
    Directory.CreateDirectory(directory);
    var temporary = SettingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      File.WriteAllText(temporary, JsonSerializer.Serialize(settings, JsonOptions));
      File.Move(temporary, SettingsPath, true);
    }
    finally
    {
      if (File.Exists(temporary))
      {
        File.Delete(temporary);
      }
    }
  }
}
