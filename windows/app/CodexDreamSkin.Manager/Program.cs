using System.Reflection;

namespace CodexDreamSkin.Manager;

internal static class Program
{
  private const string MutexName = @"Local\CodexDreamSkin.Manager";
  private const string ProductName = "Codex 动态壁纸";

  [STAThread]
  private static int Main(string[] args)
  {
    // PerMonitorV2 must be active before the first window (including the
    // single-instance notice below) so text and layout render natively at any
    // DPI. The application manifest is the primary declaration; this call is
    // the fallback when the manifest is stripped or the host ignores it.
    Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
    Application.EnableVisualStyles();
    Application.SetCompatibleTextRenderingDefault(false);

    using var mutex = new Mutex(true, MutexName, out var createdNew);
    if (!createdNew && !args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
    {
      MessageBox.Show(
        $"{ProductName}已经在运行，请查看任务栏托盘。",
        ProductName,
        MessageBoxButtons.OK,
        MessageBoxIcon.Information);
      return 0;
    }

    try
    {
      var runtime = new RuntimeProvisioner();
      runtime.EnsureExtracted();

      if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
      {
        return SelfTest.Run(runtime);
      }

      var settings = new SettingsStore();
      var service = new DreamSkinService(runtime);
      var minimized = args.Contains("--minimized", StringComparer.OrdinalIgnoreCase);
      Application.Run(new MainForm(service, settings, minimized));
      return 0;
    }
    catch (Exception exception)
    {
      var logPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodexDreamSkin",
        "manager-error.log");
      try
      {
        Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
        File.AppendAllText(logPath, $"[{DateTimeOffset.Now:O}] {exception}\r\n");
      }
      catch
      {
        // The original exception is more important than secondary logging.
      }

      MessageBox.Show(
        $"启动失败：{exception.Message}\r\n\r\n日志：{logPath}",
        ProductName,
        MessageBoxButtons.OK,
        MessageBoxIcon.Error);
      return 1;
    }
  }
}

internal static class SelfTest
{
  public static int Run(RuntimeProvisioner runtime)
  {
    try
    {
      runtime.ValidateExtractedPayload();
      if (!WallpaperCatalog.IsSupported("sample.mp4") ||
          !WallpaperCatalog.IsSupported("sample.webp") ||
          WallpaperCatalog.IsSupported("sample.exe"))
      {
        return 2;
      }

      var version = Assembly.GetExecutingAssembly().GetName().Version;
      if (version is null)
      {
        return 3;
      }
      return RunnerReturnsAfterParentExit(runtime) ? 0 : 5;
    }
    catch
    {
      return 4;
    }
  }

  private static bool RunnerReturnsAfterParentExit(RuntimeProvisioner runtime)
  {
    var temporary = Path.Combine(
      Path.GetTempPath(),
      "codex-dream-skin-runner-test-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(temporary);
    var script = Path.Combine(temporary, "parent-exits-first.ps1");
    int? childProcessId = null;
    try
    {
      File.WriteAllText(
        script,
        """
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $stdout = Join-Path $PSScriptRoot 'child-stdout.log'
        $stderr = Join-Path $PSScriptRoot 'child-stderr.log'
        $pidFile = Join-Path $PSScriptRoot 'child.pid'
        $child = Start-Process -FilePath $powershell -ArgumentList @(
          '-NoProfile', '-Command', 'Start-Sleep -Seconds 5'
        ) -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        Set-Content -LiteralPath $pidFile -Value $child.Id -Encoding Ascii
        """,
        new System.Text.UTF8Encoding(false));

      using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(8));
      var stopwatch = System.Diagnostics.Stopwatch.StartNew();
      var result = new PowerShellRunner(runtime)
        .RunScriptAsync(
          script,
          Array.Empty<string>(),
          cancellation.Token,
          captureOutput: false)
        .GetAwaiter()
        .GetResult();
      stopwatch.Stop();

      var pidFile = Path.Combine(temporary, "child.pid");
      if (File.Exists(pidFile) &&
          int.TryParse(File.ReadAllText(pidFile).Trim(), out var parsedProcessId))
      {
        childProcessId = parsedProcessId;
      }

      return result.ExitCode == 0 &&
        childProcessId.HasValue &&
        stopwatch.Elapsed < TimeSpan.FromSeconds(3);
    }
    finally
    {
      if (childProcessId.HasValue)
      {
        try
        {
          using var child = System.Diagnostics.Process.GetProcessById(childProcessId.Value);
          if (!child.HasExited &&
              child.ProcessName.Equals("powershell", StringComparison.OrdinalIgnoreCase))
          {
            child.Kill(entireProcessTree: true);
            child.WaitForExit(1000);
          }
        }
        catch
        {
          // The short-lived test child may have already exited.
        }
      }
      Directory.Delete(temporary, true);
    }
  }
}
