using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>One row of the script's $script:MigrateDefs, read through the reader.</summary>
    public sealed class MigrateDef
    {
        public string Id = "", Name = "";
        public bool Safe, Abs, IsFile;
    }

    public sealed class ShareInfo
    {
        public string Name = "", Path = "", Description = "";
    }

    public sealed class DiskFacts
    {
        public string Name = "";
        public long Free, Total;
    }

    /// <summary>A PC the sweep found, for the Network dialog's list.</summary>
    public sealed class NetHostRow
    {
        public string Title { get; set; }
        public string Sub { get; set; }
        public string Name { get; set; }
        public string Ip { get; set; }
    }

    /// <summary>
    /// The Data Backup tab's pure pieces: the row projections of Load-Users' two lists, the path
    /// rules the worker applies again, share naming, and the disk verdict.
    /// </summary>
    public static class BackupList
    {
        public const string ShareTag = "PC2Go share";
        public const string CatSafe = "What to copy   -   user data";
        public const string CatRisky = "From AppData   -   pick deliberately";
        public const string CatRestore = "What to restore";

        public static List<MigrateDef> ParseDefs(string json)
        {
            var list = new List<MigrateDef>();
            var root = Json.ParseObject(json);
            if (root == null) return list;
            foreach (var o in Json.Arr(root, "items"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new MigrateDef { Id = Json.Str(d, "id"), Name = Json.Str(d, "name"), Safe = Json.Bool(d, "safe"), Abs = Json.Bool(d, "abs"), IsFile = Json.Bool(d, "file") });
            }
            return list;
        }

        public static List<ShareInfo> ParseShares(string json)
        {
            var list = new List<ShareInfo>();
            var root = Json.ParseObject(json);
            if (root == null) return list;
            foreach (var o in Json.Arr(root, "all"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new ShareInfo { Name = Json.Str(d, "Name"), Path = Json.Str(d, "Path"), Description = Json.Str(d, "Description") });
            }
            return list;
        }

        /// <summary>The $describe block: what it is, then where.</summary>
        public static string Describe(AccountRec acct, string path)
        {
            var bits = new List<string> { acct != null ? (acct.IsAdmin ? "Administrator" : "Standard user") : "no matching account" };
            if (acct != null && acct.Kind.Length > 0) bits.Add(acct.Kind);
            if (acct != null && acct.FullName.Length > 0 && acct.FullName != acct.Name) bits.Add("shown as \"" + acct.FullName + "\"");
            if (!string.IsNullOrEmpty(path)) bits.Add(path);
            return string.Join("  -  ", bits);
        }

        /// <summary>SrcUsers: one row per profile folder on disk. UnArgs is the profile path, DetectPath the SID.</summary>
        public static AppItem SrcRow(ProfileRec p, AccountRec acct, string me)
        {
            return new AppItem
            {
                Id = "src-" + p.Sid, Name = p.Name, Publisher = Describe(acct, p.Path), Version = "", Size = p.Name == me ? "signed in now" : "",
                UnArgs = p.Path, DetectPath = p.Sid, IconBg = "#FF8A6A32", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0,
            };
        }

        /// <summary>DstUsers: one row per ENABLED account. UnArgs is the profile path (empty when new), DetectPath the account NAME.</summary>
        public static AppItem DstRow(AccountRec a, ProfileRec prof)
        {
            return new AppItem
            {
                Id = "dst-" + a.Name, Name = a.Name, Publisher = Describe(a, prof != null ? prof.Path : "profile folder will be created"), Version = "",
                Size = prof != null ? "" : "new", UnArgs = prof != null ? prof.Path : "", DetectPath = a.Name,
                IconBg = prof != null ? "#FF64748B" : "#FF34D399", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0,
            };
        }

        /// <summary>Get-ShareKey: the full path, lower-cased, trailing separator kept only on a bare drive.</summary>
        public static string ShareKey(string path)
        {
            if (string.IsNullOrEmpty(path)) return "";
            string p;
            try { p = Path.GetFullPath(path); } catch { return ""; }
            if (Regex.IsMatch(p, @"^[A-Za-z]:\\$")) return p.ToLowerInvariant();
            return p.TrimEnd('\\').ToLowerInvariant();
        }

        private static bool Under(string key, string rootKey)
        {
            if (string.IsNullOrEmpty(rootKey)) return false;
            return key == rootKey || key.StartsWith(rootKey.TrimEnd('\\') + "\\", StringComparison.Ordinal);
        }

        /// <summary>Test-SourcePathAllowed: '' when the path may be backed up, otherwise why not. The whole Windows drive is refused - that is imaging, not a backup.</summary>
        public static string TestSourcePathAllowed(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return "no folder given";
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) return "a network path - back it up from the PC it lives on";
            var key = ShareKey(path);
            if (key.Length == 0) return "'" + path + "' is not a valid path";
            if (!Directory.Exists(path)) return "'" + path + "' is not a folder that exists";
            var sysDrive = Environment.GetEnvironmentVariable("SystemDrive") ?? "C:";
            if (key == ShareKey(sysDrive + "\\")) return "the whole of " + sysDrive + " is Windows itself - add folders on it instead";
            var wk = ShareKey(Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows");
            if (Under(key, wk)) return "'" + path + "' is inside Windows";
            return "";
        }

        /// <summary>Test-SharePathAllowed: Windows, both Program Files, ProgramData and this tool's cache are never shared.</summary>
        public static string TestSharePathAllowed(string path, string cacheDir)
        {
            if (string.IsNullOrWhiteSpace(path)) return "no folder given";
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) return "a network path cannot be shared from here - share it on the PC it lives on";
            var key = ShareKey(path);
            if (key.Length == 0) return "'" + path + "' is not a valid path";
            if (!Directory.Exists(path)) return "'" + path + "' is not a folder that exists";
            var bad = new[] { Environment.GetEnvironmentVariable("SystemRoot"), Environment.GetEnvironmentVariable("ProgramFiles"),
                              Environment.GetEnvironmentVariable("ProgramFiles(x86)"), Environment.GetEnvironmentVariable("ProgramData"), cacheDir };
            foreach (var b in bad)
            {
                if (string.IsNullOrEmpty(b)) continue;
                if (Under(key, ShareKey(b))) return "'" + path + "' is inside " + b + ", which this tool will not share - Windows and every installed program live there";
            }
            return "";
        }

        /// <summary>Get-ShareName: the leaf (or the drive letter), sanitised, capped at 60, de-duplicated against the live list.</summary>
        public static string ShareName(string path, IEnumerable<string> taken)
        {
            var p = (path ?? "").TrimEnd('\\');
            var m = Regex.Match(p, "^([A-Za-z]):$");
            var baseName = m.Success ? m.Groups[1].Value.ToUpperInvariant() : Path.GetFileName(p);
            baseName = Regex.Replace(baseName ?? "", "[\\\\/:*?\"<>|]", "").Trim();
            if (baseName.Length == 0) baseName = "Share";
            if (baseName.Length > 60) baseName = baseName.Substring(0, 60).Trim();
            var have = new HashSet<string>((taken ?? new string[0]).Select(t => (t ?? "").ToLowerInvariant()));
            var name = baseName; var n = 1;
            while (have.Contains(name.ToLowerInvariant())) { n++; name = baseName + " " + n; }
            return name;
        }

        /// <summary>Get-BackupFolderName: "PC2Go Backup - PC - account", with characters a path may not hold replaced.</summary>
        public static string BackupFolderName(string user)
        {
            var raw = "PC2Go Backup - " + Environment.MachineName + " - " + user;
            foreach (var c in Path.GetInvalidFileNameChars()) raw = raw.Replace(c.ToString(), "-");
            return raw.Trim().TrimEnd('.');
        }

        public static string DiskVerdict(long free, long total, long need)
        {
            if (total <= 0) return "Muted";
            if (need > free) return "Bad";
            var after = free - need;
            if (after < 2L * 1024 * 1024 * 1024 || (after / (double)total) < 0.10) return "Warn";
            return "Good";
        }

        public static DiskFacts GetDiskFacts(string path)
        {
            try
            {
                var full = Path.GetFullPath(path);
                var d = new DriveInfo(Path.GetPathRoot(full));
                if (!d.IsReady) return null;
                return new DiskFacts { Name = d.Name.TrimEnd('\\'), Free = d.AvailableFreeSpace, Total = d.TotalSize };
            }
            catch { return null; }
        }

        /// <summary>Get-ShareCandidates: every fixed or removable drive that is ready, as a tickable row.</summary>
        public static List<AppItem> ShareCandidates()
        {
            var rows = new List<AppItem>();
            foreach (var d in DriveInfo.GetDrives())
            {
                try
                {
                    if (!d.IsReady) continue;
                    if (d.DriveType != DriveType.Fixed && d.DriveType != DriveType.Removable) continue;
                    var letter = d.Name.TrimEnd('\\');
                    var removable = d.DriveType == DriveType.Removable;
                    rows.Add(new AppItem
                    {
                        Id = "drv-" + letter, Name = (d.VolumeLabel.Length > 0 ? d.VolumeLabel : "Local Disk") + " (" + letter + ")",
                        Publisher = Format.Size(d.AvailableFreeSpace) + " free of " + Format.Size(d.TotalSize) + (removable ? "   -   removable: the share stops working when it is unplugged" : ""),
                        UnArgs = d.Name, RegKey = "drive", IconText = letter.Substring(0, 1), IconBg = removable ? "#FFF59E0B" : "#FF2563EB",
                        IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0, GlyphVis = "Collapsed", TextVis = "Visible",
                    });
                }
                catch { }
            }
            return rows;
        }

        /// <summary>Add-SrcPath's row: "Drive X" for a root, the leaf otherwise.</summary>
        public static AppItem SrcPathRow(string path, int index)
        {
            var pt = path.TrimEnd('\\');
            var m = Regex.Match(pt, "^([A-Za-z]):$");
            var name = m.Success ? "Drive " + m.Groups[1].Value.ToUpperInvariant() : Path.GetFileName(pt);
            if (string.IsNullOrEmpty(name)) name = path;
            var isDrive = m.Success;
            return new AppItem
            {
                Id = "srcp-" + index, Name = name, Publisher = path, UnArgs = path, RegKey = isDrive ? "drive" : "folder",
                IconText = name.Substring(0, 1).ToUpperInvariant(), IconBg = isDrive ? "#FF2563EB" : "#FF34D399",
                IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0, GlyphVis = "Collapsed", TextVis = "Visible", IsSelected = true,
            };
        }

        public static AppItem ShareFolderRow(string path, int index)
        {
            var name = Path.GetFileName(path.TrimEnd('\\'));
            if (string.IsNullOrEmpty(name)) name = path;
            return new AppItem
            {
                Id = "shf-" + index, Name = name, Publisher = path, UnArgs = path, RegKey = "folder",
                IconText = name.Substring(0, 1).ToUpperInvariant(), IconBg = "#FF34D399", IconData = Catalog.IconMap["default"][0],
                RowOpacity = 1.0, GlyphVis = "Collapsed", TextVis = "Visible", IsSelected = true,
            };
        }
    }
}
