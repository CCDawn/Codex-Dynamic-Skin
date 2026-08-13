using System.Diagnostics;
using System.Text.Json;

namespace CodexDreamSkin.Manager;

internal sealed class DreamSkinService : IDisposable
{
  private readonly RuntimeProvisioner _runtime;
  private readonly PowerShellRunner _runner;
  private readonly SceneStreamHost _sceneStream;

  public DreamSkinService(RuntimeProvisioner runtime)
  {
    _runtime = runtime;
    _runner = new PowerShellRunner(runtime);
    _sceneStream = new SceneStreamHost(runtime);
  }

  public Func<string, bool>? ConfirmCodexRestart { get; set; }

  public async Task StartAsync(CancellationToken cancellationToken = default)
  {
    var arguments = new List<string> { "-Port", "9335" };
    var status = GetStatus();
    if (!status.WatcherRunning && status.CodexRunning)
    {
      if (ConfirmCodexRestart?.Invoke(
          "Codex 需要重启一次以启用动态壁纸，未保存的输入可能丢失。现在重启吗？") != true)
      {
        throw new OperationCanceledException("已取消启动；Codex 未发生更改。");
      }
      arguments.Add("-RestartExisting");
    }
    var result = await _runner.RunScriptAsync(
      _runtime.StartScript,
      arguments,
      cancellationToken);
    result.ThrowIfFailed("启动 Codex 动态壁纸");
  }

  public async Task<bool> RestoreActiveSceneAsync(CancellationToken cancellationToken = default)
  {
    var scenePath = await GetActiveScenePathAsync(cancellationToken);
    if (string.IsNullOrWhiteSpace(scenePath) || !File.Exists(scenePath))
    {
      return false;
    }
    await ApplyWallpaperEngineAsync(scenePath, cancellationToken);
    return true;
  }

  public async Task ApplyWallpaperAsync(string path, CancellationToken cancellationToken = default)
  {
    if (!File.Exists(path) || !WallpaperCatalog.IsSupported(path))
    {
      throw new InvalidOperationException("请选择有效的 PNG、JPEG、WebP、MP4 或 WebM 文件。");
    }

    var result = await RunManagerCommandAsync(
      new[] { "-Action", "SetWallpaper", "-Path", path },
      cancellationToken);
    result.ThrowIfFailed("切换壁纸");

    var status = GetStatus();
    if (!status.WatcherRunning)
    {
      await StartAsync(cancellationToken);
    }
  }

  public async Task<IReadOnlyList<WallpaperEngineItem>> ListWallpaperEngineAsync(
    CancellationToken cancellationToken = default)
  {
    await _sceneStream.StopAsync();
    var result = await RunManagerCommandAsync(
      new[] { "-Action", "ListWallpaperEngine" },
      cancellationToken);
    result.ThrowIfFailed("读取 Wallpaper Engine 本地壁纸");
    using var response = JsonDocument.Parse(result.StandardOutput);
    if (!response.RootElement.TryGetProperty("items", out var items) ||
        items.ValueKind != JsonValueKind.Array)
    {
      throw new InvalidOperationException("Wallpaper Engine 壁纸列表响应无效。");
    }
    return items.EnumerateArray().Select(ParseWallpaperEngineItem).ToArray();
  }

  public async Task<SavedTheme> ApplyWallpaperEngineAsync(
    string mediaPath,
    CancellationToken cancellationToken = default)
  {
    if (string.IsNullOrWhiteSpace(mediaPath))
    {
      throw new ArgumentException("Wallpaper Engine 媒体路径不能为空。", nameof(mediaPath));
    }
    ProcessResult result;
    if (Path.GetFileName(mediaPath).Equals("scene.pkg", StringComparison.OrdinalIgnoreCase))
    {
      var streamUrl = await _sceneStream.StartAsync(mediaPath, cancellationToken);
      try
      {
        result = await RunManagerCommandAsync(
          new[] { "-Action", "UseSceneStream", "-Path", mediaPath, "-StreamUrl", streamUrl },
          cancellationToken);
      }
      catch
      {
        await _sceneStream.StopAsync();
        throw;
      }
    }
    else
    {
      await _sceneStream.StopAsync();
      result = await RunManagerCommandAsync(
        new[] { "-Action", "UseWallpaperEngine", "-Path", mediaPath },
        cancellationToken);
    }
    try
    {
      result.ThrowIfFailed("应用 Wallpaper Engine 本地壁纸");
      var theme = ParseThemeResult(result.StandardOutput);
      if (!GetStatus().WatcherRunning)
      {
        await StartAsync(cancellationToken);
      }
      return theme;
    }
    catch
    {
      if (Path.GetFileName(mediaPath).Equals("scene.pkg", StringComparison.OrdinalIgnoreCase))
      {
        await _sceneStream.StopAsync();
      }
      throw;
    }
  }

  public async Task<IReadOnlyList<SavedTheme>> ListSavedThemesAsync(
    CancellationToken cancellationToken = default)
  {
    var result = await RunManagerCommandAsync(new[] { "-Action", "ListThemes" }, cancellationToken);
    result.ThrowIfFailed("读取已保存主题");
    using var response = JsonDocument.Parse(result.StandardOutput);
    if (!response.RootElement.TryGetProperty("themes", out var themes) ||
        themes.ValueKind != JsonValueKind.Array)
    {
      throw new InvalidOperationException("主题列表响应无效。");
    }
    return themes.EnumerateArray().Select(ParseSavedTheme).ToArray();
  }

  public async Task<SavedTheme> SaveCurrentThemeAsync(
    string name,
    CancellationToken cancellationToken = default)
  {
    if (string.IsNullOrWhiteSpace(name))
    {
      throw new ArgumentException("主题名称不能为空。", nameof(name));
    }
    var result = await RunManagerCommandAsync(
      new[] { "-Action", "SaveTheme", "-Name", name.Trim() },
      cancellationToken);
    result.ThrowIfFailed("保存当前主题");
    return ParseThemeResult(result.StandardOutput);
  }

  public async Task<SavedTheme> ApplySavedThemeAsync(
    string themeId,
    CancellationToken cancellationToken = default)
  {
    await _sceneStream.StopAsync();
    if (string.IsNullOrWhiteSpace(themeId))
    {
      throw new ArgumentException("主题标识不能为空。", nameof(themeId));
    }
    var result = await RunManagerCommandAsync(
      new[] { "-Action", "UseTheme", "-ThemeId", themeId },
      cancellationToken);
    result.ThrowIfFailed("应用已保存主题");
    var theme = ParseThemeResult(result.StandardOutput);
    if (!GetStatus().WatcherRunning)
    {
      await StartAsync(cancellationToken);
    }
    return theme;
  }

  public async Task SetRevealAsync(int percent, CancellationToken cancellationToken = default)
  {
    if (percent is < 0 or > 100)
    {
      throw new ArgumentOutOfRangeException(nameof(percent));
    }
    var result = await RunManagerCommandAsync(
      new[] { "-Action", "SetReveal", "-Percent", percent.ToString() },
      cancellationToken);
    result.ThrowIfFailed("调整壁纸透出程度");
  }

  public async Task SetPausedAsync(bool paused, CancellationToken cancellationToken = default)
  {
    if (!paused)
    {
      var scenePath = await GetActiveScenePathAsync(cancellationToken);
      if (!string.IsNullOrWhiteSpace(scenePath) && File.Exists(scenePath))
      {
        await ApplyWallpaperEngineAsync(scenePath, cancellationToken);
      }
    }
    var result = await RunManagerCommandAsync(
      new[] { "-Action", paused ? "Pause" : "Resume" },
      cancellationToken);
    result.ThrowIfFailed(paused ? "暂停皮肤" : "恢复皮肤");
    if (paused)
    {
      await _sceneStream.StopAsync();
    }
  }

  public async Task RestoreAsync(CancellationToken cancellationToken = default)
  {
    await _sceneStream.StopAsync();
    var arguments = new List<string> { "-Port", "9335", "-RestoreBaseTheme" };
    if (GetStatus().CodexRunning)
    {
      if (ConfirmCodexRestart?.Invoke(
          "恢复官方外观将关闭 Codex、移除动态壁纸，然后重新打开官方应用。是否继续？") != true)
      {
        throw new OperationCanceledException("已取消恢复；Codex 未发生更改。");
      }
      arguments.Add("-ForceRestart");
    }
    var result = await _runner.RunScriptAsync(
      _runtime.RestoreScript,
      arguments,
      cancellationToken);
    result.ThrowIfFailed("恢复 Codex 官方外观");
  }

  public DreamSkinStatus GetStatus()
  {
    var statePath = Path.Combine(_runtime.StateRoot, "state.json");
    var themePath = Path.Combine(_runtime.StateRoot, "active-theme", "theme.json");
    var paused = File.Exists(Path.Combine(_runtime.StateRoot, "paused"));
    var watcherRunning = false;
    string? activeTheme = null;
    string? mediaPath = null;
    WallpaperKind? mediaKind = null;
    var reveal = 100;

    try
    {
      if (File.Exists(statePath))
      {
        using var state = JsonDocument.Parse(File.ReadAllText(statePath));
        var cdpPort = state.RootElement.TryGetProperty("port", out var portElement) &&
          portElement.TryGetInt32(out var savedPort)
            ? savedPort
            : 0;
        if (state.RootElement.TryGetProperty("injectorPid", out var pidElement) &&
            pidElement.TryGetInt32(out var pid))
        {
          try
          {
            using var process = Process.GetProcessById(pid);
            watcherRunning = !process.HasExited &&
              process.ProcessName.Equals("node", StringComparison.OrdinalIgnoreCase) &&
              cdpPort is >= 1024 and <= 65535 &&
              System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties()
                .GetActiveTcpListeners()
                .Any(endpoint =>
                  endpoint.Port == cdpPort &&
                  System.Net.IPAddress.IsLoopback(endpoint.Address));
          }
          catch
          {
            watcherRunning = false;
          }
        }
      }

      if (File.Exists(themePath))
      {
        using var theme = JsonDocument.Parse(File.ReadAllText(themePath));
        if (theme.RootElement.TryGetProperty("name", out var nameElement))
        {
          activeTheme = nameElement.GetString();
        }
        if (theme.RootElement.TryGetProperty("image", out var imageElement))
        {
          var image = imageElement.GetString();
          if (!string.IsNullOrWhiteSpace(image))
          {
            mediaPath = Path.Combine(Path.GetDirectoryName(themePath)!, image);
            mediaKind = WallpaperCatalog.GetKind(mediaPath);
          }
        }
        if (theme.RootElement.TryGetProperty("media", out var mediaElement) &&
            mediaElement.TryGetProperty("opacity", out var opacityElement) &&
            opacityElement.TryGetDouble(out var opacity))
        {
          reveal = Math.Clamp((int)Math.Round(opacity * 100), 0, 100);
        }
        if (theme.RootElement.TryGetProperty("media", out mediaElement) &&
            mediaElement.TryGetProperty("type", out var mediaTypeElement) &&
            mediaTypeElement.ValueKind == JsonValueKind.String &&
            mediaTypeElement.GetString()?.Equals("scene", StringComparison.OrdinalIgnoreCase) == true)
        {
          mediaKind = WallpaperKind.Scene;
          if (mediaElement.TryGetProperty("scenePath", out var scenePathElement) &&
              scenePathElement.ValueKind == JsonValueKind.String &&
              File.Exists(scenePathElement.GetString()))
          {
            mediaPath = scenePathElement.GetString();
          }
        }
      }
    }
    catch
    {
      // Status rendering stays available even if an external process is replacing state atomically.
    }

    var codexRunning = IsAnyProcessRunning("ChatGPT") ||
      IsAnyProcessRunning("Codex");
    return new DreamSkinStatus(
      watcherRunning,
      codexRunning,
      paused,
      activeTheme,
      mediaPath,
      mediaKind,
      reveal);
  }

  private Task<ProcessResult> RunManagerCommandAsync(
    IEnumerable<string> arguments,
    CancellationToken cancellationToken) =>
    _runner.RunScriptAsync(_runtime.ManagerCommandScript, arguments, cancellationToken);

  private static SavedTheme ParseThemeResult(string json)
  {
    using var response = JsonDocument.Parse(json);
    return ParseSavedTheme(response.RootElement);
  }

  public void Dispose()
  {
    _sceneStream.Dispose();
  }

  private async Task<string?> GetActiveScenePathAsync(CancellationToken cancellationToken)
  {
    var themePath = Path.Combine(_runtime.StateRoot, "active-theme", "theme.json");
    if (!File.Exists(themePath))
    {
      return null;
    }
    using var theme = JsonDocument.Parse(await File.ReadAllTextAsync(themePath, cancellationToken));
    if (!theme.RootElement.TryGetProperty("media", out var media) ||
        !media.TryGetProperty("type", out var mediaType) ||
        !mediaType.ValueEquals("scene") ||
        !media.TryGetProperty("scenePath", out var scenePathElement))
    {
      return null;
    }
    return scenePathElement.GetString();
  }

  private static SavedTheme ParseSavedTheme(JsonElement element)
  {
    return new SavedTheme(
      RequireJsonString(element, "themeId", "id"),
      RequireJsonString(element, "name"),
      ParseWallpaperKind(RequireJsonString(element, "mediaType")));
  }

  private static WallpaperEngineItem ParseWallpaperEngineItem(JsonElement element)
  {
    if (!element.TryGetProperty("length", out var lengthElement) || !lengthElement.TryGetInt64(out var length) ||
        length < 1)
    {
      throw new InvalidOperationException("Wallpaper Engine 条目缺少有效的媒体大小。");
    }
    return new WallpaperEngineItem(
      RequireJsonString(element, "workshopId"),
      RequireJsonString(element, "name"),
      RequireJsonString(element, "workshopRoot"),
      RequireJsonString(element, "projectDirectory"),
      RequireJsonString(element, "relativePath"),
      RequireJsonString(element, "mediaPath"),
      ParseWallpaperKind(RequireJsonString(element, "mediaType")),
      length);
  }

  private static string RequireJsonString(
    JsonElement element,
    string property,
    string? fallbackProperty = null)
  {
    if (element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String &&
        !string.IsNullOrWhiteSpace(value.GetString()))
    {
      return value.GetString()!;
    }
    if (fallbackProperty is not null && element.TryGetProperty(fallbackProperty, out value) &&
        value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()))
    {
      return value.GetString()!;
    }
    throw new InvalidOperationException($"主题响应缺少有效字段：{property}。");
  }

  private static WallpaperKind ParseWallpaperKind(string mediaType) =>
    mediaType.Equals("video", StringComparison.OrdinalIgnoreCase)
      ? WallpaperKind.Video
      : mediaType.Equals("scene", StringComparison.OrdinalIgnoreCase)
        ? WallpaperKind.Scene
      : mediaType.Equals("image", StringComparison.OrdinalIgnoreCase)
        ? WallpaperKind.Image
        : throw new InvalidOperationException($"主题响应包含未知媒体类型：{mediaType}。");

  private static bool IsAnyProcessRunning(string processName)
  {
    var processes = Process.GetProcessesByName(processName);
    try
    {
      return processes.Any(process => !process.HasExited);
    }
    finally
    {
      foreach (var process in processes)
      {
        process.Dispose();
      }
    }
  }
}
