using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>The multi-connection path cannot be used for this file: the caller falls back to one connection.</summary>
    public sealed class SegmentedFatalException : Exception
    {
        public SegmentedFatalException(string msg) : base(msg) { }
    }

    /// <summary>
    /// The script's Invoke-SegmentedDownload: one file, fetched over several connections at once,
    /// straight into its final offsets.
    ///
    /// A QUEUE of chunks, not a fixed split. The file is cut into ~64 pieces and every worker takes
    /// the next unfinished piece when it is done with its own - so no connection ever sits idle while
    /// a slower one finishes, and the last byte arrives at full width. Pieces write into ONE
    /// pre-allocated file; progress per chunk is journalled beside it (.parts), because sparse
    /// writes cannot be read back to work out how far each piece got. That journal is what makes a
    /// crash, a reboot or a closed window cost seconds, not the download: the next attempt resumes
    /// every piece from where it stood.
    ///
    /// A dropped socket is a retry on that chunk for as long as the batch runs. Only three things are
    /// fatal: the server refusing a range, the object having changed underneath (If-Range against
    /// the ETag in the journal), and a link that expired and could not be refreshed. Those throw
    /// SegmentedFatalException so the caller can fall back to one connection. The SHA-256 the worker
    /// verifies afterwards is the real safety net.
    ///
    /// MEASURED against the live edge (192 MB, median of three): 1 stream 48 MB/s, 8 streams 92,
    /// 16 streams 97. A single TCP stream is limited to roughly window / round-trip time, so the
    /// further away the client is the worse one stream does - and these clients are a long way away.
    /// </summary>
    public static class SegmentedDownloader
    {
        public const int Streams = 16;
        public const long MinBytes = 16L << 20;
        // a harness may lower the chunk floor to cut a small fixture into many pieces; 0 = the default 8 MB
        public static long ChunkFloor = 0;
        // what the adaptive throttle settled on for the last file (0 = not yet measured): a link that
        // was dropping connections at eight streams is still that link for the next package
        public static int ActiveCarry = 0;

        public delegate void StatusHandler(long done, long total, string text, string kind);

        /// <summary>Get-SegmentChunkSize: about 64 pieces per file, never under 8 MB, never over 64 MB, whole megabytes.</summary>
        public static long ChunkSize(long total)
        {
            var floor = ChunkFloor > 0 ? ChunkFloor : 8L << 20;
            if (total <= 0) return floor;
            var c = (long)Math.Ceiling(total / 64.0);
            c = Math.Max(floor, Math.Min(64L << 20, c));
            if (c >= 1L << 20) c = (long)Math.Ceiling(c / (double)(1L << 20)) * (1L << 20);
            return c;
        }

        /// <summary>The .parts journal: {total, chunk, done[], etag} - the same shape the script writes, so either client resumes the other's file.</summary>
        public static Dictionary<string, object> ReadJournal(string journalPath)
        {
            try { return Json.ParseObject(File.ReadAllText(journalPath)); } catch { return null; }
        }

        public static long JournalDone(Dictionary<string, object> j)
        {
            long sum = 0;
            if (j == null) return 0;
            foreach (var o in Json.Arr(j, "done")) { try { sum += Convert.ToInt64(o); } catch { } }
            return sum;
        }

        private sealed class Shared
        {
            public long[] Done;
            public int Next;
            public int Active;
            public int Retrying;
            public int Faults;
            public volatile string Url;
            public volatile bool NeedUrl;
            public string ETag;
            public readonly ConcurrentQueue<string> Log = new ConcurrentQueue<string>();
            public readonly ConcurrentQueue<string> Errors = new ConcurrentQueue<string>();
            public CancellationTokenSource Stop;   // cancels every worker: batch cancel, removal, or a fatal error
            public volatile bool Fatal;
        }

        public static async Task RunAsync(EdgeClient edge, AppItem item, string dest,
                                          Func<Task<string>> refreshUrl, Func<bool> removed,
                                          StatusHandler status, Action<string> log,
                                          CancellationToken ct, int streams = 0)
        {
            if (streams <= 0) streams = Streams;
            var total = item.SizeBytes;
            if (total <= 0) throw new SegmentedFatalException("segmented download needs the size from the catalog");
            var tmp = dest + ".part";
            var journal = dest + ".parts";

            // ---- will this server do Range at all? One tiny request settles it, and gives the ETag.
            string etag = "";
            using (var probe = new HttpRequestMessage(HttpMethod.Get, item.Url))
            using (var pcts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                probe.Headers.Range = new RangeHeaderValue(0, 0);
                pcts.CancelAfter(TimeSpan.FromSeconds(30));
                HttpResponseMessage pr;
                try { pr = await edge.Http.SendAsync(probe, HttpCompletionOption.ResponseHeadersRead, pcts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new SegmentedFatalException("the server did not answer the range probe within 30 seconds"); }
                catch (Exception ex) { throw new SegmentedFatalException("the range probe failed: " + ex.Message); }
                using (pr)
                {
                    if ((int)pr.StatusCode != 206) throw new SegmentedFatalException("the server ignored a Range request (HTTP " + (int)pr.StatusCode + ")");
                    try { etag = pr.Headers.ETag != null ? pr.Headers.ETag.ToString().Trim() : ""; } catch { etag = ""; }
                }
            }

            // ---- the pieces, and how far each got last time
            var chunk = ChunkSize(total);
            var count = (int)Math.Ceiling(total / (double)chunk);
            if (streams > count) streams = count;
            var done = new long[count];
            Func<int, long> chunkLen = i => Math.Min(chunk, total - (long)i * chunk);

            // A journal from an earlier attempt is only usable if it describes THIS file cut THIS way.
            if (File.Exists(tmp) && File.Exists(journal))
            {
                var j = ReadJournal(journal);
                if (j != null)
                {
                    var sameObject = true;
                    var jTag = Json.Str(j, "etag");
                    if (etag.Length > 0 && jTag.Length > 0 && jTag != etag)
                    {
                        sameObject = false;
                        log(item.Name + ": the file on the server changed since the last attempt - starting the download over.");
                    }
                    var jDone = Json.Arr(j, "done");
                    if (sameObject && Json.Long(j, "total") == total && Json.Long(j, "chunk") == chunk && jDone.Length == count && new FileInfo(tmp).Length == total)
                    {
                        for (int i = 0; i < count; i++)
                        {
                            long d = 0; try { d = Convert.ToInt64(jDone[i]); } catch { }
                            if (d > 0 && d <= chunkLen(i)) done[i] = d;
                        }
                        var already = done.Sum();
                        if (already > 0) log("Resuming " + item.Name + " - " + Format.Size(already) + " of " + Format.Size(total) + " already here.");
                    }
                }
            }
            if (!File.Exists(tmp) || new FileInfo(tmp).Length != total)
            {
                // Pre-allocated once, so every piece can seek straight to where it belongs.
                using (var init = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None)) init.SetLength(total);
                for (int i = 0; i < count; i++) done[i] = 0;
            }

            var active = ActiveCarry > 0 ? Math.Min(ActiveCarry, streams) : streams;
            var shared = new Shared { Done = done, Next = 0, Active = active, Url = item.Url, ETag = etag, Stop = CancellationTokenSource.CreateLinkedTokenSource(ct) };
            // skip pieces that are already whole
            for (int i = 0; i < count; i++) { if (done[i] < chunkLen(i)) break; shared.Next = i + 1; }
            var carried = done.Sum();

            var workers = new List<Task>();
            for (int w = 0; w < streams; w++)
            {
                var me = w;
                workers.Add(Task.Run(() => WorkerAsync(me, edge, tmp, total, chunk, count, shared, removed)));
            }

            var faultWindowStart = DateTime.UtcNow;
            var lastThrottle = DateTime.UtcNow;
            var refreshedUrl = false;
            var lastJournal = DateTime.UtcNow;
            long spBytes = -1; var spTime = DateTime.UtcNow; var spTxt = ""; var etaTxt = "";
            try
            {
                while (true)
                {
                    var running = workers.Count(t => !t.IsCompleted);
                    long dn = 0;
                    for (int i = 0; i < count; i++) dn += Interlocked.Read(ref shared.Done[i]);
                    var pct = total > 0 ? (int)Math.Floor(dn * 100.0 / total) : 0;
                    var now = DateTime.UtcNow;
                    if (spBytes < 0) { spBytes = dn; spTime = now; }
                    else
                    {
                        var dt = (now - spTime).TotalSeconds;
                        if (dt >= 1)
                        {
                            var delta = dn - spBytes;
                            if (delta > 0)
                            {
                                var rate = delta / dt;
                                spTxt = Format.Size((long)rate) + "/s";
                                etaTxt = Format.Eta(total - dn, rate);
                            }
                            spBytes = dn; spTime = now;
                        }
                    }

                    // ---- the link: a worker saw 401/403 and is waiting for a fresh one (once per file)
                    if (shared.NeedUrl)
                    {
                        string fresh = null;
                        if (!refreshedUrl)
                        {
                            refreshedUrl = true;
                            if (refreshUrl != null) { try { fresh = await refreshUrl().ConfigureAwait(false); } catch { fresh = null; } }
                        }
                        if (!string.IsNullOrEmpty(fresh))
                        {
                            shared.Url = fresh;
                            item.Url = fresh;
                            shared.NeedUrl = false;
                            log(item.Name + ": download link had expired - refreshed, the workers are carrying on.");
                        }
                    }
                    // ---- the network: say what is actually happening rather than a stale percentage
                    var netUp = true;
                    try { netUp = NetworkInterface.GetIsNetworkAvailable(); } catch { netUp = true; }
                    var retrying = shared.Retrying;
                    string l;
                    while (shared.Log.TryDequeue(out l)) log(item.Name + ": " + l);
                    // ---- adaptive concurrency: faults cluster -> halve the workers; quiet -> raise them
                    if ((now - faultWindowStart).TotalSeconds >= 60)
                    {
                        var faults = shared.Faults;
                        if (faults >= 3 && active > 2 && (now - lastThrottle).TotalSeconds >= 60)
                        {
                            active = Math.Max(2, active / 2);
                            shared.Active = active;
                            lastThrottle = now;
                            log(item.Name + ": the link is dropping connections - down to " + active + " at a time.");
                        }
                        else if (faults == 0 && active < streams && (now - lastThrottle).TotalSeconds >= 120)
                        {
                            active = Math.Min(streams, active * 2);
                            shared.Active = active;
                            lastThrottle = now;
                            log(item.Name + ": the link is steady again - back up to " + active + " at a time.");
                        }
                        shared.Faults = 0;
                        faultWindowStart = now;
                        ActiveCarry = active;
                    }

                    var txt = "Downloading " + pct + "%";
                    if (spTxt.Length > 0) txt += "  " + spTxt;
                    if (etaTxt.Length > 0) txt += "  -  " + etaTxt;
                    var kind = "active";
                    if (!netUp) { txt = "Internet lost - waiting; " + pct + "% kept, resumes on its own"; kind = "warn"; }
                    else if (shared.NeedUrl) { txt = "Download link expired - refreshing (" + pct + "% kept)"; kind = "warn"; }
                    else if (retrying > 0) txt += "  -  reconnecting " + retrying + " of " + active;
                    if (!shared.Stop.IsCancellationRequested) status(dn, total, txt, kind);

                    // Journalled on a clock, not on every block: losing two seconds of progress to a
                    // crash costs two seconds of refetch.
                    if ((now - lastJournal).TotalSeconds >= 2) { WriteJournal(journal, total, chunk, shared.Done, shared.ETag); lastJournal = now; }

                    if (removed()) shared.Stop.Cancel();
                    if (running == 0) break;
                    await Task.Delay(200).ConfigureAwait(false);
                }
            }
            finally
            {
                try { await Task.WhenAll(workers).ConfigureAwait(false); } catch { }
                WriteJournal(journal, total, chunk, shared.Done, shared.ETag);
                string l2;
                while (shared.Log.TryDequeue(out l2)) log(item.Name + ": " + l2);
            }

            if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
            if (removed()) throw new DownloadRemovedException();
            if (shared.Fatal)
            {
                // the caller falls back to one connection from byte zero: a pre-allocated .part would
                // read to it as "all there already", so it must not be left behind
                try { File.Delete(tmp); } catch { }
                try { File.Delete(journal); } catch { }
                throw new SegmentedFatalException(string.Join("; ", shared.Errors.Take(2)));
            }

            // The catalog's size outranks anything the server said - same rule as the single-stream
            // path, and the reason a truncating proxy cannot promote a partial file to a finished one.
            var actual = new FileInfo(tmp).Length;
            if (actual != total) throw new IOException("incomplete download: got " + actual + " of " + total + " bytes");
            long sum = 0;
            for (int i = 0; i < count; i++) sum += Interlocked.Read(ref shared.Done[i]);
            if (sum != total) throw new IOException("incomplete download: " + sum + " of " + total + " bytes accounted for");
            if (File.Exists(dest)) File.Delete(dest);
            File.Move(tmp, dest);
            try { File.Delete(journal); } catch { }
            log(item.Name + ": " + Format.Size(total - carried) + " fetched this time over up to " + streams + " connections" + (carried > 0 ? ", " + Format.Size(carried) + " kept from before" : "") + ".");
        }

        private static void WriteJournal(string journal, long total, long chunk, long[] done, string etag)
        {
            try
            {
                var snap = new long[done.Length];
                for (int i = 0; i < done.Length; i++) snap[i] = Interlocked.Read(ref done[i]);
                var text = Json.Serialize(new Dictionary<string, object> { { "total", total }, { "chunk", chunk }, { "done", snap }, { "etag", etag ?? "" } });
                File.WriteAllText(journal, text);
            }
            catch { }
        }

        private static async Task WorkerAsync(int me, EdgeClient edge, string path, long total, long chunk, int count, Shared shared, Func<bool> removed)
        {
            var stop = shared.Stop.Token;
            var buf = new byte[1 << 20];
            // ReadWrite sharing: every worker holds its own handle on the same file at once, opened once.
            // UNBUFFERED (buffer size 1): the journal counts a byte as done the moment its write returns,
            // so the write must have reached the OS by then. With a 1 MB buffer a killed process took up
            // to a megabyte per worker with it while the journal said those bytes were on disk - the
            // resume skipped them, and the finished file hashed wrong. Measured, not imagined.
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite, 1, true))
            {
                while (true)
                {
                    if (stop.IsCancellationRequested) return;
                    // throttled: an ordinal above the ceiling waits rather than taking work
                    if (me >= shared.Active) { try { await Task.Delay(500, stop).ConfigureAwait(false); } catch { return; } continue; }
                    var idx = Interlocked.Increment(ref shared.Next) - 1;
                    if (idx >= count) return;
                    var from = (long)idx * chunk;
                    var to = Math.Min(total - 1, from + chunk - 1);
                    var attempt = 0;
                    while (true)
                    {
                        if (stop.IsCancellationRequested) return;
                        var start = from + Interlocked.Read(ref shared.Done[idx]);
                        if (start > to) break;   // this piece is whole - next
                        attempt++;
                        long gotThisAttempt = 0;
                        try
                        {
                            using (var req = new HttpRequestMessage(HttpMethod.Get, shared.Url))
                            using (var hcts = CancellationTokenSource.CreateLinkedTokenSource(stop))
                            {
                                req.Headers.Range = new RangeHeaderValue(start, to);
                                if (!string.IsNullOrEmpty(shared.ETag)) req.Headers.TryAddWithoutValidation("If-Range", shared.ETag);
                                hcts.CancelAfter(TimeSpan.FromSeconds(60));   // connect + headers
                                using (var resp = await edge.Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, hcts.Token).ConfigureAwait(false))
                                {
                                    hcts.CancelAfter(Timeout.InfiniteTimeSpan);   // headers are in: the body has its own per-read clock
                                    var code = (int)resp.StatusCode;
                                    if (code == 200 && !string.IsNullOrEmpty(shared.ETag))
                                    {
                                        shared.Errors.Enqueue("chunk " + idx + ": the file changed on the server (If-Range answered 200)");
                                        shared.Fatal = true; shared.Stop.Cancel(); return;
                                    }
                                    if (code == 401 || code == 403)
                                    {
                                        // The link, not the network. Ask the window for a fresh one and wait;
                                        // the window says no by leaving NeedUrl set, which times out here.
                                        shared.NeedUrl = true;
                                        var waited = 0;
                                        while (shared.NeedUrl && !stop.IsCancellationRequested && waited < 90000) { await Task.Delay(500).ConfigureAwait(false); waited += 500; }
                                        if (shared.NeedUrl)
                                        {
                                            shared.Errors.Enqueue("chunk " + idx + ": the download link expired and could not be refreshed");
                                            shared.Fatal = true; shared.Stop.Cancel(); return;
                                        }
                                        continue;
                                    }
                                    if (code == 416 || code == 404 || code == 410)
                                    {
                                        shared.Errors.Enqueue("chunk " + idx + ": HTTP " + code + " " + resp.ReasonPhrase);
                                        shared.Fatal = true; shared.Stop.Cancel(); return;
                                    }
                                    if (code != 206) throw new IOException("expected 206, got " + code);
                                    using (var st = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                                    {
                                        fs.Seek(start, SeekOrigin.Begin);
                                        while (true)
                                        {
                                            int n;
                                            using (var rcts = CancellationTokenSource.CreateLinkedTokenSource(stop))
                                            {
                                                rcts.CancelAfter(TimeSpan.FromSeconds(120));   // per-read: kills a half-open socket
                                                try { n = await st.ReadAsync(buf, 0, buf.Length, rcts.Token).ConfigureAwait(false); }
                                                catch (OperationCanceledException) when (!stop.IsCancellationRequested) { throw new IOException("the connection stalled for 120 seconds"); }
                                            }
                                            if (n <= 0) break;
                                            if (stop.IsCancellationRequested) return;
                                            var room = (to + 1) - (from + Interlocked.Read(ref shared.Done[idx]));
                                            if (n > room) n = (int)room;   // a server that over-delivers must not write past this piece
                                            await fs.WriteAsync(buf, 0, n).ConfigureAwait(false);
                                            Interlocked.Add(ref shared.Done[idx], n);
                                            gotThisAttempt += n;
                                            if (n < room) continue;
                                            break;
                                        }
                                        await fs.FlushAsync().ConfigureAwait(false);
                                    }
                                    // the server closed the body early: not an error, the loop re-asks for the rest
                                }
                            }
                        }
                        catch (Exception ex)
                        {
                            if (stop.IsCancellationRequested) return;
                            try { await fs.FlushAsync().ConfigureAwait(false); } catch { }
                            // Two different failures wear the same exception. A socket that was DELIVERING and
                            // then died means the link is up and only that connection is gone - reconnect at
                            // once. Backoff is for a reconnect that yields NOTHING, which is an outage. Faults
                            // drive the throttle, so they must mean "the link is not delivering", not "a socket
                            // was cut".
                            if (gotThisAttempt <= 0) Interlocked.Increment(ref shared.Faults);
                            if (gotThisAttempt > 0) attempt = 0;
                            var wait = attempt == 0 ? 0.25 : Math.Min(30, Math.Pow(2, Math.Min(attempt, 5)));
                            shared.Log.Enqueue("chunk " + idx + " attempt " + attempt + " failed (" + Trim(ex.Message) + ") - retrying in " + wait + "s");
                            Interlocked.Increment(ref shared.Retrying);
                            try { await Task.Delay(TimeSpan.FromSeconds(wait), stop).ConfigureAwait(false); }
                            catch { return; }
                            finally { Interlocked.Decrement(ref shared.Retrying); }
                        }
                    }
                }
            }
        }

        private static string Trim(string s)
        {
            s = (s ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
            return s.Length > 160 ? s.Substring(0, 160) + "..." : s;
        }
    }

    /// <summary>
    /// The one place that decides how a file comes down: several connections for anything over
    /// 16 MB when the server does Range, one resumable connection otherwise - so the worst case is
    /// exactly the path that shipped before.
    /// </summary>
    public static class Downloads
    {
        /// <summary>Returns "segmented" or "single" - which path actually delivered the file.</summary>
        public static async Task<string> FetchAsync(EdgeClient edge, AppItem item, string dest,
                                                    Func<Task<string>> refreshUrl, Func<bool> removed,
                                                    SegmentedDownloader.StatusHandler status, Action<string> log,
                                                    CancellationToken ct, int streams = 0)
        {
            if (item.SizeBytes >= SegmentedDownloader.MinBytes || streams > 0)
            {
                try
                {
                    log("Downloading " + item.Name + " (" + Format.Size(item.SizeBytes) + ") over " + (streams > 0 ? streams : SegmentedDownloader.Streams) + " connections...");
                    await SegmentedDownloader.RunAsync(edge, item, dest, refreshUrl, removed, status, log, ct, streams).ConfigureAwait(false);
                    return "segmented";
                }
                catch (SegmentedFatalException ex)
                {
                    log("Multi-connection download did not work for " + item.Name + " (" + ex.Message + ") - falling back to a single connection.");
                }
            }
            else log("Downloading " + item.Name + " (" + item.Size + ")...");
            await Downloader.RunAsync(edge, item, dest, refreshUrl, removed,
                (done, total, rate) =>
                {
                    var pct = total > 0 ? (int)Math.Floor(done * 100.0 / total) : 0;
                    var txt = "Downloading " + pct + "%";
                    if (rate > 0) txt += "  " + Format.Size((long)rate) + "/s";
                    var eta = total > 0 ? Format.Eta(total - done, rate) : "";
                    if (eta.Length > 0) txt += "  -  " + eta;
                    status(done, total, txt, "active");
                },
                log,
                note => status(-1, 0, note, note.StartsWith("Link") ? "warn" : "active"),
                ct).ConfigureAwait(false);
            return "single";
        }
    }
}
