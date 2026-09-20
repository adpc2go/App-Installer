using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// -Download url -Dest file -Size bytes -Out report.json [-Streams n] [-ChunkFloor bytes]: the
    /// product's own download path - Downloads.FetchAsync, the same call the Install batch makes -
    /// run headless so a test can put a server in front of it that drops connections, refuses
    /// Range, or goes dark, and kill THIS process mid-file to prove the journal resumes it.
    /// </summary>
    public static class DownloadProbe
    {
        public static int Run(Options o)
        {
            var rep = new Dictionary<string, object>();
            var log = new List<string>();
            var sw = Stopwatch.StartNew();
            rep["build"] = App.BuildTag;
            rep["ok"] = false; rep["error"] = ""; rep["path"] = ""; rep["bytes"] = 0L; rep["sha256"] = "";
            try
            {
                if (o.DownloadChunkFloor > 0) SegmentedDownloader.ChunkFloor = o.DownloadChunkFloor;
                var dest = o.DownloadDest;
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(dest)));
                var item = new AppItem { Id = "probe", Name = "Probe", Url = o.DownloadUrl, SizeBytes = o.DownloadSize, FileName = Path.GetFileName(dest), Size = Format.Size(o.DownloadSize) };
                using (var edge = new EdgeClient("http://127.0.0.1:1", ""))
                {
                    var last = "";
                    // Task.Run: no dispatcher context here to deadlock a blocking wait
                    var path = Task.Run(() => Downloads.FetchAsync(edge, item, dest, null, () => false,
                        (done, total, text, kind) => { if (text != last) { last = text; lock (log) log.Add("[status] " + text); } },
                        line => { lock (log) log.Add(line); },
                        CancellationToken.None, o.DownloadStreams)).GetAwaiter().GetResult();
                    rep["path"] = path;
                }
                rep["bytes"] = new FileInfo(dest).Length;
                rep["sha256"] = WorkerHost.Sha256Hex(dest);
                rep["ok"] = true;
            }
            catch (Exception ex) { rep["error"] = ex.Message; }
            rep["seconds"] = Math.Round(sw.Elapsed.TotalSeconds, 2);
            rep["log"] = log.ToArray();
            File.WriteAllText(o.SelfTestOut ?? "download-probe.json", Json.Serialize(rep), new UTF8Encoding(false));
            return (bool)rep["ok"] ? 0 : 3;
        }
    }
}
