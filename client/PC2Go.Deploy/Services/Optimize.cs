using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>One row of the script's $script:TweakDefs, read through the reader.</summary>
    public sealed class TweakDef
    {
        public string Id = "", Name = "", Hint = "", Tab = "";
        public bool Caution;
    }

    /// <summary>
    /// The Optimize tab's pure pieces: the table parse, the probe answer parse, the two id lists the
    /// batch starters share, and the settings broadcast Windows needs after the Explorer tweaks.
    /// </summary>
    public static class Optimize
    {
        // rows that change what Explorer draws (taskbar, Start, desktop icons, context menu): one
        // Explorer restart per batch, and the WM_SETTINGCHANGE broadcast the same values need
        public static readonly string[] ExplorerIds = { "taskbarclean", "startclean", "rightclickmenu", "visualeffects", "widgets",
                                                        "endtask", "uisnappy", "explorerhome", "explorerprivacy", "desktopicons", "windowsai" };
        // undo restores the documented default; these delete or run something and cannot be put back
        /// <summary>
        /// What a CAUTION cleanup row actually costs, in the words the technician needs before
        /// pressing Continue. One sentence per id; an unknown id gets the generic line rather
        /// than silence, because the sheet is the only warning these rows get.
        /// </summary>
        public static string CleanupCost(string id)
        {
            switch (id ?? "")
            {
                case "windowsold":
                    return "Removing Windows.old permanently removes the ability to roll back the Windows version. It is also the biggest disk win available - typically 20-30 GB after a feature update.";
                case "shadowcap":
                    return "Capping System Restore at 5% deletes existing restore points that no longer fit - including one this tool may have created minutes ago, which is the only undo the CAUTION tweaks have.";
                default:
                    return "This is a CAUTION row: what it removes cannot be put back from here.";
            }
        }

        public static readonly string[] OneWayIds = { "restorepoint", "onedriveremove", "widgets", "windowsai",
                                                      "debloatweb", "debloatdev", "debloatxbox", "debloatmsapps", "debloatmobile", "debloatutil",
                                                      "taskbarclean", "explorerprivacy" };

        public static List<TweakDef> ParseDefs(string json)
        {
            var list = new List<TweakDef>();
            var root = Json.ParseObject(json);
            if (root == null) return list;
            foreach (var o in Json.Arr(root, "items"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new TweakDef { Id = Json.Str(d, "id"), Name = Json.Str(d, "name"), Hint = Json.Str(d, "hint"), Tab = Json.Str(d, "tab"), Caution = Json.Bool(d, "caution") });
            }
            return list;
        }

        /// <summary>The detectors' answers: true = applied, false = not, null = an action, not a state (never claimed applied).</summary>
        public static Dictionary<string, bool?> ParseProbe(string json)
        {
            var map = new Dictionary<string, bool?>(StringComparer.Ordinal);
            var root = Json.ParseObject(json);
            if (root == null) return map;
            foreach (var o in Json.Arr(root, "results"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                var id = Json.Str(d, "Id");
                object r = d.ContainsKey("Result") ? d["Result"] : null;
                map[id] = r is bool ? (bool?)(bool)r : null;
            }
            return map;
        }

        // ------------------------------------------------------------------ the Gaming sub-tab

        /// <summary>One run of the script's latency probe (Measure-GamingLatency, through the reader): timer granularity, preemption jitter p50/p99/max in ms, DPC and ISR load in percent (-1 when unread).</summary>
        public sealed class GameProbe
        {
            public double TimerP50, PreP50, PreP99, PreMax, Dpc = -1, Isr = -1;
            public string When = "";
        }

        public static GameProbe ParseGameProbe(string json)
        {
            var root = Json.ParseObject(json);
            if (root == null) return null;
            Func<string, double> d = k => { object v; if (!root.TryGetValue(k, out v) || v == null) return 0; double x; return double.TryParse(Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out x) ? x : 0; };
            return new GameProbe { TimerP50 = d("TimerP50"), PreP50 = d("PreP50"), PreP99 = d("PreP99"), PreMax = d("PreMax"), Dpc = root.ContainsKey("Dpc") ? d("Dpc") : -1, Isr = root.ContainsKey("Isr") ? d("Isr") : -1, When = Json.Str(root, "When") };
        }

        /// <summary>Format-GamingProbe, word for word: "jitter p99 0.120 ms (max 0.900)  |  timer 1.9 ms  |  DPC 0.3%  ISR 0.1%".</summary>
        public static string FormatProbe(GameProbe p)
        {
            var s = "jitter p99 " + p.PreP99.ToString("N3") + " ms (max " + p.PreMax.ToString("N3") + ")  |  timer " + p.TimerP50.ToString("N1") + " ms";
            if (p.Dpc >= 0) s += "  |  DPC " + p.Dpc.ToString("N1") + "%  ISR " + p.Isr.ToString("N1") + "%";
            return s;
        }

        /// <summary>
        /// Compare-GamingProbe, the same gate: the preemption p99 has to move by more than 0.2 ms AND by
        /// more than 30% before it is called a change at all - a 0.02 -> 0.25 ms wobble on a quiet
        /// machine is not a verdict. Never claim a win the numbers do not show.
        /// </summary>
        public static KeyValuePair<string, string> CompareProbe(GameProbe before, GameProbe after)
        {
            var dd = after.PreP99 - before.PreP99;
            var rel = Math.Abs(dd) / Math.Max(0.001, Math.Max(before.PreP99, after.PreP99));
            if (rel < 0.30) dd = 0.0;
            var line = "BEFORE  jitter p99 " + before.PreP99.ToString("N3") + " ms, max " + before.PreMax.ToString("N3") + ", timer " + before.TimerP50.ToString("N1") + " ms" +
                       "   ->   AFTER  jitter p99 " + after.PreP99.ToString("N3") + " ms, max " + after.PreMax.ToString("N3") + ", timer " + after.TimerP50.ToString("N1") + " ms";
            if (before.Dpc >= 0 && after.Dpc >= 0) line += "   |   DPC " + before.Dpc.ToString("N1") + "% -> " + after.Dpc.ToString("N1") + "%";
            var verdict = dd <= -0.2 ? "IMPROVED: preemption jitter p99 down " + (-dd).ToString("N3") + " ms"
                        : dd >= 0.2 ? "WORSE: preemption jitter p99 up " + dd.ToString("N3") + " ms - check the CAUTION rows"
                        : "no measurable change in this window (within the 0.2 ms noise band)";
            return new KeyValuePair<string, string>(line, verdict);
        }

        /// <summary>Each CAUTION gaming row's own cost, named on the confirm sheet - the script's $costs table, key for key.</summary>
        public static readonly Dictionary<string, string> GamingCosts = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "hags",         "Hardware-Accelerated GPU Scheduling regresses on some GPU/driver combinations and needs a reboot." },
            { "gamenic",      "Network Adapter - Gaming Profile briefly DROPS the network link (~2 s per adapter) - never run it during a remote session." },
            { "interrupts",   "GPU and NIC Interrupts (MSI + high priority) needs a reboot." },
            { "memintegrity", "Memory Integrity (VBS) - Disable trades away kernel-exploit protection for FPS and needs a reboot. Keep it ON if this machine runs WSL2, Docker, Hyper-V or Credential Guard." },
        };

        /// <summary>
        /// What a cleanup batch gave back, summed from the rows' own sentences - the worker measures
        /// the system drive before and after each row and writes "2.3 GB reclaimed" / "300 MB
        /// reclaimed" / "under 1 MB reclaimed" into the detail. Zero when no row carried a figure.
        /// </summary>
        public static long ReclaimedBytes(IEnumerable<AppItem> rows)
        {
            long sum = 0;
            foreach (var p in rows)
            {
                var s = !string.IsNullOrEmpty(p.StatusDetail) ? p.StatusDetail : (p.Status ?? "");
                var m = Regex.Match(s, @"(?<!under )(\d+(?:[.,]\d+)?) (GB|MB) reclaimed");   // "under 1 MB reclaimed" is not a megabyte
                if (!m.Success) continue;
                double v;
                if (!double.TryParse(m.Groups[1].Value.Replace(',', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) continue;
                sum += (long)(v * (m.Groups[2].Value == "GB" ? (1L << 30) : (1L << 20)));
            }
            return sum;
        }

        /// <summary>One startup entry as the reader lists it: the Run value or Startup-folder file, where it lives, and Task Manager's verdict.</summary>
        public sealed class StartupEntry
        {
            public string Name = "", Command = "", Location = "", Exe = "";
            public bool Enabled;
        }

        public static List<StartupEntry> ParseStartup(string json)
        {
            var list = new List<StartupEntry>();
            var root = Json.ParseObject(json);
            if (root == null) return list;
            foreach (var o in Json.Arr(root, "items"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new StartupEntry { Name = Json.Str(d, "Name"), Command = Json.Str(d, "Command"), Location = Json.Str(d, "Location"), Enabled = Json.Bool(d, "Enabled"), Exe = Json.Str(d, "Exe") });
            }
            return list;
        }

        public const string CatStartsOn = "Starts with Windows";
        public const string CatStartsOff = "Switched off - does not start";

        /// <summary>
        /// The Startup row: the entry's own name, its command under it, grouped by Task Manager's
        /// verdict. Location rides in UnArgs and the name in Version, which is what the worker entry
        /// carries; IsSilent mirrors Enabled so the batch starters can tell the two apart. The
        /// executable the reader resolved is the icon source - the program's own logo, as Task
        /// Manager draws it; a row without one keeps the plain glyph tile.
        /// </summary>
        public static AppItem StartupRow(StartupEntry e)
        {
            var u = new AppItem
            {
                Id = "startup-" + e.Location.Replace('\\', '-').ToLowerInvariant() + "-" + Regex.Replace(e.Name.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-'),
                Name = e.Name, Publisher = e.Command, Version = e.Name, UnArgs = e.Location, IsSilent = e.Enabled, Size = e.Enabled ? "" : "OFF",
                Category = e.Enabled ? CatStartsOn : CatStartsOff,
                IconBg = e.Enabled ? "#FF2563EB" : "#FF64748B", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0,
                IconText = e.Name.Length > 0 ? e.Name.Substring(0, 1).ToUpperInvariant() : "?", TextVis = "Collapsed", GlyphVis = "Visible",
                IconSources = string.IsNullOrEmpty(e.Exe) ? new string[0] : new[] { e.Exe },
            };
            return u;
        }

        /// <summary>The worker entry for one startup row: the entry's name and where it lives; the worker decides the StartupApproved key.</summary>
        public static Dictionary<string, object> StartupEntryFor(AppItem row, bool on, string userSid)
        {
            return new Dictionary<string, object> { { "id", row.Id }, { "action", on ? "startupon" : "startupoff" }, { "name", row.Version ?? "" }, { "location", row.UnArgs ?? "" }, { "userSid", userSid ?? "" } };
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
        [DllImport("shell32.dll")]
        private static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

        /// <summary>
        /// Send-SettingChange: best effort throughout. HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG,
        /// 100 ms - capped so one wedged top-level window cannot stall the tool; then SHCNE_ASSOCCHANGED.
        /// </summary>
        public static void SendSettingChange()
        {
            try { UIntPtr res; SendMessageTimeout((IntPtr)0xFFFF, 0x1A, UIntPtr.Zero, "ImmersiveColorSet", 0x0002, 100, out res); } catch { }
            try { SHChangeNotify(0x08000000, 0x0000, IntPtr.Zero, IntPtr.Zero); } catch { }
        }
    }
}
