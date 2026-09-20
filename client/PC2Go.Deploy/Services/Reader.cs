using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// The reads that are the script's own functions, run in a hidden powershell.exe: the
    /// Control Panel inventory, the Store package list and the leftover sweep. reader.ps1 is
    /// rendered from AppDeploy.ps1 at build time (tools\Build-Client.ps1) and embedded, so
    /// what a program is, what its quiet switch is and what a leftover is are decided by the
    /// same code in both clients. Another process also means nothing here can stall the window.
    /// </summary>
    public sealed class Reader
    {
        private readonly string _cacheDir;
        private readonly string _path;
        private bool _written;

        public Reader(string cacheDir)
        {
            _cacheDir = cacheDir;
            _path = Path.Combine(cacheDir, "reader.ps1");
        }

        public static string Source()
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("reader.ps1"))
            {
                if (s == null) throw new InvalidOperationException("the reader is not embedded in this build");
                using (var r = new StreamReader(s, Encoding.UTF8, true)) return r.ReadToEnd();
            }
        }

        private void EnsureWritten()
        {
            if (_written && File.Exists(_path)) return;
            Directory.CreateDirectory(_cacheDir);
            File.WriteAllText(_path, Source(), new UTF8Encoding(true));
            _written = true;
        }

        /// <summary>Runs one op and returns its JSON. progress receives the reader's progress line as it changes.</summary>
        public async Task<string> RunAsync(string op, string inputJson, Action<string> progress, CancellationToken ct, int timeoutSec = 900)
        {
            EnsureWritten();
            var tag = Guid.NewGuid().ToString("N").Substring(0, 8);
            var inFile = Path.Combine(_cacheDir, "reader-" + tag + ".in.json");
            var outFile = Path.Combine(_cacheDir, "reader-" + tag + ".out.json");
            var progFile = Path.Combine(_cacheDir, "reader-" + tag + ".progress.txt");
            try
            {
                if (inputJson != null) File.WriteAllText(inFile, inputJson, new UTF8Encoding(false));
                var psExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
                // No -WindowStyle Hidden. It does nothing here - UseShellExecute=false with
                // CreateNoWindow=true already means this child never gets a window, and it is the
                // correct way to do it: no SW_HIDE creation flag, both streams redirected. The
                // switch was pure noise on a command line that Defender reads on every read, and
                // "powershell -WindowStyle Hidden" is one of the strings its heuristics weigh.
                var args = "-NoProfile -ExecutionPolicy Bypass -NonInteractive -File \"" + _path + "\" -Op " + op +
                           " -Out \"" + outFile + "\" -Progress \"" + progFile + "\"" + (inputJson != null ? " -In \"" + inFile + "\"" : "");
                var psi = new ProcessStartInfo
                {
                    FileName = psExe, Arguments = args, UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardError = true, RedirectStandardOutput = true,
                };
                var err = new StringBuilder();
                using (var p = new Process { StartInfo = psi, EnableRaisingEvents = true })
                {
                    var exited = new TaskCompletionSource<bool>();
                    p.Exited += (s, e) => exited.TrySetResult(true);
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) err.AppendLine(e.Data); };
                    p.OutputDataReceived += (s, e) => { };
                    p.Start();
                    p.BeginErrorReadLine();
                    p.BeginOutputReadLine();
                    var t0 = DateTime.UtcNow;
                    string last = null;
                    while (!exited.Task.IsCompleted)
                    {
                        if (ct.IsCancellationRequested || (DateTime.UtcNow - t0).TotalSeconds > timeoutSec)
                        {
                            try { p.Kill(); } catch { }
                            if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                            throw new TimeoutException("the " + op + " read did not finish within " + timeoutSec + " seconds");
                        }
                        await Task.WhenAny(exited.Task, Task.Delay(250)).ConfigureAwait(false);
                        if (progress != null)
                        {
                            try
                            {
                                if (File.Exists(progFile))
                                {
                                    var line = File.ReadAllText(progFile).Trim();
                                    if (line.Length > 0 && line != last) { last = line; progress(line); }
                                }
                            }
                            catch { }
                        }
                    }
                    p.WaitForExit();
                    if (!File.Exists(outFile))
                        throw new InvalidOperationException("the " + op + " read produced nothing" + (err.Length > 0 ? ": " + Trim(err.ToString()) : " (exit " + p.ExitCode + ")"));
                    return File.ReadAllText(outFile, Encoding.UTF8);
                }
            }
            finally
            {
                foreach (var f in new[] { inFile, outFile, progFile }) { try { if (File.Exists(f)) File.Delete(f); } catch { } }
            }
        }

        private static string Trim(string s)
        {
            s = (s ?? "").Trim();
            return s.Length > 300 ? s.Substring(0, 300) + "..." : s;
        }
    }
}
