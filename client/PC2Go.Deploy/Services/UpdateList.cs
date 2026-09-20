using System;
using System.Collections.Generic;
using System.Linq;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>The reader's winget answer: where winget is, what it could not parse, and the rows.</summary>
    public sealed class WingetLoad
    {
        public string WingetPath = "";
        public List<string> Notes = new List<string>();
        public List<AppItem> Rows = new List<AppItem>();
        public int StoreRowsSkipped;   // msstore-sourced rows belong to the Store sub-tab
        public int Matched;            // rows that are programs on the Uninstall tab
    }

    /// <summary>Load-Updates, Load-StoreList and Load-WinUpdates: the reader's rows become the Update tab's rows.</summary>
    public static class UpdateList
    {
        public const string CatDesktop = "Desktop programs";
        public const string CatStorePkg = "Microsoft Store packages winget can update";
        public const string CatOther = "Other: components and runtimes  (no matching desktop program)";
        public const string CatStoreList = "Installed Microsoft Store apps";
        public const string CatWinOpt = "Optional updates  (what Settings > Optional updates lists - Windows leaves these to you)";
        public const string CatWinRec = "Recommended updates  (Windows would install these on its own)";

        public static WingetLoad Winget(string json)
        {
            var load = new WingetLoad();
            var root = Json.ParseObject(json);
            if (root == null) return load;
            load.WingetPath = Json.Str(root, "winget");
            load.Notes = Json.Strings(root, "notes").ToList();
            foreach (var o in Json.Arr(root, "rows"))
            {
                var r = o as Dictionary<string, object>;
                if (r == null) continue;
                var source = Json.Str(r, "Source");
                if (source == "msstore") { load.StoreRowsSkipped++; continue; }
                var version = Json.Str(r, "Version");
                var available = Json.Str(r, "Available");
                var wid = Json.Str(r, "Id");
                var explicitRow = Json.Bool(r, "Explicit");
                var u = new AppItem
                {
                    Id = Json.Str(r, "RowId"), Name = Json.Str(r, "Name"), Publisher = "winget: " + wid, Version = version,
                    DetectPath = available, UnArgs = wid, Source = source.Length > 0 ? source : "winget",
                    Size = version + " " + '→' + " " + available,
                    RowOpacity = 1.0, IconData = "", GlyphVis = "Collapsed", IconBg = "#00000000",
                    IsSilent = !explicitRow, Category = CatOther,
                };
                u.ColInstalled = version; u.ColSize = available;
                u.TagText = version == "Unknown" ? "version unknown to winget" : (explicitRow ? "needs explicit targeting" : "");
                u.TagVis = u.TagText.Length > 0 ? "Visible" : "Collapsed";
                var m = r.ContainsKey("Match") ? r["Match"] as Dictionary<string, object> : null;
                var sm = r.ContainsKey("StoreMatch") ? r["StoreMatch"] as Dictionary<string, object> : null;
                if (m != null)
                {
                    load.Matched++;
                    var pub = Json.Str(m, "Publisher");
                    if (pub.Length > 0) u.Publisher = pub + "   |   winget: " + wid;
                    u.Category = CatDesktop;
                    u.IconSources = new[] { Json.Str(m, "Icon"), Json.Str(m, "Exe") }.Where(s => s.Length > 0).ToArray();
                }
                else if (sm != null)
                {
                    u.Category = CatStorePkg;
                    var pub = Json.Str(sm, "Publisher");
                    if (pub.Length > 0) u.Publisher = pub + "   |   winget: " + wid;
                    u.StoreLocation = Json.Str(sm, "Location"); u.StoreLogo = Json.Str(sm, "Logo");
                }
                if (version == "Unknown") { u.StatusDetail = u.Status = "installed version unknown to winget - updated to the listed version regardless"; u.StatusFg = BatchPlan.StatusPalette["neutral"]; }
                else if (explicitRow) { u.StatusDetail = u.Status = "winget lists this as needing explicit targeting (pinned or side-by-side) - updated by id"; u.StatusFg = BatchPlan.StatusPalette["neutral"]; }
                load.Rows.Add(u);
            }
            return load;
        }

        /// <summary>The words under the pills for the winget list.</summary>
        public static string WingetHint(WingetLoad load)
        {
            var hint = Format.Count(load.Rows.Count, "update", "updates") + " available";
            if (load.Rows.Count > 0) hint += " - " + load.Matched + " of them are programs on the Uninstall tab, the rest are components, runtimes or Store packages";
            if (load.StoreRowsSkipped > 0) hint += "   |   " + Format.Count(load.StoreRowsSkipped, "Store app", "Store apps") + " with updates too - see the Microsoft Store apps sub-tab";
            if (load.Notes.Count > 0) hint += "   |   " + string.Join("; ", load.Notes);
            return hint;
        }

        public static List<AppItem> StoreRows(string json)
        {
            var items = new List<AppItem>();
            foreach (var s in UninstallList.StoreRows(json))
            {
                s.Id = "updx-" + s.UnArgs;
                s.ColInstalled = s.Version ?? "";
                s.UnCommand = null;
                s.Category = CatStoreList;
                s.RowOpacity = 1.0; s.IconData = ""; s.GlyphVis = "Collapsed"; s.IconBg = "#00000000";
                items.Add(s);
            }
            return items;
        }

        public sealed class WinLoad { public List<AppItem> Rows = new List<AppItem>(); public int Rec, Opt, Drv, Reb; }

        public static WinLoad WindowsUpdates(string json)
        {
            var load = new WinLoad();
            var parsed = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject((json ?? "").TrimStart('﻿'));
            var rows = new List<Dictionary<string, object>>();
            foreach (var o in (parsed as object[]) ?? new object[0]) { var d = o as Dictionary<string, object>; if (d != null) rows.Add(d); }
            var built = new List<KeyValuePair<bool, AppItem>>();
            foreach (var w in rows)
            {
                // Optional the way Settings means it: browse-only, or anything Windows would not select on its own
                var opt = Json.Bool(w, "Optional") || !Json.Bool(w, "AutoSelect") || Json.Long(w, "Deployment") == 4;
                var size = Json.Long(w, "Size");
                var reboot = Json.Bool(w, "Reboot");
                var driver = Json.Bool(w, "Driver");
                var kb = Json.Str(w, "KB"); var cat = Json.Str(w, "Category");
                var u = new AppItem
                {
                    Id = Json.Str(w, "RowId"), Name = Json.Str(w, "Title"),
                    Publisher = string.Join("   ", new[] { kb, cat }.Where(x => x.Length > 0)),
                    Version = Json.Long(w, "Rev").ToString(), UnCommand = "winupdate", UnArgs = Json.Str(w, "Id"), DetectPath = kb,
                    SizeBytes = size, Source = "Windows", Size = size > 0 ? Format.Size(size) : "",
                    RowOpacity = 1.0, IconData = "", GlyphVis = "Collapsed", IconBg = "#00000000",
                    Category = opt ? CatWinOpt : CatWinRec, IsSilent = !opt,
                };
                u.ColInstalled = size > 0 ? Format.Size(size) : "-";
                u.ColSize = reboot ? "restart needed" : "";
                u.TagText = driver ? "driver" : (opt ? "optional" : "");
                u.TagVis = u.TagText.Length > 0 ? "Visible" : "Collapsed";
                if (opt) load.Opt++; else load.Rec++;
                if (driver) load.Drv++;
                if (reboot) load.Reb++;
                built.Add(new KeyValuePair<bool, AppItem>(opt, u));
            }
            load.Rows = built.OrderBy(b => b.Key).ThenBy(b => b.Value.Name, StringComparer.CurrentCultureIgnoreCase).Select(b => b.Value).ToList();
            return load;
        }

        public static string WindowsHint(WinLoad load)
        {
            var hint = Format.Count(load.Rows.Count, "Windows update", "Windows updates") + " waiting - " + load.Rec + " recommended, " + load.Opt + " optional";
            if (load.Drv > 0) hint += " (" + Format.Count(load.Drv, "driver", "drivers") + ")";
            if (load.Reb > 0) hint += "   |   " + load.Reb + " need a restart to finish";
            return hint;
        }
    }
}
