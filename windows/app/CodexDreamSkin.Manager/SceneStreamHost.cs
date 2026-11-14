using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace CodexDreamSkin.Manager;

internal sealed class SceneStreamHost : IDisposable
{
  private static readonly HttpClient StreamProbeClient = new();
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
    if (string.IsNullOrWhiteSpace(assetsPath) || !Directory.Exists(assetsPath) ||
        !Directory.EnumerateDirectories(assetsPath).Any())
    {
      throw new InvalidOperationException("未找到 Wallpaper Engine assets 目录，请确认 Wallpaper Engine 已安装。");
    }

    var viewerPath = ResolveViewerPath();
    var streamDirectory = Path.Combine(_runtime.StateRoot, "scene-stream");
    Directory.CreateDirectory(streamDirectory);
    CleanupStaleStreamFiles(streamDirectory);
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
      var errorLines = new Queue<string>();
      var errorLock = new object();
      var errorDrainTask = DrainErrorAsync(process.StandardError, errorLines, errorLock);
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
        if (process.HasExited)
        {
          await Task.WhenAny(errorDrainTask, Task.Delay(500, CancellationToken.None));
        }
        var error = SnapshotErrorLines(errorLines, errorLock);
        if (string.IsNullOrWhiteSpace(error))
        {
          error = "场景渲染器未在 30 秒内提供有效的回环流。";
        }
        throw new InvalidOperationException($"场景渲染器启动失败：{error.Trim()}");
      }
      await ValidateStreamLivenessAsync(streamUrl, cancellationToken);
      _ = DrainAsync(process.StandardOutput);
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
    var streamFile = _streamFile;
    _streamFile = null;
    if (!string.IsNullOrWhiteSpace(streamFile))
    {
      await DeleteStreamFileWithRetryAsync(streamFile);
    }
  }

  public void Dispose()
  {
    if (_disposed)
    {
      return;
    }
    _disposed = true;
    DisposeProcessImmediately();
  }

  // The "stream ready" line only proves the loopback endpoint opened; the
  // headless encoder can still produce zero frames. Probe the HTTP stream and
  // the growing capture file while the renderer is still alive, before any
  // cleanup runs, so failures surface with a precise cause.
  private async Task ValidateStreamLivenessAsync(string streamUrl, CancellationToken cancellationToken)
  {
    var readyLength = GetStreamFileLength();
    var receivedBytes = 0;
    try
    {
      using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
      timeout.CancelAfter(TimeSpan.FromSeconds(5));
      using var request = new HttpRequestMessage(HttpMethod.Get, streamUrl);
      request.Headers.Range = new RangeHeaderValue(0, 1023);
      using var response = await StreamProbeClient.SendAsync(
        request,
        HttpCompletionOption.ResponseHeadersRead,
        timeout.Token);
      if (response.StatusCode != HttpStatusCode.OK &&
          response.StatusCode != HttpStatusCode.PartialContent)
      {
        throw new InvalidOperationException(
          $"场景流不可用：回环流服务返回了 HTTP {(int)response.StatusCode}。");
      }
      await using var payload = await response.Content.ReadAsStreamAsync(timeout.Token);
      receivedBytes = await payload.ReadAsync(new byte[1024], timeout.Token);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
      throw new InvalidOperationException("场景流不可用：回环流服务未在 5 秒内返回数据。");
    }
    catch (HttpRequestException exception)
    {
      throw new InvalidOperationException($"场景流不可用：回环流服务无响应（{exception.Message}）。");
    }
    catch (IOException exception)
    {
      throw new InvalidOperationException($"场景流不可用：回环流数据读取失败（{exception.Message}）。");
    }
    if (receivedBytes < 1)
    {
      throw new InvalidOperationException("场景流不可用：回环流服务未返回任何视频数据。");
    }
    await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
    var currentLength = GetStreamFileLength();
    if (currentLength <= 0 || currentLength <= readyLength)
    {
      throw new InvalidOperationException(
        "场景渲染器已就绪但未产出任何视频数据，可能 Wallpaper Engine 安装不完整。");
    }
  }

  private long GetStreamFileLength()
  {
    var streamFile = _streamFile;
    if (string.IsNullOrWhiteSpace(streamFile) || !File.Exists(streamFile))
    {
      return 0;
    }
    try
    {
      return new FileInfo(streamFile).Length;
    }
    catch (IOException)
    {
      return 0;
    }
    catch (UnauthorizedAccessException)
    {
      return 0;
    }
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

  private static async Task DrainErrorAsync(
    TextReader reader,
    Queue<string> lines,
    object gate)
  {
    try
    {
      while (await reader.ReadLineAsync() is { } line)
      {
        lock (gate)
        {
          lines.Enqueue(line);
          while (lines.Count > 40)
          {
            lines.Dequeue();
          }
        }
      }
    }
    catch
    {
      // Process shutdown closes redirected pipes while the drain is pending.
    }
  }

  private static string SnapshotErrorLines(Queue<string> lines, object gate)
  {
    lock (gate)
    {
      return string.Join(Environment.NewLine, lines);
    }
  }

  private static void CleanupStaleStreamFiles(string directory)
  {
    var cutoff = DateTime.UtcNow - TimeSpan.FromMinutes(10);
    foreach (var path in Directory.EnumerateFiles(directory, "*.mp4", SearchOption.TopDirectoryOnly))
    {
      try
      {
        if (File.GetLastWriteTimeUtc(path) < cutoff)
        {
          File.Delete(path);
        }
      }
      catch (IOException)
      {
        // Another stream host may still own the file; a future start can retry.
      }
      catch (UnauthorizedAccessException)
      {
        // Keep startup available even if an old file has restrictive permissions.
      }
    }
  }

  private static async Task DeleteStreamFileWithRetryAsync(string path)
  {
    for (var attempt = 0; attempt < 5; attempt += 1)
    {
      try
      {
        File.Delete(path);
        return;
      }
      catch (IOException)
      {
        if (attempt == 4)
        {
          return;
        }
        await Task.Delay(100 * (attempt + 1));
      }
      catch (UnauthorizedAccessException)
      {
        if (attempt == 4)
        {
          return;
        }
        await Task.Delay(100 * (attempt + 1));
      }
    }
  }

  private void DisposeProcessImmediately()
  {
    var process = _process;
    _process = null;
    if (process is not null)
    {
      try
      {
        if (!process.HasExited)
        {
          process.Kill(entireProcessTree: true);
        }
      }
      catch
      {
        // Disposal is best-effort and must not block the WinForms UI thread.
      }
      finally
      {
        process.Dispose();
      }
    }

    var streamFile = _streamFile;
    _streamFile = null;
    if (!string.IsNullOrWhiteSpace(streamFile))
    {
      try
      {
        File.Delete(streamFile);
      }
      catch
      {
        // Startup cleanup removes any file still held by a closing stream client.
      }
    }
  }
}
