using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// The batch's rules with no window attached: what goes on the queue, what a status line
    /// means for a row, what the disk verdict is. MainWindow applies them; SelfTest reports them.
    /// </summary>
    public static class BatchPlan
    {
        public static readonly Dictionary<string, string> StatusPalette = new Dictionary<string, string>
        {
            { "neutral", "#FF9A9AA6" }, { "active", "#FF4C8DFF" }, { "ready", "#FF5EEAD4" },
            { "warn", "#FFFBBF24" }, { "ok", "#FF34D399" }, { "fail", "#FFF87171" },
        };

        public static readonly Regex DoneRx = new Regex("^(Installed|Uninstalled|Cleaned|Applied|Reverted)", RegexOptions.Compiled);
        public static readonly Regex GoneRx = new Regex("^(Removed|Cancelled|Skipped)", RegexOptions.Compiled);
        public static readonly Regex TerminalRx = new Regex("^(Installed|Uninstalled|Cleaned|Applied|Reverted|Failed|Cancelled|Skipped|Removed)", RegexOptions.Compiled);

        /// <summary>
        /// The row the batch is actually working on: the first that has neither settled nor is still
        /// queued. The strip scrolls to keep it in view. Null when every row is queued or settled -
        /// there is nothing to follow, so the strip stays where the technician left it.
        /// </summary>
        public static AppItem ActiveRow(IEnumerable<AppItem> rows)
        {
            foreach (var p in rows ?? new List<AppItem>())
            {
                var st = p.Status ?? "";
                if (IsTerminal(st) || st.StartsWith("Queued", StringComparison.Ordinal)) continue;
                return p;
            }
            return null;
        }

        /// <summary>What the overall bar shows during the execution phase: whether it can claim a number at all, the number, and the words beside it.</summary>
        public sealed class Overall
        {
            public bool Indeterminate;
            public double Value;
            public string Text = "";
        }

        /// <summary>
        /// The execution phase's overall progress, counted over EVERY row in the batch - the twelve
        /// tweaks that were ticked, not just the ones that happen to report a percentage.
        ///
        /// Each row is worth one share of the bar. A settled row has all of it. A row the worker
        /// reports a figure for has that fraction of it. A row that is running but reports nothing -
        /// which is every tweak, every fix and every account action - is worth HALF a share, so the
        /// bar steps forward when a row starts and again when it finishes: two visible moves per
        /// row, on a batch that would otherwise sit still. A row still queued is worth nothing.
        ///
        /// There is no indeterminate case any more. The batch knows how many rows it has from the
        /// moment it starts, so it can always give a number, and the bar that "sweeps" instead is
        /// the bar that renders as a frozen solid line on a template that does not animate it.
        /// The caption carries the percentage AND the exact count, the same shape the download
        /// phase uses: "58%   -   7 of 12 finished". The percentage is the estimate; the count is
        /// the fact.
        /// </summary>
        public static Overall OverallFor(IEnumerable<AppItem> rows)
        {
            var list = rows == null ? new List<AppItem>() : rows.ToList();
            var total = list.Count;
            if (total == 0) return new Overall { Indeterminate = false, Value = 0, Text = "" };
            var done = 0; var credit = 0.0;
            foreach (var p in list)
            {
                var st = p.Status ?? "";
                if (IsTerminal(st)) { done++; credit += 1.0; continue; }
                if (st.StartsWith("Queued", StringComparison.Ordinal)) continue;
                // capped just under a whole share: a row the worker reports at 100% has not
                // SETTLED, and a full bar over the words "11 of 12 finished" reads as the tool
                // having lost count of itself
                if (p.ProgressVis == "Visible" && p.Progress > 0) credit += Math.Min(99, p.Progress) / 100.0;
                else credit += 0.5;
            }
            // "finished", not "done": this counts every row that has settled, failures included, while
            // the strip's own header counts successes and appends ", N failed". Two different numbers
            // under the same word, twenty pixels apart, is how a batch reads as lying about itself.
            var pct = Math.Min(100, credit * 100.0 / total);
            return new Overall { Indeterminate = false, Value = pct,
                                 Text = Math.Floor(pct) + "%   -   " + done + " of " + total + " finished" };
        }

        public static bool IsDone(string st) { return DoneRx.IsMatch(st ?? ""); }
        public static bool IsFail(string st) { return (st ?? "").StartsWith("Failed", StringComparison.Ordinal); }
        public static bool IsGone(string st) { return GoneRx.IsMatch(st ?? ""); }
        public static bool IsTerminal(string st) { return TerminalRx.IsMatch(st ?? ""); }

        /// <summary>Test-Removable: free while queued or downloading, never once the installer has launched.</summary>
        public static bool Removable(string status, bool batchLive)
        {
            if (!batchLive) return false;
            var st = status ?? "";
            if (st == "") return true;
            if (st.StartsWith("Queued")) return true;
            if (st.StartsWith("Starting download")) return true;
            if (st.StartsWith("Downloading")) return true;
            if (st.StartsWith("Retrying")) return true;
            if (st.StartsWith("Paused")) return true;
            if (st.StartsWith("Link expired")) return true;
            return false;
        }

        /// <summary>Set-Status's shortening: a settled card shows one verdict word; the sentence lives in StatusDetail.</summary>
        public static string ShortStatus(string text, string kind)
        {
            if (kind != "ok" && kind != "fail" && kind != "warn") return text;
            var m = Regex.Match(text ?? "", "^(.*?)(?::| - )");
            if (m.Success && m.Groups[1].Value.Trim().Length > 0) return m.Groups[1].Value.Trim();
            return text;
        }

        public sealed class Words { public string Text; public string Kind; public string Ring; }

        /// <summary>Read-WorkerStatus's mapping of one record to the row's words, colour and indicator.</summary>
        public static Words RowWords(WorkerStatus s, bool itemDirty, string batchTab)
        {
            var txt = s.State ?? "";
            if (!string.IsNullOrEmpty(s.Detail)) txt += ": " + s.Detail;
            if (s.Pct >= 0 && s.Elapsed >= 0) txt += "  -  " + Format.Elapsed(s.Elapsed);
            if (s.Bytes >= 0 && s.Total > 0)
            {
                txt += "  -  " + Format.Size(s.Bytes) + " of " + Format.Size(s.Total);
                if (s.Rate > 0)
                {
                    txt += "  at " + Format.Size(s.Rate) + "/s";
                    var eta = Format.Eta(s.Total - s.Bytes, s.Rate);
                    if (eta.Length > 0) txt += "  -  " + eta;
                }
            }
            var kind = "active"; var ring = "busy";
            if (IsDone(s.State)) { kind = "ok"; ring = "ok"; }
            else if (s.State == "Failed") { kind = "fail"; ring = "fail"; }
            else if (s.State == "Cancelled" || s.State == "Skipped" || s.State == "Removed") { kind = "warn"; ring = "warn"; }
            // a wipe after a failed install must not turn the row green
            if (s.State == "Cleaned" && itemDirty)
            {
                var what = batchTab == "Un" ? "what the failed uninstall left behind" : "partial install";
                txt = "Failed: " + what + " removed - " + s.Detail;
                kind = "fail"; ring = "fail";
            }
            return new Words { Text = txt, Kind = kind, Ring = ring };
        }

        /// <summary>
        /// EVERY field the worker reads has to be listed here - this hashtable is the only thing
        /// that crosses into the elevated side. tests\Test-Push.ps1 compares the script's list
        /// against the worker; tests\Test-Client.ps1 compares this one against the script's.
        /// </summary>
        public static Dictionary<string, object> StepFor(Dictionary<string, object> st, string localFile)
        {
            var step = new Dictionary<string, object>
            {
                { "type", Json.Str(st, "type") }, { "name", Json.Str(st, "name") }, { "args", Json.Str(st, "args") },
                { "sha256", Json.Str(st, "sha256").ToUpperInvariant() }, { "dest", Json.Str(st, "dest") }, { "from", Json.Str(st, "from") },
                { "path", Json.Str(st, "path") }, { "value", Json.Str(st, "value") }, { "valueType", Json.Str(st, "valueType") },
                { "action", Json.Str(st, "action") }, { "timeoutSec", (int)Json.Long(st, "timeoutSec") },
                { "command", Json.Str(st, "command") }, { "folder", Json.Str(st, "folder") },
                // absent means true, which is the worker's own default
                { "stopOnError", Json.Has(st, "stopOnError") ? Json.Bool(st, "stopOnError") : true },
                { "waitMs", (int)Json.Long(st, "waitMs") },
            };
            if (localFile != null) step["file"] = localFile;
            return step;
        }

        /// <summary>Enqueue-Install's entry, field for field.</summary>
        public static Dictionary<string, object> InstallEntry(AppItem item, string file, string userSid, List<Dictionary<string, object>> steps)
        {
            return new Dictionary<string, object>
            {
                { "id", item.Id }, { "action", "install" }, { "file", file },
                { "sha256", item.Sha256 }, { "silentArgs", item.SilentArgs ?? "" }, { "verifyPaths", item.VerifyPaths ?? new string[0] },
                { "entry", item.Entry ?? "" }, { "postInstall", steps ?? new List<Dictionary<string, object>>() }, { "userSid", userSid ?? "" },
                { "installTimeoutSec", item.InstallTimeoutSec }, { "allowUi", item.AllowUi },
                { "silentSource", item.SilentSource ?? "" }, { "installerFamily", item.InstallerFamily ?? "" },
                { "chain", item.Chain },
                { "after", (item.After ?? new string[0]).Where(a => !string.IsNullOrEmpty(a)).ToArray() },
            };
        }

        /// <summary>Get-DiskVerdict: the brush name the sheet paints with.</summary>
        public static string DiskVerdict(long free, long total, long need)
        {
            if (total <= 0) return "Muted";
            if (need > free) return "Bad";
            var after = free - need;
            if (after < (2L << 30) || (after / (double)total) < 0.10) return "Warn";
            return "Good";
        }

        /// <summary>Get-BatchSpaceNeeded: 1.2x the download (2.2x for a package that unpacks), less what is already here.</summary>
        public static long SpaceNeeded(IEnumerable<AppItem> items, string cacheDir)
        {
            long need = 0;
            foreach (var s in items)
            {
                if (s == null) continue;
                var want = (long)(s.SizeBytes * (string.IsNullOrEmpty(s.Entry) ? 1.2 : 2.2));
                try
                {
                    var have = Path.Combine(cacheDir, "files", Catalog.SafeId(s.Id), s.FileName ?? "");
                    if (File.Exists(have)) want -= new FileInfo(have).Length;
                }
                catch { }
                if (want > 0) need += want;
            }
            return need;
        }

        /// <summary>A detect target - a registry key or a path - is present on this machine.</summary>
        public static bool DetectPresent(string d)
        {
            if (string.IsNullOrEmpty(d)) return false;
            if (Regex.IsMatch(d, "^HK(LM|CU|CR|EY|U)")) return RegKeyExists(d);
            return PathExists(Environment.ExpandEnvironmentVariables(d));
        }

        /// <summary>Test-CatalogInstalled: the cheap probe - the uninstall block's detect target, then the verify paths.</summary>
        public static bool IsInstalled(AppItem item)
        {
            try
            {
                var d = item.DetectPath ?? "";
                if (d.Length > 0 && DetectPresent(d)) return true;
                foreach (var vp in item.VerifyPaths ?? new string[0])
                    if (!string.IsNullOrEmpty(vp) && PathExists(Environment.ExpandEnvironmentVariables(vp))) return true;
            }
            catch { }
            return false;
        }

        private static bool PathExists(string p) { return File.Exists(p) || Directory.Exists(p); }

        private static bool RegKeyExists(string path)
        {
            var p = path.Replace('/', '\\');
            var i = p.IndexOf('\\');
            var hive = (i < 0 ? p : p.Substring(0, i)).ToUpperInvariant();
            var sub = i < 0 ? "" : p.Substring(i + 1);
            Microsoft.Win32.RegistryKey root;
            switch (hive)
            {
                case "HKLM": case "HKEY_LOCAL_MACHINE": root = Microsoft.Win32.Registry.LocalMachine; break;
                case "HKCU": case "HKEY_CURRENT_USER": root = Microsoft.Win32.Registry.CurrentUser; break;
                case "HKCR": case "HKEY_CLASSES_ROOT": root = Microsoft.Win32.Registry.ClassesRoot; break;
                case "HKU": case "HKEY_USERS": root = Microsoft.Win32.Registry.Users; break;
                default: return false;
            }
            sub = sub.TrimEnd('\\');
            if (sub.Length == 0) return true;
            using (var k = root.OpenSubKey(sub, false)) { if (k != null) return true; }
            // a key that only exists in the other registry view still counts as "here"
            try
            {
                var other = Environment.Is64BitProcess ? Microsoft.Win32.RegistryView.Registry32 : Microsoft.Win32.RegistryView.Registry64;
                using (var baseKey = Microsoft.Win32.RegistryKey.OpenBaseKey(HiveOf(hive), other))
                using (var k = baseKey.OpenSubKey(sub, false)) { return k != null; }
            }
            catch { return false; }
        }

        /// <summary>
        /// The order a batch downloads in: SMALLEST FIRST, so the first install starts within seconds
        /// and the worker is busy while the 14 GB package comes down - in catalog order the Autodesk
        /// suite led and nothing installed for hours. A dependency still wins over size: a base is
        /// moved ahead of everything that requires it. A file with no known size goes last (it may be
        /// the biggest); catalog position breaks ties.
        /// </summary>
        public static List<AppItem> Order(IEnumerable<AppItem> sel, IList<AppItem> catalog)
        {
            var list = sel.OrderBy(i => i.SizeBytes > 0 ? 0 : 1).ThenBy(i => i.SizeBytes).ThenBy(i => catalog.IndexOf(i)).ToList();
            // a base ahead of its add-on, repeated until nothing moves (a chain of requirements settles in a few passes)
            for (var pass = 0; pass < list.Count + 1; pass++)
            {
                var moved = false;
                for (var p = 0; p < list.Count; p++)
                {
                    foreach (var req in list[p].Requires ?? new string[0])
                    {
                        var b = list.FindIndex(x => x.Id == req);
                        if (b <= p) continue;
                        var baseItem = list[b];
                        list.RemoveAt(b);
                        list.Insert(p, baseItem);
                        moved = true;
                        break;
                    }
                    if (moved) break;
                }
                if (!moved) break;
            }
            return list;
        }

        /// <summary>
        /// Get-PfDepState's missing list: (add-on, base id) for every requirement that is neither on the
        /// machine nor in the batch. An id the catalog does not know is reported in `unknown` and
        /// SKIPPED, as the script does - the catalog should merely say so, never block the batch.
        /// </summary>
        public static List<KeyValuePair<AppItem, string>> MissingBases(IList<AppItem> sel, IDictionary<string, bool> installedById, out List<KeyValuePair<AppItem, string>> unknown)
        {
            var missing = new List<KeyValuePair<AppItem, string>>();
            unknown = new List<KeyValuePair<AppItem, string>>();
            foreach (var p in sel)
                foreach (var req in p.Requires ?? new string[0])
                {
                    if (string.IsNullOrEmpty(req)) continue;
                    if (!installedById.ContainsKey(req)) { unknown.Add(new KeyValuePair<AppItem, string>(p, req)); continue; }
                    if (!installedById[req] && !sel.Any(s => s.Id == req)) missing.Add(new KeyValuePair<AppItem, string>(p, req));
                }
            return missing;
        }

        private static Microsoft.Win32.RegistryHive HiveOf(string hive)
        {
            switch (hive)
            {
                case "HKLM": case "HKEY_LOCAL_MACHINE": return Microsoft.Win32.RegistryHive.LocalMachine;
                case "HKCU": case "HKEY_CURRENT_USER": return Microsoft.Win32.RegistryHive.CurrentUser;
                case "HKCR": case "HKEY_CLASSES_ROOT": return Microsoft.Win32.RegistryHive.ClassesRoot;
                default: return Microsoft.Win32.RegistryHive.Users;
            }
        }
    }
}
