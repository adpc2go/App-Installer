using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>One outbound block rule that names a program, as the script's Get-FirewallBlockMap lists it.</summary>
    public sealed class FwRule
    {
        public string Path = "", Name = "", Display = "", Group = "";
        public bool Enabled;
    }

    /// <summary>One row of the reader's `firewall` scan: a program that lives somewhere blockable, or a vendor folder of stray rules.</summary>
    public sealed class FwRow
    {
        public string Id = "", Name = "", Publisher = "", Root = "";
        public int On, Off;
        public bool Stray;
        public string[] RuleNames = new string[0];
        public string[] IconSources = new string[0];
    }

    public sealed class FwLoad
    {
        public int RuleTotal, Orphans;
        public List<FwRow> Rows = new List<FwRow>();
        // lower-cased program path -> the rules that name it: the same map Load-Firewall keeps as $script:FwMap
        public Dictionary<string, List<FwRule>> Map = new Dictionary<string, List<FwRule>>(StringComparer.Ordinal);
    }

    /// <summary>
    /// The Firewall tab's pure pieces: the scan parse, the Load-Firewall row projection, the foreign-rule
    /// count, the batch summary rewrite and the executable preview. Nothing here touches the machine's
    /// rules - the reader reads them with the script's own functions, the worker writes them.
    /// </summary>
    public static class FirewallList
    {
        // The Group is the handle Windows uses to delete every rule in one call, so it is the one string
        // that must stay stable - the script's $script:FwGroup, and the "Group" column in wf.msc.
        public const string Group = "Application Block";

        public const string CatBlocked = "Blocked - no internet access";
        public const string CatOpen = "Not blocked";
        public const string CatStray = "Stray rules - no installed program owns these";

        public static FwLoad Parse(string json)
        {
            var load = new FwLoad();
            var root = Json.ParseObject(json);
            if (root == null) return load;
            load.RuleTotal = (int)Json.Long(root, "ruleTotal");
            load.Orphans = (int)Json.Long(root, "orphans");
            foreach (var o in Json.Arr(root, "rows"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                load.Rows.Add(new FwRow
                {
                    Id = Json.Str(d, "Id"), Name = Json.Str(d, "Name"), Publisher = Json.Str(d, "Publisher"), Root = Json.Str(d, "Root"),
                    On = (int)Json.Long(d, "On"), Off = (int)Json.Long(d, "Off"), Stray = Json.Bool(d, "Stray"),
                    RuleNames = Json.Strings(d, "RuleNames"), IconSources = Json.Strings(d, "IconSources"),
                });
            }
            load.Map = ParseMap(root);
            return load;
        }

        /// <summary>The `rules` list of a `firewall` or `fwmap` answer, keyed the way the script keys its map.</summary>
        public static Dictionary<string, List<FwRule>> ParseMap(string json)
        {
            var root = Json.ParseObject(json);
            return root == null ? new Dictionary<string, List<FwRule>>(StringComparer.Ordinal) : ParseMap(root);
        }

        private static Dictionary<string, List<FwRule>> ParseMap(Dictionary<string, object> root)
        {
            var map = new Dictionary<string, List<FwRule>>(StringComparer.Ordinal);
            foreach (var o in Json.Arr(root, "rules"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                var key = Json.Str(d, "Path").ToLowerInvariant();
                if (key.Length == 0) continue;
                List<FwRule> list;
                if (!map.TryGetValue(key, out list)) { list = new List<FwRule>(); map[key] = list; }
                list.Add(new FwRule { Path = key, Name = Json.Str(d, "Name"), Display = Json.Str(d, "Display"), Group = Json.Str(d, "Group"), Enabled = Json.Bool(d, "Enabled") });
            }
            return map;
        }

        /// <summary>
        /// Load-Firewall's row: a badge rather than a coloured tile (the real program icon replaces
        /// the tile), the rule counts riding in DetectPath (on) and OrigState (off) as the script keeps
        /// them, the stray's exact rule names in CleanTokens because those rows cannot go through the
        /// root-based worker action - it deliberately refuses shared roots.
        /// </summary>
        public static AppItem Row(FwRow r)
        {
            var n = r.On; var off = r.Off;
            var u = new AppItem { Id = r.Id, Name = r.Name, Publisher = r.Root, UnArgs = r.Root, IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0 };
            if (r.Stray)
            {
                u.Version = "no installed program claims this folder";
                u.Size = "ORPHAN  " + n;
                u.BadgeBg = "#FFF59E0B";
                u.DetectPath = n.ToString();
                u.OrigState = "0";
                u.IsSilent = true;
                u.CleanTokens = r.RuleNames;
                u.RegKey = "unmatched";
                u.Category = CatStray;
                u.Source = "2";
                u.IconBg = "#FFF59E0B";
                return u;
            }
            u.Version = r.Publisher;
            u.Size = n > 0 ? "BLOCKED  " + n + (off > 0 ? "  (" + off + " off)" : "") : (off > 0 ? "RULES OFF  " + off : "");
            u.BadgeBg = n > 0 ? "#FFF87171" : "#FFF59E0B";
            u.DetectPath = n.ToString();
            u.OrigState = off.ToString();
            u.IsSilent = n > 0;
            u.Category = n > 0 ? CatBlocked : CatOpen;
            u.Source = "1";
            u.IconBg = n > 0 ? "#FFF87171" : "#FF64748B";
            return u;
        }

        /// <summary>
        /// Start-FwBatch's queue entry. The queue carries only the app name and its install folder -
        /// the elevated worker does the exe enumeration and re-checks the protected-path rules itself
        /// rather than trusting a list of paths off the queue. An Unmatched row lives under a shared
        /// root the worker's Test-FwRoot refuses by design, so it is removed by explicit rule NAME.
        /// </summary>
        public static Dictionary<string, object> Entry(string action, AppItem s, string build)
        {
            if (action == "fwunblock" && IsStray(s))
                return new Dictionary<string, object> { { "id", s.Id }, { "action", "fwunblockrules" }, { "app", s.Name ?? "" },
                                                        { "rules", s.CleanTokens ?? new string[0] }, { "folder", s.UnArgs ?? "" }, { "group", Group } };
            return new Dictionary<string, object> { { "id", s.Id }, { "action", action }, { "app", s.Name ?? "" },
                                                    { "publisher", s.Version ?? "" }, { "build", build },
                                                    { "root", s.UnArgs ?? "" }, { "group", Group } };
        }

        public static bool IsStray(AppItem i) { return i.RegKey == "unmatched"; }
        public static int OnCount(AppItem i) { int n; return int.TryParse(i.DetectPath ?? "", out n) ? n : 0; }
        public static int OffCount(AppItem i) { int n; return int.TryParse(i.OrigState ?? "", out n) ? n : 0; }
        /// <summary>A row whose only rules are switched off still has rules to clear.</summary>
        public static bool HasRules(AppItem i) { return i.IsSilent || OffCount(i) > 0; }

        /// <summary>The hint line under the toolbar, from the scan's own totals.</summary>
        public static string Hint(int ruleTotal, int orphans, int offTotal)
        {
            var s = Format.Count(ruleTotal, "outbound block rule", "outbound block rules") + " on this machine";
            if (orphans > 0) s += "; " + orphans + " belong to no installed program - listed as stray at the end of the Blocked column";
            if (offTotal > 0) s += "; " + offTotal + " are switched off and block nothing";
            return s;
        }

        /// <summary>
        /// Get-ForeignRuleCount: how many of the rules about to be deleted were made by something other
        /// than this tool. Removing them is intended - that is how a legacy batch file's leftovers get
        /// cleared - but the technician sees the blast radius before agreeing to it.
        /// </summary>
        public static int ForeignRuleCount(Dictionary<string, List<FwRule>> map, IEnumerable<AppItem> rows)
        {
            if (map == null) return 0;
            var n = 0;
            foreach (var row in rows)
            {
                if (IsStray(row))
                {
                    // names were captured at scan time; look them up in the current map
                    var want = new HashSet<string>(row.CleanTokens ?? new string[0], StringComparer.Ordinal);
                    foreach (var list in map.Values)
                        foreach (var r in list)
                            if (want.Contains(r.Name) && r.Group != Group) n++;
                    continue;
                }
                var prefix = (row.UnArgs ?? "").TrimEnd('\\').ToLowerInvariant() + "\\";
                foreach (var kv in map)
                {
                    if (!kv.Key.StartsWith(prefix, StringComparison.Ordinal)) continue;
                    foreach (var r in kv.Value) if (r.Group != Group) n++;
                }
            }
            return n;
        }

        /// <summary>
        /// Finish-Batch's Firewall summary: the question the batch file answered - how many rules were
        /// actually NEW. Running it twice visibly changes nothing rather than looking like it did the
        /// work again. Parsed from StatusDetail, where the worker's numbers live.
        /// </summary>
        public static string BatchSummary(IEnumerable<AppItem> pending, string fallback)
        {
            int add = 0, skip = 0, del = 0, none = 0;
            foreach (var p in pending)
            {
                var s = !string.IsNullOrEmpty(p.StatusDetail) ? p.StatusDetail : (p.Status ?? "");
                Match m;
                if ((m = Regex.Match(s, @"(\d+) rule\(s\) added")).Success) add += int.Parse(m.Groups[1].Value);
                if ((m = Regex.Match(s, @"(\d+) switched back on")).Success) add += int.Parse(m.Groups[1].Value);
                if ((m = Regex.Match(s, @"(\d+) already blocked")).Success) skip += int.Parse(m.Groups[1].Value);
                if ((m = Regex.Match(s, @"(\d+) rule\(s\) removed")).Success) del += int.Parse(m.Groups[1].Value);
                if (Regex.IsMatch(s, "no block rules pointed|no executables found")) none++;
            }
            var bits = new List<string>();
            if (add > 0 || skip > 0)
            {
                bits.Add(add > 0 ? Format.Count(add, "new rule", "new rules") + " added" : "no new rules added - everything was already blocked");
                if (skip > 0) bits.Add(Format.Count(skip, "executable", "executables") + " already blocked, skipped");
            }
            if (del > 0) bits.Add(Format.Count(del, "rule", "rules") + " removed");
            if (none > 0) bits.Add(Format.Count(none, "program", "programs") + " had nothing to do");
            return bits.Count > 0 ? string.Join(", ", bits) : fallback;
        }

        /// <summary>
        /// Every .exe under a folder - the same list the worker's Block-AppNetwork enumerates. One
        /// unreadable subfolder must not turn the preview into "(nothing found)" for a folder the worker
        /// would then block, so the fast enumeration falls back to a walk that skips what it cannot read.
        /// </summary>
        public static List<string> EnumerateExes(string root)
        {
            try { return Directory.EnumerateFiles(root, "*.exe", SearchOption.AllDirectories).ToList(); }
            catch
            {
                var found = new List<string>();
                Walk(root, found, 0);
                return found;
            }
        }

        private static void Walk(string dir, List<string> found, int depth)
        {
            if (depth > 48) return;
            try { foreach (var f in Directory.EnumerateFiles(dir, "*.exe")) if (string.Equals(Path.GetExtension(f), ".exe", StringComparison.OrdinalIgnoreCase)) found.Add(f); } catch { }
            string[] subs;
            try { subs = Directory.GetDirectories(dir); } catch { return; }
            foreach (var s in subs) Walk(s, found, depth + 1);
        }

        /// <summary>Show-FwDetail for a blocked row: one line per executable, not per rule - that is what a technician reads.</summary>
        public static List<string> BlockedDetail(Dictionary<string, List<FwRule>> map, string root, out int exeCount)
        {
            var lines = new List<string>();
            var prefix = root.ToLowerInvariant() + "\\";
            var paths = new List<string>();
            if (map != null)
                foreach (var k in map.Keys)
                    if (k == root.ToLowerInvariant() || k.StartsWith(prefix, StringComparison.Ordinal)) paths.Add(k);
            paths.Sort(StringComparer.Ordinal);
            foreach (var k in paths)
            {
                var rules = map[k];
                var mine = rules.Count(r => r.Group == Group);
                var tag = mine == rules.Count ? "this tool" : (mine == 0 ? "another tool" : "mixed");
                var offN = rules.Count(r => !r.Enabled);
                if (offN > 0) tag += ", " + offN + " switched OFF";
                lines.Add(k + "    (" + Format.Count(rules.Count, "rule", "rules") + ", " + tag + ")");
            }
            exeCount = paths.Count;
            return lines;
        }
    }
}
