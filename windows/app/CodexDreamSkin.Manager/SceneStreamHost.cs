using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace CodexDreamSkin.Manager;

internal sealed class SceneStreamHost : IDisposable
{
  private readonly RuntimeProvisioner _runtime;
  private Process? _process;
  private string? _streamFile;
  private bool _disposed;

  public SceneStreamHost(RuntimeProvisioner runtime)
  {
    _runtime = runtime;
  }

  public async Task<string> StartAsync(string scenePath, CancellationToken cancellationToken)
  {
    ObjectDisposedException.ThrowIf(_disposed, this);
    await StopAsync();

    var fullScenePath = Path.GetFullPath(scenePath);
    if (!File.Exists(fullScenePath) ||
        !Path.GetFileName(fullScenePath).Equals("scene.pkg", StringComparison.OrdinalIgnoreCase))
    {
      throw new InvalidOperationException("Wallpaper Engine 场景文件无效。");
    }
    var projectDirectory = Path.GetDirectoryName(fullScenePath)
      ?? throw new InvalidOperationException("Wallpaper Engine 场景目录无效。");
    var workshopRoot = Directory.GetParent(projectDirectory)?.FullName
      ?? throw new InvalidOperationException("Wallpaper Engine Workshop 目录无效。");
    if (!Path.GetFileName(projectDirectory).All(char.IsDigit) ||
        !workshopRoot.EndsWith(
          Path.Combine("steamapps", "workshop", "content", "431960"),
          StringComparison.OrdinalIgnoreCase))
    {
      throw new InvalidOperationException("场景文件不在受支持的 Wallpaper Engine Workshop 目录中。");
    }

    var steamApps = Directory.GetParent(
      Directory.GetParent(
        Directory.GetParent(workshopRoot)?.FullName
          ?? string.Empty)?.FullName
        ?? string.Empty)?.FullName;
    var assetsPath = string.IsNullOrWhiteSpace(steamApps)
      ? null
      : Path.Combine(steamApps, "common", "wallpaper_engine", "assets");
    if (string.IsNullOrWhiteSpace(assetsPath) || !Directory.Exists(assetsPath))
    {
      throw new InvalidOperationException("未找到 Wallpaper Engine assets 目录，请确认 Wallpaper Engine 已安装。");
    }

    var viewerPath = ResolveViewerPath();
    var streamDirectory = Path.Combine(_runtime.StateRoot, "scene-stream");
    Directory.CreateDirectory(streamDirectory);
    _streamFile = Path.Combine(streamDirectory, $"{Guid.NewGuid():N}.mp4");
    var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();

    var startInfo = new ProcessStartInfo
    {
      FileName = viewerPath,
      UseShellExecute = false,
      CreateNoWindow = true,
      RedirectStandardInput = true,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      StandardInputEncoding = new UTF8Encoding(false),
      StandardOutputEncoding = new UTF8Encoding(false),
      StandardErrorEncoding = new UTF8Encoding(false),
    };
    startInfo.ArgumentList.Add("--stdin-json");
    startInfo.ArgumentList.Add("--resolution");
    startInfo.ArgumentList.Add("1280x720");
    startInfo.ArgumentList.Add("--fps");
    startInfo.ArgumentList.Add("15");
    startInfo.ArgumentList.Add(assetsPath);
    startInfo.ArgumentList.Add(fullScenePath);
    startInfo.Environment["WP_HEADLESS"] = "1";
    startInfo.Environment["WP_OFFSCREEN"] = "1";
    startInfo.Environment["WP_ENCODE_MP4"] = _streamFile;
    startInfo.Environment["WP_STREAM_PORT"] = "0";
    startInfo.Environment["WP_STREAM_TOKEN"] = token;

    var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
    try
    {
      if (!process.Start())
      {
        throw new InvalidOperationException("场景渲染器未能启动。");
      }
      _process = process;
      using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
      timeout.CancelAfter(TimeSpan.FromSeconds(30));
      var readyPrefix = "scene-viewer: stream ready ";
      string? streamUrl = null;
      while (!timeout.IsCancellationRequested && !process.HasExited)
      {
        var line = await process.StandardOutput.ReadLineAsync(timeout.Token);
        if (line is null)
        {
          break;
        }
        if (line.StartsWith(readyPrefix, StringComparison.Ordinal))
        {
          streamUrl = line[readyPrefix.Length..].Trim();
          break;
        }
      }
      if (streamUrl is null ||
          !Uri.TryCreate(streamUrl, UriKind.Absolute, out var uri) ||
          uri.Scheme != Uri.UriSchemeHttp ||
          !uri.Host.Equals("127.0.0.1", StringComparison.Ordinal) ||
          uri.Port < 1 ||
          !uri.AbsolutePath.Equals($"/{token}/stream.mp4", StringComparison.Ordinal))
      {
        var error = process.HasExited
          ? await process.StandardError.ReadToEndAsync(cancellationToken)
          : "场景渲染器未在 30 秒内提供有效的回环流。";
        throw new InvalidOperationException($"场景渲染器启动失败：{error.Trim()}");
      }
      _ = DrainAsync(process.StandardOutput);
      _ = DrainAsync(process.StandardError);
      return streamUrl;
    }
    catch
    {
      await StopAsync();
      throw;
    }
  }

  public async Task StopAsync()
  {
    var process = _process;
    _process = null;
    if (process is not null)
    {
      try
      {
        if (!process.HasExited)
        {
          await process.StandardInput.WriteLineAsync("{\"command\":\"shutdown\"}");
          await process.StandardInput.FlushAsync();
          using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
          try
          {
            await process.WaitForExitAsync(timeout.Token);
          }
          catch (OperationCanceledException)
          {
            process.Kill(true);
            await process.WaitForExitAsync();
          }
        }
      }
      catch
      {
        if (!process.HasExited)
        {
          process.Kill(true);
          await process.WaitForExitAsync();
        }
      }
      finally
      {
        process.Dispose();
      }
    }
    if (!string.IsNullOrWhiteSpace(_streamFile))
    {
      try
      {
        File.Delete(_streamFile);
      }
      catch (IOException)
      {
        // A closing Chromium stream may retain the file briefly; startup cleanup handles stale files.
      }
      _streamFile = null;
    }
  }

  public void Dispose()
  {
    if (_disposed)
    {
      return;
    }
    _disposed = true;
    StopAsync().GetAwaiter().GetResult();
  }

  private string ResolveViewerPath()
  {
    var configured = Environment.GetEnvironmentVariable("CODEX_DREAM_SKIN_SCENE_VIEWER");
    var candidates = new[]
    {
      configured,
      Path.Combine(_runtime.StateRoot, "scene-runtime", "SceneViewer.exe"),
      Path.Combine(AppContext.BaseDirectory, "scene-runtime", "SceneViewer.exe"),
    };
    var viewerPath = candidates.FirstOrDefault(path =>
      path is not null && !string.IsNullOrWhiteSpace(path) && File.Exists(Path.GetFullPath(path)));
    return viewerPath is null
      ? throw new InvalidOperationException(
        "未安装场景渲染侧车。请将 SceneViewer.exe 放到 " +
        Path.Combine(_runtime.StateRoot, "scene-runtime") + "。")
      : Path.GetFullPath(viewerPath);
  }

  private static async Task DrainAsync(TextReader reader)
  {
    try
    {
      while (await reader.ReadLineAsync() is not null)
      {
      }
    }
    catch
    {
      // The process owns the pipe; closure during wallpaper switching is expected.
    }
  }
}
