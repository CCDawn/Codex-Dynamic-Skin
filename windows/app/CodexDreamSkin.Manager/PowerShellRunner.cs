using System.Diagnostics;

namespace CodexDreamSkin.Manager;

internal sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
  public void ThrowIfFailed(string operation)
  {
    if (ExitCode == 0)
    {
      return;
    }

    var detail = string.IsNullOrWhiteSpace(StandardError) ? StandardOutput : StandardError;
    throw new InvalidOperationException($"{operation}失败（{ExitCode}）：{detail.Trim()}");
  }
}

internal sealed class PowerShellRunner
{
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
    CancellationToken cancellationToken = default)
  {
    var startInfo = new ProcessStartInfo
    {
      FileName = _powershellPath,
      WorkingDirectory = _runtime.PayloadRoot,
      UseShellExecute = false,
      CreateNoWindow = true,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      StandardOutputEncoding = System.Text.Encoding.UTF8,
      StandardErrorEncoding = System.Text.Encoding.UTF8,
    };
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
    process.Start();
    var outputTask = process.StandardOutput.ReadToEndAsync();
    var errorTask = process.StandardError.ReadToEndAsync();
    try
    {
      await process.WaitForExitAsync(cancellationToken);
    }
    catch (OperationCanceledException)
    {
      if (!process.HasExited)
      {
        process.Kill(entireProcessTree: true);
        await process.WaitForExitAsync(CancellationToken.None);
      }
      throw;
    }
    return new ProcessResult(
      process.ExitCode,
      await outputTask,
      await errorTask);
  }
}
