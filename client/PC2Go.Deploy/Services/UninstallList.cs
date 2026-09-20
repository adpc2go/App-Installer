using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// Refresh-UnList and Refresh-UnStore: the reader's rows become Uninstall rows, and a catalog
    /// entry of the same name - when its detect target is really here - lends the row its vendor
    /// uninstaller and its cleanup knowledge. ONE list: what is registered on this machine.
    /// </summary>
    public static class UninstallList
    {
        public const string DesktopCategory = "Desktop programs  (Control Panel)";
        public const string StoreCategory = "Microsoft Store apps  (Settings > Installed apps)";

        public static List<AppItem> DesktopRows(string readerJson, Dictionary<string, object> catalogRaw)
        {
            var rows = ParseRows(readerJson);
            // the catalog's uninstall knowledge, keyed by the exact lower-cased name
            var byName = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
            if (catalogRaw != null)
            {
                foreach (var o in Json.Arr(catalogRaw, "apps"))
                {
                    var a = o as Dictionary<string, object>;
                    if (a == null) continue;
                    var un = a.ContainsKey("uninstall") ? a["uninstall"] as Dictionary<string, object> : null;
                    var name = Json.Str(a, "name");
                    if (un == null || name.Length == 0) continue;
                    var detect = Json.Str(un, "detect");
                    if (detect.Length == 0) { var vp = Json.Strings(a, "verifyPaths"); if (vp.Length > 0) detect = vp[0]; }
                    if (detect.Length == 0) continue;
                    if (!byName.ContainsKey(name.ToLowerInvariant())) byName[name.ToLowerInvariant()] = a;
                }
            }

            var items = new List<AppItem>();
            foreach (var r in rows)
            {
                var sizeKb = Json.Long(r, "SizeKB");
                var silent = Json.Bool(r, "Silent");
                var family = Json.Str(r, "Family");
                var location = Json.Str(r, "Location");
                var regKey = Json.Str(r, "RegKey");
                var u = new AppItem
                {
                    Id = Json.Str(r, "Id"), Name = Json.Str(r, "Name"), Version = Json.Str(r, "Version"), Publisher = Json.Str(r, "Publisher"),
                    Size = sizeKb > 0 ? Format.Size(sizeKb * 1024) : "", SizeBytes = sizeKb * 1024,
                    UnCommand = Json.Str(r, "Exe"), UnArgs = Json.Str(r, "Args"), DetectPath = regKey, RegKey = regKey,
                    IsSilent = silent, UnFamily = family,
                    Source = family.Length > 0 ? "Silent uninstall (" + Json.Str(r, "FamilyLabel") + ")" : (silent ? "Silent uninstall" : "Shows installer UI"),
                    Category = DesktopCategory,
                    IconData = Catalog.IconMap["default"][0],
                    IconBg = silent ? "#FF64748B" : "#FF8A6A32",
                    CleanPaths = location.Length > 0 ? new[] { location } : new string[0],
                    CleanReg = regKey.Length > 0 ? new[] { regKey } : new string[0],
                    CleanTokens = Json.Strings(r, "CleanTokens"),
                    CleanHosts = new string[0],
                    IconSources = Json.Strings(r, "IconSources"),
                };
                var inst = Json.Str(r, "Installed");
                DateTime d;
                if (inst.Length > 0 && DateTime.TryParseExact(inst, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out d)) u.Installed = d;
                if (u.Name.Length == 0) u.Name = u.Id;

                Dictionary<string, object> cat;
                byName.TryGetValue(u.Name.ToLowerInvariant(), out cat);
                if (cat != null)
                {
                    var cun = cat["uninstall"] as Dictionary<string, object>;
                    var detect = Json.Str(cun, "detect");
                    if (detect.Length == 0) { var vp = Json.Strings(cat, "verifyPaths"); if (vp.Length > 0) detect = vp[0]; }
                    var present = detect.Length > 0 && BatchPlan.DetectPresent(detect);
                    if (present)
                    {
                        var vArgs = Json.Str(cun, "args");
                        var upgrade = true;
                        if (vArgs.Contains("__ODIS_MANIFEST__"))
                        {
                            var man = ResolveOdisManifest(u.Name, null);
                            if (man.Length > 0) vArgs = vArgs.Replace("__ODIS_MANIFEST__", man); else upgrade = false;
                        }
                        if (upgrade)
                        {
                            u.UnCommand = Json.Str(cun, "command");
                            u.UnArgs = vArgs;
                            u.DetectPath = detect;
                            u.IsSilent = true;
                            u.Source = "Vendor uninstaller";
                        }
                        var cleanup = cat.ContainsKey("cleanup") ? cat["cleanup"] as Dictionary<string, object> : null;
                        if (cleanup != null)
                        {
                            u.CleanPaths = Union(u.CleanPaths, Json.Strings(cleanup, "paths"));
                            u.CleanReg = Union(u.CleanReg, Json.Strings(cleanup, "registry"));
                            u.CleanTokens = Union(u.CleanTokens, Json.Strings(cleanup, "tokens"));
                            u.CleanHosts = Json.Strings(cleanup, "hosts");
                            u.Removers = Json.Arr(cleanup, "removers").Where(x => x != null).ToArray();
                        }
                    }
                }
                // An InstallLocation is a claim, not a curated target - a registry-only row was on
                // this machine before the batch, so nothing of it is pre-ticked for deletion.
                u.PreExisting = cat == null;
                items.Add(u);
            }
            return items;
        }

        public static List<AppItem> StoreRows(string readerJson)
        {
            var items = new List<AppItem>();
            foreach (var s in ParseRows(readerJson))
            {
                var full = Json.Str(s, "PackageFull");
                var isSystem = Json.Bool(s, "IsSystem");
                var u = new AppItem
                {
                    Id = "appx-" + full, Name = Json.Str(s, "Name"), Version = Json.Str(s, "Version"), Publisher = Json.Str(s, "Publisher"),
                    Size = "", SizeBytes = 0,
                    UnCommand = "appx", UnArgs = full, DetectPath = "", IsSilent = true,
                    Source = isSystem ? "Store app (system)" : "Store app",
                    Category = StoreCategory,
                    IconData = Catalog.IconMap["default"][0], IconBg = "#FF7A5CFF",
                    CleanPaths = new string[0], CleanReg = new string[0], CleanTokens = new string[0], CleanHosts = new string[0],
                    StoreLocation = Json.Str(s, "Location"), StoreLogo = Json.Str(s, "Logo"),
                    PreExisting = true,
                };
                items.Add(u);
            }
            return items;
        }

        private static List<Dictionary<string, object>> ParseRows(string json)
        {
            var list = new List<Dictionary<string, object>>();
            var text = (json ?? "").TrimStart('﻿', ' ', '\r', '\n', '\t');
            if (text.Length == 0) return list;
            var parsed = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(text);
            var arr = parsed as object[];
            if (arr == null) { var one = parsed as Dictionary<string, object>; if (one != null) list.Add(one); return list; }
            foreach (var o in arr) { var d = o as Dictionary<string, object>; if (d != null) list.Add(d); }
            return list;
        }

        private static string[] Union(string[] a, string[] b)
        {
            var seen = new List<string>();
            foreach (var s in (a ?? new string[0]).Concat(b ?? new string[0]))
                if (!string.IsNullOrEmpty(s) && !seen.Contains(s, StringComparer.Ordinal)) seen.Add(s);
            return seen.ToArray();
        }

        /// <summary>Resolve-OdisManifest: the Autodesk ODIS setup manifest that names this product.</summary>
        public static string ResolveOdisManifest(string productName, string root)
        {
            if (string.IsNullOrEmpty(root)) root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"Autodesk\ODIS\metadata");
            if (string.IsNullOrEmpty(productName) || !Directory.Exists(root)) return "";
            try
            {
                foreach (var dir in Directory.GetDirectories(root))
                    foreach (var mf in Directory.GetFiles(dir, "*setup.xml"))
                    {
                        try { if (Regex.IsMatch(File.ReadAllText(mf), Regex.Escape(productName))) return mf; } catch { }
                    }
            }
            catch { }
            return "";
        }

        /// <summary>Test-UnRowGone: a row whose detect target is already gone (unknown reads as "still here").</summary>
        public static bool RowGone(AppItem item)
        {
            var d = item.DetectPath ?? "";
            if (d.Length == 0) return false;
            try { return !BatchPlan.DetectPresent(d); } catch { return false; }
        }
    }
}
