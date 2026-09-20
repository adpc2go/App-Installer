using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// Real logos, off the UI thread. Disk first (instant), network on a background task, result
    /// marshalled to the row. A miss is remembered for a day, not for ever: an icon published
    /// tomorrow must appear tomorrow, and the client has no other way to learn it exists.
    /// </summary>
    public sealed class IconPump
    {
        private readonly EdgeClient _edge;
        private readonly string _iconDir;
        private readonly Action<AppItem, BitmapImage> _apply;
        private sealed class Job { public AppItem Item; public string Kind; public string[] Sources; public string Location; public string Logo; }
        private readonly ConcurrentQueue<Job> _queue = new ConcurrentQueue<Job>();
        private int _running;

        public IconPump(EdgeClient edge, string cacheDir, Action<AppItem, BitmapImage> applyOnUiThread)
        {
            _edge = edge;
            _iconDir = Path.Combine(cacheDir, "icons");
            _apply = applyOnUiThread;
        }

        /// <summary>
        /// How long a "the server has no such logo" answer is believed before the URL is asked again.
        /// An hour: a dead URL costs one attempt per launch, a logo published this afternoon shows
        /// this afternoon. (A day, as before, kept letters on the tiles until tomorrow.)
        /// </summary>
        public const int MissMinutes = 60;

        /// <summary>
        /// The cache file for one logo: the app's id plus a short hash of the URL it comes from.
        /// The id alone was the key until client 15, and that let a logo fetched from one server -
        /// or a miss recorded against it - stand in for the same id's logo on another: the test
        /// suite's loopback edge wrote four misses into the cache the real launches share, and the
        /// technician's own client showed letters for a day.
        /// </summary>
        public static string CacheName(string id, string url)
        {
            var ext = ".png";
            try { var e = Path.GetExtension(new Uri(url).LocalPath); if (!string.IsNullOrEmpty(e) && e.Length <= 5) ext = e; } catch { }
            return Catalog.SafeId(id) + "-" + UrlHash(url) + ext;
        }

        private static string UrlHash(string url)
        {
            using (var sha = System.Security.Cryptography.SHA1.Create())
            {
                var h = sha.ComputeHash(Encoding.UTF8.GetBytes((url ?? "").Trim().ToLowerInvariant()));
                return BitConverter.ToString(h, 0, 4).Replace("-", "").ToLowerInvariant();
            }
        }

        public string CachePath(AppItem item) { return Path.Combine(_iconDir, CacheName(item.Id, item.IconUrl)); }

        // once per pump: the id-keyed misses earlier builds wrote (and the script client still
        // writes) are the files that hid the logos - they are cleared, the logos themselves stay
        private int _swept;
        private void SweepOldMisses()
        {
            if (Interlocked.Exchange(ref _swept, 1) != 0) return;
            try
            {
                // ids carry dashes themselves (sketchup-pro, email-migration): the new scheme is told by its hash tail
                foreach (var f in Directory.GetFiles(_iconDir, "*.miss"))
                    if (!System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileNameWithoutExtension(f), "-[0-9a-f]{8}$")) { try { File.Delete(f); } catch { } }
            }
            catch { }
        }

        /// <summary>Disk only, never network: a cold cache must not stall the UI thread.</summary>
        public BitmapImage Cached(AppItem item)
        {
            try
            {
                var p = CachePath(item);
                if (!File.Exists(p)) return null;
                return Load(File.ReadAllBytes(p));
            }
            catch { return null; }
        }

        /// <summary>A catalog logo by URL, cached on disk.</summary>
        public void Request(AppItem item) { Enqueue(new Job { Item = item, Kind = "url" }); }
        /// <summary>A desktop program's own logo: DisplayIcon first, then the uninstaller exe, then whatever the reader found.</summary>
        public void RequestExe(AppItem item, string[] sources) { Enqueue(new Job { Item = item, Kind = "exe", Sources = sources ?? new string[0] }); }
        /// <summary>A Store package's logo asset from its own folder.</summary>
        public void RequestStore(AppItem item, string location, string logo) { Enqueue(new Job { Item = item, Kind = "store", Location = location, Logo = logo }); }

        private void Enqueue(Job job)
        {
            _queue.Enqueue(job);
            if (Interlocked.CompareExchange(ref _running, 1, 0) == 0)
                Task.Run(() => Drain());
        }

        private async Task Drain()
        {
            try
            {
                Directory.CreateDirectory(_iconDir);
                SweepOldMisses();
                Job job;
                while (_queue.TryDequeue(out job))
                {
                    var item = job.Item;
                    try
                    {
                        if (job.Kind == "exe")
                        {
                            BitmapImage got = null;
                            foreach (var src in job.Sources) { got = ExeIcon(src); if (got != null) break; }
                            if (got != null) _apply(item, got);
                            continue;
                        }
                        if (job.Kind == "store")
                        {
                            var got = StoreLogo(job.Location, job.Logo);
                            if (got != null) _apply(item, got);
                            continue;
                        }
                        var cache = CachePath(item);
                        var miss = Path.ChangeExtension(cache, ".miss");
                        if (File.Exists(miss))
                        {
                            try { if ((DateTime.Now - File.GetLastWriteTime(miss)).TotalMinutes >= MissMinutes) File.Delete(miss); } catch { }
                        }
                        if (!File.Exists(cache) && !File.Exists(miss))
                        {
                            // A miss is what the SERVER says - 404, 410 - and nothing else. No network,
                            // a timeout, a window closed before the answer came (the HttpClient is
                            // disposed under this fetch): none of those is knowledge about the logo,
                            // so none is remembered, and the next launch simply asks again.
                            var status = await _edge.GetFileStatusAsync(item.IconUrl, cache, 10, CancellationToken.None).ConfigureAwait(false);
                            if (status == 404 || status == 410)
                            {
                                try { File.WriteAllText(miss, ""); } catch { }
                            }
                        }
                        if (File.Exists(cache))
                        {
                            var img = Load(File.ReadAllBytes(cache));
                            if (img != null) _apply(item, img);
                        }
                    }
                    catch { }
                }
            }
            finally
            {
                Interlocked.Exchange(ref _running, 0);
                if (!_queue.IsEmpty && Interlocked.CompareExchange(ref _running, 1, 0) == 0)
                    await Drain().ConfigureAwait(false);
            }
        }

        /// <summary>Get-ExeIcon: the icon Explorer would show for the file, as a frozen image.</summary>
        public static BitmapImage ExeIcon(string source)
        {
            if (string.IsNullOrWhiteSpace(source)) return null;
            var path = source.Trim().Trim('"');
            var m = System.Text.RegularExpressions.Regex.Match(path, @"^(.*?),\s*-?\d+\s*$");
            if (m.Success) path = m.Groups[1].Value;
            path = Environment.ExpandEnvironmentVariables(path.Trim('"'));
            if (!File.Exists(path)) return null;
            try
            {
                if (string.Equals(Path.GetExtension(path), ".ico", StringComparison.OrdinalIgnoreCase)) return Load(File.ReadAllBytes(path));
                using (var ico = System.Drawing.Icon.ExtractAssociatedIcon(path))
                {
                    if (ico == null) return null;
                    using (var bmp = ico.ToBitmap())
                    using (var ms = new MemoryStream())
                    {
                        bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                        return Load(ms.ToArray());
                    }
                }
            }
            catch { return null; }
        }

        /// <summary>The package's logo asset: exact name first, then the largest scale-qualified variant.</summary>
        private static BitmapImage StoreLogo(string location, string logo)
        {
            try
            {
                if (string.IsNullOrEmpty(location) || string.IsNullOrEmpty(logo) || !Directory.Exists(location)) return null;
                var full = Path.Combine(location, logo);
                if (File.Exists(full)) return Load(File.ReadAllBytes(full));
                var dir = Path.GetDirectoryName(full);
                var baseName = Path.GetFileNameWithoutExtension(full);
                if (dir == null || !Directory.Exists(dir)) return null;
                var cand = Directory.GetFiles(dir, baseName + "*.png").Select(f => new FileInfo(f)).OrderByDescending(f => f.Length).FirstOrDefault();
                return cand != null ? Load(File.ReadAllBytes(cand.FullName)) : null;
            }
            catch { return null; }
        }

        private static BitmapImage Load(byte[] bytes)
        {
            try
            {
                var img = new BitmapImage();
                using (var ms = new MemoryStream(bytes))
                {
                    img.BeginInit();
                    img.CacheOption = BitmapCacheOption.OnLoad;
                    img.StreamSource = ms;
                    img.EndInit();
                }
                img.Freeze();
                return img;
            }
            catch { return null; }
        }
    }
}
