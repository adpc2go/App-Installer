using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace PC2Go.Deploy.Services
{
    /// <summary>One line of status.jsonl.</summary>
    public sealed class WorkerStatus
    {
        public string Id; public string State; public string Detail; public bool Dirty;
        public string[] Created = new string[0];
        public int Pct = -1; public long Bytes = -1; public long Total = -1; public long Rate = -1; public int Elapsed = -1;
    }

    /// <summary>
    /// The client side of the contract with the elevated worker, unchanged from AppDeploy.ps1:
    /// worker.ps1 written per batch and hashed, a stub run through -EncodedCommand that re-hashes
    /// it before dot-sourcing, queue.jsonl appended one entry at a time and closed with the end
    /// marker, status.jsonl read forward-only, cancel.flag and skip.txt as the two ways back in.
    /// </summary>
    public sealed class WorkerHost
    {
        public readonly string CacheDir, QueuePath, StatusPath, WorkerPath, CancelPath, SkipPath;
        public bool Started { get; private set; }
        public bool EndQueued { get; private set; }
        private int _statusOffset;
        private static readonly Encoding Utf8Bom = new UTF8Encoding(true);

        public WorkerHost(string cacheDir)
        {
            CacheDir = cacheDir;
            QueuePath = Path.Combine(cacheDir, "queue.jsonl");
            StatusPath = Path.Combine(cacheDir, "status.jsonl");
            WorkerPath = Path.Combine(cacheDir, "worker.ps1");
            CancelPath = Path.Combine(cacheDir, "cancel.flag");
            SkipPath = Path.Combine(cacheDir, "skip.txt");
        }

        /// <summary>The worker as it will be written: the embedded, already-rendered script.</summary>
        public static string WorkerSource()
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("worker.ps1"))
            {
                if (s == null) throw new InvalidOperationException("the elevated worker is not embedded in this build");
                using (var r = new StreamReader(s, Encoding.UTF8, true)) return r.ReadToEnd();
            }
        }

        public void ResetForBatch()
        {
            Started = false; EndQueued = false; _statusOffset = 0;
            foreach (var p in new[] { QueuePath, StatusPath, CancelPath, SkipPath })
                try { if (File.Exists(p)) File.Delete(p); } catch { }
        }

        /// <summary>Exactly Start-Worker. Returns false when UAC was declined.</summary>
        public bool Start()
        {
            if (Started) return true;
            Directory.CreateDirectory(CacheDir);
            try { if (File.Exists(WorkerPath)) File.Delete(WorkerPath); } catch { }
            // Set-Content -Encoding UTF8 in 5.1: BOM, CRLF, trailing newline
            var body = WorkerSource().Replace("\r\n", "\n").Replace("\n", "\r\n");
            if (!body.EndsWith("\r\n")) body += "\r\n";
            File.WriteAllText(WorkerPath, body, Utf8Bom);
            try { if (File.Exists(StatusPath)) File.Delete(StatusPath); } catch { }
            try { if (File.Exists(CancelPath)) File.Delete(CancelPath); } catch { }
            _statusOffset = 0;

            var psExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            var want = Sha256Hex(WorkerPath);
            var stub = BuildStub(WorkerPath, StatusPath, QueuePath, CancelPath, SkipPath, want, Process.GetCurrentProcess().Id);
            var enc = Convert.ToBase64String(Encoding.Unicode.GetBytes(stub));
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = psExe,
                    // The switch is redundant - WindowStyle below already hides it - and the pair
                    // "-WindowStyle Hidden -EncodedCommand <base64>" on one command line is about
                    // the most dropper-shaped string a process can present. The window still ends
                    // up hidden; there is just one fewer signal on the way.
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + enc,
                    UseShellExecute = true,
                    Verb = "runas",
                    WindowStyle = ProcessWindowStyle.Hidden,
                };
                // Keep the handle. Without it nothing can tell a worker that is installing from one
                // that endpoint protection killed thirty seconds ago - and the GUI's only other way
                // to end a batch is every row settling, which a dead worker guarantees never happens.
                _proc = Process.Start(psi);
                Started = true;
                return true;
            }
            catch (Win32Exception)
            {
                return false;   // declined
            }
        }

        private Process _proc;

        /// <summary>
        /// False once the elevated process is gone. UseShellExecute with "runas" still hands back a
        /// usable handle, so a worker killed by antivirus, by Task Manager, or by its own crash is
        /// visible here within one tick. Null means we never got a handle - treat that as alive, so
        /// a missing handle can never end a batch that is really running.
        /// </summary>
        public bool Alive { get { try { return _proc == null || !_proc.HasExited; } catch { return true; } } }

        /// <summary>The elevated process's exit code, or null while it is running or unknown.</summary>
        public int? ExitCode { get { try { return _proc != null && _proc.HasExited ? (int?)_proc.ExitCode : null; } catch { return null; } } }

        /// <summary>The verbatim stub from Start-Worker: the worker's hash is checked by the elevated side itself.</summary>
        public static string BuildStub(string workerPath, string statusPath, string queuePath, string cancelPath, string skipPath, string want, int parentPid)
        {
            Func<string, string> lit = s => "'" + (s ?? "").Replace("'", "''") + "'";
            var sb = new StringBuilder();
            sb.Append("$ErrorActionPreference = 'Stop'\n");
            sb.Append("$w  = ").Append(lit(workerPath)).Append('\n');
            sb.Append("$st = ").Append(lit(statusPath)).Append('\n');
            sb.Append("try {\n");
            sb.Append("    if ((Get-FileHash -LiteralPath $w -Algorithm SHA256).Hash -ne '").Append(want).Append("') {\n");
            sb.Append("        Add-Content -LiteralPath $st -Encoding UTF8 -Value '{\"id\":\"_batch\",\"state\":\"Complete\",\"detail\":\"the installer worker was modified on disk after it was written, so it was NOT run - nothing has been installed or changed\"}'\n");
            sb.Append("        exit 9\n");
            sb.Append("    }\n");
            sb.Append("    & $w -QueueFile ").Append(lit(queuePath)).Append(" -StatusFile $st `\n");
            sb.Append("          -CancelFile ").Append(lit(cancelPath)).Append(" -SkipFile ").Append(lit(skipPath)).Append(" -ParentPid ").Append(parentPid).Append('\n');
            sb.Append("} catch {\n");
            sb.Append("    # this window is hidden, so an unreported throw here is a batch that simply never moves\n");
            sb.Append("    Add-Content -LiteralPath $st -Encoding UTF8 -Value ('{\"id\":\"_batch\",\"state\":\"Complete\",\"detail\":' + (ConvertTo-Json (\"the elevated worker could not start - \" + $_.Exception.Message)) + '}')\n");
            sb.Append("    exit 9\n");
            sb.Append("}\n");
            return sb.ToString();
        }

        public void Enqueue(Dictionary<string, object> entry)
        {
            AppendLine(QueuePath, Json.Serialize(entry));
        }

        public void EnqueueRaw(string jsonLine)
        {
            AppendLine(QueuePath, jsonLine);
        }

        /// <summary>The end marker: nothing more is coming, the worker may exit.</summary>
        public void Complete()
        {
            if (Started && !EndQueued) { AppendLine(QueuePath, "{\"end\":true}"); EndQueued = true; }
        }

        public void RequestCancel()
        {
            try { File.WriteAllText(CancelPath, ""); } catch { }
        }

        public bool CancelFlagged() { return File.Exists(CancelPath); }

        public void Skip(string id)
        {
            try { AppendLine(SkipPath, id); } catch { }
        }

        /// <summary>
        /// New status lines since the last read. The offset only ever moves forward: the worker
        /// appends while this reads, so a momentary lock returns fewer lines than last time, and
        /// assigning the offset from that count replayed the whole batch.
        /// </summary>
        public List<WorkerStatus> ReadStatus()
        {
            var fresh = new List<WorkerStatus>();
            if (!File.Exists(StatusPath)) return fresh;
            List<string> lines;
            try
            {
                lines = new List<string>();
                using (var fs = new FileStream(StatusPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(fs, Encoding.UTF8, true))
                {
                    string l;
                    while ((l = r.ReadLine()) != null) lines.Add(l);
                }
            }
            catch { return fresh; }
            if (lines.Count <= _statusOffset) return fresh;
            for (int i = _statusOffset; i < lines.Count; i++)
            {
                var s = Parse(lines[i]);
                if (s != null) fresh.Add(s);
            }
            _statusOffset = lines.Count;
            return fresh;
        }

        public static WorkerStatus Parse(string line)
        {
            if (string.IsNullOrWhiteSpace(line)) return null;
            Dictionary<string, object> d;
            try { d = Json.ParseObject(line); } catch { return null; }
            if (d == null) return null;
            var s = new WorkerStatus
            {
                Id = Json.Str(d, "id"), State = Json.Str(d, "state"), Detail = Json.Str(d, "detail"),
                Dirty = Json.Bool(d, "dirty"), Created = Json.Strings(d, "created"),
            };
            if (Json.Has(d, "pct")) s.Pct = (int)Json.Long(d, "pct");
            if (Json.Has(d, "bytes")) s.Bytes = Json.Long(d, "bytes");
            if (Json.Has(d, "total")) s.Total = Json.Long(d, "total");
            if (Json.Has(d, "rate")) s.Rate = Json.Long(d, "rate");
            if (Json.Has(d, "elapsed")) s.Elapsed = (int)Json.Long(d, "elapsed");
            return s;
        }

        /// <summary>Overwrite with random bytes, then delete - the queue can carry protected secrets.</summary>
        public void ClearQueueFile()
        {
            try
            {
                if (!File.Exists(QueuePath)) return;
                var len = new FileInfo(QueuePath).Length;
                using (var rng = RandomNumberGenerator.Create())
                using (var fs = new FileStream(QueuePath, FileMode.Open, FileAccess.Write, FileShare.None))
                {
                    var buf = new byte[Math.Max(1, Math.Min(len, 1 << 16))];
                    long left = len;
                    while (left > 0) { rng.GetBytes(buf); var n = (int)Math.Min(left, buf.Length); fs.Write(buf, 0, n); left -= n; }
                }
                File.Delete(QueuePath);
            }
            catch { }
        }

        private static void AppendLine(string path, string line)
        {
            // Add-Content -Encoding UTF8: a BOM when the file is created, none on an append, CRLF
            using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            using (var w = new StreamWriter(fs, Utf8Bom))
            {
                w.Write(line);
                w.Write("\r\n");
            }
        }

        public static string Sha256Hex(string path)
        {
            using (var sha = SHA256.Create())
            using (var fs = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToUpperInvariant();
        }

        public static string Sha256Hex(byte[] bytes)
        {
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToUpperInvariant();
        }
    }
}
