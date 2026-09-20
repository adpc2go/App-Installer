using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy.Models
{
    /// <summary>What Load-Catalog produces: the rows, the category rail, and one line per entry it refused.</summary>
    public sealed class CatalogLoad
    {
        public List<AppItem> Items = new List<AppItem>();
        public List<string> Categories = new List<string>();
        public List<string> Skipped = new List<string>();
        public Dictionary<string, object> Raw;
    }

    public static class Catalog
    {
        // key -> (glyph path, tile colour); the same table the script draws from
        public static readonly Dictionary<string, string[]> IconMap = new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            { "cad",     new[] { "M12,4 L20,20 L4,20 Z M12,12 L12,20", "#FFCE6A32" } },
            { "media",   new[] { "M9,5.5 L19,12 L9,18.5 Z", "#FF8B5CF6" } },
            { "archive", new[] { "M4,8 L12,4 L20,8 L20,16 L12,20 L4,16 Z M4,8 L12,12 L20,8 M12,12 L12,20", "#FF14B8A6" } },
            { "office",  new[] { "M7,3 L14,3 L18,7 L18,21 L7,21 Z M14,3 L14,7 L18,7", "#FF3B82F6" } },
            { "dev",     new[] { "M9,7 L4,12 L9,17 M15,7 L20,12 L15,17", "#FF22C55E" } },
            { "net",     new[] { "M12,3 A9,9 0 1 1 11.99,3 M3.8,9 L20.2,9 M3.8,15 L20.2,15 M12,3 C8,8.5 8,15.5 12,21 M12,3 C16,8.5 16,15.5 12,21", "#FF0EA5E9" } },
            { "photo",   new[] { "M4,8 L8,8 L10,5 L14,5 L16,8 L20,8 L20,19 L4,19 Z M12,10.5 A3,3 0 1 1 11.99,10.5", "#FF31A8FF" } },
            { "design",  new[] { "M12,3 L15,10 L12,21 L9,10 Z M9,10 L15,10", "#FFFF9A00" } },
            { "video",   new[] { "M4,5 L20,5 L20,19 L4,19 Z M8,5 L8,19 M16,5 L16,19 M4,9.5 L8,9.5 M4,14.5 L8,14.5 M16,9.5 L20,9.5 M16,14.5 L20,14.5", "#FF9999FF" } },
            { "tweak",   new[] { "M4,7 L20,7 M4,12 L20,12 M4,17 L20,17 M9,7 A2,2 0 1 1 8.99,7 M15,12 A2,2 0 1 1 14.99,12 M8,17 A2,2 0 1 1 7.99,17", "#FF2563EB" } },
            { "default", new[] { "M4,4 L10,4 L10,10 L4,10 Z M14,4 L20,4 L20,10 L14,10 Z M4,14 L10,14 L10,20 L4,20 Z M14,14 L20,14 L20,20 L14,20 Z", "#FF64748B" } },
        };

        /// <summary>
        /// The script's Load-Catalog, rule for rule: one bad entry costs that entry, not the tab;
        /// an uninstall-only entry never becomes a row; the first of two ids wins.
        /// </summary>
        public static CatalogLoad Parse(string json)
        {
            var load = new CatalogLoad();
            var root = Json.ParseObject(json);
            if (root == null) throw new InvalidDataException("the catalog is not a JSON object");
            load.Raw = root;
            var apps = Json.Arr(root, "apps");
            if (apps.Length == 0) throw new InvalidDataException("the catalog has no apps array");

            foreach (var c in Json.Arr(root, "categories"))
            {
                var name = (c as string ?? "").Trim();
                if (name.Length > 0 && !load.Categories.Contains(name)) load.Categories.Add(name);
            }

            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var o in apps)
            {
                var a = o as Dictionary<string, object>;
                if (a == null) continue;
                if (Json.Bool(a, "uninstallOnly")) continue;
                var id = Json.Str(a, "id").Trim();
                var url = Json.Str(a, "url");
                var sha = Json.Str(a, "sha256");
                var name = Json.Str(a, "name");
                string why = null;
                if (id.Length == 0) why = "no id";
                else if (seen.Contains(id)) why = "duplicate id '" + id + "' - the first entry wins";
                else if (url.Trim().Length == 0) why = "no url";
                else if (!Regex.IsMatch(url, "^(?i)(https?|file)://")) why = "url is not http(s):// or file:// (" + url + ")";
                else if (!Regex.IsMatch(sha, "^(?i)[0-9a-f]{64}$")) why = "sha256 is missing or is not 64 hex characters";
                if (why != null)
                {
                    load.Skipped.Add((name.Length > 0 ? name : (id.Length > 0 ? id : "(unnamed)")) + ": " + why);
                    continue;
                }
                seen.Add(id);
                var item = new AppItem
                {
                    Id = id,
                    Name = name.Length > 0 ? name : id,
                    Version = Json.Str(a, "version"),
                    Url = url,
                    Sha256 = sha.ToUpperInvariant(),
                    SilentArgs = Json.Str(a, "silentArgs"),
                    Entry = Json.Str(a, "entry"),
                    Instructions = Json.Str(a, "instructions"),
                    VerifyPaths = Json.Strings(a, "verifyPaths"),
                    SizeBytes = Json.Long(a, "sizeBytes"),
                    InstallTimeoutSec = (int)Json.Long(a, "installTimeoutSec"),
                    AllowUi = Json.Bool(a, "allowUi"),
                    SilentSource = Json.Str(a, "silentSource"),
                    Requires = Json.Strings(a, "requires"),
                    PostInstall = Json.Arr(a, "postInstall"),
                    Publisher = Json.Str(a, "publisher"),
                };
                item.Size = Format.Size(item.SizeBytes);
                item.FileName = FileNameOf(url);
                if (string.IsNullOrEmpty(item.FileName)) item.FileName = SafeId(id) + ".bin";
                var inst = a.ContainsKey("installer") ? a["installer"] as Dictionary<string, object> : null;
                item.InstallerFamily = inst != null ? Json.Str(inst, "family") : "";
                var un = a.ContainsKey("uninstall") ? a["uninstall"] as Dictionary<string, object> : null;
                if (un != null) item.DetectPath = Json.Str(un, "detect");
                var cat = Json.Str(a, "category");
                if (cat.Length == 0) cat = item.Publisher;
                if (string.IsNullOrEmpty(cat)) cat = "Apps";
                item.Category = cat;
                var iconKey = Json.Str(a, "icon");
                if (!IconMap.ContainsKey(iconKey)) iconKey = "default";
                item.IconData = IconMap[iconKey][0];
                item.IconBg = IconMap[iconKey][1];
                var iconColor = Json.Str(a, "iconColor");
                if (iconColor.Length > 0) item.IconBg = iconColor;
                var iconText = Json.Str(a, "iconText");
                if (iconText.Length > 0) { item.IconText = iconText; item.TextVis = "Visible"; item.GlyphVis = "Collapsed"; }
                item.IconUrl = Json.Str(a, "iconUrl");
                load.Items.Add(item);
            }

            // The rail order is the catalog's categories list; a category that owns rows but is
            // missing from the list is appended, never dropped - the editor keeps them in step and
            // this is the same rule. Rows inside a category keep catalog order: it IS the install
            // order (Civil 3D onto AutoCAD), and it never reorders.
            foreach (var it in load.Items)
                if (!load.Categories.Contains(it.Category)) load.Categories.Add(it.Category);
            var rank = new Dictionary<string, int>(StringComparer.Ordinal);
            for (int i = 0; i < load.Categories.Count; i++) rank[load.Categories[i]] = i;
            load.Items = load.Items.Select((it, i) => new { it, i })
                                   .OrderBy(x => rank[x.it.Category]).ThenBy(x => x.i)
                                   .Select(x => x.it).ToList();
            return load;
        }

        public static string FileNameOf(string url)
        {
            try { return Path.GetFileName(new Uri(url).LocalPath); } catch { return ""; }
        }

        // ids come from the catalogue, so they are tame, but they become folder names that are
        // created and deleted recursively - the same rule as the script's Get-SafeId
        public static string SafeId(string id)
        {
            var safe = Regex.Replace(id ?? "", "[^A-Za-z0-9._-]", "_").Trim('.');
            return safe.Length > 0 ? safe : "unknown";
        }
    }
}
