using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    public sealed class DownloadRemovedException : Exception
    {
        public DownloadRemovedException() : base("removed from the batch") { }
    }

    /// <summary>
    /// The script's Invoke-ResumableDownload: a .part file, Range resume, five attempts with
    /// backoff, one URL refresh on 403/401, and the catalog's size outranking Content-Length.
    /// Async end to end, so the window never waits on a socket.
    /// </summary>
    public static class Downloader
    {
        public delegate void ProgressHandler(long done, long total, double bytesPerSec);

        public static async Task RunAsync(EdgeClient edge, AppItem item, string dest,
                                          Func<Task<string>> refreshUrl, Func<bool> removed,
                                          ProgressHandler progress, Action<string> log,
                                          Action<string> retryNote, CancellationToken ct)
        {
            var tmp = dest + ".part";
            const int maxAttempts = 5;
            var refreshed = false;

            for (int attempt = 1; attempt <= maxAttempts; attempt++)
            {
                long existing = 0;
                if (File.Exists(tmp)) existing = new FileInfo(tmp).Length;
                try
                {
                    using (var req = new HttpRequestMessage(HttpMethod.Get, item.Url))
                    {
                        if (existing > 0) req.Headers.Range = new RangeHeaderValue(existing, null);
                        using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                        {
                            cts.CancelAfter(TimeSpan.FromSeconds(60));   // connect + headers
                            using (var resp = await edge.Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false))
                            {
                                cts.CancelAfter(Timeout.InfiniteTimeSpan);   // headers are in: the body has its own per-read clock below
                                if (!resp.IsSuccessStatusCode)
                                    throw new HttpStatusException((int)resp.StatusCode, resp.ReasonPhrase);
                                var append = existing > 0 && resp.StatusCode == HttpStatusCode.PartialContent;
                                if (!append) existing = 0;
                                var len = resp.Content.Headers.ContentLength ?? -1;
                                long total = len >= 0 ? len + existing : 0;
                                if (item.SizeBytes > 0) total = item.SizeBytes;
                                using (var fs = new FileStream(tmp, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, true))
                                using (var stream = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                                {
                                    var buf = new byte[1 << 20];
                                    long done = existing;
                                    var lastTick = DateTime.UtcNow; long lastBytes = done; double rate = 0;
                                    var lastReport = DateTime.MinValue;
                                    int n;
                                    while (true)
                                    {
                                        using (var rcts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                                        {
                                            rcts.CancelAfter(TimeSpan.FromSeconds(120));   // per-read: kills a half-open socket
                                            try { n = await stream.ReadAsync(buf, 0, buf.Length, rcts.Token).ConfigureAwait(false); }
                                            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("the connection stalled for 120 seconds"); }
                                        }
                                        if (n <= 0) break;
                                        await fs.WriteAsync(buf, 0, n, ct).ConfigureAwait(false);
                                        done += n;
                                        ct.ThrowIfCancellationRequested();
                                        if (removed()) throw new DownloadRemovedException();
                                        var now = DateTime.UtcNow;
                                        var span = (now - lastTick).TotalSeconds;
                                        if (span >= 1.0) { rate = (done - lastBytes) / span; lastTick = now; lastBytes = done; }
                                        if ((now - lastReport).TotalMilliseconds >= 250) { lastReport = now; progress(done, total, rate); }
                                    }
                                    progress(done, total, rate);
                                }
                            }
                        }
                    }

                    // The catalog outranks Content-Length: a truncating proxy or a half-finished
                    // upload reports a length that agrees with the short body it sends.
                    var actual = new FileInfo(tmp).Length;
                    long expected = item.SizeBytes > 0 ? item.SizeBytes : 0;
                    if (expected > 0 && actual != expected)
                        throw new IOException("Incomplete download: got " + actual + " of " + expected + " bytes.");
                    if (File.Exists(dest)) File.Delete(dest);
                    File.Move(tmp, dest);
                    return;
                }
                catch (Exception ex)
                {
                    if (ct.IsCancellationRequested) throw;
                    if (ex is DownloadRemovedException) throw;
                    var code = (ex as HttpStatusException)?.Code ?? 0;
                    // A signed link that aged out cannot be fixed by waiting: mint a fresh URL once,
                    // then carry on resuming from the same .part file.
                    if ((code == 403 || code == 401) && !refreshed && refreshUrl != null)
                    {
                        refreshed = true;
                        var fresh = await refreshUrl().ConfigureAwait(false);
                        if (!string.IsNullOrEmpty(fresh))
                        {
                            log(item.Name + ": download link had expired - refreshed, resuming.");
                            retryNote("Link expired - refreshing");
                            item.Url = fresh;
                            attempt--;   // the refresh is not one of the caller's retries
                            continue;
                        }
                    }
                    if (attempt >= maxAttempts) throw;
                    var wait = (int)Math.Min(30, Math.Pow(2, attempt));
                    long keep = File.Exists(tmp) ? new FileInfo(tmp).Length : 0;
                    retryNote("Retrying in " + wait + "s (kept " + Math.Round(keep / 1048576.0, 1) + " MB)");
                    await Task.Delay(TimeSpan.FromSeconds(wait), ct).ConfigureAwait(false);
                }
            }
        }

        public sealed class HttpStatusException : Exception
        {
            public int Code { get; private set; }
            public HttpStatusException(int code, string reason) : base("HTTP " + code + " " + reason) { Code = code; }
        }
    }
}
