using System.Diagnostics;
using System.Text;

namespace CodexDreamSkin.Manager;

internal sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
  private const int MaxDetailLength = 1200;

  public void ThrowIfFailed(string operation)
  {
    if (ExitCode == 0)
    {
      return;
    }

    var detail = string.IsNullOrWhiteSpace(StandardError) ? StandardOutput : StandardError;
    throw new InvalidOperationException($"{operation}失败（{ExitCode}）：{Tail(detail)}");
  }

  internal static string Tail(string text)
  {
    text = text.Trim();
    if (text.Length <= MaxDetailLength)
    {
      return text;
    }
    return "…" + text[^MaxDetailLength..];
  }
}

// Accumulates partial stream output so a killed or pipe-leaked child still
// yields whatever was written before the failure instead of nothing.
internal sealed class OutputCaptureBuffer
{
  private readonly StringBuilder _builder = new();
  private readonly object _gate = new();

  public void Append(char[] buffer, int count)
  {
    lock (_gate)
    {
      _builder.Append(buffer, 0, count);
    }
  }

  public override string ToString()
  {
    lock (_gate)
    {
      return _builder.ToString();
    }
  }
}

internal sealed class PowerShellRunner
{
  // Manager commands (SetWallpaper/UseTheme/…) are quick file operations.
  public const int DefaultTimeoutMilliseconds = 120_000;
  // Start/restore may close and relaunch Codex plus run renderer verification.
  public const int StartTimeoutMilliseconds = 420_000;
  public const int RestoreTimeoutMilliseconds = 300_000;
  private static readonly TimeSpan DrainGrace = TimeSpan.FromSeconds(10);

  private readonly RuntimeProvisioner _runtime;
  private readonly string _powershellPath;

  public PowerShellRunner(RuntimeProvisioner runtime)
  {
    _runtime = runtime;
    _powershellPath = Path.Combine(
      Environment.GetFolderPath(Environment.SpecialFolder.Windows),
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe");
    if (!File.Exists(_powershellPath))
    {
      throw new FileNotFoundException("找不到 Windows PowerShell 5.1。", _powershellPath);
    }
  }

  public async Task<ProcessResult> RunScriptAsync(
    string script,
    IEnumerable<string> arguments,
    CancellationToken cancellationToken = default,
    bool captureOutput = true,
    int timeoutMilliseconds = DefaultTimeoutMilliseconds)
  {
    var startInfo = new ProcessStartInfo
    {
      FileName = _powershellPath,
      WorkingDirectory = _runtime.PayloadRoot,
      UseShellExecute = false,
      CreateNoWindow = true,
    };
    if (captureOutput)
    {
      startInfo.RedirectStandardOutput = true;
      startInfo.RedirectStandardError = true;
      startInfo.StandardOutputEncoding = System.Text.Encoding.UTF8;
      startInfo.StandardErrorEncoding = System.Text.Encoding.UTF8;
    }
    startInfo.ArgumentList.Add("-NoProfile");
    startInfo.ArgumentList.Add("-ExecutionPolicy");
    startInfo.ArgumentList.Add("Bypass");
    startInfo.ArgumentList.Add("-File");
    startInfo.ArgumentList.Add(script);
    foreach (var argument in arguments)
    {
      startInfo.ArgumentList.Add(argument);
    }

    var nodeDirectory = Path.GetDirectoryName(_runtime.NodePath)!;
    startInfo.Environment["PATH"] = nodeDirectory + Path.PathSeparator +
      (startInfo.Environment.TryGetValue("PATH", out var path) ? path : Environment.GetEnvironmentVariable("PATH"));

    using var process = new Process { StartInfo = startInfo };
    var outputBuffer = new OutputCaptureBuffer();
    var errorBuffer = new OutputCaptureBuffer();
    process.Start();
    var outputTask = captureOutput
      ? PumpAsync(process.StandardOutput, outputBuffer)
      : Task.CompletedTask;
    var errorTask = captureOutput
      ? PumpAsync(process.StandardError, errorBuffer)
      : Task.CompletedTask;
    using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeoutCts.CancelAfter(timeoutMilliseconds);
    var timedOut = false;
    try
    {
      await process.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
    {
      await KillProcessTreeAsync(process).ConfigureAwait(false);
      throw;
    }
    catch (OperationCanceledException)
    {
      timedOut = true;
    }

    if (timedOut)
    {
      await KillProcessTreeAsync(process).ConfigureAwait(false);
      await AwaitDrain(outputTask, errorTask).ConfigureAwait(false);
      throw new InvalidOperationException(
        $"powershell 未在 {TimeSpan.FromMilliseconds(timeoutMilliseconds).TotalSeconds:0} 秒内退出，已强制结束。"
        + $" stdout 尾部：{ProcessResult.Tail(outputBuffer.ToString())}"
        + $" stderr 尾部：{ProcessResult.Tail(errorBuffer.ToString())}");
    }

    // The child exited; its streams normally reach EOF immediately. If some
    // long-lived grandchild still holds the redirected pipe, waiting forever
    // would hang the Manager, so bail out with the partial output instead.
    if (!await AwaitDrain(outputTask, errorTask).ConfigureAwait(false))
    {
      await KillProcessTreeAsync(process).ConfigureAwait(false);
      await AwaitDrain(outputTask, errorTask).ConfigureAwait(false);
    }

    var exitCode = process.HasExited ? SafeExitCode(process) : -1;
    return new ProcessResult(
      exitCode,
      outputBuffer.ToString(),
      errorBuffer.ToString());
  }

  private static int SafeExitCode(Process process)
  {
    try
    {
      return process.ExitCode;
    }
    catch
    {
      return -1;
    }
  }

  // Returns true when both pumps finished (EOF reached), false when abandoned.
  private static async Task<bool> AwaitDrain(Task outputTask, Task errorTask)
  {
    var drain = Task.WhenAll(outputTask, errorTask);
    var finished = await Task.WhenAny(drain, Task.Delay(DrainGrace)).ConfigureAwait(false);
    return finished == drain;
  }

  private static async Task KillProcessTreeAsync(Process process)
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
      // Already gone or access denied; nothing further to reclaim here.
    }
    try
    {
      await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
    }
    catch
    {
      // WaitForExitAsync on a killed process should return promptly.
    }
  }

  private static async Task PumpAsync(StreamReader reader, OutputCaptureBuffer buffer)
  {
    var chunk = new char[4096];
    try
    {
      while (true)
      {
        var read = await reader.ReadAsync(chunk, 0, chunk.Length).ConfigureAwait(false);
        if (read <= 0)
        {
          return;
        }
        buffer.Append(chunk, read);
      }
    }
    catch
    {
      // The stream died with the process (kill/pipe break); keep what we have.
    }
  }
}
